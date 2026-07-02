import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';

import 'emulator.dart';
import 'regtest.dart';
import 'sim_harness.dart';

// fsim: interactively drive the running sim app + devices through the SAME SimHarness
// methods the keygen test uses — no second implementation that can drift.
//
//   fsim serve [--devices N]    launch the app + N devices ONCE, listen for commands
//   fsim <cmd> ...              run ONE command against the running daemon, exit
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
// repo-root `./fsim` launcher (e.g. `./fsim serve`, `./fsim test keygen`).

/// This session's STATE ROOT: `<identity>/.fsim`, holding its control socket, serve.log, app dir, and
/// screenshots. Identity = `--dir <path>` if given, else the INVOCATION cwd (FSIM_INVOCATION_CWD, captured
/// by the `./fsim` wrapper BEFORE it cd's into the package — `Directory.current` is the package dir, not
/// where the user ran fsim). The directory IS the session id, so two fsim runs in different dirs never
/// collide. Set once by [main] via [_resolveStateRoot].
late final Directory _stateRoot;

/// Resolve [_stateRoot] from `--dir`/FSIM_INVOCATION_CWD, stripping `--dir <path>` out of [args] and
/// returning the rest. Fails fast if the longest unix socket under the root would exceed the OS `sun_path`
/// limit (rather than truncating or hashing).
List<String> _resolveStateRoot(List<String> args) {
  String? dir;
  final rest = <String>[];
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--dir' && i + 1 < args.length) {
      dir = args[++i];
    } else {
      rest.add(args[i]);
    }
  }
  final invocationCwd =
      Platform.environment['FSIM_INVOCATION_CWD'] ?? Directory.current.path;
  // A relative `--dir` is relative to WHERE THE USER RAN fsim (the invocation cwd), NOT the package dir the
  // wrapper cd'd into. No `--dir` → the invocation cwd itself.
  var identity = dir == null
      ? invocationCwd
      : (dir.startsWith('/') ? dir : '$invocationCwd/$dir');
  // Canonicalize so the same directory always maps to the same session (resolve symlinks/`..` when it
  // exists; else normalize the absolute path of a not-yet-created --dir).
  try {
    identity = Directory(identity).resolveSymbolicLinksSync();
  } catch (_) {
    identity = Directory(identity).absolute.path;
  }
  final root = Directory('$identity/.fsim');
  // The regtest control socket is the longest unix-socket path under the root, and startRegtestSession
  // guards THAT path at 100 chars (a conservative margin under macOS's 104-byte sun_path); match it here so
  // an over-long dir fails at resolution with a clear message rather than inside serve.
  final longest = '${root.path}/regtest/control.sock';
  const limit = 100;
  if (longest.length > limit) {
    stderr.writeln(
      'fsim: session dir too long for a unix socket (${longest.length} > $limit chars): $longest\n'
      '  use a shorter --dir',
    );
    exit(2);
  }
  _stateRoot = root;
  return rest;
}

String get _socketPath => '${_stateRoot.path}/control.sock';

/// flutter device ids whose app shares the host filesystem — so the device-input `device-<n>.sock`s
/// are reachable and a full [SimHarness] (with device channels) can run. Anything else (an Android
/// emulator) runs an app-channel-only [AppSession].
const _hostPlatforms = {'macos', 'linux', 'windows'};

