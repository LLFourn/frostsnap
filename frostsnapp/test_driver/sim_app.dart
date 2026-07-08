import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:frostsnap/global.dart';
import 'package:frostsnap/id_ext.dart';
import 'package:frostsnap/main.dart' as app;
import 'package:frostsnap/secure_key_provider.dart';
import 'package:frostsnap/sim_device_tray.dart';

/// Driver data channel for things the harness can't get off the widget tree by semantic label.
/// `clipboard` reads the app clipboard (e.g. a wallet receive address after its Copy button);
/// `setclip:<text>` writes it (e.g. to seed a recipient before a Paste button) — portably, via
/// Flutter's own Clipboard, so scenarios don't shell out to pbcopy/xclip. `add-device` grows the
/// virtual fleet at runtime (CLI parity with the tray + button) and returns the new device number;
/// `device-numbers` reports the app-side fleet (CSV of 1-based numbers) — the SINGLE source of truth
/// for which devices exist (the harness has no separate cache; the tray, button, and CLI all grow
/// this one pool). Test-only.
Future<String> _driverData(String? payload) async {
  const setClipPrefix = 'setclip:';
  if (payload != null && payload.startsWith(setClipPrefix)) {
    await Clipboard.setData(
      ClipboardData(text: payload.substring(setClipPrefix.length)),
    );
    return 'ok';
  }
  // `device-set-chain:<csv>` is POOL-level (re-cable the whole chain), not per-device, so it's
  // matched here before the per-device `device-<cmd>:<n>` dispatch below. Empty csv = empty chain.
  const setChainPrefix = 'device-set-chain:';
  if (payload != null && payload.startsWith(setChainPrefix)) {
    final pool = simDevicePool;
    if (pool == null) throw 'sim_app: no device pool (not a sim build?)';
    final csv = payload.substring(setChainPrefix.length);
    pool.setChain(
      order: csv.isEmpty ? <int>[] : csv.split(',').map(int.parse).toList(),
    );
    return 'ok';
  }
  // `device-<cmd>:<n>:…` drives a virtual device through the FRB `simDevicePool` IN-PROCESS — the
  // same pool/router the tray drives. Reachable over the (adb-forwarded) VM service, so flows drive
  // devices identically on host AND emulator. This is the ONE device transport (the host-only
  // `device-<n>.sock` channels are gone — app-channel-only-device-driving).
  if (payload != null &&
      payload.startsWith('device-') &&
      payload.contains(':')) {
    return _driveDevice(payload.split(':'));
  }
  switch (payload) {
    case 'clipboard':
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      return data?.text ?? '';
    case 'add-device':
      final pool = simDevicePool;
      if (pool == null) throw 'sim_app: no device pool (not a sim build?)';
      final device = await pool.addDevice();
      return '${device.number()}';
    // Delete the app's secure key so a sim flow can exercise the "hardware key is gone → regenerate/recover"
    // path. ANDROID-ONLY: the desktop provider's key is a fixed constant (deleteKey is a no-op + hasKey is
    // always true), so REJECT on host rather than report a hollow success the verification can't reflect.
    case 'delete-secure-key':
      if (!Platform.isAndroid) {
        throw 'delete-secure-key is android-only — the desktop sim key is a fixed constant, not deletable';
      }
      await SecureKeyProvider.instance.deleteKey();
      return 'ok';
    case 'secure-key-exists':
      if (!Platform.isAndroid) {
        throw 'secure-key-exists is android-only — the desktop sim key is a fixed constant';
      }
      return (await SecureKeyProvider.instance.hasKey()) ? 'true' : 'false';
    case 'device-numbers':
      final pool = simDevicePool;
      if (pool == null) throw 'sim_app: no device pool (not a sim build?)';
      final devices = await pool.devices();
      return devices.map((d) => d.number()).join(',');
    case 'device-chain':
      // The connected daisy chain (1-based, in order) — the pool's single source of truth.
      final pool = simDevicePool;
      if (pool == null) throw 'sim_app: no device pool (not a sim build?)';
      return pool.chain().join(',');
    case 'recognized-device-ids':
      // The ids (lowercase hex) of devices the COORDINATOR has recognized (announce handshake done) —
      // ITS device list, a DISTINCT and later gate than sim-pool/chain membership. The keygen
      // "Device name N" field and signer availability are built from THIS list and exist only once a
      // device is in it. Same id form as device-id:<n> (DeviceId Display == toHex), so the harness can
      // wait the recognized SET to the connected chain's ids — a same-cardinality re-cable (1→2) is then
      // NOT satisfied by stale recognition of the old device.
      return coord.deviceListState().devices.map((d) => d.id.toHex()).join(',');
    case 'app-screenshot':
      // Render the whole sim surface (app + tray) OFF-SCREEN through the render tree (toImage), NOT the
      // OS window — so it's fresh even when the window is backgrounded (macOS pauses a backgrounded
      // window's compositing, the reason driver.screenshot() returned stale frames and needed an
      // osascript foreground) and it works per-instance. Mirrors how `device-screen` reads the device
      // framebuffer directly rather than screenshotting a window.
      //
      // FORCE a synchronous frame first: toImage captures the last PAINTED frame, but a backgrounded/
      // idle desktop window has vsync paused, so a state change (e.g. a just-arrived keygen confirm)
      // rebuilds the widget tree without ever painting it — the capture would then predate the change.
      // Pump one ourselves (the scheduler is idle inside this driver handler) so the shot is CURRENT.
      final shotBinding = WidgetsBinding.instance;
      if (shotBinding.schedulerPhase == SchedulerPhase.idle) {
        shotBinding.handleBeginFrame(null);
        shotBinding.handleDrawFrame();
      }
      final appBoundary =
          simAppScreenshotKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (appBoundary == null) {
        throw 'sim_app: no app screenshot boundary (not a sim build?)';
      }
      final appShotDpr = WidgetsBinding
          .instance
          .platformDispatcher
          .views
          .first
          .devicePixelRatio;
      final appShot = await appBoundary.toImage(pixelRatio: appShotDpr);
      final appShotPng = await appShot.toByteData(
        format: ui.ImageByteFormat.png,
      );
      return base64Encode(appShotPng!.buffer.asUint8List());
    case 'metrics':
      // The app's FlutterView size + system insets in LOGICAL px — the truth the occlusion check
      // compares a widget's screen rect against (e.g. the emulator's 3-button nav bar = bottomInset).
      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      final dpr = view.devicePixelRatio;
      final pad = view.viewPadding;
      return jsonEncode({
        'width': view.physicalSize.width / dpr,
        'height': view.physicalSize.height / dpr,
        'topInset': pad.top / dpr,
        'bottomInset': pad.bottom / dpr,
      });
    case 'delete-wallet':
      // Forget ALL wallets from the COORDINATOR — the same coord.deleteKey path the "Hold to Delete" UI's
      // onComplete calls — WITHOUT touching the virtual devices' shares, so the recovery flow can restore
      // the wallet from those devices. The wallet list is stream-driven (subKeyEvents), so the UI drops it.
      final toDelete = coord.keyState().keys;
      for (final key in toDelete) {
        await coord.deleteKey(keyId: key.keyId());
      }
      return toDelete.length.toString();
    default:
      throw 'sim_app: unknown driver data request "$payload"';
  }
}

