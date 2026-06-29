// The sim harness: one object ([AppSession]) that brings up the sim app + virtual devices, drives
// BOTH the app widget tree and the devices through one ergonomic API, and tears everything down (app
// process, the disposable app dir, all screenshots) as a unit.
//
//   - app (Flutter widget tree): driven by semantic label over flutter_driver / the VM service.
//     `app.*` + `screenshot()`.
//   - device (a framebuffer + touchscreen): driven via [AppDevice] (`device(n).*`) over the SAME app
//     channel — driver-data → the in-process `simDevicePool`.
//
// ONE transport (the app channel) on every platform: it works wherever flutter_driver can reach the
// VM service, including an adb-forwarded Android emulator. (Devices were once ALSO reachable over
// host `device-<n>.sock` sockets — a second transport that only worked on desktop; that split, and
// the [SimHarness] vs [AppSession] shapes it forced, are gone — see app-channel-only-device-driving.)
//
// Lives in test_driver/ so flutter_driver stays a dev dependency. Used by the e2e driver tests and
// by `simctl`.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';
import 'package:frostsnap/sim_faucet.dart';

import 'regtest.dart'
    show
        RegtestSession,
        androidSdkRoot,
        bridgeRegtestToEmulator,
        ensureRegtestBackend,
        regtestControlSocket,
        startRegtestSession;

/// Root for all sim temp artifacts — disposable app dirs, the simctl control socket,
/// ad-hoc screenshots — grouped under one folder instead of loose in the system temp
/// root. Created on demand.
Directory simTmpRoot() {
  final dir = Directory('${Directory.systemTemp.path}/frostsnap-sim');
  dir.createSync(recursive: true);
  return dir;
}

/// A scenario's PRIVATE regtest backend (its own chain), bound to the harness for the run and reaped
/// on tearDown. On Android the app's endpoints are bridged to its emulator; [_unbridge] tears that
/// bridge down (null on host, where the app reaches the session's unix socket + electrum directly).
class _ScenarioRegtest {
  final RegtestSession session;

  /// The launch config that points the app's regtest wallet + tray faucet at THIS session.
  final Map<String, String> defines;

  /// On Android, tears down the emulator bridge (close the faucet proxy + remove the adb reverses).
  /// Null on host, where the app reaches the session's endpoints directly.
  final Future<void> Function()? _unbridge;

  _ScenarioRegtest(this.session, this.defines, [this._unbridge]);

  Future<void> stop() async {
    try {
      await _unbridge?.call();
    } catch (_) {}
    await session.stop();
  }
}

/// A launched sim app: the Flutter process + FlutterDriver over the (possibly adb-forwarded) VM
/// service. Drives the app widget tree by semantic label (`app.*` + `screenshot()`) AND the virtual
/// devices ([device] → [AppDevice]) over the SAME app channel, so it's the ONE session shape for host
/// and emulator alike (`SimHarness` is now an alias for it).
class AppSession {
  final Process _appProcess;
  final Directory appDir;
  final FlutterDriver driver;
  final List<String> _appLog;
  final String flutterDevice;
  int _shotSeq = 0;

  /// This scenario's isolated regtest backend, if it ran `withRegtest` (see [faucet]). Owned by the
  /// session: reaped on [tearDown].
  _ScenarioRegtest? _regtest;

  AppSession(
    this._appProcess,
    this.appDir,
    this.driver,
    this._appLog,
    this.flutterDevice,
  );

  /// Connect to THIS scenario's private faucet (its own chain). The test drives funding/mining here,
  /// so parallel scenarios never share a chain. Throws if the scenario didn't request `withRegtest`.
  Future<SimFaucet> faucet() {
    final r = _regtest;
    if (r == null) {
      throw StateError(
        'scenario has no regtest backend (run with withRegtest: true)',
      );
    }
    return r.session.faucet();
  }

  /// Resolves when the launched app process exits — e.g. its window was closed, which (with
  /// `applicationShouldTerminateAfterLastWindowClosed`) terminates the launched app process.
  /// `simctl serve` watches this so the daemon never outlives a dead app (a zombie daemon would answer
  /// `up` with already:true against nothing).
  Future<int> get appExitCode => _appProcess.exitCode;

  /// Launch the instrumented sim app and return a session that drives the app + devices over the app
  /// channel. [agentOwnsKeyboard] true routes text through the driver's mock input so [enterText]
  /// works but the real keyboard is blocked; false hands the keyboard to a human.
  static Future<AppSession> launch({
    int deviceCount = 1,
    String flutterDevice = 'macos',
    bool agentOwnsKeyboard = true,
    bool withRegtest = false,
    Map<String, String> extraDartDefines = const {},
    IOSink? logSink,
  }) async {
    // An AppSession holds no host device sockets, but the launch shape still depends on whether the
    // target shares the host filesystem: a desktop host uses our disposable appDir (and has no build
    // flavor); an emulator keeps its sandbox app-support dir (host paths are meaningless there) and
    // needs the `direct` build flavor.
    final hostPlatform = const {
      'macos',
      'linux',
      'windows',
    }.contains(flutterDevice);
    final (proc, dir, drv, log) = await _launchApp(
      deviceCount: deviceCount,
      flutterDevice: flutterDevice,
      agentOwnsKeyboard: agentOwnsKeyboard,
      withRegtest: withRegtest,
      extraDartDefines: extraDartDefines,
      shareHostAppDir: hostPlatform,
      flavor: hostPlatform ? null : 'direct',
      logSink: logSink,
    );
    return AppSession(proc, dir, drv, log, flutterDevice);
  }