const _usage = '''
fsim — drive the running sim app/devices through SimHarness.
  Session-scoped: state lives in <dir>/.fsim (--dir <path> sets the dir, default the invocation cwd) — so
  concurrent fsim sessions in different dirs are isolated. `clean` deletes only that <dir>/.fsim.
  fsim serve [--devices N] [--android] [--platform <d>] [--agent-owns-keyboard] [--no-regtest]
                                              launch app + listen (regtest ON by default;
                                              --no-regtest = offline)
  fsim up [serve flags]                     idempotently bring the sim up + return once ready
                                              (no backgrounding/polling; reuses a matching live
                                              daemon, refuses a mismatched one — `down` first)
  fsim up --android [--devices N]           bring the sim up on an Android emulator (boot/provision
                                              one if needed) with regtest bridged over adb; drive the
                                              devices via `./fsim` (below) or the in-app tray
  fsim info                                 print the running daemon's shape (platform/count/regtest)
  fsim test [NAMES...] [--android] [--jobs N] [--test-timeout SECS] [--nocapture|-v] [--junit PATH]
                                              run e2e driver tests (stems; ALL if none) IN PARALLEL —
                                              host: one `dart run` each; --android: each SELF-BOOTS
                                              its OWN emulator + (if it uses regtest) bridges its OWN
                                              per-worker chain (rt-<pid>) to it. --jobs caps parallelism
                                              (default = all at once);
                                              --test-timeout (default 900s) reaps a wedged test as
                                              TIMEOUT so the run never stalls; raw output goes to
                                              build/sim-failures/<test>/output.log unless
                                              --nocapture/-v streams it live; --junit writes XML
  fsim regtest up|down|status               manage THIS session's regtest (<dir>/.fsim/regtest) — the
                                              serve auto-starts it; bitcoind+electrs+faucet
  fsim regtest fund <addr> <sats> | mine [n] | balance | height | address | url   drive the faucet
  fsim clean                                reap + delete ONLY this session's <dir>/.fsim (socket, regtest,
                                              app dir, emulator) — never another session or a test run
                                              (no daemon running)
  fsim tap <label> [--regex]                tap a control by semantic label
  fsim tap-until <label> <expect> [--regex] [--regex-expect]
  fsim enter <label> <text> [--regex]       focus a field + type (agent-owns-keyboard only)
  fsim wait <label> [--regex]               wait for a label to appear
  fsim exists <label> [--regex]             report whether a label is present
  fsim clipboard                            print the app clipboard text (e.g. a copied address)
  fsim shot [path]                          whole-app screenshot (incl. tray)
  fsim down                                 tear down (quit app, clean up)
 device commands (over the app channel — work on host AND emulator):
  fsim devices                              list each device (number/id/connected)
  fsim add-device                           add a device at runtime (joins the chain tail)
  fsim chain                                print the connected chain order
  fsim set-chain <n>...                     re-cable to exactly these devices, in order
  fsim connect <n>                          plug device n into the tail of the chain
  fsim disconnect <n>                       disconnect device n + everything downstream
  fsim move-up <n> / move-down <n>          reorder device n within the chain
  fsim hold <x> <y> [ms] [--device N]       device hold-to-confirm at a point
  fsim swipe <x1> <y1> <x2> <y2> [ms] [--device N]   device swipe
  fsim touch <x> <y> <down|up> [--device N]          device raw touch
  fsim set-connected <true|false> [--device N]       plug/unplug a device
  fsim screen <path> [--device N]           write the device framebuffer PNG
(--regex matches the label as a substring; default is exact. --device selects the
 virtual device, 1-based, default 1. `serve` gives the keyboard to a human unless
 --agent-owns-keyboard is passed, which the driver needs for `enter`.)''';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(_usage);
    exit(2);
  }
  // Two ISOLATION MODELS, deliberately non-overlapping so an interactive `clean` and a concurrent `fsim
  // test` never disturb each other: the test runner scopes per worker under the shared root
  // (simTmpRoot/rt-<pid> chains + `frostsnap_sim_pool_*` emulators at 5582↑), while every interactive command
  // scopes to <dir>/.fsim (its own socket/regtest/app-dir + `frostsnap_sim_session_*` emulators at 5680↓,
  // claimed by probe). `clean` deletes ONLY <dir>/.fsim and the runner reaps ONLY its own slots — so this
  // dispatch returns BEFORE resolving any interactive session root.
  if (args.first == 'test') {
    await _runTests(args.skip(1).toList());
    return;
  }
  // Every interactive command scopes to the session state root (`<--dir or invocation-cwd>/.fsim`).
  args = _resolveStateRoot(args);
  // The interactive regtest — serve's backend AND the `fsim regtest` commands — is this session's own,
  // under the state root, not the shared node.
  regtestDirOverride = Directory('${_stateRoot.path}/regtest');
  if (args.first == 'serve') {
    await _serve(args.skip(1).toList());
  } else if (args.first == 'up') {
    await _up(args.skip(1).toList());
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
/// `./fsim down` first.
Future<void> _clean() async {
  if (await _daemonAlive()) {
    stderr.writeln('fsim: a serve daemon is running — run `./fsim down` first');
    exit(1);
  }
  // Reap THIS session's regtest (a graceful `down` already self-reaped it; this catches a killed session's
  // leftover) — scoped to <dir>/.fsim/regtest, so it never touches another session's backend.
  await reapRegtestSessionDir(Directory('${_stateRoot.path}/regtest'));
  // Reap THIS session's self-booted android emulator if a hard-killed session left one (recorded serial) —
  // scoped to this session, NEVER a global sweep that could kill a concurrent test run's pool emulator.
  final emSerialFile = File('${_stateRoot.path}/emulator-serial');
  if (await emSerialFile.exists()) {
    final serial = (await emSerialFile.readAsString()).trim();
    if (serial.isNotEmpty) {
      try {
        await killEmulator(androidSdkRoot(), serial);
      } catch (_) {}
    }
  }
  // Delete ONLY this session's state root (`<dir>/.fsim`) — never the cwd/worktree or a shared root, so a
  // `clean` in one session can't nuke another's (the per-session regtest reaping is Task 2).
  final root = _stateRoot;
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

/// `fsim up [serve flags]` — idempotent bring-up. If a live daemon already matches the requested
/// shape (device count, regtest, keyboard mode) it's a no-op (`already:true`); on a MISMATCH it
/// refuses with a clear "down first" error rather than reporting a wrong daemon ready; otherwise it
/// launches `serve` DETACHED (which self-logs) and returns only once the control socket is live. The
/// whole point: one command, no backgrounding or readiness polling by the caller.
Future<void> _up(List<String> args) async {
  var count = 1;
  // Default to the host desktop OS so it matches what `serve`/_resolvePlatform would launch (else `up` on
  // Linux would read the launched linux daemon as an incompatible-platform mismatch).
  var wantPlatform = Platform.isLinux ? 'linux' : 'macos';
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
            'agentOwnsKeyboard=${live.keyboard}); run `./fsim down` first',
      }),
    );
    exit(1);
  }

  // No daemon: launch `serve` detached via the repo-root launcher (which runs `just maybe-gen`
  // first, then self-logs every startup step to serve.log). We TAIL that log straight to our stdout,
  // so the caller watches the bring-up live (emulator boot, regtest bridge, gradle build, app
  // launch) and we return the instant the serve writes its terminal FSIM_READY / FSIM_FAILED
  // line — no socket polling, and a failure surfaces its real reason instead of a blank timeout.
  _stateRoot.createSync(recursive: true);
  final logPath = '${_stateRoot.path}/serve.log';
  try {
    File(logPath).deleteSync(); // don't tail a stale prior-run log
  } catch (_) {}
  final launcher = '${Directory.current.parent.path}/fsim';
  // Forward this session's identity as `--dir`: the detached serve re-runs the wrapper, whose
  // FSIM_INVOCATION_CWD would be OUR cwd (the package dir), so `--dir` is what pins the daemon to the SAME
  // state root this client resolved.
  final serve = await Process.start(launcher, [
    'serve',
    '--dir',
    _stateRoot.parent.path,
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
    if (log.contains('FSIM_READY')) {
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
    final failAt = log.indexOf('FSIM_FAILED:');
    if (failAt >= 0) {
      final reason = log
          .substring(failAt + 'FSIM_FAILED:'.length)
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

const _driveSuffix = '_drive.dart';
const _diagnosticTimeout = Duration(seconds: 10);

class _TestSpec {
  final String file;
  final String name;
  final Directory artifactsDir;

  _TestSpec(this.file, this.name)
    : artifactsDir = Directory('build/sim-failures/$name');
}

class _TestResult {
  final _TestSpec test;
  final String status;
  final String output;
  final Duration duration;
  final String? reason;

  /// Transient-flake retries taken before this (final) result; 0 = passed/failed first try.
  int retries = 0;

  _TestResult({
    required this.test,
    required this.status,
    required this.output,
    required this.duration,
    this.reason,
  });

  bool get passed => status == 'PASSED';
  bool get failed => status == 'FAILED';
  bool get timedOut => status == 'TIMEOUT';
  bool get skipped => status == 'SKIPPED';
}

List<_TestSpec> _testSpecs(List<String> files) {
  final seen = <String, int>{};
  return [
    for (final file in files)
      () {
        final stem = file.substring(0, file.length - _driveSuffix.length);
        final count = (seen[stem] ?? 0) + 1;
        seen[stem] = count;
        return _TestSpec(file, count == 1 ? stem : '$stem-$count');
      }(),
  ];
}

Future<void> _clearArtifacts(Directory dir) async {
  if (await dir.exists()) await dir.delete(recursive: true);
}

Future<void> _writeOutputLog(Directory dir, String output) async {
  await dir.create(recursive: true);
  await File('${dir.path}/output.log').writeAsString(output);
}

Future<void> _writeErrorIfAbsent(Directory dir, String error) async {
  await dir.create(recursive: true);
  final file = File('${dir.path}/error.txt');
  if (!await file.exists()) await file.writeAsString(error);
}

String _elapsed(Duration d) =>
    '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';

String _displayStatus(_TestResult r) => switch (r.status) {
  'PASSED' => 'ok',
  'FAILED' => 'FAILED',
  'TIMEOUT' => 'TIMEOUT',
  'SKIPPED' => 'SKIPPED',
  _ => r.status,
};

void _printResult(_TestResult r) {
  stdout.writeln(
    'test ${r.test.name} ... ${_displayStatus(r)} (${_elapsed(r.duration)})',
  );
}

void _printFailures(List<_TestResult> failures) {
  if (failures.isEmpty) return;
  stdout.writeln();
  stdout.writeln('failures:');
  for (final failure in failures) {
    final reason = failure.reason ?? failure.status;
    stdout.writeln(
      '  ${failure.test.name}: $reason; see ${failure.test.artifactsDir.path}',
    );
  }
}

void _printSummary(List<_TestResult> results, Duration elapsed) {
  final passed = results.where((r) => r.passed).length;
  final failed = results.where((r) => r.failed).length;
  final timedOut = results.where((r) => r.timedOut).length;
  final skipped = results.where((r) => r.skipped).length;
  final retried = results.where((r) => r.retries > 0).length;
  stdout.writeln();
  stdout.writeln(
    'test result: $passed passed; $failed failed; $timedOut timed out; '
    '$skipped skipped; finished in ${_elapsed(elapsed)}'
    '${retried > 0 ? ' ($retried retried a transient flake)' : ''}',
  );
}

Future<void> _writeJunit(
  String path,
  List<_TestResult> results,
  Duration elapsed,
) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  final failed = results.where((r) => r.failed).length;
  final timedOut = results.where((r) => r.timedOut).length;
  final skipped = results.where((r) => r.skipped).length;
  final retries = results.fold<int>(0, (sum, r) => sum + r.retries);
  final b = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln(
      '<testsuite name="fsim" tests="${results.length}" failures="$failed" '
      'errors="$timedOut" skipped="$skipped" retries="$retries" '
      'time="${_junitTime(elapsed)}">',
    );
  for (final r in results) {
    b.writeln(
      '  <testcase classname="fsim" name="${_xmlEscape(r.test.name)}" '
      'retries="${r.retries}" time="${_junitTime(r.duration)}">',
    );
    if (r.skipped) {
      b.writeln('    <skipped/>');
    } else if (r.failed) {
      final message = _xmlEscape(r.reason ?? 'failed');
      b.writeln(
        '    <failure message="$message">${_xmlEscape(r.output)}</failure>',
      );
    } else if (r.timedOut) {
      final message = _xmlEscape(r.reason ?? 'timed out');
      b.writeln(
        '    <error type="timeout" message="$message">${_xmlEscape(r.output)}</error>',
      );
    }
    b.writeln('  </testcase>');
  }
  b.writeln('</testsuite>');
  await file.writeAsString(b.toString());
}

String _junitTime(Duration d) => (d.inMilliseconds / 1000).toStringAsFixed(3);

String _xmlEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

/// Run one driver test by its file STEM (`<stem>_drive.dart`), or all of them with no arg.
/// Each runs as its own `dart run` so they get a fresh app/harness; a non-zero exit from any
/// fails the whole run. Replaces the per-test justfile recipes — a new test is just a new
/// `*_drive.dart` file, discovered here automatically.
Future<void> _runTests(List<String> args) async {
  // Runs the named tests (or ALL if none) IN PARALLEL. Each test is a self-contained `dart run` owning
  // its isolated state (its own app instance(s) + per-session regtest chain); on `--android` each test
  // SELF-BOOTS its own emulator(s) and bridges the chain to them. No shared state to serialize around.
  // `--jobs N` caps the parallelism; default = run them all at once.
  final android = args.contains('--android');
  int? jobs; // null = "as many as possible"
  int? testTimeout; // per-test hard deadline, seconds
  var noCapture = false;
  String? junitPath;
  final positional = <String>[];
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--android') continue;
    if (a == '--nocapture' || a == '-v') {
      noCapture = true;
      continue;
    }
    if (a == '--jobs') {
      jobs = int.parse(args[++i]);
      continue;
    }
    if (a == '--test-timeout') {
      testTimeout = int.parse(args[++i]);
      continue;
    }
    if (a == '--junit') {
      junitPath = args[++i];
      continue;
    }
    if (a.startsWith('--')) continue;
    positional.add(a);
  }

  final stems = <String, String>{}; // stem -> filename
  for (final entry in Directory('test_driver').listSync()) {
    final name = entry.uri.pathSegments.last;
    if (entry is File && name.endsWith(_driveSuffix)) {
      stems[name.substring(0, name.length - _driveSuffix.length)] = name;
    }
  }
  final available = stems.keys.toList()..sort();

  final List<String> files;
  if (positional.isEmpty) {
    files = available.map((s) => stems[s]!).toList();
  } else {
    files = [];
    for (final name in positional) {
      final file = stems[name];
      if (file == null) {
        stderr.writeln(
          'fsim test: no test "$name". Available: ${available.join(', ')}',
        );
        exit(2);
      }
      files.add(file);
    }
  }
  final tests = _testSpecs(files);

  // Default to running every test at once.
  final effJobs = (jobs ?? files.length).clamp(1, files.length);
  // Per-test hard deadline so a wedged test (frozen app / unbounded wait) can't stall the run — it's
  // reaped and reported TIMEOUT instead. Generous by default: Android workers can queue behind a
  // serialized `flutter run` build/install. Host workers direct-launch a prebuilt debug app.
  final deadline = Duration(seconds: testTimeout ?? 900);
  final results = <_TestResult>[];
  final started = DateTime.now();
  stdout.writeln('running ${tests.length} tests');
  // Build the app ONCE up front (host binary / android APK), then run every test as a self-contained
  // `dart run` owning its PRIVATE per-session regtest chain — up to `effJobs` concurrently, no shared
  // state. Android tests SELF-BOOT their own emulator(s) from the worker slot (no pre-booted pool);
  // that keeps host and android on the ONE dispatch path. Concurrent output is captured + printed grouped
  // on completion (interleaved live streams would be unreadable); a single test streams live.
  final hostAppBinary = android
      ? null
      : Platform.isMacOS
      ? await AppSession.ensureMacosSimAppBuilt(logSink: stderr)
      : Platform.isLinux
      ? await AppSession.ensureLinuxSimAppBuilt(logSink: stderr)
      : null;
  final androidAppBinary = android
      ? await AppSession.ensureAndroidSimApkBuilt(logSink: stderr)
      : null;
  final sdk = android ? androidSdkRoot() : null;
  // Host device: null on macOS (the test defaults to 'macos' — unchanged); 'linux' on Linux so the test
  // targets the Linux desktop app + the prebuilt binary built above. Android self-boots ('android').
  final hostDevice = Platform.isLinux ? 'linux' : null;
  await _runBounded(tests, effJobs, (test, workerSlot) async {
    final (r, retries) = await runWithRetry<_TestResult>(
      (_) => _runOneTest(
        test,
        flutterDevice: android ? 'android' : hostDevice,
        sdk: sdk,
        hostAppBinary: hostAppBinary,
        androidAppBinary: androidAppBinary,
        windowSlot: workerSlot,
        capture: !noCapture,
        deadline: deadline,
      ),
      (res) => res.failed && isTransientFlake(res.output),
    );
    // Android: reap the emulator(s) this slot self-booted — belt-and-suspenders so a timed-out/killed
    // test (whose own teardown didn't run) can't orphan one. Deterministic serials from the slot.
    if (android && sdk != null) await _reapSlotEmulators(sdk, workerSlot);
    r.retries = retries;
    _printResult(r);
    _reportRetries(r, retries);
    results.add(r);
  });

  final failures = results.where((r) => !r.passed && !r.skipped).toList();
  _printFailures(failures);
  final elapsed = DateTime.now().difference(started);
  _printSummary(results, elapsed);
  if (junitPath != null) await _writeJunit(junitPath, results, elapsed);
  exit(failures.isEmpty ? 0 : 1);
}

/// Kill any emulators worker [slot] could have self-booted (its device-index range), so a timed-out or
/// killed test — whose own teardown didn't run — never orphans one. Idempotent (a harmless no-op for an
/// index that never booted); deterministic serials keep it independent of the dead test process.
Future<void> _reapSlotEmulators(String sdk, int slot) async {
  for (var i = 0; i < maxInstancesPerTest; i++) {
    await killEmulator(sdk, emulatorSerial(slot * maxInstancesPerTest + i));
  }
}

/// One try plus up to two retries — enough to ride out a transient startup flake without masking a
/// chronically broken test.
const _maxTestAttempts = 3;

/// Signatures of a GENUINE scenario failure — present iff the test ran and asserted/threw on its own.
/// Such a failure must NOT be retried even when a connection-drop line is ALSO in the output (e.g. the
/// app shutting down after the failure prints "Lost connection to device"). NB: an uncaught
/// `StateError('x')` prints as `Bad state: x`, NOT "StateError" — matching the literal type name would
/// miss every real scenario assertion.
const _realFailureSignatures = [
  'Bad state:', // StateError — the scenarios' and tapUntil's assertions
  'Expected:', // package:test / matcher expect()
  'TestFailure', // package:test
  'Failed assertion', // dart assert()
];

/// True if [output] shows a TRANSIENT startup connection flake — the emulator dropping the VM service
/// while the app janks at launch — rather than a real failure. The driver's first command after the
/// drop fails with a SetFrameSync remote error / "Lost connection to device". A failure that ALSO
/// carries a real-assertion signature is never transient, so a genuine failure whose app then dropped
/// the connection is not retried.
bool isTransientFlake(String output) {
  final connectionDropped =
      output.contains('Failed to fulfill SetFrameSync') ||
      output.contains('Lost connection to device');
  if (!connectionDropped) return false;
  return !_realFailureSignatures.any(output.contains);
}

/// Run [attempt] (each call is one fresh attempt, given its 1-based number) and retry while
/// [shouldRetry] holds the result, up to [maxAttempts] total. Returns the final result and the number
/// of RETRIES taken (0 on a first-try result). Pure control flow — unit-tested with a fake [attempt].
Future<(T, int)> runWithRetry<T>(
  Future<T> Function(int attempt) attempt,
  bool Function(T) shouldRetry, {
  int maxAttempts = _maxTestAttempts,
}) async {
  for (var n = 1; ; n++) {
    final r = await attempt(n);
    if (n >= maxAttempts || !shouldRetry(r)) return (r, n - 1);
  }
}

/// Surface retries on stderr so a flaky test is visible, never silently papered over.
void _reportRetries(_TestResult r, int retries) {
  if (retries == 0) return;
  final s = retries == 1 ? 'retry' : 'retries';
  stderr.writeln(
    r.passed
        ? 'fsim: ${r.test.name} recovered after $retries transient-flake $s'
        : 'fsim: ${r.test.name} FAILED after ${retries + 1} attempts (transient startup flake persisted)',
  );
}

/// Run `dart run test_driver/<file>` to completion or [deadline], whichever comes first. On the
/// deadline the test is wedged — commonly a frozen app whose VM service can't answer, so NO in-test
/// timeout can fire — so reap what it spawned and return TIMEOUT, and the run never stalls. With
/// [capture] the child's output is buffered (returned for grouped printing); else it inherits stdio.
Future<_TestResult> _runOneTest(
  _TestSpec test, {
  String? flutterDevice,
  String? sdk,
  String? hostAppBinary,
  String? androidAppBinary,
  int? windowSlot,
  required bool capture,
  required Duration deadline,
}) async {
  await _clearArtifacts(test.artifactsDir);
  final started = DateTime.now();
  final proc = await Process.start(
    'dart',
    ['run', 'test_driver/${test.file}'],
    mode: ProcessStartMode.normal,
    environment: {
      'SIM_TEST_NAME': test.name,
      'SIM_TEST_ARTIFACTS_DIR': test.artifactsDir.absolute.path,
      // For android, this is the generic 'android' — the TEST self-boots its own emulator(s) from the
      // slot (sim-unify-app-host); for host it's unset (the test defaults to macos).
      if (flutterDevice != null) 'SIM_FLUTTER_DEVICE': flutterDevice,
      if (flutterDevice != null) 'SIM_REQUIRE_FLUTTER_DEVICE': '1',
      if (hostAppBinary != null) 'SIM_HOST_APP_BINARY': hostAppBinary,
      if (androidAppBinary != null) 'SIM_ANDROID_APP_BINARY': androidAppBinary,
      if (windowSlot != null) 'FROSTSNAP_SIM_WINDOW_SLOT': '$windowSlot',
    },
  );
  final buf = StringBuffer();
  final drains = [
    proc.stdout.transform(utf8.decoder).forEach((chunk) {
      buf.write(chunk);
      if (!capture) stdout.write(chunk);
    }),
    proc.stderr.transform(utf8.decoder).forEach((chunk) {
      buf.write(chunk);
      if (!capture) stderr.write(chunk);
    }),
  ];
  int code;
  var timedOut = false;
  String? reason;
  try {
    code = await proc.exitCode.timeout(deadline);
  } on TimeoutException {
    timedOut = true;
    reason = 'timed out after ${deadline.inSeconds}s';
    await _writeOutputLog(test.artifactsDir, buf.toString());
    // Self-booted android emulators (if any) are reaped by the caller from the slot; here just kill the
    // dart process + its regtest dir (serial null → skip the emulator-specific adb reaping).
    await _captureTimeoutDiagnostics(
      test.artifactsDir,
      output: buf.toString(),
      serial: null,
      sdk: sdk,
      deadline: deadline,
    );
    await _reapHungTest(proc, null, sdk);
    code = await proc.exitCode.timeout(_diagnosticTimeout, onTimeout: () => -1);
  }
  await Future.wait(
    drains,
  ).timeout(_diagnosticTimeout, onTimeout: () => <void>[]);
  final output = buf.toString();
  // A scenario can declare itself skipped (exit 0 + marker) — e.g. a host-only dual-instance scenario
  // on an emulator. Classify that as SKIPPED so a never-ran test isn't reported as a silent PASS.
  final skipped =
      !timedOut && code == 0 && output.contains(simTestSkippedMarker);
  final status = timedOut
      ? 'TIMEOUT'
      : skipped
      ? 'SKIPPED'
      : (code == 0 ? 'PASSED' : 'FAILED');
  await _writeOutputLog(test.artifactsDir, output);
  if (status != 'PASSED') {
    reason ??= 'exit code $code';
    await _writeErrorIfAbsent(
      test.artifactsDir,
      '$status: $reason\n\nSee output.log for the child process log.\n',
    );
  }
  return _TestResult(
    test: test,
    status: status,
    output: output,
    duration: DateTime.now().difference(started),
    reason: reason,
  );
}

Future<void> _captureTimeoutDiagnostics(
  Directory dir, {
  required String output,
  required String? serial,
  required String? sdk,
  required Duration deadline,
}) async {
  await dir.create(recursive: true);
  await File('${dir.path}/error.txt').writeAsString(
    'TIMEOUT after ${deadline.inSeconds}s\n\n'
    'The child test process did not exit before the runner deadline.\n'
    'Partial child output is in output.log.\n',
  );
  if (serial != null && sdk != null) {
    await _captureAndroidTimeoutDiagnostics(dir, serial: serial, sdk: sdk);
  } else {
    await _captureHostTimeoutDiagnostics(dir);
  }
  await _captureVmDeviceFrames(dir, output);
}

Future<void> _captureAndroidTimeoutDiagnostics(
  Directory dir, {
  required String serial,
  required String sdk,
}) async {
  final adb = '$sdk/platform-tools/adb';
  final screen = await _runDiagnosticProcess(adb, [
    '-s',
    serial,
    'exec-out',
    'screencap',
    '-p',
  ], stdoutEncoding: null);
  if (screen != null && screen.exitCode == 0 && screen.stdout is List<int>) {
    await File(
      '${dir.path}/android-screen.png',
    ).writeAsBytes(screen.stdout as List<int>);
  }

  final logcat = await _runDiagnosticProcess(adb, [
    '-s',
    serial,
    'logcat',
    '-d',
  ]);
  if (logcat != null) {
    await File(
      '${dir.path}/logcat.txt',
    ).writeAsString('${logcat.stdout}${logcat.stderr}');
  }
}

Future<void> _captureHostTimeoutDiagnostics(Directory dir) async {
  if (Platform.isMacOS) {
    await _runDiagnosticProcess('screencapture', [
      '-x',
      '${dir.path}/host-screen.png',
    ]);
  } else if (Platform.isLinux) {
    await _runDiagnosticProcess('scrot', ['${dir.path}/host-screen.png']);
  }
}

Future<void> _captureVmDeviceFrames(Directory dir, String output) async {
  final url = _vmServiceUrl(output);
  if (url == null) return;
  FlutterDriver? driver;
  try {
    driver = await FlutterDriver.connect(
      dartVmServiceUrl: url,
    ).timeout(_diagnosticTimeout);
    final csv = await driver
        .runUnsynchronized(() => driver!.requestData('device-numbers'))
        .timeout(_diagnosticTimeout);
    final numbers = csv.isEmpty ? <int>[] : csv.split(',').map(int.parse);
    for (final n in numbers) {
      try {
        final b64 = await driver
            .runUnsynchronized(() => driver!.requestData('device-screen:$n'))
            .timeout(_diagnosticTimeout);
        await File('${dir.path}/device-$n.png').writeAsBytes(base64Decode(b64));
      } catch (_) {}
    }
  } catch (_) {
  } finally {
    try {
      await driver?.close().timeout(_diagnosticTimeout);
    } catch (_) {}
  }
}

String? _vmServiceUrl(String output) {
  final m = RegExp(r'(http://127\.0\.0\.1:\d+/[^\s]+)').firstMatch(output);
  return m?.group(1);
}

Future<ProcessResult?> _runDiagnosticProcess(
  String executable,
  List<String> args, {
  Encoding? stdoutEncoding = utf8,
}) async {
  try {
    return await Process.run(
      executable,
      args,
      stdoutEncoding: stdoutEncoding,
      stderrEncoding: utf8,
    ).timeout(_diagnosticTimeout);
  } catch (_) {
    return null;
  }
}

/// Best-effort reap of a timed-out test: it never ran its own teardown, so kill what it spawned — the
/// app on its emulator, the `flutter run` driving that serial, its per-session regtest backend
/// (`rt-<testpid>`), and the process itself. Serial-scoped, so a parallel run's other workers survive.
Future<void> _reapHungTest(Process proc, String? serial, String? sdk) async {
  if (serial != null && sdk != null) {
    await Process.run('$sdk/platform-tools/adb', [
      '-s',
      serial,
      'shell',
      'am',
      'force-stop',
      'com.frostsnap',
    ]);
    await Process.run('pkill', ['-9', '-f', 'sim_app.dart -d $serial']);
  }
  await reapRegtestSessionDir(Directory('${simTmpRoot().path}/rt-${proc.pid}'));
  await _killProcessTree(proc.pid);
}

Future<void> _killProcessTree(int rootPid) async {
  final pids = await _processTree(rootPid);
  if (pids.isEmpty) return;
  _signalPids(pids, ProcessSignal.sigterm);
  await Future<void>.delayed(const Duration(milliseconds: 500));
  _signalPids(pids, ProcessSignal.sigkill);

  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (DateTime.now().isBefore(deadline)) {
    if ((await _alivePids(pids)).isEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void _signalPids(List<int> pids, ProcessSignal signal) {
  for (final pid in pids.reversed) {
    try {
      Process.killPid(pid, signal);
    } catch (_) {}
  }
}

Future<Set<int>> _alivePids(List<int> pids) async {
  final ps = await Process.run('ps', ['-ax', '-o', 'pid=']);
  if (ps.exitCode != 0) return {};
  final alive = <int>{};
  for (final line in (ps.stdout as String).split('\n')) {
    final pid = int.tryParse(line.trim());
    if (pid != null) alive.add(pid);
  }
  return pids.where(alive.contains).toSet();
}

Future<List<int>> _processTree(int rootPid) async {
  final ps = await Process.run('ps', ['-ax', '-o', 'pid=,ppid=']);
  if (ps.exitCode != 0) return [rootPid];
  final children = <int, List<int>>{};
  var rootAlive = false;
  for (final line in (ps.stdout as String).split('\n')) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    final pid = int.tryParse(parts[0]);
    final ppid = int.tryParse(parts[1]);
    if (pid == null || ppid == null) continue;
    if (pid == rootPid) rootAlive = true;
    children.putIfAbsent(ppid, () => []).add(pid);
  }

  final ordered = <int>[];
  void visit(int pid) {
    ordered.add(pid);
    for (final child in children[pid] ?? const <int>[]) {
      visit(child);
    }
  }

  visit(rootPid);
  return rootAlive || ordered.length > 1 ? ordered : <int>[];
}

/// Run [task] over [items] with at most [jobs] running concurrently (a bounded worker pool). Workers
/// pull from a shared queue; the Dart event loop is single-threaded, so `failed.add` from concurrent
/// tasks doesn't race.
Future<void> _runBounded(
  List<_TestSpec> items,
  int jobs,
  Future<void> Function(_TestSpec, int workerSlot) task,
) async {
  final queue = [...items];
  final workers = (jobs < 1 ? 1 : jobs).clamp(1, items.length);
  await Future.wait(
    List.generate(workers, (workerSlot) async {
      while (queue.isNotEmpty) {
        await task(queue.removeAt(0), workerSlot);
      }
    }),
  );
}

// ---- platform resolution: --android boots/reuses an emulator ----

/// The flutter device a launch targets. `--android` boots (or reuses) an emulator and returns its
/// serial — so the sim runs on a phone, driven via the slide-in tray; device-channel CLI commands
/// are then host-only. Otherwise `--platform <d>` (default: the host desktop OS), the desktop sim.
Future<String> _resolvePlatform(List<String> args) async {
  if (args.contains('--android')) return _claimAndBootSessionEmulator();
  var platform = Platform.isLinux ? 'linux' : 'macos';
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--platform') platform = args[i + 1];
  }
  return platform;
}

/// Every running emulator serial (`emulator-<port>`) per `adb devices`.
Future<Set<String>> _runningSerials(String sdk) async {
  final res = await Process.run('$sdk/platform-tools/adb', ['devices']);
  final serials = <String>{};
  for (final line in (res.stdout as String).split('\n')) {
    final m = RegExp(r'^(emulator-\d+)\s+device$').firstMatch(line.trim());
    if (m != null) serials.add(m.group(1)!);
  }
  return serials;
}

/// Grace for an EMPTY lock (created, but its owner pid not yet written) before it counts as abandoned —
/// generously longer than the microsecond create→write gap, so a live mid-write claim is never stolen.
const _lockWriteGrace = Duration(seconds: 10);

/// Whether an existing slot lock is STALE — reclaimable. STRICT on live owners: while the recorded owner PID
/// is alive the lock is NEVER stale, however long its boot / first-run SDK+AVD setup takes — so a second
/// session can't steal a slow-but-legitimate claimant that may still return the slot. Reclaim only when the
/// owner PID is gone, or — for a lock whose pid was never written (a claimer that died between create and
/// write) — once it's older than [_lockWriteGrace].
bool _lockIsStale(File lock) {
  int? owner;
  try {
    owner = int.tryParse(lock.readAsStringSync().trim());
  } catch (_) {}
  if (owner != null) {
    // A live owner is never stolen; reclaim only once its process is gone (SIGCONT = harmless probe).
    return !Process.killPid(owner, ProcessSignal.sigcont);
  }
  // No pid yet: a claimer mid-write (µs) or one that died between create and write. Reclaim only past the
  // write grace, which cannot overlap a live mid-write.
  try {
    return DateTime.now().difference(lock.statSync().modified) >
        _lockWriteGrace;
  } catch (_) {
    return false; // vanished/unreadable — let the exclusive-create retry decide
  }
}

/// Machine-global per-slot lock so only ONE session ever boots a given interactive slot. Probe-then-boot is
/// otherwise racy: two `up --android` can both see a slot free, both start `-port N`, and the LOSER's
/// [bootEmulator] then waits on + returns the WINNER's `emulator-N`. Exclusive-create is atomic AND the lock
/// records the owner PID; a held lock is reclaimed only when [_lockIsStale] — a live boot in progress is
/// never stolen.
bool _claimSlotLock(int slot) {
  final lock = File('${simTmpRoot().path}/interactive-slot-$slot.lock');
  try {
    lock.createSync(exclusive: true);
    lock.writeAsStringSync('$pid'); // owner PID for [_lockIsStale]
    return true;
  } catch (_) {
    if (!_lockIsStale(lock))
      return false; // live owner mid-boot — don't steal it
    try {
      lock.deleteSync();
      lock.createSync(
        exclusive: true,
      ); // reclaim; only one wins the exclusive create
      lock.writeAsStringSync('$pid');
      return true;
    } catch (_) {
      return false;
    }
  }
}

void _releaseSlotLock(int slot) {
  try {
    File('${simTmpRoot().path}/interactive-slot-$slot.lock').deleteSync();
  } catch (_) {}
}

/// Claim a free interactive-SESSION emulator slot and boot its OWN emulator (cold, clean), returning the
/// serial — so each `up --android` session gets a distinct emulator. The per-slot lock ([_claimSlotLock])
/// makes the claim ATOMIC across sessions; it's held only across the boot. Under the lock we re-check FRESH
/// `adb devices` for the slot's serial (a snapshot would be stale: a concurrent session can boot the slot +
/// release its boot-only lock, after which bootEmulator would wait on + return ITS emulator). The AVD per
/// slot is created on demand + NAME-isolated from the pool and the legacy interactive AVD. Errors if the
/// range is exhausted.
Future<String> _claimAndBootSessionEmulator() async {
  final sdk = androidSdkRoot();
  for (var slot = 0; slot < maxInteractiveSessions; slot++) {
    if (!_claimSlotLock(slot)) continue;
    try {
      // Fresh, under the lock: if this slot's emulator is ALREADY running (a concurrent session booted it
      // then released its lock), it's taken — advance rather than return its serial.
      if ((await _runningSerials(
        sdk,
      )).contains(interactiveSessionSerial(slot))) {
        continue;
      }
      final avd = await ensureAvd(sdk, interactiveSessionAvd(slot));
      stderr.writeln(
        'fsim: booting session emulator "$avd" (slot $slot, cold) …',
      );
      final serial = await bootEmulator(
        sdk,
        avd: avd,
        port: interactiveSessionPort(slot),
      );
      await provisionEmulator(sdk, serial);
      return serial;
    } catch (e) {
      stderr.writeln('fsim: session slot $slot boot failed ($e); next slot …');
    } finally {
      // Release the boot-only lock (whether we booted, skipped a running slot, or failed) — the emulator is
      // now in `adb devices`, so the fresh-serial check keeps other sessions off this slot.
      _releaseSlotLock(slot);
    }
  }
  throw StateError(
    'fsim: all $maxInteractiveSessions interactive android session slots are busy — '
    '`down` another session first',
  );
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
  // `FSIM_READY` / `FSIM_FAILED` line. `up` launches us detached (our stdio -> /dev/null) and
  // TAILS this file to stream progress to its own stdout and learn the real outcome — so no caller
  // ever has to poll the socket or guess at liveness.
  _stateRoot.createSync(recursive: true);
  final logSink = File('${_stateRoot.path}/serve.log').openWrite();
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
  // This session's OWN regtest backend (under <dir>/.fsim/regtest): started below, held for the daemon's
  // lifetime so it self-reaps on a hard kill (the death-pipe), and stopped in shutdown() on a graceful down.
  RegtestSession? rtSession;
  // Host-only liveness socket the app holds open + exits when it drops, so a hard-killed serve doesn't
  // orphan the app window (the app-side analogue of the regtest death-pipe). Accepted connections are
  // RETAINED in [livenessClients] so they aren't GC'd/finalized (which could close one and make the app
  // exit while we're still alive).
  ServerSocket? livenessSocket;
  final livenessClients = <Socket>{};
  try {
    serveLog('fsim: resolving target …');
    platform = await _resolvePlatform(args);
    isHost = _hostPlatforms.contains(platform);
    serveLog('fsim: target $platform (${isHost ? 'host' : 'emulator'})');
    if (args.contains('--android')) {
      // Record our self-booted SESSION emulator so `down`/`clean` reap EXACTLY it — even if this daemon is
      // hard-killed and shutdown() never runs.
      File('${_stateRoot.path}/emulator-serial').writeAsStringSync(platform);
    }

    // Regtest: this session owns its OWN backend under <dir>/.fsim/regtest — started here, reaped on
    // shutdown (or self-reaped via the death-pipe on a hard kill), so `down` leaves no orphan and no shared
    // node is touched. On host the app reaches its unix control socket + electrum TCP directly; on an
    // emulator those host endpoints are unreachable, so bridge them over adb (best-effort: a bridge failure
    // degrades to an OFFLINE session rather than sinking the bring-up).
    if (wantRegtest) {
      serveLog(
        'fsim: starting session regtest under ${_stateRoot.path}/regtest …',
      );
      rtSession = await startRegtestSession(
        Directory('${_stateRoot.path}/regtest'),
      );
      if (isHost) {
        extraDefines['SIM_REGTEST_ELECTRUM_URL'] = rtSession.url;
        extraDefines['SIM_REGTEST_CONTROL_SOCKET'] = rtSession.controlSocket;
      } else {
        try {
          serveLog('fsim: bridging regtest to $platform over adb …');
          final adb = '${androidSdkRoot()}/platform-tools/adb';
          final ePort = electrumPort(rtSession.url);
          await runInheritStdio(adb, [
            '-s',
            platform,
            'reverse',
            'tcp:$ePort',
            'tcp:$ePort',
          ]);
          extraDefines['SIM_REGTEST_ELECTRUM_URL'] = rtSession.url;
          controlProxy = await bridgeUnixOverTcp(rtSession.controlSocket);
          await runInheritStdio(adb, [
            '-s',
            platform,
            'reverse',
            'tcp:${controlProxy.port}',
            'tcp:${controlProxy.port}',
          ]);
          extraDefines['SIM_REGTEST_CONTROL_SOCKET'] =
              '127.0.0.1:${controlProxy.port}';
          serveLog(
            'fsim: regtest bridged — electrs tcp:$ePort, faucet tcp:${controlProxy.port}',
          );
        } catch (e) {
          serveLog('fsim: regtest bridge failed, continuing OFFLINE: $e');
          extraDefines.clear();
          await controlProxy?.close();
          controlProxy = null;
        }
      }
    }

    // Host only: bind a liveness socket the app holds open + exits when it drops, so a hard-killed serve
    // doesn't orphan the app window. An emulator app can't reach a host unix socket, and its window IS the
    // emulator (owned separately), so this is host-desktop-only. Wired to the app via the env below.
    if (isHost) {
      final livenessPath = '${_stateRoot.path}/liveness.sock';
      try {
        File(livenessPath).deleteSync();
      } catch (_) {}
      livenessSocket = await ServerSocket.bind(
        InternetAddress(livenessPath, type: InternetAddressType.unix),
        0,
      );
      // Accept + RETAIN each connection (never read/write): held for the session so it isn't GC'd; dropped
      // from the set when it closes. When this daemon dies the OS closes the socket → the app reads EOF.
      livenessSocket.listen((conn) {
        livenessClients.add(conn);
        conn.listen(
          (_) {},
          onDone: () => livenessClients.remove(conn),
          onError: (_) => livenessClients.remove(conn),
          cancelOnError: true,
        );
      });
      extraDefines['SIM_SERVE_LIVENESS_SOCKET'] = livenessPath;
    }

    serveLog('fsim: launching the app on $platform (first build is slow) …');
    // One session shape (devices drive over the app channel everywhere); regtest is wired purely through
    // extraDefines above (this session's own backend), so _launchApp never touches a shared node.
    harness = await AppSession.launch(
      deviceCount: count,
      flutterDevice: platform,
      agentOwnsKeyboard: agentOwnsKeyboard,
      withRegtest: false,
      extraDartDefines: extraDefines,
      appDirRoot: _stateRoot,
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
    serveLog('FSIM_FAILED: $e');
    logSink.writeln('$st');
    await logSink.flush();
    exit(1);
  }
  serveLog('FSIM_READY $_socketPath');
  stdout.writeln('FSIM_READY $_socketPath');

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
      // tearDown reaps the app orderly on a graceful down; only THEN close the liveness socket, so its
      // watcher stays a pure hard-kill backstop (never fires mid-teardown).
      await harness.tearDown();
      for (final c in livenessClients.toList()) {
        try {
          await c.close();
        } catch (_) {}
      }
      await livenessSocket?.close();
      // Gracefully reap this session's regtest (the death-pipe is the backstop for a hard kill).
      await rtSession?.stop();
      // Reap our self-booted session emulator (`clean` recovers a hard-killed session's via the recorded
      // serial).
      if (args.contains('--android')) {
        await killEmulator(androidSdkRoot(), platform);
        try {
          File('${_stateRoot.path}/emulator-serial').deleteSync();
        } catch (_) {}
      }
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
  // away and `./fsim up` RELAUNCHES instead of reporting already:true. (The captured app output
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

  // Every command — device driving included — runs over the app channel (driver-data → the in-process
  // simDevicePool), so it works on host AND emulator. No host-only device sockets, no SimHarness vs
  // AppSession split, and no channel-cache to reconcile: the app-side fleet is the only source.
  final cmd = req['cmd'];
  try {
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
                  'app directly, or relaunch with `./fsim serve --agent-owns-keyboard`',
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
        // The daemon's LAUNCH shape — `./fsim up` compares `count` against the requested
        // --devices to decide whether an already-live daemon satisfies the request. It's the
        // launch count, NOT the live count, so runtime adds (tray / add-device) don't flip
        // idempotence. `currentDevices` reports the live fleet (the app-side source of truth) for
        // introspection.
        final current = (await h.deviceNumbers()).length;
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
        for (final n in await h.deviceNumbers()) {
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
/// `./fsim serve` builds + launches the app (cold builds take a while), so a `./fsim <cmd>`
/// fired right after should just block until the control socket is ready — no external
/// "wait for FSIM_READY" polling. Retries until [FSIM_WAIT_SECS] (default 300s), then
/// gives up so a genuine missing-daemon mistake still errors. Announces once so a wait is
/// visible, not a silent hang.
Future<Socket> _connectWaiting() async {
  final addr = InternetAddress(_socketPath, type: InternetAddressType.unix);
  final waitSecs =
      int.tryParse(Platform.environment['FSIM_WAIT_SECS'] ?? '') ?? 300;
  final deadline = DateTime.now().add(Duration(seconds: waitSecs));
  var announced = false;
  while (true) {
    try {
      return await Socket.connect(addr, 0);
    } on SocketException {
      if (DateTime.now().isAfter(deadline)) rethrow;
      if (!announced) {
        stderr.writeln('fsim: waiting for the sim daemon to come up …');
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
    stderr.writeln('fsim: no daemon at $_socketPath (run `fsim serve`): $e');
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

/// Translate `fsim <cmd> ...` argv into the wire command, or null if unrecognized.
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
