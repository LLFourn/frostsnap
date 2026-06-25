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

import 'regtest.dart' show ensureRegtestBackend, regtestControlSocket;

/// Root for all sim temp artifacts — disposable app dirs, the simctl control socket,
/// ad-hoc screenshots — grouped under one folder instead of loose in the system temp
/// root. Created on demand.
Directory simTmpRoot() {
  final dir = Directory('${Directory.systemTemp.path}/frostsnap-sim');
  dir.createSync(recursive: true);
  return dir;
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
  int _shotSeq = 0;

  AppSession(this._appProcess, this.appDir, this.driver, this._appLog);

  /// Resolves when the launched app process exits — e.g. its window was closed, which (with
  /// `applicationShouldTerminateAfterLastWindowClosed`) terminates the app and exits `flutter run`.
  /// `simctl serve` watches this so the daemon never outlives a dead app (a zombie daemon would
  /// answer `up` with already:true against nothing).
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
    return AppSession(proc, dir, drv, log);
  }

  /// Start `flutter run` for the sim target, connect FlutterDriver, enable semantics, and return the
  /// pieces both session shapes need. On any setup failure tears down whatever got created and
  /// rethrows (so a timed-out connect can't leak the flutter process + the app dir).
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

      proc = await Process.start(
        'flutter',
        [
          'run',
          '-t',
          'test_driver/sim_app.dart',
          '-d',
          flutterDevice,
          if (flavor != null) ...['--flavor', flavor],
          '--dart-define=SIM=true',
          // Omitted on Android — a host path is meaningless in the sandbox (the app uses its own
          // app-support dir). On desktop it puts the device sockets where SimHarness connects them.
          if (shareHostAppDir) '--dart-define=SIM_APP_DIR=${appDir.path}',
          '--dart-define=SIM_DEVICE_COUNT=$deviceCount',
          '--dart-define=SIM_AGENT_OWNS_KEYBOARD=$agentOwnsKeyboard',
          // main.dart points the regtest wallet at this electrs (regtest-only); empty = offline.
          if (regtestElectrumUrl != null)
            '--dart-define=SIM_REGTEST_ELECTRUM_URL=$regtestElectrumUrl',
          // ...and gives the tray's "Test BTC" column the faucet control socket to drive.
          if (regtestElectrumUrl != null)
            '--dart-define=SIM_REGTEST_CONTROL_SOCKET=$regtestControlSocket',
          for (final e in extraDartDefines.entries)
            '--dart-define=${e.key}=${e.value}',
          // Tell the macOS app (AppDelegate) to launch as an accessory so it doesn't steal focus —
          // it's driven over the VM service, not looked at. Sim-only: only this harness sets it.
        ],
        environment: {'FROSTSNAP_SIM_NO_ACTIVATE': '1'},
      );

      // Capture the VM service URL from the run output (surface logs on stderr). flutter forwards
      // the emulator's VM service to 127.0.0.1 too, so this regex matches on Android as well.
      final vmUrl = Completer<String>();
      final urlRe = RegExp(r'(http://127\.0\.0\.1:\d+/[^\s]+)');
      proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            stderr.writeln('[app] $line');
            log('[app] $line');
            if (!vmUrl.isCompleted && line.contains('Dart VM Service')) {
              final m = urlRe.firstMatch(line);
              if (m != null) vmUrl.complete(m.group(1));
            }
          });
      proc.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            stderr.writeln('[app:err] $line');
            log('[app:err] $line');
          });

      final url = await vmUrl.future.timeout(const Duration(minutes: 5));
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

      return (proc, appDir, driver, appLog);
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
  }) async {
    Object? firstError;
    Future<void> guard(Future<void> Function() step) async {
      try {
        await step();
      } catch (e) {
        firstError ??= e;
      }
    }

    // NB: the regtest backend is a DELIBERATELY PERSISTENT shared node — no test or serve tears it
    // down, so sequential runs reuse it AND multiple app instances in one test share it (none pulls
    // it out from under another). It's reaped only by `./simctl regtest down` / `./simctl clean`.
    if (driver != null) await guard(driver.close);
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

  /// The app's live device numbers (1..N), via the `device-numbers` driver-data endpoint — the
  /// app-side source of truth that BOTH the tray + button and `./simctl add-device` grow. App
  /// channel only, so it works on an emulator (no host sockets involved).
  Future<List<int>> deviceNumbers() async {
    final csv = await driver.runUnsynchronized(
      () => driver.requestData('device-numbers'),
    );
    return csv.isEmpty ? <int>[] : csv.split(',').map(int.parse).toList();
  }

  /// Add a virtual device to the fleet at runtime (CLI/harness parity with the tray + button) and
  /// return its 1-based number. App channel only — triggers the in-app pool add via driver data.
  /// [SimHarness] overrides this to also connect the new device's host socket.
  Future<int> addDevice() async => int.parse(
    await driver.runUnsynchronized(() => driver.requestData('add-device')),
  );

  // ---- device driving over the APP channel (FRB pool) ----
  // These drive the in-process `simDevicePool` via driver-data, so a scenario drives a device the
  // SAME way on host and emulator — the one device transport. Coordinates are
  // device-framebuffer coords (240x280), same as the device channel.

  Future<void> _device(String cmd) async {
    await _deviceQuery(cmd);
  }

  /// Drive a device endpoint and return its reply — for the query endpoints (chain/id/is-connected/
  /// screen) that return data, not just an ack.
  Future<String> _deviceQuery(String cmd) =>
      driver.runUnsynchronized(() => driver.requestData(cmd));

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
    final m =
        jsonDecode(
              await driver.runUnsynchronized(
                () => driver.requestData('metrics'),
              ),
            )
            as Map<String, dynamic>;
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
  /// `./simctl test <name> --android` boots the emulator and sets that env. [withRegtest] brings up
  /// (or attaches to) the shared regtest backend. Captures failure diagnostics and asserts no residue.
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
    final h = await AppSession.launch(
      deviceCount: deviceCount,
      flutterDevice: device,
      withRegtest: withRegtest,
      extraDartDefines: extraDartDefines,
    );
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
      final br = await driver.runUnsynchronized(
        () => driver.getBottomRight(finder),
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

  Future<void> tap(Pattern label) => driver.runUnsynchronized(
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
      await driver.runUnsynchronized(
        () => driver.waitFor(find.bySemanticsLabel(label), timeout: timeout),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> enterText(Pattern label, String text) =>
      driver.runUnsynchronized(() async {
        await driver.tap(find.bySemanticsLabel(label), timeout: _cmdTimeout);
        await driver.enterText(text, timeout: _cmdTimeout);
      });

  Future<String> getText(Pattern label) => driver.runUnsynchronized(
    () => driver.getText(find.bySemanticsLabel(label), timeout: _cmdTimeout),
  );

  /// The app clipboard, via the sim_app driver data handler — e.g. to read a wallet receive
  /// address after tapping its Copy button (the address Text has no stable label to target).
  Future<String> getClipboard() =>
      driver.runUnsynchronized(() => driver.requestData('clipboard'));

  /// Set the app clipboard (e.g. to seed a recipient address before tapping a Paste button), via
  /// the sim_app driver data handler. Portable counterpart to [getClipboard] — uses Flutter's
  /// Clipboard, so scenarios need no platform pasteboard tool (pbcopy/xclip) and stay cross-platform.
  Future<void> setClipboard(String text) =>
      driver.runUnsynchronized(() => driver.requestData('setclip:$text'));

  Future<void> waitFor(
    Pattern label, {
    Duration timeout = const Duration(seconds: 30),
  }) => driver.runUnsynchronized(
    () => driver.waitFor(find.bySemanticsLabel(label), timeout: timeout),
  );

  Future<void> waitForAbsent(
    Pattern label, {
    Duration timeout = const Duration(seconds: 30),
  }) => driver.runUnsynchronized(
    () => driver.waitForAbsent(find.bySemanticsLabel(label), timeout: timeout),
  );

  /// Whether a control with semantic [label] is present right now.
  Future<bool> exists(Pattern label) async {
    try {
      await driver.runUnsynchronized(
        () => driver.waitFor(
          find.bySemanticsLabel(label),
          timeout: const Duration(milliseconds: 800),
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
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
    final png = await driver.runUnsynchronized(() => driver.screenshot());
    final path = keep ?? '${appDir.path}/screenshots/${_shotSeq++}-$name.png';
    await File(path).writeAsBytes(png);
    return path;
  }

  /// Best-effort: raise the macOS app window so its render loop resumes and the next
  /// screenshot is a fresh frame. A no-op (silently) off macOS or if osascript is absent.
  Future<void> _bringAppToFront() async {
    if (!Platform.isMacOS) return;
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

  /// On a scenario failure, dump where it stopped to `build/sim-failures/<name>/`
  /// (a gitignored, persistent dir — survives tearDown): the whole-app screenshot,
  /// the error + stack + recent app logs, and (via [_captureExtra]) any per-session
  /// extras. Best-effort: a capture step failing must not mask the original error.
  Future<void> _captureFailure(
    String name,
    Object error,
    StackTrace stack,
  ) async {
    final dir = Directory('build/sim-failures/$name');
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
      await dir.create(recursive: true);
      try {
        await screenshot('app', keep: '${dir.path}/app.png');
      } catch (_) {}
      await _captureExtra(dir);
      await File('${dir.path}/error.txt').writeAsString(
        '$error\n\n$stack\n\n--- recent app log ---\n${_appLog.join('\n')}\n',
      );
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