  static const _macosSimAppBinary =
      'build/macos/Build/Products/Debug/Frostsnap.app/Contents/MacOS/Frostsnap';

  /// Build the macOS debug sim app once. Parallel workers direct-launch this binary so they don't
  /// serialize on `flutter run`'s shared build directory.
  static Future<String> ensureMacosSimAppBuilt({
    IOSink? logSink,
  }) => _withFlutterBuildLock(() async {
    final proc = await Process.start('flutter', [
      'build',
      'macos',
      '--debug',
      '-t',
      'test_driver/sim_app.dart',
      '--dart-define=SIM=true',
    ]);
    final output = StringBuffer();
    void capture(String prefix, String line) {
      final tagged = '[$prefix] $line';
      output.writeln(tagged);
      logSink?.writeln(tagged);
    }

    final drains = [
      proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach((line) => capture('build', line)),
      proc.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach((line) => capture('build:err', line)),
    ];
    final code = await proc.exitCode;
    await Future.wait(drains);
    if (code != 0) {
      throw StateError('flutter build macos failed with exit $code\n$output');
    }
    final binary = File(_macosSimAppBinary);
    if (!await binary.exists()) {
      throw StateError(
        'flutter build macos succeeded but $_macosSimAppBinary does not exist',
      );
    }
    return binary.absolute.path;
  });

  static Future<T> _withFlutterBuildLock<T>(Future<T> Function() body) async {
    // Serialize Flutter's writes to build/ across concurrent launches. The OS drops the lock if a
    // worker dies, so it can't deadlock.
    final buildLock = await File(
      '${simTmpRoot().path}/flutter-build.lock',
    ).open(mode: FileMode.write);
    await buildLock.lock(FileLock.blockingExclusive);
    try {
      return await body();
    } finally {
      try {
        await buildLock.unlock();
      } catch (_) {}
      try {
        await buildLock.close();
      } catch (_) {}
    }
  }

  static Map<String, String> _simLaunchEnvironment({
    required Directory appDir,
    required int deviceCount,
    required bool agentOwnsKeyboard,
    required bool shareHostAppDir,
    required String? regtestElectrumUrl,
    required Map<String, String> extraDartDefines,
  }) {
    final windowSlot = Platform.environment['FROSTSNAP_SIM_WINDOW_SLOT'];
    return {
      'FROSTSNAP_SIM_NO_ACTIVATE': '1',
      if (windowSlot != null && windowSlot.isNotEmpty)
        'FROSTSNAP_SIM_WINDOW_SLOT': windowSlot,
      if (shareHostAppDir) 'SIM_APP_DIR': appDir.path,
      'SIM_DEVICE_COUNT': '$deviceCount',
      'SIM_AGENT_OWNS_KEYBOARD': '$agentOwnsKeyboard',
      if (regtestElectrumUrl != null)
        'SIM_REGTEST_ELECTRUM_URL': regtestElectrumUrl,
      if (regtestElectrumUrl != null)
        'SIM_REGTEST_CONTROL_SOCKET': regtestControlSocket,
      ...extraDartDefines,
    };
  }

  static Map<String, String> _macosVmServiceEnvironment() {
    final switches = <String>[
      'enable-dart-profiling=true',
      'vm-service-port=0',
      'enable-checked-mode=true',
      'verify-entry-points=true',
    ];
    return {
      for (var i = 0; i < switches.length; i++)
        'FLUTTER_ENGINE_SWITCH_${i + 1}': switches[i],
      'FLUTTER_ENGINE_SWITCHES': '${switches.length}',
    };
  }

  static List<String> _flutterRunArgs({
    required String flutterDevice,
    required String? flavor,
    required Directory appDir,
    required int deviceCount,
    required bool agentOwnsKeyboard,
    required bool shareHostAppDir,
    required String? regtestElectrumUrl,
    required Map<String, String> extraDartDefines,
  }) => [
    'run',
    '-t',
    'test_driver/sim_app.dart',
    '-d',
    flutterDevice,
    '--no-pub',
    if (!shareHostAppDir) '--no-hot',
    if (flavor != null) ...['--flavor', flavor],
    '--dart-define=SIM=true',
    // Omitted on Android — a host path is meaningless in the sandbox.
    if (shareHostAppDir) '--dart-define=SIM_APP_DIR=${appDir.path}',
    '--dart-define=SIM_DEVICE_COUNT=$deviceCount',
    '--dart-define=SIM_AGENT_OWNS_KEYBOARD=$agentOwnsKeyboard',
    if (regtestElectrumUrl != null)
      '--dart-define=SIM_REGTEST_ELECTRUM_URL=$regtestElectrumUrl',
    if (regtestElectrumUrl != null)
      '--dart-define=SIM_REGTEST_CONTROL_SOCKET=$regtestControlSocket',
    for (final e in extraDartDefines.entries)
      '--dart-define=${e.key}=${e.value}',
  ];