/// Drive virtual device `parts[1]` (1-based) via the FRB pool. `device-hold` synthesises a hold
/// (touch-down → wait ms → touch-up) since [SimDevice] has touch/swipe but no hold; the device
/// integrates the elapsed wall-clock and fires a hold-to-confirm control.
Future<String> _driveDevice(List<String> parts) async {
  final pool = simDevicePool;
  if (pool == null) throw 'sim_app: no device pool (not a sim build?)';
  final n = int.parse(parts[1]);
  final device = (await pool.devices()).firstWhere(
    (d) => d.number() == n,
    orElse: () => throw 'sim_app: no device $n',
  );
  switch (parts[0]) {
    case 'device-hold':
      final x = int.parse(parts[2]);
      final y = int.parse(parts[3]);
      device.touch(x: x, y: y, liftUp: false);
      await Future<void>.delayed(Duration(milliseconds: int.parse(parts[4])));
      device.touch(x: x, y: y, liftUp: true);
      return 'ok';
    case 'device-touch':
      device.touch(
        x: int.parse(parts[2]),
        y: int.parse(parts[3]),
        liftUp: parts[4] == 'up',
      );
      return 'ok';
    case 'device-swipe':
      // swipe is async (emits intermediate events over `ms`); AWAIT it so the harness only
      // continues once the gesture has completed, not while it's still in flight.
      await device.swipe(
        x1: int.parse(parts[2]),
        y1: int.parse(parts[3]),
        x2: int.parse(parts[4]),
        y2: int.parse(parts[5]),
        ms: int.parse(parts[6]),
      );
      return 'ok';
    case 'device-connect':
      device.setConnected(connected: true);
      return 'ok';
    case 'device-disconnect':
      device.setConnected(connected: false);
      return 'ok';
    case 'device-tap':
      // A tap is a touch-down + touch-up at the same point (the SimDevice has no `tap` primitive).
      final x = int.parse(parts[2]);
      final y = int.parse(parts[3]);
      device.touch(x: x, y: y, liftUp: false);
      device.touch(x: x, y: y, liftUp: true);
      return 'ok';
    case 'device-id':
      return device.id();
    case 'device-is-connected':
      // Connected == this device's number is in the chain (the pool's single source of truth).
      return pool.chain().contains(n) ? 'true' : 'false';
    case 'device-screen':
      // The current framebuffer (RGBA8888) PNG-encoded + base64'd over the String channel — the
      // app-channel equivalent of the socket's `screen`. `snapshot()` reads the framebuffer DIRECTLY
      // (not via `frames()`, which would steal the live tray subscriber). Diagnostics path, not hot.
      final frame = device.snapshot();
      final decoded = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        frame.data,
        frame.width,
        frame.height,
        ui.PixelFormat.rgba8888,
        decoded.complete,
      );
      final image = await decoded.future;
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      return base64Encode(png!.buffer.asUint8List());
    default:
      throw 'sim_app: unknown device request "${parts[0]}"';
  }
}

