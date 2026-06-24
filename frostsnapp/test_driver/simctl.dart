import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'regtest.dart';
import 'sim_harness.dart';

// simctl: interactively drive the running sim app + devices through the SAME SimHarness
// methods the keygen test uses — no second implementation that can drift.
//
//   simctl serve [--devices N]    launch the app + N devices ONCE, listen for commands
//   simctl <cmd> ...              run ONE command against the running daemon, exit
//
// Device commands take `--device N` (1-based, default 1) to pick which virtual device.
// By default `serve` hands the keyboard to a human (real typing works; `enter` does not);
// pass `--agent-owns-keyboard` to let the driver own text input instead (enables `enter`,
// blocks the physical keyboard). One mode for the session — no hybrid.
//
// `serve` holds a SimHarness and forwards each command to its methods over a control
// socket, so the app stays alive across commands: send one, see the result, try the
// next — a failed attempt is just followed by another command on the same live app
// (no relaunch). `test` runs the driver e2e tests. See `_usage` for commands. Run via the
// repo-root `./simctl` launcher (e.g. `./simctl serve`, `./simctl test keygen`).

String get _socketPath => '${simTmpRoot().path}/control.sock';

const _usage = '''
simctl — drive the running sim app/devices through SimHarness.
  simctl serve [--devices N] [--platform <d>] [--agent-owns-keyboard] [--no-regtest]   launch app + listen
                                              (regtest is ON by default; --no-regtest = offline sim)
  simctl up [serve flags]                     idempotently bring the sim up + return once ready
                                              (no backgrounding/polling; reuses a matching live
                                              daemon, refuses a mismatched one — `down` first)
  simctl info                                 print the running daemon's shape (count/regtest/keyboard)
  simctl test [NAME]                          run e2e driver test <NAME> (a *_drive.dart stem),
                                              or all of them with no NAME
  simctl regtest up|down|status               manage the shared regtest bitcoind+electrs+faucet
  simctl regtest fund <addr> <sats> | mine [n] | balance | height | address | url   drive the faucet
  simctl clean                                remove sim temp artifacts + reap any backend
                                              (no daemon running)
  simctl tap <label> [--regex]                tap a control by semantic label
  simctl tap-until <label> <expect> [--regex] [--regex-expect]
  simctl enter <label> <text> [--regex]       focus a field + type (agent-owns-keyboard only)
  simctl wait <label> [--regex]               wait for a label to appear
  simctl exists <label> [--regex]             report whether a label is present
  simctl clipboard                            print the app clipboard text (e.g. a copied address)
  simctl devices                              list each device (number/id/connected)
  simctl add-device                           add a device at runtime (joins the chain tail)
  simctl chain                                print the connected chain order
  simctl set-chain <n>...                     re-cable to exactly these devices, in order
  simctl connect <n>                          plug device n into the tail of the chain
  simctl disconnect <n>                       disconnect device n + everything downstream
  simctl move-up <n> / move-down <n>          reorder device n within the chain
  simctl hold <x> <y> [ms] [--device N]       device hold-to-confirm at a point
  simctl swipe <x1> <y1> <x2> <y2> [ms] [--device N]   device swipe
  simctl touch <x> <y> <down|up> [--device N]          device raw touch
  simctl set-connected <true|false> [--device N]       plug/unplug a device
  simctl screen <path> [--device N]           write the device framebuffer PNG
  simctl shot [path]                          whole-app screenshot (incl. tray)
  simctl down                                 tear down (quit app, clean up)
(--regex matches the label as a substring; default is exact. --device selects the
 virtual device, 1-based, default 1. `serve` gives the keyboard to a human unless
 --agent-owns-keyboard is passed, which the driver needs for `enter`.)''';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(_usage);
    exit(2);
  }
  if (args.first == 'serve') {
    await _serve(args.skip(1).toList());
  } else if (args.first == 'up') {
    await _up(args.skip(1).toList());
  } else if (args.first == 'test') {
    await _runTests(args.skip(1).toList());
  } else if (args.first == 'regtest') {
    await runRegtest(args.skip(1).toList());
  } else if (args.first == 'clean') {
    await _clean();
  } else {
    await _client(args);
  }
}

