// The sim-8 dual-channel harness: one object that brings up the sim app + virtual
// device, drives BOTH through one ergonomic API, and tears everything down (app
// process, both channels, the disposable app dir, and all screenshots) as a unit.
//
//   - app (Flutter widget tree): driven by semantic label over flutter_driver / the VM
//     service. `app.*` + `screenshot()`.
//   - device (a framebuffer + touchscreen): driven by hardware gestures over the
//     device-channel unix socket. `device.*`.
//
// Lives in test_driver/ so flutter_driver stays a dev dependency. Used by the keygen
// driver test and by `simctl`. See `.clank/plans/sim-8-dual-channel-harness.md`.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';

import 'regtest.dart'
    show ensureRegtestBackend, stopRegtestBackend, regtestControlSocket;

/// Root for all sim temp artifacts — disposable app dirs, the simctl control socket,
/// ad-hoc screenshots — grouped under one folder instead of loose in the system temp
/// root. Created on demand.
Directory simTmpRoot() {
  final dir = Directory('${Directory.systemTemp.path}/frostsnap-sim');
  dir.createSync(recursive: true);
  return dir;
}

/// The device-input channel client: JSON request/reply lines over the device's unix
/// socket. Replies arrive in request order on the single connection, so a FIFO of
/// completers correlates them.
class SimDeviceChannel {
  final Socket _socket;
  final Queue<Completer<Map<String, dynamic>>> _pending = Queue();
  late final StreamSubscription<String> _sub;

  SimDeviceChannel._(this._socket) {
    _sub = _socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line.trim().isEmpty) return;
          final reply = jsonDecode(line) as Map<String, dynamic>;
          if (_pending.isNotEmpty) _pending.removeFirst().complete(reply);
        });
  }

  static Future<SimDeviceChannel> connect(String socketPath) async {
    final socket = await Socket.connect(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    );
    return SimDeviceChannel._(socket);
  }

  Future<Map<String, dynamic>> _send(Map<String, dynamic> req) {
    final completer = Completer<Map<String, dynamic>>();
    _pending.add(completer);
    _socket.write('${jsonEncode(req)}\n');
    return completer.future;
  }

  /// Send a command and throw if the server reports `ok:false`.
  Future<Map<String, dynamic>> _ok(Map<String, dynamic> req) async {
    final reply = await _send(req);
    if (reply['ok'] != true) {
      throw StateError(
        'device command ${req['cmd']} failed: ${reply['error']}',
      );
    }
    return reply;
  }

  Future<void> tap(int x, int y) => _ok({'cmd': 'tap', 'x': x, 'y': y});

  /// Press and hold at `(x,y)` for `duration` (the device integrates the elapsed
  /// wall-clock; a hold-to-confirm control fires once past its threshold).
  Future<void> hold(int x, int y, Duration duration) =>
      _ok({'cmd': 'hold', 'x': x, 'y': y, 'ms': duration.inMilliseconds});

  /// Hold a hold-to-confirm button at `(x,y)` long enough to fire it. Hold-to-confirm
  /// is a device-wide pattern; the caller supplies the per-screen button point, so this
  /// is generic (not specific to any flow).
  Future<void> holdConfirm(
    int x,
    int y, [
    Duration duration = const Duration(milliseconds: 2600),
  ]) => hold(x, y, duration);

  Future<void> swipe(int x1, int y1, int x2, int y2, Duration duration) => _ok({
    'cmd': 'swipe',
    'x1': x1,
    'y1': y1,
    'x2': x2,
    'y2': y2,
    'ms': duration.inMilliseconds,
  });

  /// Raw single touch event (press/move when `liftUp` false, release when true).
  Future<void> touch(int x, int y, {required bool liftUp}) =>
      _ok({'cmd': 'touch', 'x': x, 'y': y, 'lift_up': liftUp});

  /// Write the exact device framebuffer to `path` as a PNG.
  Future<void> screen(String path) => _ok({'cmd': 'screen', 'path': path});

  Future<void> setConnected(bool connected) =>
      _ok({'cmd': 'set_connected', 'connected': connected});

  Future<bool> isConnected() async =>
      (await _ok({'cmd': 'is_connected'}))['connected'] as bool;

  /// The connected chain as 1-based device numbers, in order (pool-level — the router is
  /// shared, so any device socket answers it).
  Future<List<int>> chain() async =>
      ((await _ok({'cmd': 'chain'}))['chain'] as List).cast<int>();

  /// Re-cable the chain to exactly these 1-based numbers, in order (pool-level).
  Future<void> setChain(List<int> order) =>
      _ok({'cmd': 'set_chain', 'order': order});

  Future<String> deviceId() async =>
      (await _ok({'cmd': 'device_id'}))['device_id'] as String;

  Future<void> close() async {
    await _sub.cancel();
    await _socket.close();
    _socket.destroy();
  }
}

