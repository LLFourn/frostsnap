import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:frostsnap/global.dart';
import 'package:frostsnap/main.dart' as app;

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
  // the agent (the automated test path); `simctl serve` hands the keyboard to a human.
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
  return app.main();
}