/// Remove all sim temp artifacts under the session root (disposable app dirs, screenshots, a
/// stopped backend's files) and reap any running regtest backend — for clearing residue left by
/// a killed session. Refuses while a serve daemon is live so it can't nuke an active session;
/// `./simctl down` first.
Future<void> _clean() async {
  if (await _daemonAlive()) {
    stderr.writeln(
      'simctl: a serve daemon is running — run `./simctl down` first',
    );
    exit(1);
  }
  await stopRegtestBackend();
  final root = simTmpRoot();
  if (await root.exists()) await root.delete(recursive: true);
  stdout.writeln(jsonEncode({'ok': true, 'cleaned': root.path}));
}

/// Whether a `serve` daemon is listening on the control socket.
Future<bool> _daemonAlive() async {
  try {
    final socket = await Socket.connect(
      InternetAddress(_socketPath, type: InternetAddressType.unix),
      0,
    ).timeout(const Duration(seconds: 1));
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

// ---- up: one idempotent command that brings the sim up and returns only once ready ----

/// `simctl up [serve flags]` — idempotent bring-up. If a live daemon already matches the requested
/// shape (device count, regtest, keyboard mode) it's a no-op (`already:true`); on a MISMATCH it
/// refuses with a clear "down first" error rather than reporting a wrong daemon ready; otherwise it
/// launches `serve` DETACHED (which self-logs) and returns only once the control socket is live. The
/// whole point: one command, no backgrounding or readiness polling by the caller.
Future<void> _up(List<String> args) async {
  var count = 1;
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--devices') count = int.parse(args[i + 1]);
  }
  // The shape `serve` WOULD launch — mirror its `withRegtest = !--no-regtest` so the exact
  // compatibility check below stays consistent with what a fresh launch actually produces.
  // Regtest is ON by default (the common case is a wallet that can receive); --no-regtest opts out.
  final wantRegtest = !args.contains('--no-regtest');
  final wantKeyboard = args.contains('--agent-owns-keyboard');

  if (await _daemonAlive()) {
    final info = await _query({'cmd': 'info'});
    final live = (
      count: info['count'] as int,
      regtest: info['regtest'] as bool,
      keyboard: info['keyboard'] as bool,
    );
    // Compatible iff the EXACT recorded shape matches the requested shape (what serve would launch)
    // — same device count, keyboard mode, AND regtest on/off. A real mismatch fails (down first).
    final compatible =
        live.count == count &&
        live.keyboard == wantKeyboard &&
        live.regtest == wantRegtest;
    if (compatible) {
      stdout.writeln(
        jsonEncode({'ok': true, 'already': true, 'socket': _socketPath}),
      );
      exit(0);
    }
    stderr.writeln(
      jsonEncode({
        'ok': false,
        'error':
            'a different-shape sim daemon is already running '
            '(count=${live.count}, regtest=${live.regtest}, agentOwnsKeyboard=${live.keyboard}); '
            'run `./simctl down` first',
      }),
    );
    exit(1);
  }

  // No daemon: launch `serve` detached via the repo-root launcher (which runs `just maybe-gen`
  // first, then self-logs), and wait for the control socket to come live.
  simTmpRoot(); // ensure the session dir exists for the self-log
  final launcher = '${Directory.current.parent.path}/simctl';
  final serve = await Process.start(launcher, [
    'serve',
    ...args,
  ], mode: ProcessStartMode.detached);

  final deadline = DateTime.now().add(const Duration(minutes: 6));
  while (!await _daemonAlive()) {
    if (DateTime.now().isAfter(deadline)) {
      stderr.writeln(
        jsonEncode({
          'ok': false,
          'error':
              'sim daemon did not come up within 6 minutes '
              '(see ${simTmpRoot().path}/serve.log)',
        }),
      );
      exit(1);
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  stdout.writeln(
    jsonEncode({
      'ok': true,
      'started': true,
      'pid': serve.pid,
      'socket': _socketPath,
    }),
  );
  exit(0);
}

/// Connect to the live daemon, send one command, return its decoded reply (does NOT exit — used by
/// `up` to query daemon `info`, unlike `_client` which prints + exits).
Future<Map<String, dynamic>> _query(Map<String, dynamic> req) async {
  final socket = await Socket.connect(
    InternetAddress(_socketPath, type: InternetAddressType.unix),
    0,
  );
  socket.write('${jsonEncode(req)}\n');
  await socket.flush();
  final reply = await socket
      .cast<List<int>>()
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .firstWhere((l) => l.trim().isNotEmpty);
  await socket.close();
  return jsonDecode(reply) as Map<String, dynamic>;
}

// ---- test runner: run the driver e2e tests (test_driver/*_drive.dart) ----

/// Run one driver test by its file STEM (`<stem>_drive.dart`), or all of them with no arg.
/// Each runs as its own `dart run` so they get a fresh app/harness; a non-zero exit from any
/// fails the whole run. Replaces the per-test justfile recipes — a new test is just a new
/// `*_drive.dart` file, discovered here automatically.
Future<void> _runTests(List<String> args) async {
  final stems = <String, String>{}; // stem -> filename
  for (final entry in Directory('test_driver').listSync()) {
    final name = entry.uri.pathSegments.last;
    if (entry is File && name.endsWith('_drive.dart')) {
      stems[name.substring(0, name.length - '_drive.dart'.length)] = name;
    }
  }
  final available = stems.keys.toList()..sort();

  final List<String> files;
  if (args.isEmpty) {
    files = available.map((s) => stems[s]!).toList();
  } else {
    final file = stems[args.first];
    if (file == null) {
      stderr.writeln(
        'simctl test: no test "${args.first}". Available: ${available.join(', ')}',
      );
      exit(2);
    }
    files = [file];
  }

  final failed = <String>[];
  for (final file in files) {
    stdout.writeln('=== simctl test: $file ===');
    final proc = await Process.start('dart', [
      'run',
      'test_driver/$file',
    ], mode: ProcessStartMode.inheritStdio);
    if (await proc.exitCode != 0) failed.add(file);
  }

  if (files.length > 1) {
    stdout.writeln(
      '=== simctl test: ${files.length - failed.length}/${files.length} passed'
      '${failed.isEmpty ? '' : ' — FAILED: ${failed.join(', ')}'} ===',
    );
  }
  exit(failed.isEmpty ? 0 : 1);
}

// ---- daemon: holds one SimHarness, forwards commands to it ----

Future<void> _serve(List<String> args) async {
  var platform = 'macos';
  var count = 1;
  // Default: a human owns the keyboard (real typing works, `enter` is rejected). Pass
  // --agent-owns-keyboard for the driver to own text input instead (enables `enter`,
  // blocks the physical keyboard). One mode for the session — no hybrid.
  final agentOwnsKeyboard = args.contains('--agent-owns-keyboard');
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--platform') platform = args[i + 1];
    if (args[i] == '--devices') count = int.parse(args[i + 1]);
  }

  // Spawn (or attach to) the regtest faucet by default so the wallet can receive; `--no-regtest`
  // keeps the sim offline (no bitcoind/electrs).
  final withRegtest = !args.contains('--no-regtest');

  // SELF-LOG: mirror our + the app's output to the session logfile, so a detached `up`-launched
  // daemon still produces a readable log without the caller redirecting stdout. `simTmpRoot()`
  // (re)creates the session dir, so the file can't be orphaned by an earlier teardown.
  final logSink = File('${simTmpRoot().path}/serve.log').openWrite();
  final flushTimer = Timer.periodic(
    const Duration(seconds: 1),
    (_) => unawaited(logSink.flush()),
  );

  final harness = await SimHarness.launch(
    deviceCount: count,
    flutterDevice: platform,
    agentOwnsKeyboard: agentOwnsKeyboard,
    withRegtest: withRegtest,
    logSink: logSink,
  );

  try {
    File(_socketPath).deleteSync();
  } catch (_) {}
  final server = await ServerSocket.bind(
    InternetAddress(_socketPath, type: InternetAddressType.unix),
    0,
  );
  stdout.writeln('SIMCTL_READY $_socketPath');
  logSink.writeln('SIMCTL_READY $_socketPath');

  // Idempotent AND awaitable: `down`, a signal, and the app-death watcher can all race in here;
  // they share ONE cleanup future, so EVERY caller awaits the same cleanup to FINISH before its
  // exit(0) runs. (A bare boolean guard would let a second caller return + exit mid-cleanup,
  // killing the process before the first's app-dir delete / log flush completed.)
  Future<void>? shutdownFuture;
  Future<void> shutdown() {
    return shutdownFuture ??= () async {
      flushTimer.cancel();
      await server.close();
      try {
        File(_socketPath).deleteSync();
      } catch (_) {}
      await harness.tearDown();
      await logSink.flush();
      await logSink.close();
    }();
  }

  for (final sig in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    sig.watch().listen((_) async {
      await shutdown();
      exit(0);
    });
  }

  // The daemon must not outlive its app: if the app dies (e.g. you close its window — the last
  // window closing terminates it and exits `flutter run`), shut down so the control socket goes
  // away and `./simctl up` RELAUNCHES instead of reporting already:true. (The captured app output
  // already logs the app finishing; awaiting shutdown() shares the one cleanup before exit.)
  unawaited(
    harness.appExitCode.then((_) async {
      await shutdown();
      exit(0);
    }),
  );

  await for (final conn in server) {
    final lines = conn
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      if (line.trim().isEmpty) continue;
      final (reply, down) = await _dispatch(
        line,
        harness,
        agentOwnsKeyboard,
        withRegtest,
        count,
      );
      conn.write('${jsonEncode(reply)}\n');
      await conn.flush();
      if (down) {
        await conn.close();
        await shutdown();
        exit(0);
      }
    }
  }
}

/// Forward one command to a [SimHarness] method. Returns the reply and whether to shut
/// down. A failing command returns `{ok:false,error}` but keeps the daemon (and the
/// app) alive, so the next command can try something else.
Future<(Map<String, dynamic>, bool)> _dispatch(
  String line,
  SimHarness h,
  bool agentOwnsKeyboard,
  bool withRegtest,
  int launchDeviceCount,
) async {
  final Map<String, dynamic> req;
  try {
    req = jsonDecode(line) as Map<String, dynamic>;
  } catch (e) {
    return ({'ok': false, 'error': 'bad json: $e'}, false);
  }
  Pattern pat(String key, String flag) =>
      req[flag] == true ? RegExp(req[key] as String) : req[key] as String;
  // Which virtual device a device-command targets (1-based, default 1).
  final dn = (req['device'] as int?) ?? 1;

  // The fleet can GROW behind the daemon's back — the tray + button adds devices the daemon
  // never issued — so before any command that reports or indexes devices, reconcile the
  // harness channel cache with the app-side fleet. Otherwise device(n) for a tray-added n would
  // be missing/misindexed. App-channel-only commands (tap/wait/…) don't touch the fleet.
  const fleetCmds = {
    'info',
    'devices',
    'chain',
    'setChain',
    'connect',
    'disconnect',
    'moveUp',
    'moveDown',
    'hold',
    'swipe',
    'touch',
    'setConnected',
    'screen',
  };
  try {
    if (fleetCmds.contains(req['cmd'])) await h.ensureDevices();
    switch (req['cmd']) {
      case 'tap':
        await h.tap(pat('label', 'regex'));
        return ({'ok': true}, false);
      case 'tapUntil':
        await h.tapUntil(pat('label', 'regex'), pat('expect', 'regexExpect'));
        return ({'ok': true}, false);
      case 'enter':
        if (!agentOwnsKeyboard) {
          return (
            {
              'ok': false,
              'error':
                  'enter is unavailable when a human owns the keyboard; type into the '
                  'app directly, or relaunch with `./simctl serve --agent-owns-keyboard`',
            },
            false,
          );
        }
        await h.enterText(pat('label', 'regex'), req['text'] as String);
        return ({'ok': true}, false);
      case 'wait':
        await h.waitFor(pat('label', 'regex'));
        return ({'ok': true}, false);
      case 'exists':
        return (
          {'ok': true, 'exists': await h.exists(pat('label', 'regex'))},
          false,
        );
      case 'clipboard':
        return ({'ok': true, 'text': await h.getClipboard()}, false);
      case 'info':
        // The daemon's LAUNCH shape — `./simctl up` compares `count` against the requested
        // --devices to decide whether an already-live daemon satisfies the request. It's the
        // launch count, NOT the live count, so runtime adds (tray / add-device) don't flip
        // idempotence. `currentDevices` reports the live (resynced) fleet for introspection.
        return (
          {
            'ok': true,
            'count': launchDeviceCount,
            'currentDevices': h.devices.length,
            'regtest': withRegtest,
            'keyboard': agentOwnsKeyboard,
          },
          false,
        );
      case 'addDevice':
        return ({'ok': true, 'device': await h.addDevice()}, false);
      case 'devices':
        final list = <Map<String, dynamic>>[];
        for (var n = 1; n <= h.devices.length; n++) {
          list.add({
            'number': n,
            'id': await h.device(n).deviceId(),
            'connected': await h.device(n).isConnected(),
          });
        }
        return ({'ok': true, 'devices': list}, false);
      case 'chain':
        return ({'ok': true, 'chain': await h.chain()}, false);
      case 'setChain':
        await h.setChain((req['order'] as List).cast<int>());
        return ({'ok': true}, false);
      case 'connect':
        await h.connect(req['device'] as int);
        return ({'ok': true}, false);
      case 'disconnect':
        await h.disconnect(req['device'] as int);
        return ({'ok': true}, false);
      case 'moveUp':
        await h.moveUp(req['device'] as int);
        return ({'ok': true}, false);
      case 'moveDown':
        await h.moveDown(req['device'] as int);
        return ({'ok': true}, false);
      case 'hold':
        final ms = req['ms'] as int?;
        await h
            .device(dn)
            .holdConfirm(
              req['x'] as int,
              req['y'] as int,
              ms != null
                  ? Duration(milliseconds: ms)
                  : const Duration(milliseconds: 2600),
            );
        return ({'ok': true}, false);
      case 'swipe':
        await h
            .device(dn)
            .swipe(
              req['x1'] as int,
              req['y1'] as int,
              req['x2'] as int,
              req['y2'] as int,
              Duration(milliseconds: (req['ms'] as int?) ?? 300),
            );
        return ({'ok': true}, false);
      case 'touch':
        await h
            .device(dn)
            .touch(
              req['x'] as int,
              req['y'] as int,
              liftUp: req['liftUp'] as bool,
            );
        return ({'ok': true}, false);
      case 'setConnected':
        await h.device(dn).setConnected(req['connected'] as bool);
        return ({'ok': true}, false);
      case 'screen':
        await h.device(dn).screen(req['path'] as String);
        return ({'ok': true, 'path': req['path']}, false);
      case 'shot':
        // No path -> the session dir (cleaned up on teardown); an explicit path is kept.
        final reqPath = req['path'] as String?;
        final path = reqPath == null
            ? await h.screenshot('manual')
            : await h.screenshot('manual', keep: reqPath);
        return ({'ok': true, 'path': path}, false);
      case 'down':
        return ({'ok': true, 'down': true}, true);
      default:
        return ({'ok': false, 'error': 'unknown cmd: ${req['cmd']}'}, false);
    }
  } catch (e) {
    return ({'ok': false, 'error': '$e'}, false);
  }
}

// ---- client: run one command against the running daemon ----

/// Connect to the daemon, waiting for it to come up rather than failing instantly:
/// `./simctl serve` builds + launches the app (cold builds take a while), so a `./simctl <cmd>`
/// fired right after should just block until the control socket is ready — no external
/// "wait for SIMCTL_READY" polling. Retries until [SIMCTL_WAIT_SECS] (default 300s), then
/// gives up so a genuine missing-daemon mistake still errors. Announces once so a wait is
/// visible, not a silent hang.
Future<Socket> _connectWaiting() async {
  final addr = InternetAddress(_socketPath, type: InternetAddressType.unix);
  final waitSecs =
      int.tryParse(Platform.environment['SIMCTL_WAIT_SECS'] ?? '') ?? 300;
  final deadline = DateTime.now().add(Duration(seconds: waitSecs));
  var announced = false;
  while (true) {
    try {
      return await Socket.connect(addr, 0);
    } on SocketException {
      if (DateTime.now().isAfter(deadline)) rethrow;
      if (!announced) {
        stderr.writeln('simctl: waiting for the sim daemon to come up …');
        announced = true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }
}

Future<void> _client(List<String> args) async {
  final req = _argsToCommand(args);
  if (req == null) {
    stderr.writeln(_usage);
    exit(2);
  }
  final Socket socket;
  try {
    socket = await _connectWaiting();
  } catch (e) {
    stderr.writeln(
      'simctl: no daemon at $_socketPath (run `simctl serve`): $e',
    );
    exit(1);
  }
  socket.write('${jsonEncode(req)}\n');
  await socket.flush();
  final reply = await socket
      .cast<List<int>>()
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .firstWhere((l) => l.trim().isNotEmpty);
  await socket.close();
  stdout.writeln(reply);
  exit((jsonDecode(reply) as Map<String, dynamic>)['ok'] == true ? 0 : 1);
}

/// Translate `simctl <cmd> ...` argv into the wire command, or null if unrecognized.
Map<String, dynamic>? _argsToCommand(List<String> args) {
  // Pull the valued option `--device <n>` (the virtual-device selector) out before
  // positional parsing, so its value isn't mistaken for a positional argument.
  var device = 1;
  final rest = <String>[];
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--device' && i + 1 < args.length) {
      device = int.parse(args[i + 1]);
      i++;
    } else {
      rest.add(args[i]);
    }
  }
  bool flag(String f) => rest.contains(f);
  final pos = rest.where((a) => !a.startsWith('--')).toList();
  if (pos.isEmpty) return null;
  switch (pos.first) {
    case 'tap':
      return {'cmd': 'tap', 'label': pos[1], 'regex': flag('--regex')};
    case 'tap-until':
      return {
        'cmd': 'tapUntil',
        'label': pos[1],
        'expect': pos[2],
        'regex': flag('--regex'),
        'regexExpect': flag('--regex-expect'),
      };
    case 'enter':
      return {
        'cmd': 'enter',
        'label': pos[1],
        'text': pos[2],
        'regex': flag('--regex'),
      };
    case 'wait':
      return {'cmd': 'wait', 'label': pos[1], 'regex': flag('--regex')};
    case 'exists':
      return {'cmd': 'exists', 'label': pos[1], 'regex': flag('--regex')};
    case 'clipboard':
      return {'cmd': 'clipboard'};
    case 'info':
      return {'cmd': 'info'};
    case 'devices':
      return {'cmd': 'devices'};
    case 'add-device':
      return {'cmd': 'addDevice'};
    case 'chain':
      return {'cmd': 'chain'};
    case 'set-chain':
      return {'cmd': 'setChain', 'order': pos.skip(1).map(int.parse).toList()};
    case 'connect':
      return {'cmd': 'connect', 'device': int.parse(pos[1])};
    case 'disconnect':
      return {'cmd': 'disconnect', 'device': int.parse(pos[1])};
    case 'move-up':
      return {'cmd': 'moveUp', 'device': int.parse(pos[1])};
    case 'move-down':
      return {'cmd': 'moveDown', 'device': int.parse(pos[1])};
    case 'hold':
      return {
        'cmd': 'hold',
        'x': int.parse(pos[1]),
        'y': int.parse(pos[2]),
        if (pos.length > 3) 'ms': int.parse(pos[3]),
        'device': device,
      };
    case 'swipe':
      return {
        'cmd': 'swipe',
        'x1': int.parse(pos[1]),
        'y1': int.parse(pos[2]),
        'x2': int.parse(pos[3]),
        'y2': int.parse(pos[4]),
        if (pos.length > 5) 'ms': int.parse(pos[5]),
        'device': device,
      };
    case 'touch':
      return {
        'cmd': 'touch',
        'x': int.parse(pos[1]),
        'y': int.parse(pos[2]),
        'liftUp': pos[3] == 'up',
        'device': device,
      };
    case 'set-connected':
      return {
        'cmd': 'setConnected',
        'connected': pos[1] == 'true',
        'device': device,
      };
    case 'screen':
      return {'cmd': 'screen', 'path': pos[1], 'device': device};
    case 'shot':
      return {'cmd': 'shot', if (pos.length > 1) 'path': pos[1]};
    case 'down':
      return {'cmd': 'down'};
    default:
      return null;
  }
}
