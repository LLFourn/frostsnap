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

/// flutter device ids whose app shares the host filesystem — so the device-input `device-<n>.sock`s
/// are reachable and a full [SimHarness] (with device channels) can run. Anything else (an Android
/// emulator) runs an app-channel-only [AppSession].
const _hostPlatforms = {'macos', 'linux', 'windows'};

const _usage = '''
simctl — drive the running sim app/devices through SimHarness.
  simctl serve [--devices N] [--android] [--platform <d>] [--agent-owns-keyboard] [--no-regtest]
                                              launch app + listen (regtest ON by default;
                                              --no-regtest = offline)
  simctl up [serve flags]                     idempotently bring the sim up + return once ready
                                              (no backgrounding/polling; reuses a matching live
                                              daemon, refuses a mismatched one — `down` first)
  simctl up --android [--devices N]           bring the sim up on an Android emulator (boot/provision
                                              one if needed) with regtest bridged over adb; drive the
                                              devices via the in-app slide-in tray
  simctl info                                 print the running daemon's shape (platform/count/regtest)
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
  simctl shot [path]                          whole-app screenshot (incl. tray)
  simctl down                                 tear down (quit app, clean up)
 device-channel commands (HOST-only; on an Android (`--android`) session drive these via the tray):
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
  var wantPlatform = 'macos';
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--devices') count = int.parse(args[i + 1]);
    if (args[i] == '--platform') wantPlatform = args[i + 1];
  }
  // `--android` targets an emulator (the exact serial is resolved by the launched `serve`, so the
  // compatibility check below matches on "is an emulator" rather than a specific serial).
  final wantAndroid = args.contains('--android');
  // The shape `serve` WOULD launch — mirror its `withRegtest = !--no-regtest`. Regtest is ON by
  // default (on the host directly, on an emulator bridged over adb); --no-regtest opts out.
  final wantRegtest = !args.contains('--no-regtest');
  final wantKeyboard = args.contains('--agent-owns-keyboard');

  if (await _daemonAlive()) {
    final info = await _query({'cmd': 'info'});
    final live = (
      count: info['count'] as int,
      regtest: info['regtest'] as bool,
      keyboard: info['keyboard'] as bool,
      platform: info['platform'] as String? ?? 'macos',
    );
    // Compatible iff the recorded shape matches what serve would launch — same platform kind (an
    // emulator for --android, else the exact desktop platform), device count, keyboard mode, AND
    // regtest. A real mismatch fails (down first) rather than reporting a wrong daemon ready (e.g. an
    // Android AppSession that can't serve host device commands against a desktop request).
    final liveIsAndroid = !_hostPlatforms.contains(live.platform);
    final platformOk = wantAndroid
        ? liveIsAndroid
        : live.platform == wantPlatform;
    final compatible =
        platformOk &&
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
            '(platform=${live.platform}, count=${live.count}, regtest=${live.regtest}, '
            'agentOwnsKeyboard=${live.keyboard}); run `./simctl down` first',
      }),
    );
    exit(1);
  }

  // No daemon: launch `serve` detached via the repo-root launcher (which runs `just maybe-gen`
  // first, then self-logs every startup step to serve.log). We TAIL that log straight to our stdout,
  // so the caller watches the bring-up live (emulator boot, regtest bridge, gradle build, app
  // launch) and we return the instant the serve writes its terminal SIMCTL_READY / SIMCTL_FAILED
  // line — no socket polling, and a failure surfaces its real reason instead of a blank timeout.
  final logPath = '${simTmpRoot().path}/serve.log';
  try {
    File(logPath).deleteSync(); // don't tail a stale prior-run log
  } catch (_) {}
  final launcher = '${Directory.current.parent.path}/simctl';
  final serve = await Process.start(launcher, [
    'serve',
    ...args,
  ], mode: ProcessStartMode.detached);

  final logFile = File(logPath);
  var shown = 0;
  final deadline = DateTime.now().add(const Duration(minutes: 8));
  while (true) {
    final log = await logFile.exists() ? await logFile.readAsString() : '';
    if (log.length > shown) {
      stdout.write(log.substring(shown)); // stream new progress lines live
      shown = log.length;
    }
    if (log.contains('SIMCTL_READY')) {
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
    final failAt = log.indexOf('SIMCTL_FAILED:');
    if (failAt >= 0) {
      final reason = log
          .substring(failAt + 'SIMCTL_FAILED:'.length)
          .split('\n')
          .first
          .trim();
      stderr.writeln(
        jsonEncode({
          'ok': false,
          'error': 'sim daemon failed to start: $reason (see $logPath)',
        }),
      );
      exit(1);
    }
    if (DateTime.now().isAfter(deadline)) {
      stderr.writeln(
        jsonEncode({
          'ok': false,
          'error': 'sim daemon did not come up within 8 minutes (see $logPath)',
        }),
      );
      exit(1);
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
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

// ---- platform resolution: --android boots/reuses an emulator ----

/// The flutter device a launch targets. `--android` boots (or reuses) an emulator and returns its
/// serial — so the sim runs on a phone, driven via the slide-in tray; device-channel CLI commands
/// are then host-only. Otherwise `--platform <d>` (default macos), the desktop sim.
Future<String> _resolvePlatform(List<String> args) async {
  if (args.contains('--android')) return _ensureEmulatorBooted();
  var platform = 'macos';
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--platform') platform = args[i + 1];
  }
  return platform;
}

/// The TCP port from an electrum URL (`tcp://host:port`, `ssl://host:port`, or `host:port`).
int _electrumPort(String url) {
  final u = Uri.parse(url.contains('://') ? url : 'tcp://$url');
  if (u.port == 0) throw StateError('cannot parse electrum port from "$url"');
  return u.port;
}

/// Proxy a host unix socket over a loopback TCP port so an adb-reversed emulator can reach it. Each
/// TCP connection opens a fresh unix connection and pipes both ways (the faucet protocol is short
/// connect→request→close exchanges). Returns the listening server — close it to stop the bridge.
Future<ServerSocket> _bridgeUnixOverTcp(String unixPath) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((client) async {
    final Socket upstream;
    try {
      upstream = await Socket.connect(
        InternetAddress(unixPath, type: InternetAddressType.unix),
        0,
      );
    } catch (_) {
      client.destroy();
      return;
    }
    unawaited(client.cast<List<int>>().pipe(upstream).catchError((_) {}));
    unawaited(upstream.cast<List<int>>().pipe(client).catchError((_) {}));
  });
  return server;
}

/// The simctl-managed AVD; created on first use, reused after.
const _avdName = 'frostsnap_sim';

/// The Android SDK root from ANDROID_HOME / ANDROID_SDK_ROOT / android/local.properties / the macOS
/// default. Throws a clear error if none resolves.
String _androidSdkRoot() {
  for (final v in [
    Platform.environment['ANDROID_HOME'],
    Platform.environment['ANDROID_SDK_ROOT'],
  ]) {
    if (v != null && v.isNotEmpty && Directory(v).existsSync()) return v;
  }
  final lp = File('android/local.properties');
  if (lp.existsSync()) {
    for (final line in lp.readAsLinesSync()) {
      final m = RegExp(r'^\s*sdk\.dir\s*=\s*(.+)$').firstMatch(line);
      if (m != null && Directory(m.group(1)!.trim()).existsSync()) {
        return m.group(1)!.trim();
      }
    }
  }
  final fallback = '${Platform.environment['HOME']}/Library/Android/sdk';
  if (Directory(fallback).existsSync()) return fallback;
  throw StateError(
    'Android SDK not found — set ANDROID_HOME or android/local.properties sdk.dir',
  );
}

/// The serial of a running emulator (e.g. `emulator-5554`), or null if none is up.
Future<String?> _runningEmulatorSerial(String sdk) async {
  final res = await Process.run('$sdk/platform-tools/adb', ['devices']);
  for (final line in (res.stdout as String).split('\n')) {
    final m = RegExp(r'^(emulator-\d+)\s+device$').firstMatch(line.trim());
    if (m != null) return m.group(1);
  }
  return null;
}

/// Boot an emulator (reusing a running one, else provisioning + booting [_avdName]) and return its
/// serial once `sys.boot_completed` is set.
Future<String> _ensureEmulatorBooted() async {
  final sdk = _androidSdkRoot();
  final existing = await _runningEmulatorSerial(sdk);
  if (existing != null) {
    stderr.writeln('simctl: reusing the running emulator $existing');
    await _provisionEmulator(sdk, existing);
    return existing;
  }
  final avd = await _ensureAvd(sdk);
  stderr.writeln('simctl: booting emulator AVD "$avd" (cold, clean state) …');
  // `-wipe-data` cold-boots a CLEAN package DB. Repeated `flutter run` installs otherwise corrupt
  // the package state on a long-lived emulator — the launcher activity stops resolving (am start ->
  // -92), so the app never launches and bring-up dies on the VM-service timeout. A clean boot is
  // reliable; a warm reuse (above) keeps later `up`s in the same session fast.
  await Process.start('$sdk/emulator/emulator', [
    '-avd',
    avd,
    '-no-snapshot',
    '-wipe-data',
    '-no-boot-anim',
    '-gpu',
    'auto',
  ], mode: ProcessStartMode.detached);
  final serial = await _waitForBoot(sdk);
  await _provisionEmulator(sdk, serial);
  return serial;
}

/// Put a booted emulator into the state the sim needs, BEFORE the app launches. Best-effort and
/// idempotent (it runs on every bring-up, reused emulator or fresh boot):
///   - a secure lock-screen PIN (0000) — Frostsnap requires a secure lock, as it keystores secrets
///     behind device authentication;
///   - the device left UNLOCKED and kept awake — a locked device gives the app no focused window,
///     which ANRs it on launch ("Input dispatching timed out"); `stayon` stops it re-locking during
///     the slow build/launch;
///   - 3-button navigation — the app draws edge-to-edge, so the nav bar overlapping content is
///     exactly the case we want exercised (a common source of safe-area bugs).
Future<void> _provisionEmulator(String sdk, String serial) async {
  final adb = '$sdk/platform-tools/adb';
  Future<void> sh(List<String> cmd) =>
      Process.run(adb, ['-s', serial, 'shell', ...cmd]);

  // Keep the screen awake so the device can't sleep + re-lock during the build/launch.
  await sh(['svc', 'power', 'stayon', 'true']);
  await sh(['input', 'keyevent', 'KEYCODE_WAKEUP']);
  // Unlock: dismiss the keyguard, entering the PIN if one is already set (harmless otherwise).
  await sh(['wm', 'dismiss-keyguard']);
  await sh(['input', 'text', '0000']);
  await sh(['input', 'keyevent', 'KEYCODE_ENTER']);
  // Set the PIN while unlocked + awake, so it's configured but the session stays unlocked (a no-op
  // exit if one already exists).
  await sh(['locksettings', 'set-pin', '0000']);
  // enable-exclusive --category disables the other nav-bar overlays (gestural/two-button) so we
  // land on three-button cleanly rather than leaving several enabled.
  await sh([
    'cmd',
    'overlay',
    'enable-exclusive',
    '--category',
    'com.android.internal.systemui.navbar.threebutton',
  ]);
}

/// Ensure [_avdName] exists, provisioning the emulator package + a host-matching system image and
/// creating it if missing. Idempotent; the first run is a large download (logged).
Future<String> _ensureAvd(String sdk) async {
  final avdIni = '${Platform.environment['HOME']}/.android/avd/$_avdName.ini';
  if (File(avdIni).existsSync()) return _avdName;

  final abi = _hostArchIsArm() ? 'arm64-v8a' : 'x86_64';
  final image = 'system-images;android-34;google_apis;$abi';
  final sdkmanager = '$sdk/cmdline-tools/latest/bin/sdkmanager';
  final avdmanager = '$sdk/cmdline-tools/latest/bin/avdmanager';

  stderr.writeln(
    'simctl: provisioning emulator + $image (one-time, large download) …',
  );
  // Accept any pending licenses, then install (feeding "y" covers per-package license prompts).
  await _runFeeding(sdkmanager, ['--licenses'], 'y\n' * 50);
  await _runFeeding(sdkmanager, [
    '--install',
    'emulator',
    'platform-tools',
    image,
  ], 'y\n' * 50);

  stderr.writeln('simctl: creating AVD "$_avdName" …');
  // "no" declines the custom-hardware-profile prompt.
  await _runFeeding(avdmanager, [
    'create',
    'avd',
    '-n',
    _avdName,
    '-k',
    image,
    '--device',
    'pixel_6',
    '--force',
  ], 'no\n');
  return _avdName;
}

bool _hostArchIsArm() {
  try {
    return (Process.runSync('uname', ['-m']).stdout as String).trim() ==
        'arm64';
  } catch (_) {
    return false;
  }
}

/// adb wait-for-device + poll `sys.boot_completed`; return the emulator serial.
Future<String> _waitForBoot(String sdk) async {
  final adb = '$sdk/platform-tools/adb';
  await _run(adb, ['wait-for-device']);
  final deadline = DateTime.now().add(const Duration(minutes: 5));
  while (DateTime.now().isBefore(deadline)) {
    final r = await Process.run(adb, [
      'shell',
      'getprop',
      'sys.boot_completed',
    ]);
    if ((r.stdout as String).trim() == '1') {
      final serial = await _runningEmulatorSerial(sdk);
      if (serial != null) return serial;
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  throw StateError('emulator did not finish booting within 5 minutes');
}

/// Run a command, streaming its output; throw on non-zero exit.
Future<void> _run(String exe, List<String> args) async {
  final p = await Process.start(exe, args, mode: ProcessStartMode.inheritStdio);
  if (await p.exitCode != 0) {
    throw StateError('command failed: $exe ${args.join(' ')}');
  }
}

/// Run a command, feeding [stdinText] to its stdin (for license/prompt acceptance), streaming its
/// output. Best-effort: a non-zero exit logs but does not throw (e.g. `--licenses` exits non-zero
/// when there is nothing to accept).
Future<void> _runFeeding(
  String exe,
  List<String> args,
  String stdinText,
) async {
  final p = await Process.start(exe, args);
  p.stdin.write(stdinText);
  await p.stdin.close();
  unawaited(stdout.addStream(p.stdout));
  unawaited(stderr.addStream(p.stderr));
  final code = await p.exitCode;
  if (code != 0) {
    stderr.writeln('simctl: `$exe ${args.first}` exited $code (continuing)');
  }
}

// ---- daemon: holds one SimHarness, forwards commands to it ----

Future<void> _serve(List<String> args) async {
  var count = 1;
  // Default: a human owns the keyboard (real typing works, `enter` is rejected). Pass
  // --agent-owns-keyboard for the driver to own text input instead (enables `enter`,
  // blocks the physical keyboard). One mode for the session — no hybrid.
  final agentOwnsKeyboard = args.contains('--agent-owns-keyboard');
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--devices') count = int.parse(args[i + 1]);
  }
  // Regtest is ON by default (the common case is a wallet that can receive); `--no-regtest` opts out.
  final wantRegtest = !args.contains('--no-regtest');

  // SELF-LOG every startup step to serve.log from the very start, ending in a terminal
  // `SIMCTL_READY` / `SIMCTL_FAILED` line. `up` launches us detached (our stdio -> /dev/null) and
  // TAILS this file to stream progress to its own stdout and learn the real outcome — so no caller
  // ever has to poll the socket or guess at liveness. `simTmpRoot()` (re)creates the session dir.
  final logSink = File('${simTmpRoot().path}/serve.log').openWrite();
  final flushTimer = Timer.periodic(
    const Duration(seconds: 1),
    (_) => unawaited(logSink.flush()),
  );
  void serveLog(String s) {
    stderr.writeln(s);
    logSink.writeln(s);
  }

  // A desktop target shares the host filesystem, so its `device-<n>.sock`s are reachable and we run
  // a full SimHarness. A non-desktop target (an Android emulator) does not: those sockets live in
  // the app sandbox, so we run an AppSession (app channel only) and device-channel commands are
  // rejected as host-only (see _dispatch). Drive an emulator session via the in-app slide-in tray.
  late final String platform;
  late final bool isHost;
  late final AppSession harness;
  late final ServerSocket server;
  // On an emulator the electrum (TCP) + faucet control (unix) sockets live on the host, so we bridge
  // them: adb-reverse the electrum port (the app reaches the host electrs at the same 127.0.0.1:port
  // the URL already names) and proxy the unix control socket over an adb-reversed TCP port (SimFaucet
  // speaks either). The app then runs regtest unaware it's remote.
  final extraDefines = <String, String>{};
  ServerSocket? controlProxy;
  try {
    serveLog('simctl: resolving target …');
    platform = await _resolvePlatform(args);
    isHost = _hostPlatforms.contains(platform);
    serveLog('simctl: target $platform (${isHost ? 'host' : 'emulator'})');

    // Best-effort: a regtest-bridge failure degrades to an OFFLINE session (logged) rather than
    // sinking the whole bring-up.
    if (!isHost && wantRegtest) {
      try {
        serveLog('simctl: bridging regtest to $platform over adb …');
        final backend = await ensureRegtestBackend();
        final adb = '${_androidSdkRoot()}/platform-tools/adb';
        final ePort = _electrumPort(backend.url);
        await _run(adb, [
          '-s',
          platform,
          'reverse',
          'tcp:$ePort',
          'tcp:$ePort',
        ]);
        extraDefines['SIM_REGTEST_ELECTRUM_URL'] = backend.url;
        controlProxy = await _bridgeUnixOverTcp(regtestControlSocket);
        await _run(adb, [
          '-s',
          platform,
          'reverse',
          'tcp:${controlProxy.port}',
          'tcp:${controlProxy.port}',
        ]);
        extraDefines['SIM_REGTEST_CONTROL_SOCKET'] =
            '127.0.0.1:${controlProxy.port}';
        serveLog(
          'simctl: regtest bridged — electrs tcp:$ePort, faucet tcp:${controlProxy.port}',
        );
      } catch (e) {
        serveLog('simctl: regtest bridge failed, continuing OFFLINE: $e');
        extraDefines.clear();
        await controlProxy?.close();
        controlProxy = null;
      }
    }

    serveLog('simctl: launching the app on $platform (first build is slow) …');
    harness = isHost
        ? await SimHarness.launch(
            deviceCount: count,
            flutterDevice: platform,
            agentOwnsKeyboard: agentOwnsKeyboard,
            withRegtest: wantRegtest,
            logSink: logSink,
          )
        : await AppSession.launch(
            deviceCount: count,
            flutterDevice: platform,
            agentOwnsKeyboard: agentOwnsKeyboard,
            // An emulator's regtest is wired via the bridge above (extraDefines), not _launchApp's
            // internal host-socket path.
            withRegtest: false,
            extraDartDefines: extraDefines,
            logSink: logSink,
          );

    try {
      File(_socketPath).deleteSync();
    } catch (_) {}
    server = await ServerSocket.bind(
      InternetAddress(_socketPath, type: InternetAddressType.unix),
      0,
    );
  } catch (e, st) {
    serveLog('SIMCTL_FAILED: $e');
    logSink.writeln('$st');
    await logSink.flush();
    exit(1);
  }
  serveLog('SIMCTL_READY $_socketPath');
  stdout.writeln('SIMCTL_READY $_socketPath');

  // Idempotent AND awaitable: `down`, a signal, and the app-death watcher can all race in here;
  // they share ONE cleanup future, so EVERY caller awaits the same cleanup to FINISH before its
  // exit(0) runs. (A bare boolean guard would let a second caller return + exit mid-cleanup,
  // killing the process before the first's app-dir delete / log flush completed.)
  Future<void>? shutdownFuture;
  Future<void> shutdown() {
    return shutdownFuture ??= () async {
      flushTimer.cancel();
      await server.close();
      await controlProxy?.close();
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
        wantRegtest,
        count,
        platform,
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
  AppSession h,
  bool agentOwnsKeyboard,
  bool withRegtest,
  int launchDeviceCount,
  String platform,
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

  // device-channel commands need the host `device-<n>.sock`s; on an AppSession (an Android session)
  // they are rejected as host-only — drive those via the in-app tray instead. App-channel commands
  // (tap/wait/info/add-device/shot) work on either session over the (possibly adb-forwarded) VM
  // service.
  const deviceCmds = {
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
  final cmd = req['cmd'];
  final sim = h is SimHarness ? h : null;
  if (sim == null && deviceCmds.contains(cmd)) {
    return (
      {'ok': false, 'error': 'host-only on Android; drive via the in-app tray'},
      false,
    );
  }
  try {
    // The fleet can GROW behind the daemon's back — the tray + button adds devices the daemon
    // never issued — so before any command that reports or indexes devices, reconcile the channel
    // cache with the app-side fleet. An AppSession holds no device channels: nothing to resync.
    if (sim != null && (deviceCmds.contains(cmd) || cmd == 'info')) {
      await sim.ensureDevices();
    }
    switch (cmd) {
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
        // idempotence. `currentDevices` reports the live (resynced) fleet for introspection —
        // from the host channels, or the app-side count on an Android AppSession.
        final current = sim != null
            ? sim.devices.length
            : (await h.deviceNumbers()).length;
        return (
          {
            'ok': true,
            'count': launchDeviceCount,
            'currentDevices': current,
            'regtest': withRegtest,
            'keyboard': agentOwnsKeyboard,
            // The launch platform is part of the observable shape so `up` won't treat an Android
            // (AppSession) daemon and a desktop request as interchangeable.
            'platform': platform,
          },
          false,
        );
      case 'addDevice':
        return ({'ok': true, 'device': await h.addDevice()}, false);
      case 'devices':
        final list = <Map<String, dynamic>>[];
        for (var n = 1; n <= sim!.devices.length; n++) {
          list.add({
            'number': n,
            'id': await sim.device(n).deviceId(),
            'connected': await sim.device(n).isConnected(),
          });
        }
        return ({'ok': true, 'devices': list}, false);
      case 'chain':
        return ({'ok': true, 'chain': await sim!.chain()}, false);
      case 'setChain':
        await sim!.setChain((req['order'] as List).cast<int>());
        return ({'ok': true}, false);
      case 'connect':
        await sim!.connect(req['device'] as int);
        return ({'ok': true}, false);
      case 'disconnect':
        await sim!.disconnect(req['device'] as int);
        return ({'ok': true}, false);
      case 'moveUp':
        await sim!.moveUp(req['device'] as int);
        return ({'ok': true}, false);
      case 'moveDown':
        await sim!.moveDown(req['device'] as int);
        return ({'ok': true}, false);
      case 'hold':
        final ms = req['ms'] as int?;
        await sim!
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
        await sim!
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
        await sim!
            .device(dn)
            .touch(
              req['x'] as int,
              req['y'] as int,
              liftUp: req['liftUp'] as bool,
            );
        return ({'ok': true}, false);
      case 'setConnected':
        await sim!.device(dn).setConnected(req['connected'] as bool);
        return ({'ok': true}, false);
      case 'screen':
        await sim!.device(dn).screen(req['path'] as String);
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
