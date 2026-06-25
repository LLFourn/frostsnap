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
                                              devices via `./simctl` (below) or the in-app tray
  simctl info                                 print the running daemon's shape (platform/count/regtest)
  simctl test [NAMES...] [--android] [--jobs N]
                                              run e2e driver tests (stems; ALL if none) IN PARALLEL —
                                              host: one `dart run` each; --android: each on its OWN
                                              pool emulator + (if it uses regtest) its OWN chain
                                              bridged to that emulator (degrades to however many
                                              boot). --jobs caps parallelism (default = all at once)
  simctl regtest up|down|status               manage the shared regtest bitcoind+electrs+faucet
  simctl regtest fund <addr> <sats> | mine [n] | balance | height | address | url   drive the faucet
  simctl pool status|acquire [--cap N]|release <slot>|reset
                                              inspect/manage the test emulator pool (dedicated
                                              per-test emulators, name-isolated from the interactive
                                              one); the parallel test runner allocates from it
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
  } else if (args.first == 'pool') {
    await _pool(args.skip(1).toList());
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
  // Reap any pooled emulators before deleting their lockfile registry, else they orphan.
  // Best-effort: a no-op when there's no Android SDK (host-only checkout).
  try {
    final claimed = _claimedSlots();
    if (claimed.isNotEmpty) {
      final sdk = androidSdkRoot();
      for (final slot in claimed) {
        _releaseEmulator(sdk, slot);
      }
    }
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

/// Run one driver test by its file STEM (`<stem>_drive.dart`), or all of them with no arg.
/// Each runs as its own `dart run` so they get a fresh app/harness; a non-zero exit from any
/// fails the whole run. Replaces the per-test justfile recipes — a new test is just a new
/// `*_drive.dart` file, discovered here automatically.
Future<void> _runTests(List<String> args) async {
  // Runs the named tests (or ALL if none) IN PARALLEL. On `--android`, each test runs on its own
  // DEDICATED pool emulator (Task 1's allocator); on host, each is a self-contained `dart run`. Each
  // test owns its isolated state (a fresh emulator/app dir + its own per-session regtest chain, bridged
  // to its emulator on `--android`), so there's no shared state to serialize around. `--jobs N` caps
  // the parallelism; default = run them all at once (degrading to however many emulators boot).
  final android = args.contains('--android');
  int? jobs; // null = "as many as possible"
  final positional = <String>[];
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--android') continue;
    if (a == '--jobs') {
      jobs = int.parse(args[++i]);
      continue;
    }
    if (a.startsWith('--')) continue;
    positional.add(a);
  }

  final stems = <String, String>{}; // stem -> filename
  for (final entry in Directory('test_driver').listSync()) {
    final name = entry.uri.pathSegments.last;
    if (entry is File && name.endsWith('_drive.dart')) {
      stems[name.substring(0, name.length - '_drive.dart'.length)] = name;
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

  // Default to running every test at once; the android pool degrades to however many emulators boot.
  final effJobs = (jobs ?? files.length).clamp(1, files.length);
  final failed = <String>[];
  if (android) {
    await _runAndroidPool(files, effJobs, failed);
  } else {
    // Host: each test is a self-contained `dart run` (owns its PRIVATE per-session regtest chain), so
    // up to `effJobs` run concurrently with no shared state. Concurrent output is captured + printed
    // grouped on completion (interleaved live streams would be unreadable); a single test streams live.
    final capture = effJobs > 1;
    await _runBounded(files, effJobs, (file) async {
      if (!capture) stdout.writeln('=== simctl test: $file ===');
      final proc = await Process.start(
        'dart',
        ['run', 'test_driver/$file'],
        mode: capture ? ProcessStartMode.normal : ProcessStartMode.inheritStdio,
      );
      if (!capture) {
        if (await proc.exitCode != 0) failed.add(file);
        return;
      }
      final buf = StringBuffer();
      final outDone = proc.stdout.transform(utf8.decoder).forEach(buf.write);
      final errDone = proc.stderr.transform(utf8.decoder).forEach(buf.write);
      final code = await proc.exitCode;
      await Future.wait([outDone, errDone]);
      stdout.writeln(
        '=== simctl test: $file ${code == 0 ? 'PASSED' : 'FAILED'} ===\n$buf',
      );
      if (code != 0) failed.add(file);
    });
  }

  if (files.length > 1) {
    stdout.writeln(
      '=== simctl test: ${files.length - failed.length}/${files.length} passed'
      '${failed.isEmpty ? '' : ' — FAILED: ${failed.join(', ')}'} ===',
    );
  }
  exit(failed.isEmpty ? 0 : 1);
}

/// Run [files] across the emulator POOL: spawn up to [jobs] workers, each acquiring its OWN dedicated
/// pool emulator (Task 1's allocator) and running queued tests on it (`pm clear` between for fresh
/// app state), releasing it on finish. A worker that can't boot an emulator drops out — so this
/// DEGRADES to however many emulators actually boot (down to one = serial) rather than failing. Per-
/// test output is captured + printed grouped (workers interleave) when more than one test runs.
Future<void> _runAndroidPool(
  List<String> files,
  int jobs,
  List<String> failed,
) async {
  final sdk = androidSdkRoot();
  final adb = '$sdk/platform-tools/adb';
  final queue = [...files];
  final capture = files.length > 1;
  final workers = jobs.clamp(1, files.length);
  stdout.writeln(
    '=== simctl test: ${files.length} test(s) across up to $workers pool emulator(s) ===',
  );

  // NB: concurrent `flutter run` builds write the shared build/ dir and would corrupt the packaged
  // native lib — they're serialized by a cross-process build lock in the harness's `_launchApp`
  // (released once each app's VM service is up), so only the slow test EXECUTION overlaps. Nothing to
  // pre-build here.

  var acquiredAny = false;

  Future<void> runOne(String serial, String file) async {
    await Process.run(adb, [
      '-s',
      serial,
      'shell',
      'pm',
      'clear',
      'com.frostsnap',
    ]);
    if (!capture) stdout.writeln('=== simctl test: $file on $serial ===');
    final proc = await Process.start(
      'dart',
      ['run', 'test_driver/$file'],
      mode: capture ? ProcessStartMode.normal : ProcessStartMode.inheritStdio,
      environment: {'SIM_FLUTTER_DEVICE': serial},
    );
    if (!capture) {
      if (await proc.exitCode != 0) failed.add(file);
      return;
    }
    final buf = StringBuffer();
    final outDone = proc.stdout.transform(utf8.decoder).forEach(buf.write);
    final errDone = proc.stderr.transform(utf8.decoder).forEach(buf.write);
    final code = await proc.exitCode;
    await Future.wait([outDone, errDone]);
    stdout.writeln(
      '=== simctl test: $file on $serial ${code == 0 ? 'PASSED' : 'FAILED'} ===\n$buf',
    );
    if (code != 0) failed.add(file);
  }

  await Future.wait(
    List.generate(workers, (_) async {
      ({int slot, String serial}) emu;
      try {
        emu = await _acquireEmulator(sdk, cap: workers);
      } catch (e) {
        stderr.writeln(
          'simctl: a pool worker could not boot an emulator ($e) — running with fewer in parallel',
        );
        return;
      }
      acquiredAny = true;
      try {
        while (queue.isNotEmpty) {
          await runOne(emu.serial, queue.removeAt(0));
        }
      } finally {
        _releaseEmulator(sdk, emu.slot);
      }
    }),
  );

  if (!acquiredAny) {
    stderr.writeln('simctl: could not boot ANY pool emulator');
    failed.addAll(queue); // nothing ran
  }
}

/// Run [task] over [items] with at most [jobs] running concurrently (a bounded worker pool). Workers
/// pull from a shared queue; the Dart event loop is single-threaded, so `failed.add` from concurrent
/// tasks doesn't race.
Future<void> _runBounded(
  List<String> items,
  int jobs,
  Future<void> Function(String) task,
) async {
  final queue = [...items];
  final workers = (jobs < 1 ? 1 : jobs).clamp(1, items.length);
  await Future.wait(
    List.generate(workers, (_) async {
      while (queue.isNotEmpty) {
        await task(queue.removeAt(0));
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

/// The simctl-managed AVD; created on first use, reused after.
const _avdName = 'frostsnap_sim';

/// Whether [serial] is running a pool AVD (the `frostsnap_sim_pool` prefix). The interactive path
/// uses this to skip pool emulators — true AVD ownership, not a port/serial guess.
Future<bool> _isPoolEmulator(String sdk, String serial) async {
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
/// [excludePool], skips pool-owned emulators (by AVD name) so `up`/`serve` can never reuse one.
Future<String?> _runningEmulatorSerial(
  String sdk, {
  bool excludePool = false,
}) async {
  final res = await Process.run('$sdk/platform-tools/adb', ['devices']);
  for (final line in (res.stdout as String).split('\n')) {
    final m = RegExp(r'^(emulator-\d+)\s+device$').firstMatch(line.trim());
    if (m == null) continue;
    final serial = m.group(1)!;
    if (excludePool && await _isPoolEmulator(sdk, serial)) continue;
    return serial;
  }
  return null;
}

/// Boot an emulator (reusing a running one, else provisioning + booting [_avdName]) and return its
/// serial once `sys.boot_completed` is set.
Future<String> _ensureEmulatorBooted() async {
  final sdk = androidSdkRoot();
  final existing = await _runningEmulatorSerial(sdk, excludePool: true);
  if (existing != null) {
    stderr.writeln('simctl: reusing the running emulator $existing');
    await _provisionEmulator(sdk, existing);
    return existing;
  }
  final avd = await _ensureAvd(sdk);
  stderr.writeln('simctl: booting emulator AVD "$avd" (cold, clean state) …');
  // Boot on the FIXED interactive port (clear of the pool's `_poolBasePort`+), so every wait/probe
  // below targets `_interactiveSerial`. An untargeted `adb wait-for-device`/`adb shell` would return
  // for / fail against a concurrently-running pool emulator ("more than one device"), so the
  // interactive bring-up must not depend on being the only emulator connected.
  //
  // `-wipe-data` cold-boots a CLEAN package DB. Repeated `flutter run` installs otherwise corrupt
  // the package state on a long-lived emulator — the launcher activity stops resolving (am start ->
  // -92), so the app never launches and bring-up dies on the VM-service timeout. A clean boot is
  // reliable; a warm reuse (above) keeps later `up`s in the same session fast.
  await Process.start('$sdk/emulator/emulator', [
    '-avd',
    avd,
    '-port',
    '$_interactivePort',
    '-no-snapshot',
    '-wipe-data',
    '-no-boot-anim',
    '-gpu',
    'auto',
  ], mode: ProcessStartMode.detached);
  await _waitForBoot(sdk, serial: _interactiveSerial);
  await _provisionEmulator(sdk, _interactiveSerial);
  return _interactiveSerial;
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
  // Unlock past the keyguard. Feed the PIN to the bouncer ONLY when the device is actually locked (a
  // secure PIN set AND the keyguard engaged) — `dumpsys trust` reports `deviceLocked=1` exactly then.
  // Typing it unconditionally was a bug: on a fresh emulator (no PIN, keyguard already dismissed) the
  // `0000` has no PIN field, so it lands on whatever IS focused — the launcher's Google search box —
  // and fires a stray web search. `deviceLocked` is 0 for an insecure/already-unlocked device, so the
  // guard correctly skips it there and only types into a real bouncer.
  await sh(['wm', 'dismiss-keyguard']);
  final trust = await Process.run(adb, [
    '-s',
    serial,
    'shell',
    'dumpsys',
    'trust',
  ]);
  if ((trust.stdout as String).contains('deviceLocked=1')) {
    await sh(['input', 'text', '0000']);
    await sh(['input', 'keyevent', 'KEYCODE_ENTER']);
  }
  // Set the PIN while unlocked + awake, so it's configured but the session stays unlocked (a no-op
  // exit if one already exists). This is REQUIRED, not cosmetic: the app's SecureKeyManager
  // (getOrCreateKey) fails fast with NO_LOCK_SCREEN unless `isDeviceSecure`, because its signing key
  // is `setUserAuthenticationRequired(true)` — so the sim can't keygen/sign without a secure lock.
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

String get _sysImage =>
    'system-images;android-34;google_apis;${_hostArchIsArm() ? 'arm64-v8a' : 'x86_64'}';

/// Install the emulator package + system image once (idempotent; gated on the image already being
/// present, so per-AVD callers don't re-run the slow check). The first run is a large download.
Future<void> _ensureSdkPackages(String sdk) async {
  final abi = _hostArchIsArm() ? 'arm64-v8a' : 'x86_64';
  if (File('$sdk/emulator/emulator').existsSync() &&
      Directory(
        '$sdk/system-images/android-34/google_apis/$abi',
      ).existsSync()) {
    return;
  }
  final sdkmanager = '$sdk/cmdline-tools/latest/bin/sdkmanager';
  stderr.writeln(
    'simctl: provisioning emulator + $_sysImage (one-time, large download) …',
  );
  // Accept any pending licenses, then install (feeding "y" covers per-package license prompts).
  await _runFeeding(sdkmanager, ['--licenses'], 'y\n' * 50);
  await _runFeeding(sdkmanager, [
    '--install',
    'emulator',
    'platform-tools',
    _sysImage,
  ], 'y\n' * 50);
}

/// Ensure AVD [avd] exists (creating it if missing), installing the SDK packages first if needed.
/// Idempotent. Used for the interactive AVD and for each pool AVD.
Future<String> _ensureAvd(String sdk, {String avd = _avdName}) async {
  final avdIni = '${Platform.environment['HOME']}/.android/avd/$avd.ini';
  if (File(avdIni).existsSync()) return avd;
  await _ensureSdkPackages(sdk);
  final avdmanager = '$sdk/cmdline-tools/latest/bin/avdmanager';
  stderr.writeln('simctl: creating AVD "$avd" …');
  // "no" declines the custom-hardware-profile prompt.
  await _runFeeding(avdmanager, [
    'create',
    'avd',
    '-n',
    avd,
    '-k',
    _sysImage,
    '--device',
    'pixel_6',
    '--force',
  ], 'no\n');
  return avd;
}

bool _hostArchIsArm() {
  try {
    return (Process.runSync('uname', ['-m']).stdout as String).trim() ==
        'arm64';
  } catch (_) {
    return false;
  }
}

/// adb wait-for-device + poll `sys.boot_completed` for the SPECIFIC [serial] (every emulator boots on
/// a known fixed port, so we always target one device). Targeting matters: an untargeted poll fails
/// with "more than one device" once the pool and the interactive emulator run concurrently.
Future<void> _waitForBoot(String sdk, {required String serial}) async {
  final adb = '$sdk/platform-tools/adb';
  await _run(adb, ['-s', serial, 'wait-for-device']);
  final deadline = DateTime.now().add(const Duration(minutes: 5));
  while (DateTime.now().isBefore(deadline)) {
    final r = await Process.run(adb, [
      '-s',
      serial,
      'shell',
      'getprop',
      'sys.boot_completed',
    ]);
    if ((r.stdout as String).trim() == '1') return;
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  throw StateError('emulator $serial did not finish booting within 5 minutes');
}

// ---- test emulator pool: a DEDICATED emulator per concurrent test (parallel-android-tests) ----

/// The interactive emulator's FIXED port + serial. Kept below `_poolBasePort` so it never collides
/// with a pool slot, and fixed so interactive bring-up can target it even when pool emulators run.
const _interactivePort = 5554;
const _interactiveSerial = 'emulator-$_interactivePort';

/// Pool AVD name for slot [s] — the `frostsnap_sim_pool` prefix keeps it NAME-isolated from the
/// interactive `frostsnap_sim` AVD, so a pooled test can never boot/clear the interactive wallet.
String _poolAvd(int slot) => 'frostsnap_sim_pool_$slot';

/// First pool emulator port. Kept clear of the interactive emulator's default 5554 so the pool can
/// never collide with it. Slot s → port `_poolBasePort + 2s` → serial `emulator-(port)` (the
/// emulator assigns the serial from `-port`), so each slot has a DETERMINISTIC serial — no
/// boot-order/serial-diff race.
const _poolBasePort = 5582;
int _poolPort(int slot) => _poolBasePort + slot * 2;
String _poolSerial(int slot) => 'emulator-${_poolPort(slot)}';
Directory _poolDir() =>
    Directory('${simTmpRoot().path}/pool')..createSync(recursive: true);

/// Atomically claim the lowest free pool slot in `[0, cap)`, or null if all are busy. The claim is an
/// O_EXCL lockfile create (`exclusive: true`), so two concurrent runners can never grab the same slot
/// (the exact collision this pool prevents).
int? _claimSlot(int cap) {
  for (var slot = 0; slot < cap; slot++) {
    try {
      File('${_poolDir().path}/slot-$slot.lock').createSync(exclusive: true);
      return slot;
    } on FileSystemException {
      continue; // already claimed
    }
  }
  return null;
}

void _releaseSlot(int slot) {
  try {
    File('${_poolDir().path}/slot-$slot.lock').deleteSync();
  } catch (_) {}
}

Future<bool> _serialRunning(String sdk, String serial) async {
  final res = await Process.run('$sdk/platform-tools/adb', ['devices']);
  return (res.stdout as String)
      .split('\n')
      .any((l) => l.trim().startsWith('$serial\t'));
}

/// Acquire a DEDICATED test emulator: claim a free slot, ensure its pool AVD, cold-boot it on the
/// slot's fixed port (deterministic serial), provision it. Returns the slot + serial. The caller MUST
/// `_releaseEmulator(slot)` it (try/finally) to kill the instance and free the slot.
Future<({int slot, String serial})> _acquireEmulator(
  String sdk, {
  required int cap,
}) async {
  final slot = _claimSlot(cap);
  if (slot == null) throw StateError('emulator pool exhausted (cap $cap)');
  final serial = _poolSerial(slot);
  try {
    await _ensureAvd(sdk, avd: _poolAvd(slot));
    if (!await _serialRunning(sdk, serial)) {
      stderr.writeln(
        'simctl: pool slot $slot booting ${_poolAvd(slot)} → $serial …',
      );
      await Process.start('$sdk/emulator/emulator', [
        '-avd',
        _poolAvd(slot),
        '-port',
        '${_poolPort(slot)}',
        '-no-snapshot',
        '-wipe-data',
        '-no-boot-anim',
        '-gpu',
        'auto',
      ], mode: ProcessStartMode.detached);
      await _waitForBoot(sdk, serial: serial);
    }
    await _provisionEmulator(sdk, serial);
    return (slot: slot, serial: serial);
  } catch (_) {
    // KILL the instance before freeing the slot: if `Process.start` already booted it but boot/
    // provision then threw, releasing only the lock would orphan a running emulator that
    // `release`/`reset` can no longer reap (no claim). `emu kill` is a harmless no-op if unstarted.
    _releaseEmulator(sdk, slot);
    rethrow;
  }
}

/// Kill the slot's emulator and free the slot (idempotent — safe to call on a failed acquire).
void _releaseEmulator(String sdk, int slot) {
  Process.runSync('$sdk/platform-tools/adb', [
    '-s',
    _poolSerial(slot),
    'emu',
    'kill',
  ]);
  _releaseSlot(slot);
}

/// The currently-claimed pool slots (from the lockfile registry), sorted.
List<int> _claimedSlots() {
  final dir = _poolDir();
  if (!dir.existsSync()) return const [];
  return dir
      .listSync()
      .map((e) => RegExp(r'slot-(\d+)\.lock$').firstMatch(e.path)?.group(1))
      .whereType<String>()
      .map(int.parse)
      .toList()
    ..sort();
}

/// `./simctl pool <status|acquire|release|reset>` — inspect/manage the test emulator pool (the
/// allocator the parallel test runner uses). Separate from the interactive emulator by AVD name +
/// this lockfile registry, so it can never touch the interactive wallet.
Future<void> _pool(List<String> args) async {
  final sdk = androidSdkRoot();
  switch (args.isEmpty ? 'status' : args.first) {
    case 'status':
      stdout.writeln(
        jsonEncode({
          'ok': true,
          'claimed': [
            for (final s in _claimedSlots())
              {'slot': s, 'serial': _poolSerial(s)},
          ],
        }),
      );
    case 'acquire':
      var cap = 4;
      for (var i = 0; i < args.length - 1; i++) {
        if (args[i] == '--cap') cap = int.parse(args[i + 1]);
      }
      final emu = await _acquireEmulator(sdk, cap: cap);
      stdout.writeln(
        jsonEncode({'ok': true, 'slot': emu.slot, 'serial': emu.serial}),
      );
    case 'release':
      final slot = int.parse(args[1]);
      _releaseEmulator(sdk, slot);
      stdout.writeln(jsonEncode({'ok': true, 'released': slot}));
    case 'reset':
      for (final slot in _claimedSlots()) {
        _releaseEmulator(sdk, slot);
      }
      stdout.writeln(jsonEncode({'ok': true, 'reset': true}));
    default:
      stderr.writeln(
        'simctl pool <status | acquire [--cap N] | release <slot> | reset>',
      );
      exit(2);
  }
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
        final adb = '${androidSdkRoot()}/platform-tools/adb';
        final ePort = electrumPort(backend.url);
        await _run(adb, [
          '-s',
          platform,
          'reverse',
          'tcp:$ePort',
          'tcp:$ePort',
        ]);
        extraDefines['SIM_REGTEST_ELECTRUM_URL'] = backend.url;
        controlProxy = await bridgeUnixOverTcp(regtestControlSocket);
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