/// Instrumented SIM entrypoint (the app channel of the sim-8 harness).
///
/// Enables the `flutter_driver` extension so the out-of-process harness can drive the
/// app's widget tree by semantic label over the VM service, then runs the normal app.
/// Lives in `test_driver/` so `flutter_driver` stays a dev-dependency and never enters
/// production `lib/main.dart`. SIM mode + a clean app dir come from launch configuration:
///
///   flutter run -t test_driver/sim_app.dart --dart-define=SIM=true \
///     --dart-define=SIM_APP_DIR=/tmp/...
Future<void> main() {
  // Who owns the keyboard — the one mode switch for the session. When the AGENT owns it,
  // text is emulated through flutter_driver (`driver.enterText` works) and the real
  // keyboard is blocked; when the USER owns it, the real keyboard works and
  // `driver.enterText` does not. The two are mutually exclusive (no hybrid). Defaults to
  // the agent (the automated test path); `fsim serve` hands the keyboard to a human.
  const compileAgentOwnsKeyboard = bool.fromEnvironment(
    'SIM_AGENT_OWNS_KEYBOARD',
    defaultValue: true,
  );
  final envAgentOwnsKeyboard = Platform.environment['SIM_AGENT_OWNS_KEYBOARD'];
  final agentOwnsKeyboard = envAgentOwnsKeyboard == null
      ? compileAgentOwnsKeyboard
      : envAgentOwnsKeyboard == 'true';
  enableFlutterDriverExtension(
    handler: _driverData,
    enableTextEntryEmulation: agentOwnsKeyboard,
  );
  if (agentOwnsKeyboard) {
    // Keep the frame pipeline alive while the agent drives a (likely backgrounded) sim window. macOS
    // PAUSES vsync for an occluded/backgrounded window, which freezes everything that only advances on a
    // painted frame: dialog dismiss animations (so a frame-gated action dialog lingers and blocks the
    // keygen flow that `await`s its dismissal), and the flutter_driver semantics tree the harness finds
    // against. `scheduleForcedFrame` produces a frame even when the engine has disabled them
    // (`framesEnabled == false`). A slow 1Hz heartbeat is enough: it only needs to UN-STICK frame-gated
    // work, not render smoothly — a dismiss animation is timestamp-driven so it completes in the next
    // forced frame, and finds only need semantics within the harness's second-scale waits. (During
    // active device animation the SimFrame stream already drives finer repaints.) Agent-driven only;
    // interactive `serve` is foregrounded by a human and paints normally.
    Timer.periodic(const Duration(seconds: 1), (_) {
      WidgetsBinding.instance.scheduleForcedFrame();
    });
  }
  return app.main();
}