/// One launched sim app + virtual device, with both channels connected.
class SimHarness {
  final Process _appProcess;
  final Directory appDir;
  final FlutterDriver driver;

  /// One device-input channel per virtual device, in 1-based order; index with
  /// [device]. A single-device session has just `devices[0]` (i.e. `device(1)`).
  final List<SimDeviceChannel> devices;
  final List<String> _appLog;
  int _shotSeq = 0;

  /// True if THIS session spawned the regtest backend (so tearDown stops it). False when it
  /// attached to a pre-existing one (e.g. started by `./simctl regtest up`) — left running.
  final bool _ownsRegtest;

  SimHarness._(
    this._appProcess,
    this.appDir,
    this.driver,
    this.devices,
    this._appLog,
    this._ownsRegtest,
  );

  /// The device-input channel for device [number] (1-based; defaults to device 1).
  SimDeviceChannel device([int number = 1]) => devices[number - 1];

  /// Run [body] against a fresh harness; on ANY failure capture diagnostics — a
  /// whole-app screenshot, the device framebuffer, the error+stack, and recent app
  /// logs — to a persistent dir, then always tear down. Rethrows so the run still
  /// fails. This is the supported way to drive a scenario: a failure leaves you a
  /// picture of where it stopped plus the logs, instead of a bare stack trace.
  ///
  /// On success it also enforces the no-residue invariant: the disposable app dir (and
  /// thus the device socket + all screenshots) must be gone after teardown.
  static Future<void> runScenario(
    String name,
    Future<void> Function(SimHarness h) body, {
    int deviceCount = 1,
    String flutterDevice = 'macos',
    bool withRegtest = false,
  }) async {
    final h = await SimHarness.launch(
      deviceCount: deviceCount,
      flutterDevice: flutterDevice,
      withRegtest: withRegtest,
    );
    try {
      await body(h);
    } catch (error, stack) {
      await h._captureFailure(name, error, stack);
      rethrow;
    } finally {
      await h.tearDown();
    }
    // Reached only when [body] succeeded: assert teardown left nothing behind.
    if (await h.appDir.exists()) {
      throw StateError('teardown left residue: ${h.appDir.path}');
    }
  }

  /// Launch the instrumented sim app on a fresh disposable app dir, then connect the
  /// app channel (flutter_driver) and the device channel (socket).
  /// [agentOwnsKeyboard] true (the default, for tests) routes text through the driver's
  /// mock input so [driver.enterText] works but the real keyboard is blocked; pass false
  /// to hand the keyboard to a human (then `enterText` is unavailable). One mode per
  /// session — see `sim_app.dart`.
  static Future<SimHarness> launch({
    int deviceCount = 1,
    String flutterDevice = 'macos',
    bool agentOwnsKeyboard = true,
    bool withRegtest = false,
  }) async {
    // Bring up (or attach to) the shared regtest backend BEFORE the app, so its electrum URL
    // can be seeded into the app at launch. `owned` => we spawned it and must stop it on
    // teardown; attaching to a pre-existing one leaves it running.
    String? regtestElectrumUrl;
    var ownsRegtest = false;
    if (withRegtest) {
      final backend = await ensureRegtestBackend();
      regtestElectrumUrl = backend.url;
      ownsRegtest = backend.owned;
    }

    final appDir = await simTmpRoot().createTemp('app-');
    // Ring buffer of recent app stdout/stderr, dumped into the failure artifacts.
    final appLog = <String>[];
    void log(String line) {
      appLog.add(line);
      if (appLog.length > 400) appLog.removeAt(0);
    }

    // Track partial resources so a failure anywhere in setup tears them all down
    // (otherwise a timed-out connect would leak the flutter process + the app dir).
    Process? proc;
    FlutterDriver? driver;
    final channels = <SimDeviceChannel>[];
    try {
      await Directory('${appDir.path}/screenshots').create();

      proc = await Process.start('flutter', [
        'run',
        '-t',
        'test_driver/sim_app.dart',
        '-d',
        flutterDevice,
        '--dart-define=SIM=true',
        '--dart-define=SIM_APP_DIR=${appDir.path}',
        '--dart-define=SIM_DEVICE_COUNT=$deviceCount',
        '--dart-define=SIM_AGENT_OWNS_KEYBOARD=$agentOwnsKeyboard',
        // main.dart points the regtest wallet at this electrs (regtest-only); empty = offline.
        if (regtestElectrumUrl != null)
          '--dart-define=SIM_REGTEST_ELECTRUM_URL=$regtestElectrumUrl',
        // ...and gives the tray's "Test BTC" column the faucet control socket to drive.
        if (regtestElectrumUrl != null)
          '--dart-define=SIM_REGTEST_CONTROL_SOCKET=$regtestControlSocket',
      ]);

      // Capture the VM service URL from the run output (surface logs on stderr).
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
      // Build the semantics tree so find.bySemanticsLabel resolves (it isn't generated
      // without an a11y client otherwise).
      await driver.setSemantics(true);

      // load_sim creates device-<n>.sock (1-based) during startup; wait for each
      // before connecting.
      for (var n = 1; n <= deviceCount; n++) {
        final socketPath = '${appDir.path}/device-$n.sock';
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (!await File(socketPath).exists()) {
          if (DateTime.now().isAfter(deadline)) {
            throw StateError('device socket never appeared at $socketPath');
          }
          await Future.delayed(const Duration(milliseconds: 100));
        }
        channels.add(await SimDeviceChannel.connect(socketPath));
      }

      return SimHarness._(proc, appDir, driver, channels, appLog, ownsRegtest);
    } catch (_) {
      // Tear down whatever got created, then rethrow the original setup error.
      await _cleanup(
        channels: channels,
        driver: driver,
        proc: proc,
        appDir: appDir,
        ownsRegtest: ownsRegtest,
      );
      rethrow;
    }
  }

