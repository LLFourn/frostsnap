import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'sim_harness.dart';

// simctl: interactively drive the running sim app + device through the SAME SimHarness
// methods the keygen test uses — no second implementation that can drift.
//
//   simctl serve [--device <d>]   launch the app + device ONCE, listen for commands
//   simctl <cmd> ...              run ONE command against the running daemon, exit
//
// `serve` holds a SimHarness and forwards each command to its methods over a control
// socket, so the app stays alive across commands: send one, see the result, try the
// next — a failed attempt is just followed by another command on the same live app
// (no relaunch). See `_usage` for commands. Run via `just sim-serve` / `just sim ...`.

String get _socketPath => '${simTmpRoot().path}/control.sock';

const _usage = '''
simctl — drive the running sim app/device through SimHarness.
  simctl serve [--device <d>]                 launch app+device, listen for commands
  simctl tap <label> [--regex]                tap a control by semantic label
  simctl tap-until <label> <expect> [--regex] [--regex-expect]
  simctl enter <label> <text> [--regex]       focus a field + type
  simctl wait <label> [--regex]               wait for a label to appear
  simctl exists <label> [--regex]             report whether a label is present
  simctl hold <x> <y> [ms]                    device hold-to-confirm at a point
  simctl swipe <x1> <y1> <x2> <y2> [ms]       device swipe
  simctl touch <x> <y> <down|up>              device raw touch
  simctl set-connected <true|false>           plug/unplug the device
  simctl screen <path>                        write the device framebuffer PNG
  simctl shot [path]                          whole-app screenshot (incl. tray)
  simctl down                                 tear down (quit app, clean up)
(--regex matches the label as a substring; default is exact.)''';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(_usage);
    exit(2);
  }
  if (args.first == 'serve') {
    await _serve(args.skip(1).toList());
  } else {
    await _client(args);
  }
}

// ---- daemon: holds one SimHarness, forwards commands to it ----

Future<void> _serve(List<String> args) async {
  var device = 'macos';
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--device') device = args[i + 1];
  }

  final harness = await SimHarness.launch(device: device);

  try {
    File(_socketPath).deleteSync();
  } catch (_) {}
  final server = await ServerSocket.bind(
    InternetAddress(_socketPath, type: InternetAddressType.unix),
    0,
  );
  stdout.writeln('SIMCTL_READY $_socketPath');

  Future<void> shutdown() async {
    await server.close();
    try {
      File(_socketPath).deleteSync();
    } catch (_) {}
    await harness.tearDown();
  }

  for (final sig in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    sig.watch().listen((_) async {
      await shutdown();
      exit(0);
    });
  }

  await for (final conn in server) {
    final lines = conn
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      if (line.trim().isEmpty) continue;
      final (reply, down) = await _dispatch(line, harness);
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
) async {
  final Map<String, dynamic> req;
  try {
    req = jsonDecode(line) as Map<String, dynamic>;
  } catch (e) {
    return ({'ok': false, 'error': 'bad json: $e'}, false);
  }
  Pattern pat(String key, String flag) =>
      req[flag] == true ? RegExp(req[key] as String) : req[key] as String;

  try {
    switch (req['cmd']) {
      case 'tap':
        await h.tap(pat('label', 'regex'));
        return ({'ok': true}, false);
      case 'tapUntil':
        await h.tapUntil(pat('label', 'regex'), pat('expect', 'regexExpect'));
        return ({'ok': true}, false);
      case 'enter':
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
      case 'hold':
        final ms = req['ms'] as int?;
        await h.device.holdConfirm(
          req['x'] as int,
          req['y'] as int,
          ms != null
              ? Duration(milliseconds: ms)
              : const Duration(milliseconds: 2600),
        );
        return ({'ok': true}, false);
      case 'swipe':
        await h.device.swipe(
          req['x1'] as int,
          req['y1'] as int,
          req['x2'] as int,
          req['y2'] as int,
          Duration(milliseconds: (req['ms'] as int?) ?? 300),
        );
        return ({'ok': true}, false);
      case 'touch':
        await h.device.touch(
          req['x'] as int,
          req['y'] as int,
          liftUp: req['liftUp'] as bool,
        );
        return ({'ok': true}, false);
      case 'setConnected':
        await h.device.setConnected(req['connected'] as bool);
        return ({'ok': true}, false);
      case 'screen':
        await h.device.screen(req['path'] as String);
        return ({'ok': true, 'path': req['path']}, false);
      case 'shot':
        final path =
            (req['path'] as String?) ?? '${simTmpRoot().path}/shot.png';
        await h.screenshot('manual', keep: path);
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

Future<void> _client(List<String> args) async {
  final req = _argsToCommand(args);
  if (req == null) {
    stderr.writeln(_usage);
    exit(2);
  }
  final Socket socket;
  try {
    socket = await Socket.connect(
      InternetAddress(_socketPath, type: InternetAddressType.unix),
      0,
    );
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
  bool flag(String f) => args.contains(f);
  final pos = args.where((a) => !a.startsWith('--')).toList();
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
    case 'hold':
      return {
        'cmd': 'hold',
        'x': int.parse(pos[1]),
        'y': int.parse(pos[2]),
        if (pos.length > 3) 'ms': int.parse(pos[3]),
      };
    case 'swipe':
      return {
        'cmd': 'swipe',
        'x1': int.parse(pos[1]),
        'y1': int.parse(pos[2]),
        'x2': int.parse(pos[3]),
        'y2': int.parse(pos[4]),
        if (pos.length > 5) 'ms': int.parse(pos[5]),
      };
    case 'touch':
      return {
        'cmd': 'touch',
        'x': int.parse(pos[1]),
        'y': int.parse(pos[2]),
        'liftUp': pos[3] == 'up',
      };
    case 'set-connected':
      return {'cmd': 'setConnected', 'connected': pos[1] == 'true'};
    case 'screen':
      return {'cmd': 'screen', 'path': pos[1]};
    case 'shot':
      return {'cmd': 'shot', if (pos.length > 1) 'path': pos[1]};
    case 'down':
      return {'cmd': 'down'};
    default:
      return null;
  }
}
