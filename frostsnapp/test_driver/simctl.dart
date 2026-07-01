import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';

import 'emulator.dart';
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
                                              devices via `./simctl` (below) or the in-app tray
  simctl info                                 print the running daemon's shape (platform/count/regtest)
  simctl test [NAMES...] [--android] [--jobs N] [--test-timeout SECS] [--nocapture|-v] [--junit PATH]
                                              run e2e driver tests (stems; ALL if none) IN PARALLEL —
                                              host: one `dart run` each; --android: each SELF-BOOTS
                                              its OWN emulator + (if it uses regtest) bridges the
                                              shared chain to it. --jobs caps parallelism (default =
                                              all at once);
                                              --test-timeout (default 900s) reaps a wedged test as
                                              TIMEOUT so the run never stalls; raw output goes to
                                              build/sim-failures/<test>/output.log unless
                                              --nocapture/-v streams it live; --junit writes XML
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
 device commands (over the app channel — work on host AND emulator):
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
  // Reap any leftover self-booted test emulators (a crashed test/runner can orphan one past its own
  // reap) before wiping tmp. Best-effort: a no-op when there's no Android SDK (host-only checkout).
  try {
    await _reapTestEmulators(androidSdkRoot());
  } catch (_) {}
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
      '<testsuite name="simctl" tests="${results.length}" failures="$failed" '
      'errors="$timedOut" skipped="$skipped" retries="$retries" '
      'time="${_junitTime(elapsed)}">',
    );
  for (final r in results) {
    b.writeln(
      '  <testcase classname="simctl" name="${_xmlEscape(r.test.name)}" '
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
          'simctl test: no test "$name". Available: ${available.join(', ')}',
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
  final hostAppBinary = !android && Platform.isMacOS
      ? await AppSession.ensureMacosSimAppBuilt(logSink: stderr)
      : null;
  final androidAppBinary = android
      ? await AppSession.ensureAndroidSimApkBuilt(logSink: stderr)
      : null;
  final sdk = android ? androidSdkRoot() : null;
  await _runBounded(tests, effJobs, (test, workerSlot) async {
    final (r, retries) = await runWithRetry<_TestResult>(
      (_) => _runOneTest(
        test,
        flutterDevice: android ? 'android' : null,
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
        ? 'simctl: ${r.test.name} recovered after $retries transient-flake $s'
        : 'simctl: ${r.test.name} FAILED after ${retries + 1} attempts (transient startup flake persisted)',
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
/// are then host-only. Otherwise `--platform <d>` (default macos), the desktop sim.
Future<String> _resolvePlatform(List<String> args) async {
  if (args.contains('--android')) return _ensureEmulatorBooted();
  var platform = 'macos';
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--platform') platform = args[i + 1];
  }
  return platform;
}

/// The interactive simctl-managed AVD (`up`/`serve`); created on first use, reused after.
const _avdName = 'frostsnap_sim';

/// The interactive emulator's FIXED port — kept clear of the self-booted test emulators' range
/// ([emulatorBasePort]+) so interactive bring-up never collides with a running test emulator.
const _interactivePort = 5554;

/// Whether [serial] is running a self-booted TEST emulator (the `frostsnap_sim_pool` AVD prefix that
/// [emulatorAvd] assigns), so the interactive path can skip it — true AVD ownership, not a port guess.
Future<bool> _isTestEmulator(String sdk, String serial) async {
  final r = await Process.run('$sdk/platform-tools/adb', [
    '-s',
    serial,
    'emu',
    'avd',
    'name',
  ]);
  final name = (r.stdout as String).trim().split('\n').first.trim();
  return name.startsWith('frostsnap_sim_pool');
}

/// The serial of a running INTERACTIVE emulator (e.g. `emulator-5554`), or null if none is up. With
/// [excludeTestEmulators], skips self-booted test emulators (by AVD name) so `up`/`serve` never reuses one.
Future<String?> _runningEmulatorSerial(
  String sdk, {
  bool excludeTestEmulators = false,
}) async {
  final res = await Process.run('$sdk/platform-tools/adb', ['devices']);
  for (final line in (res.stdout as String).split('\n')) {
    final m = RegExp(r'^(emulator-\d+)\s+device$').firstMatch(line.trim());
    if (m == null) continue;
    final serial = m.group(1)!;
    if (excludeTestEmulators && await _isTestEmulator(sdk, serial)) continue;
    return serial;
  }
  return null;
}

/// Kill every running self-booted TEST emulator (best-effort) — a crashed test or runner can orphan one
/// past its own reap, so `simctl clean` sweeps them and none linger.
Future<void> _reapTestEmulators(String sdk) async {
  final res = await Process.run('$sdk/platform-tools/adb', ['devices']);
  for (final line in (res.stdout as String).split('\n')) {
    final m = RegExp(r'^(emulator-\d+)\s+device$').firstMatch(line.trim());
    if (m == null) continue;
    final serial = m.group(1)!;
    if (await _isTestEmulator(sdk, serial)) await killEmulator(sdk, serial);
  }
}

/// Boot an emulator (reusing a running one, else provisioning + booting [_avdName]) and return its
/// serial once `sys.boot_completed` is set.
Future<String> _ensureEmulatorBooted() async {
  final sdk = androidSdkRoot();
  final existing = await _runningEmulatorSerial(
    sdk,
    excludeTestEmulators: true,
  );
  if (existing != null) {
    stderr.writeln('simctl: reusing the running emulator $existing');
    await provisionEmulator(sdk, existing);
    return existing;
  }
  final avd = await ensureAvd(sdk, _avdName);
  stderr.writeln('simctl: booting emulator AVD "$avd" (cold, clean state) …');
  // Boot on the FIXED interactive port (clear of the self-booted test emulators' range) so
  // provisioning/probes target it even when test emulators run concurrently — a warm reuse (above)
  // keeps later `up`s in the same session fast.
  final serial = await bootEmulator(sdk, avd: avd, port: _interactivePort);
  await provisionEmulator(sdk, serial);
  return serial;
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
        final adb = '${androidSdkRoot()}/platform-tools/adb';
        final ePort = electrumPort(backend.url);
        await runInheritStdio(adb, [
          '-s',
          platform,
          'reverse',
          'tcp:$ePort',
          'tcp:$ePort',
        ]);
        extraDefines['SIM_REGTEST_ELECTRUM_URL'] = backend.url;
        controlProxy = await bridgeUnixOverTcp(regtestControlSocket);
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
    // One session shape now (devices drive over the app channel everywhere); the host/emulator
    // branch is only about regtest — a host session uses _launchApp's shared node directly, an
    // emulator gets regtest via the adb bridge above (extraDefines) with _launchApp's regtest off.
    harness = isHost
        ? await AppSession.launch(
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