  /// Guarded best-effort teardown of any subset of the harness resources. Every step
  /// runs even if an earlier one throws; returns the first error seen (or null).
  static Future<Object?> _cleanup({
    List<SimDeviceChannel>? channels,
    FlutterDriver? driver,
    Process? proc,
    Directory? appDir,
    bool ownsRegtest = false,
  }) async {
    Object? firstError;
    Future<void> guard(Future<void> Function() step) async {
      try {
        await step();
      } catch (e) {
        firstError ??= e;
      }
    }

    // Stop the regtest backend only if we started it; an attached (pre-existing) one stays up.
    if (ownsRegtest) await guard(stopRegtestBackend);
    if (channels != null) {
      for (final channel in channels) {
        await guard(channel.close);
      }
    }
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

  // ---- chain composition (pool-level; one source of truth via setChain) ----
  // The connected chain is an ordered list of 1-based device numbers (first = the device
  // on the coordinator USB port). connect/disconnect/reorder all funnel through setChain.

  /// The connected chain, in order.
  Future<List<int>> chain() => device(1).chain();

  /// Re-cable the chain to exactly [order] (1-based numbers, in order).
  Future<void> setChain(List<int> order) => device(1).setChain(order);

  /// Connect [number] by plugging it into the tail of the chain (no-op if already
  /// connected). Routes through the device's `set_connected` so the router applies the
  /// daisy-chain semantics (the single source of truth), same as the tray.
  Future<void> connect(int number) => device(number).setConnected(true);

  /// Disconnect [number] AND everything downstream of it — pulling a device from a daisy
  /// chain cuts power/comms to every device below it.
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

  /// Disconnect/connect [number] (kept for the keygen driver's post-keygen unplug).
  Future<void> unplug([int number = 1]) => disconnect(number);
  Future<void> plug([int number = 1]) => connect(number);

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
  /// the exact device framebuffer, and `error.txt` (the error + stack + recent app
  /// logs). Best-effort: a capture step failing must not mask the original error.
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
      for (var n = 1; n <= devices.length; n++) {
        try {
          await device(n).screen('${dir.path}/device-$n.png');
        } catch (_) {}
      }
      await File('${dir.path}/error.txt').writeAsString(
        '$error\n\n$stack\n\n--- recent app log ---\n${_appLog.join('\n')}\n',
      );
      stderr.writeln('sim-failure diagnostics: ${dir.absolute.path}');
    } catch (_) {
      // Diagnostics are best-effort; never mask the scenario's own error.
    }
  }

  /// Close both channels, quit the app, and delete the disposable app dir (which
  /// holds the device socket and all harness screenshots) — no residue. App
  /// termination and dir deletion run even if a client close fails; the first
  /// cleanup error (if any) is rethrown once everything has been torn down.
  Future<void> tearDown() async {
    final err = await _cleanup(
      channels: devices,
      driver: driver,
      proc: _appProcess,
      appDir: appDir,
      ownsRegtest: _ownsRegtest,
    );
    if (err != null) throw err;
  }
}