  /// Start the sim target, connect FlutterDriver, enable semantics, and return the pieces both
  /// session shapes need. On macOS host runs this direct-launches the prebuilt debug app; Android
  /// stays on `flutter run` for install + adb-forwarded VM service.
  static Future<(Process, Directory, FlutterDriver, List<String>)> _launchApp({
    required int deviceCount,
    required String flutterDevice,
    required bool agentOwnsKeyboard,
    required bool withRegtest,
    required Map<String, String> extraDartDefines,
    // Whether the app shares the host filesystem (a desktop platform). When true the app is pointed
    // at the host [appDir] via SIM_APP_DIR so its `device-<n>.sock`s land where [SimHarness] can
    // connect them. When false (an Android emulator) that host path is invalid INSIDE the sandbox,
    // so SIM_APP_DIR is omitted and the app falls back to its own app-support dir (main.dart); the
    // host [appDir] is then used only for screenshots/diagnostics.
    required bool shareHostAppDir,
    // Android build flavor (the app defines `direct`/`playstore` product flavors, so `flutter run`
    // needs one to pick the APK). Null on desktop, which has no flavors.
    String? flavor,
    IOSink? logSink,
  }) async {
    // Bring up (or attach to) the shared regtest backend BEFORE the app, so its electrum URL can
    // be seeded into the app at launch.
    String? regtestElectrumUrl;
    if (withRegtest) {
      // Start the shared regtest node if it isn't up, else attach to it. Either way we never tear
      // it down (see _cleanup) — it's a persistent shared resource reaped by `regtest down`/`clean`.
      regtestElectrumUrl = (await ensureRegtestBackend()).url;
    }

    final appDir = await simTmpRoot().createTemp('app-');
    // Ring buffer of recent app stdout/stderr, dumped into the failure artifacts.
    final appLog = <String>[];
    void log(String line) {
      appLog.add(line);
      if (appLog.length > 400) appLog.removeAt(0);
      logSink?.writeln(line);
    }

    // Track partial resources so a failure anywhere in setup tears them all down.
    Process? proc;
    FlutterDriver? driver;

    try {
      await Directory('${appDir.path}/screenshots').create();

      final launchEnvironment = _simLaunchEnvironment(
        appDir: appDir,
        deviceCount: deviceCount,
        agentOwnsKeyboard: agentOwnsKeyboard,
        shareHostAppDir: shareHostAppDir,
        regtestElectrumUrl: regtestElectrumUrl,
        extraDartDefines: extraDartDefines,
      );

      // Capture the VM service URL from the app/tool output (surface logs on stderr). `flutter run`
      // forwards an emulator's VM service to 127.0.0.1 too, so this regex matches on Android as well.
      final vmUrl = Completer<String>();
      final urlRe = RegExp(r'(http://127\.0\.0\.1:\d+/[^\s]+)');
      void wireProcessLogs(Process p) {
        p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
          (line) {
            stderr.writeln('[app] $line');
            log('[app] $line');
            if (!vmUrl.isCompleted &&
                line.toLowerCase().contains('dart vm service')) {
              final m = urlRe.firstMatch(line);
              if (m != null) vmUrl.complete(m.group(1));
            }
          },
        );
        p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(
          (line) {
            stderr.writeln('[app:err] $line');
            log('[app:err] $line');
          },
        );
        p.exitCode.then((code) {
          if (!vmUrl.isCompleted) {
            vmUrl.completeError(
              StateError('sim app exited before VM service URL (exit $code)'),
            );
          }
        });
      }

      late final String url;
      final directMacosLaunch =
          shareHostAppDir && flutterDevice == 'macos' && Platform.isMacOS;
      if (directMacosLaunch) {
        final configuredBinary = Platform.environment['SIM_HOST_APP_BINARY'];
        final binary = configuredBinary != null && configuredBinary.isNotEmpty
            ? configuredBinary
            : await ensureMacosSimAppBuilt(logSink: logSink);
        if (!await File(binary).exists()) {
          throw StateError('SIM_HOST_APP_BINARY does not exist: $binary');
        }
        proc = await Process.start(
          binary,
          const <String>[],
          environment: {...launchEnvironment, ..._macosVmServiceEnvironment()},
        );
        wireProcessLogs(proc);
        log('[harness] launched macOS sim app binary: $binary');
        url = await vmUrl.future.timeout(const Duration(minutes: 5));
      } else {
        url = await _withFlutterBuildLock(() async {
          proc = await Process.start(
            'flutter',
            _flutterRunArgs(
              flutterDevice: flutterDevice,
              flavor: flavor,
              appDir: appDir,
              deviceCount: deviceCount,
              agentOwnsKeyboard: agentOwnsKeyboard,
              shareHostAppDir: shareHostAppDir,
              regtestElectrumUrl: regtestElectrumUrl,
              extraDartDefines: extraDartDefines,
            ),
            environment: launchEnvironment,
          );
          wireProcessLogs(proc!);
          return vmUrl.future.timeout(const Duration(minutes: 5));
        });
      }
      driver = await FlutterDriver.connect(dartVmServiceUrl: url);
      // Build the semantics tree so find.bySemanticsLabel resolves (it isn't generated without an
      // a11y client otherwise). On Android setSemantics throws until runApp has attached the root
      // widget (a startup race: "No root widget is attached"), so RETRY until it takes — find/tap/
      // geometry all need it. Only give up (logged) after a generous window, so a genuinely broken
      // app doesn't hang forever.
      var semanticsOn = false;
      for (var i = 0; i < 60 && !semanticsOn; i++) {
        try {
          await driver.setSemantics(true);
          semanticsOn = true;
        } catch (_) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      }
      if (!semanticsOn) {
        log('[harness] setSemantics never took — find-by-label will not work');
      }

      final launchedProc = proc;
      if (launchedProc == null) {
        throw StateError('sim launch reached success without an app process');
      }
      return (launchedProc, appDir, driver, appLog);
    } catch (_) {
      // Tear down whatever got created, then rethrow the original setup error.
      await _cleanup(driver: driver, proc: proc, appDir: appDir);
      rethrow;
    }
  }

  /// Guarded best-effort teardown of any subset of the session resources. Every step
  /// runs even if an earlier one throws; returns the first error seen (or null).
  static Future<Object?> _cleanup({
    FlutterDriver? driver,
    Process? proc,
    Directory? appDir,
    _ScenarioRegtest? regtest,
  }) async {
    Object? firstError;
    Future<void> guard(Future<void> Function() step) async {
      try {
        await step();
      } catch (e) {
        firstError ??= e;
      }
    }

    // A scenario's regtest is a PRIVATE per-session backend (its own chain) — reaped here with the
    // session so parallel scenarios never share a chain, and nothing orphans. (The INTERACTIVE
    // `serve` node is the separate, deliberately-persistent shared one, reaped by `regtest down`.)
    if (regtest != null) await guard(regtest.stop);
    if (driver != null) {
      await guard(() => driver.close().timeout(const Duration(seconds: 5)));
    }
    if (proc != null) {
      final p = proc;
      p.kill();
      await guard(
        () => p.exitCode.timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            p.kill(ProcessSignal.sigkill);
            return -1;
          },
        ),
      );
    }
    if (appDir != null && await appDir.exists()) {
      await guard(() => appDir.delete(recursive: true));
    }
    return firstError;
  }

  /// Start an ISOLATED regtest backend for ONE scenario (its own chain) + the launch config that points
  /// the app at it. On a host target the app reaches the session's unix control socket + electrum TCP
  /// directly; on an Android emulator [device] those host endpoints are unreachable, so bridge them to
  /// THAT emulator (adb-reverse electrs + a unix→TCP faucet proxy) and point the app at the bridge —
  /// dynamic per-session ports + per-serial reverses, so parallel scenarios never collide. The dir is
  /// `rt-$pid` (one scenario per test process) kept SHORT so the control socket stays under the
  /// unix-socket path limit (the scenario name lives in the test's own logs).
  static Future<_ScenarioRegtest> _startScenarioRegtest(String device) async {
    final session = await startRegtestSession(
      Directory('${simTmpRoot().path}/rt-$pid'),
    );
    final isHost = const {'macos', 'linux', 'windows'}.contains(device);
    if (isHost) {
      return _ScenarioRegtest(session, {
        'SIM_REGTEST_ELECTRUM_URL': session.url,
        'SIM_REGTEST_CONTROL_SOCKET': session.controlSocket,
      });
    }
    try {
      final bridge = await bridgeRegtestToEmulator(session, device);
      return _ScenarioRegtest(session, bridge.defines, bridge.unbridge);
    } catch (_) {
      await session
          .stop(); // bridge failed → reap the backend so it can't orphan
      rethrow;
    }
  }

  /// The app's live device numbers (1..N), via the `device-numbers` driver-data endpoint — the
  /// app-side source of truth that BOTH the tray + button and `./simctl add-device` grow. App
  /// channel only, so it works on an emulator (no host sockets involved).
  Future<List<int>> deviceNumbers() async {
    final csv = await _requestData('device-numbers');
    return csv.isEmpty ? <int>[] : csv.split(',').map(int.parse).toList();
  }

  /// Add a virtual device to the fleet at runtime (CLI/harness parity with the tray + button) and
  /// return its 1-based number. App channel only — triggers the in-app pool add via driver data.
  /// [SimHarness] overrides this to also connect the new device's host socket.
  Future<int> addDevice() async => int.parse(await _requestData('add-device'));

  // ---- device driving over the APP channel (FRB pool) ----
  // These drive the in-process `simDevicePool` via driver-data, so a scenario drives a device the
  // SAME way on host and emulator — the one device transport. Coordinates are
  // device-framebuffer coords (240x280), same as the device channel.

  Future<void> _device(String cmd) async {
    await _deviceQuery(cmd);
  }

  /// Drive a device endpoint and return its reply — for the query endpoints (chain/id/is-connected/
  /// screen) that return data, not just an ack.
  Future<String> _deviceQuery(String cmd) => _requestData(cmd);

  /// Every app-channel driver-data request funnels through here so they share ONE client-side timeout:
  /// a slow/stuck app can't make a single request hang the scenario forever. (A FULLY wedged app —
  /// VM service unable to answer at all, e.g. a frozen UI thread — is caught by the runner's per-test
  /// deadline, since no client-side timeout can fire if the isolate never schedules the reply.)
  Future<String> _requestData(String message) => driver
      .runUnsynchronized(() => driver.requestData(message))
      .timeout(_cmdTimeout);

  /// An app-channel handle to virtual device [number] (1-based, default 1): the same method surface
  /// the host socket had, but every call goes over the app channel (driver-data → the in-process
  /// `simDevicePool`), so it drives a device IDENTICALLY on host and emulator.
  AppDevice device([int number = 1]) => AppDevice(this, number);

  // ---- chain composition (pool-level; one source of truth via setChain), over the app channel ----
  // The connected chain is an ordered list of 1-based device numbers (first = the device on the
  // coordinator USB port). connect/disconnect/reorder all funnel through setChain.

  /// The connected chain, in order.
  Future<List<int>> chain() => device(1).chain();

  /// Re-cable the chain to exactly [order] (1-based numbers, in order).
  Future<void> setChain(List<int> order) => device(1).setChain(order);

  /// Connect [number] by plugging it into the tail of the chain (the router applies the daisy-chain
  /// semantics — the single source of truth, same as the tray).
  Future<void> connect(int number) => device(number).setConnected(true);

  /// Disconnect [number] AND everything downstream (pulling a daisy-chain device cuts those below).
  Future<void> disconnect(int number) => device(number).setConnected(false);

  /// Move [number] one position toward the head (the coordinator end).
  Future<void> moveUp(int number) async {
    final order = await chain();
    final i = order.indexOf(number);
    if (i > 0) {
      order
        ..removeAt(i)
        ..insert(i - 1, number);
      await setChain(order);
    }
  }

  /// Move [number] one position toward the tail.
  Future<void> moveDown(int number) async {
    final order = await chain();
    final i = order.indexOf(number);
    if (i >= 0 && i < order.length - 1) {
      order
        ..removeAt(i)
        ..insert(i + 1, number);
      await setChain(order);
    }
  }

  /// Disconnect/connect [number] (the keygen driver's post-keygen unplug).
  Future<void> unplug([int number = 1]) => disconnect(number);
  Future<void> plug([int number = 1]) => connect(number);

  /// The app's FlutterView size + system insets (LOGICAL px) — for occlusion checks against a
  /// widget's screen rect (e.g. is a button below `height - bottomInset`, i.e. behind the nav bar).
  Future<({double width, double height, double topInset, double bottomInset})>
  viewMetrics() async {
    final m = jsonDecode(await _requestData('metrics')) as Map<String, dynamic>;
    return (
      width: (m['width'] as num).toDouble(),
      height: (m['height'] as num).toDouble(),
      topInset: (m['topInset'] as num).toDouble(),
      bottomInset: (m['bottomInset'] as num).toDouble(),
    );
  }

  // ---- reusable flows (driven over the app channel, so they run on host AND emulator) ----

  /// Run [body] against an [AppSession] on [flutterDevice] (or the `SIM_FLUTTER_DEVICE` env, default
  /// macos) — the single session shape for host AND emulator (devices drive over the app channel).
  /// `./simctl test <name> --android` boots the emulator and sets that env. [withRegtest] starts a
  /// PRIVATE per-session regtest backend (its own chain) so concurrent scenarios never share one.
  /// Captures failure diagnostics and asserts no residue.
  static Future<void> runScenario(
    String name,
    Future<void> Function(AppSession h) body, {
    int deviceCount = 1,
    String? flutterDevice,
    bool withRegtest = false,
    Map<String, String> extraDartDefines = const {},
  }) async {
    final device =
        flutterDevice ?? Platform.environment['SIM_FLUTTER_DEVICE'] ?? 'macos';
    if (Platform.environment['SIM_REQUIRE_FLUTTER_DEVICE'] == '1' &&
        flutterDevice == null &&
        Platform.environment['SIM_FLUTTER_DEVICE'] == null) {
      throw StateError(
        'SIM_REQUIRE_FLUTTER_DEVICE=1 but SIM_FLUTTER_DEVICE is unset',
      );
    }
    // Start the scenario's PRIVATE regtest backend (its own chain) BEFORE the app, so its electrum
    // URL + faucet socket seed the launch. Owned by the session → reaped on tearDown, so concurrent
    // scenarios never share a chain (a foreign `mine` can't confirm another's pending receive).
    final regtest = withRegtest ? await _startScenarioRegtest(device) : null;
    final defines = {...extraDartDefines, ...?regtest?.defines};

    late final AppSession h;
    try {
      h = await AppSession.launch(
        deviceCount: deviceCount,
        flutterDevice: device,
        extraDartDefines: defines,
      );
    } catch (_) {
      await regtest
          ?.stop(); // launch failed before the session could own it — reap it here
      rethrow;
    }
    h._regtest = regtest;
    try {
      await body(h);
    } catch (error, stack) {
      await h._captureFailure(name, error, stack);
      rethrow;
    } finally {
      await h.tearDown();
    }
    if (await h.appDir.exists()) {
      throw StateError('teardown left residue: ${h.appDir.path}');
    }
  }

  /// Device-screen point of the keygen security-code confirm button (the KeygenCheck screen, sim-3).
  static const _keygenConfirmX = 120;
  static const _keygenConfirmY = 215;

  /// Drive a full keygen to a created wallet: create → name the wallet + [deviceCount] devices →
  /// (threshold) → generate → each device hold-confirms the security code → unplug to finalize →
  /// the wallet home. Devices are driven over the APP channel ([holdConfirm]/[disconnectDevice]),
  /// so this runs unchanged on host and emulator.
  Future<void> createWallet({
    String name = 'SimTest',
    int deviceCount = 1,
    String devicePrefix = 'SimDev',
  }) async {
    await tapUntil(RegExp('Create a multi-sig wallet'), 'Wallet name');
    await enterText('Wallet name', name);
    await tapUntil('Next', 'Device name 1');
    for (var i = 1; i <= deviceCount; i++) {
      await enterText('Device name $i', '$devicePrefix$i');
    }
    if (deviceCount == 1) {
      // 1-of-1 is below the recommended threshold, so it has an extra confirm dialog.
      await tapUntil('Continue with 1 device', 'Continue anyway');
      await tapUntil('Continue anyway', 'Generate keys');
    } else {
      // N devices: Continue → Choose threshold (defaults to recommended) → Generate keys.
      await tapUntil('Continue with $deviceCount devices', 'Generate keys');
    }
    await tapUntil('Generate keys', RegExp('Security Check'));
    // Each device confirms the security code via hold-to-confirm; the app reveals "Yes" at N/N.
    // Re-assert (the device-render can lag the hold).
    var confirmed = false;
    for (var attempt = 0; attempt < 8 && !confirmed; attempt++) {
      for (var n = 1; n <= deviceCount; n++) {
        await device(n).holdConfirm(_keygenConfirmX, _keygenConfirmY);
      }
      confirmed = await exists('Yes');
    }
    if (!confirmed) {
      throw StateError('devices never confirmed the security code');
    }
    await tapUntil('Yes', RegExp('Unplug devices to continue'));
    for (var n = 1; n <= deviceCount; n++) {
      await device(n).setConnected(false);
    }
    await waitFor(RegExp('Receive'));
  }

  /// From a created wallet, open a device's "Record backup information" sheet: enter the backup
  /// checklist (the wallet's unfinished-backups banner) → connect [device] → tap its Backup. Leaves
  /// the sheet (with the "Show secret backup" action) on screen.
  Future<void> openDeviceBackup({int device = 1}) async {
    await tapUntil(RegExp('unfinished backups'), RegExp('Backup keys'));
    await this.device(device).setConnected(true);
    await tapUntil('Backup', RegExp('Record backup information'));
  }

  /// Assert the widget [label] sits ABOVE the bottom system inset — i.e. is not occluded by the
  /// navigation bar. Compares the widget's screen rect ([FlutterDriver.getBottomRight]) with
  /// [viewMetrics]. Trivially true where there's no bottom inset (a desktop host); on the emulator
  /// it catches a control rendered behind the nav bar.
  Future<void> expectAboveBottomInset(Pattern label) async {
    final m = await viewMetrics();
    final safeBottom = m.height - m.bottomInset;
    final br = await _settledBottomRight(label);
    if (br.dy > safeBottom) {
      throw StateError(
        'widget "$label" is occluded by the ${m.bottomInset.toStringAsFixed(0)}px bottom '
        'inset: its bottom is ${br.dy.toStringAsFixed(0)} but the safe area ends at '
        '${safeBottom.toStringAsFixed(0)} (view height ${m.height.toStringAsFixed(0)})',
      );
    }
  }

  /// The on-screen bottom-right of [label] once it has stopped moving (e.g. a sheet has finished
  /// sliding in). We can't use flutter_driver's frame-sync (`pumpAndSettle`'s out-of-process
  /// equivalent) for this: the sim app never reaches frame-idle (a live tray/device keeps
  /// repainting — the reason every other call here is `runUnsynchronized`), so a synchronized read
  /// just times out. So we do what out-of-process drivers do when they can't hook the frame loop
  /// (cf. Appium/Playwright explicit waits): sample the geometry until two reads agree, then use it.
  Future<DriverOffset> _settledBottomRight(
    Pattern label, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final finder = find.bySemanticsLabel(label);
    final deadline = DateTime.now().add(timeout);
    var prev = double.nan;
    while (true) {
      final br = await _driverCall(
        () => driver.getBottomRight(finder, timeout: _cmdTimeout),
      );
      if ((br.dy - prev).abs() < 1.0 || DateTime.now().isAfter(deadline)) {
        return br;
      }
      prev = br.dy;
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
  }

  // ---- app channel (widget tree, by semantic label) ----
  // `label` is a Pattern: a String matches the accessible name exactly; a RegExp
  // matches a substring (needed for composite widgets, e.g. a card that merges its
  // title + subtitle into one semantics label).
  //
  // Every command runs UNSYNCHRONIZED and with a timeout. Unsynchronized because the
  // sim device tray repaints whenever the device screen changes, so the app rarely
  // reaches the frame-quiescent state flutter_driver waits for by default — a
  // synchronized command (e.g. a tap that triggers device activity) would otherwise
  // never return. The timeout turns an unresolvable target into a fast, clear failure
  // instead of an indefinite hang (flutter_driver waits forever with no timeout).

  /// Per-command timeout for app interactions.
  static const Duration _cmdTimeout = Duration(seconds: 20);

  Future<T> _driverCall<T>(Future<T> Function() call, [Duration? timeout]) =>
      driver.runUnsynchronized(call).timeout(timeout ?? _cmdTimeout);

  Future<void> tap(Pattern label) => _driverCall(
    () => driver.tap(find.bySemanticsLabel(label), timeout: _cmdTimeout),
  );

  /// Tap [label] and wait for [expect] to appear. Distinguishes two failure modes of
  /// an unsynchronized tap:
  ///  - the tap *no-ops* (landed before the control was interactable) — [label] is
  ///    still present afterwards, so re-tap;
  ///  - the tap *worked but the result is slow* (e.g. a brief "preparing" step before
  ///    the next screen) — [label] is gone, so DON'T re-tap (it would hit nothing);
  ///    just wait longer for [expect].
  /// Throws if [expect] never appears.
  Future<void> tapUntil(
    Pattern label,
    Pattern expect, {
    int tries = 8,
    Duration settle = const Duration(seconds: 30),
  }) async {
    for (var i = 0; i < tries; i++) {
      await tap(label);
      if (await _appears(expect, const Duration(seconds: 3))) return;
      // Tap took effect (button gone) but the result is slow — wait it out.
      if (!await _appears(label, const Duration(milliseconds: 500))) {
        await waitFor(expect, timeout: settle);
        return;
      }
      // Otherwise [label] is still there: the tap no-op'd, so loop and re-tap.
    }
    throw StateError(
      'tapped "$label" $tries times but "$expect" never appeared',
    );
  }

  Future<bool> _appears(Pattern label, Duration timeout) async {
    try {
      await _driverCall(
        () => driver.waitFor(find.bySemanticsLabel(label), timeout: timeout),
        timeout + const Duration(seconds: 1),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> enterText(Pattern label, String text) => _driverCall(() async {
    await driver.tap(find.bySemanticsLabel(label), timeout: _cmdTimeout);
    await driver.enterText(text, timeout: _cmdTimeout);
  });

  Future<String> getText(Pattern label) => _driverCall(
    () => driver.getText(find.bySemanticsLabel(label), timeout: _cmdTimeout),
  );

  /// The app clipboard, via the sim_app driver data handler — e.g. to read a wallet receive
  /// address after tapping its Copy button (the address Text has no stable label to target).
  Future<String> getClipboard() => _requestData('clipboard');

  /// Set the app clipboard (e.g. to seed a recipient address before tapping a Paste button), via
  /// the sim_app driver data handler. Portable counterpart to [getClipboard] — uses Flutter's
  /// Clipboard, so scenarios need no platform pasteboard tool (pbcopy/xclip) and stay cross-platform.
  Future<void> setClipboard(String text) => _requestData('setclip:$text');

  Future<void> waitFor(
    Pattern label, {
    Duration timeout = const Duration(seconds: 30),
  }) => _driverCall(
    () => driver.waitFor(find.bySemanticsLabel(label), timeout: timeout),
    timeout + const Duration(seconds: 1),
  );

  Future<void> waitForAbsent(
    Pattern label, {
    Duration timeout = const Duration(seconds: 30),
  }) => _driverCall(
    () => driver.waitForAbsent(find.bySemanticsLabel(label), timeout: timeout),
    timeout + const Duration(seconds: 1),
  );

  /// Whether a control with semantic [label] is present right now.
  Future<bool> exists(Pattern label) async {
    try {
      await _driverCall(
        () => driver.waitFor(
          find.bySemanticsLabel(label),
          timeout: const Duration(milliseconds: 800),
        ),
        const Duration(seconds: 2),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Dismiss the topmost `showBottomSheetOrDialog`. Its layout is responsive: the WIDE layout is a
  /// Dialog with a 'Close' button (host), the COMPACT layout is a drag-handle bottom sheet with NO
  /// Close button (the emulator's narrow screen). So tap Close where it exists, else dismiss the sheet
  /// the way a user would — the Android system Back gesture pops the modal route. Keeps sheet-closing
  /// portable across host and emulator without baking a Close button into the app's mobile sheets.
  Future<void> dismissSheetOrDialog() async {
    if (await exists('Close')) {
      await tap('Close');
      return;
    }
    final serial = Platform.environment['SIM_FLUTTER_DEVICE'];
    if (serial == null) {
      throw StateError(
        'no Close button and no SIM_FLUTTER_DEVICE: cannot dismiss the sheet',
      );
    }
    await Process.run('${androidSdkRoot()}/platform-tools/adb', [
      '-s',
      serial,
      'shell',
      'input',
      'keyevent',
      'KEYCODE_BACK',
    ]);
  }

  // ---- whole-app screenshot (incl. the tray) ----

  /// Capture the whole Flutter surface (app + tray) to `<appDir>/screenshots/`. The
  /// file is removed with everything else on [tearDown]; pass [keep] for a path
  /// outside the app dir to retain a shot. Returns the written path.
  ///
  /// Brings the app window to the foreground first: macOS pauses a backgrounded window's
  /// render loop, so `driver.screenshot()` would otherwise return the last on-screen frame
  /// (e.g. a chain edit made via the socket would not appear, even though the tray's widget
  /// tree already reflects it). Foregrounding resumes rendering so the shot is current.
  Future<String> screenshot(String name, {String? keep}) async {
    await _bringAppToFront();
    // `screenshot` takes no `timeout:`, so bound it client-side — keeps the failure-diagnostics path
    // from turning a bounded command failure back into an unbounded FlutterDriver wait on a stuck app.
    final png = await driver
        .runUnsynchronized(() => driver.screenshot())
        .timeout(_cmdTimeout);
    final path = keep ?? '${appDir.path}/screenshots/${_shotSeq++}-$name.png';
    await File(path).writeAsBytes(png);
    return path;
  }

  /// Best-effort: raise the macOS app window so its render loop resumes and the next
  /// screenshot is a fresh frame. A no-op (silently) off macOS or if osascript is absent.
  Future<void> _bringAppToFront() async {
    if (!Platform.isMacOS || flutterDevice != 'macos') return;
    try {
      await Process.run('osascript', [
        '-e',
        'tell application "Frostsnap" to activate',
      ]);
      // Give the embedder a moment to resume and render a frame before capturing.
      await Future<void>.delayed(const Duration(milliseconds: 400));
    } catch (_) {
      // Foregrounding is a convenience; never fail a screenshot over it.
    }
  }

  // ---- failure diagnostics ----

  /// On a scenario failure, dump where it stopped to the runner-provided artifacts dir
  /// (`SIM_TEST_ARTIFACTS_DIR`) or `build/sim-failures/<name>/` when run directly.
  /// (a gitignored, persistent dir — survives tearDown): the whole-app screenshot,
  /// the error + stack + recent app logs, and (via [_captureExtra]) any per-session
  /// extras. Best-effort: a capture step failing must not mask the original error.
  Future<void> _captureFailure(
    String name,
    Object error,
    StackTrace stack,
  ) async {
    final configuredDir = Platform.environment['SIM_TEST_ARTIFACTS_DIR'];
    final runnerOwnedDir = configuredDir != null && configuredDir.isNotEmpty;
    final dir = Directory(
      runnerOwnedDir ? configuredDir : 'build/sim-failures/$name',
    );
    try {
      // The runner owns SIM_TEST_ARTIFACTS_DIR and may already have timeout
      // artifacts there; direct runs still get a fresh directory per failure.
      if (!runnerOwnedDir && await dir.exists())
        await dir.delete(recursive: true);
      await dir.create(recursive: true);
      try {
        await screenshot('app', keep: '${dir.path}/app.png');
      } catch (_) {}
      await _captureExtra(dir);
      final errorText =
          '$error\n\n$stack\n\n--- recent app log ---\n${_appLog.join('\n')}\n';
      final errorFile = File('${dir.path}/error.txt');
      final path = runnerOwnedDir && await errorFile.exists()
          ? '${dir.path}/scenario-error.txt'
          : errorFile.path;
      await File(path).writeAsString(errorText);
      stderr.writeln('sim-failure diagnostics: ${dir.absolute.path}');
    } catch (_) {
      // Diagnostics are best-effort; never mask the scenario's own error.
    }
  }

  /// Each virtual device's framebuffer PNG into the failure-diagnostics [dir], over the app channel
  /// (so it works on host AND emulator). Best-effort per device.
  Future<void> _captureExtra(Directory dir) async {
    for (final n in await deviceNumbers()) {
      try {
        await device(n).screen('${dir.path}/device-$n.png');
      } catch (_) {}
    }
  }

  /// Quit the app and delete the disposable app dir (which holds all harness
  /// screenshots) — no residue. The first cleanup error (if any) is rethrown once
  /// everything has been torn down.
  Future<void> tearDown() async {
    final err = await _cleanup(
      driver: driver,
      proc: _appProcess,
      appDir: appDir,
      regtest: _regtest,
    );
    if (err != null) throw err;
  }
}

/// An app-channel handle to one virtual device (1-based [_number]): the same method surface the
/// host-only `device-<n>.sock` client had, but every call goes over the app channel (driver-data → the
/// in-process `simDevicePool`) — so a scenario drives a device IDENTICALLY on host and emulator, and
/// `./simctl` device commands are no longer host-only. Returned by [AppSession.device].
class AppDevice {
  final AppSession _session;
  final int _number;
  AppDevice(this._session, this._number);

  /// Tap (touch down then up) at `(x,y)`.
  Future<void> tap(int x, int y) =>
      _session._device('device-tap:$_number:$x:$y');

  /// Press and hold at `(x,y)` for [duration] — the device integrates the elapsed wall-clock and a
  /// hold-to-confirm control fires past its threshold.
  Future<void> hold(int x, int y, Duration duration) =>
      _session._device('device-hold:$_number:$x:$y:${duration.inMilliseconds}');

  /// Hold a hold-to-confirm button at `(x,y)` long enough to fire it.
  Future<void> holdConfirm(
    int x,
    int y, [
    Duration duration = const Duration(milliseconds: 2600),
  ]) => hold(x, y, duration);

  /// Swipe from `(x1,y1)` to `(x2,y2)` over [duration] (advances the device's review screens).
  Future<void> swipe(int x1, int y1, int x2, int y2, Duration duration) =>
      _session._device(
        'device-swipe:$_number:$x1:$y1:$x2:$y2:${duration.inMilliseconds}',
      );

  /// Raw single touch (press when `liftUp` false, release when true).
  Future<void> touch(int x, int y, {required bool liftUp}) =>
      _session._device('device-touch:$_number:$x:$y:${liftUp ? 'up' : 'down'}');

  /// Plug this device into / out of the chain (the router applies daisy-chain semantics).
  Future<void> setConnected(bool connected) => _session._device(
    'device-${connected ? 'connect' : 'disconnect'}:$_number',
  );

  /// Whether this device is connected (its number is in the chain).
  Future<bool> isConnected() async =>
      (await _session._deviceQuery('device-is-connected:$_number')) == 'true';

  /// The connected chain as 1-based device numbers, in order (pool-level — any device answers it).
  Future<List<int>> chain() async {
    final csv = await _session._deviceQuery('device-chain');
    return csv.isEmpty ? <int>[] : csv.split(',').map(int.parse).toList();
  }

  /// Re-cable the chain to exactly these 1-based numbers, in order (pool-level).
  Future<void> setChain(List<int> order) =>
      _session._device('device-set-chain:${order.join(',')}');

  Future<String> deviceId() => _session._deviceQuery('device-id:$_number');

  /// Write the device framebuffer to [path] as a PNG (the endpoint returns a base64 PNG).
  Future<void> screen(String path) async {
    final b64 = await _session._deviceQuery('device-screen:$_number');
    await File(path).writeAsBytes(base64Decode(b64));
  }
}

/// `SimHarness` was the desktop session shape — an [AppSession] plus host `device-<n>.sock` channels.
/// Now that devices drive over the app channel on every platform (see [AppDevice]), the two shapes
/// are one; this alias keeps existing callers compiling.
typedef SimHarness = AppSession;
