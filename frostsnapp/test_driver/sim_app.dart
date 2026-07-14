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
import 'package:frostsnap/src/rust/api/device_list.dart';
import 'package:frostsnap/id_ext.dart';
import 'package:frostsnap/main.dart' as app;
import 'package:frostsnap/secure_key_provider.dart';
import 'package:frostsnap/sim_camera.dart';
import 'package:frostsnap/sim_device_tray.dart';
import 'package:frostsnap/src/rust/api/qr.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

import 'app_tap.dart';
import 'focused_text.dart';
import 'silent_clock.dart';

void _forceFrameIfIdle() {
  final binding = WidgetsBinding.instance;
  if (binding.schedulerPhase == SchedulerPhase.idle) {
    binding.handleBeginFrame(null);
    binding.handleDrawFrame();
  }
}

Map<String, double> _rectToJson(Rect rect) => {
  'left': rect.left,
  'top': rect.top,
  'right': rect.right,
  'bottom': rect.bottom,
  'width': rect.width,
  'height': rect.height,
};

Rect? _globalSemanticBounds(RenderObject renderObject) {
  try {
    final rect = MatrixUtils.transformRect(
      renderObject.getTransformTo(null),
      renderObject.semanticBounds,
    );
    if (rect.left.isFinite &&
        rect.top.isFinite &&
        rect.right.isFinite &&
        rect.bottom.isFinite) {
      return rect;
    }
  } catch (_) {}
  return null;
}

String _semanticsSnapshotJson() {
  _forceFrameIfIdle();
  final root = WidgetsBinding.instance.rootElement;
  if (root == null) {
    throw 'sim_app: no root element attached';
  }

  final nodes = <Map<String, Object?>>[];
  final seenLabels = <String>{};
  var ordinal = 0;

  void visit(Element element, int depth) {
    if (element is RenderObjectElement) {
      final renderObject = element.renderObject;
      final semantics = renderObject.debugSemantics;
      if (semantics != null) {
        final data = semantics.getSemanticsData();
        // Preserve labels byte-for-byte: FlutterDriver's bySemanticsLabel finder
        // matches debugSemantics.label without normalizing it.
        final label = data.label;
        final value = data.value.trim();
        final hint = data.hint.trim();
        final tooltip = data.tooltip.trim();
        final actions = [
          for (final action in ui.SemanticsAction.values)
            if (data.hasAction(action)) action.name,
        ];
        final flags = data.flagsCollection.toStrings();
        final globalBounds = _globalSemanticBounds(renderObject);
        if (label.isNotEmpty ||
            value.isNotEmpty ||
            hint.isNotEmpty ||
            tooltip.isNotEmpty ||
            actions.isNotEmpty ||
            flags.isNotEmpty ||
            data.role.name != 'none') {
          nodes.add({
            'id': semantics.id,
            'ordinal': ordinal++,
            'depth': depth,
            if (label.isNotEmpty) 'label': label,
            if (label.isNotEmpty) 'labelFirstSeen': seenLabels.add(label),
            if (value.isNotEmpty) 'value': value,
            if (hint.isNotEmpty) 'hint': hint,
            if (tooltip.isNotEmpty) 'tooltip': tooltip,
            if (data.identifier.isNotEmpty) 'identifier': data.identifier,
            if (actions.isNotEmpty) 'actions': actions,
            if (flags.isNotEmpty) 'flags': flags,
            if (data.role.name != 'none') 'role': data.role.name,
            if (data.textDirection != null)
              'textDirection': data.textDirection!.name,
            if (data.increasedValue.isNotEmpty)
              'increasedValue': data.increasedValue,
            if (data.decreasedValue.isNotEmpty)
              'decreasedValue': data.decreasedValue,
            if (data.scrollIndex != null) 'scrollIndex': data.scrollIndex,
            if (data.scrollChildCount != null)
              'scrollChildCount': data.scrollChildCount,
            if (data.scrollPosition != null)
              'scrollPosition': data.scrollPosition,
            if (data.scrollExtentMin != null)
              'scrollExtentMin': data.scrollExtentMin,
            if (data.scrollExtentMax != null)
              'scrollExtentMax': data.scrollExtentMax,
            'rect': _rectToJson(data.rect),
            if (globalBounds != null) 'bounds': _rectToJson(globalBounds),
          });
        }
      }
    }
    element.debugVisitOnstageChildren((child) => visit(child, depth + 1));
  }

  visit(root, 0);
  return jsonEncode({'nodes': nodes});
}

/// One QR module, in pixels. Big enough that the grid survives the PNG round-trip into `rqrr` with
/// margin, small enough that a ~130-module part stays a sane image to encode.
const _qrModulePx = 6;

/// Quiet zone, in modules. The QR spec's minimum is 4 and grid detection relies on it.
const _qrQuietModules = 4;

/// Render `data` as a PNG of a real QR code — what another wallet's screen would be showing, and
/// what the sim camera then reports seeing. Error correction matches the app's own [AnimatedQr] (L),
/// so a part that this can't carry is one the app couldn't display either.
Future<Uint8List> _renderQrPng(String data) async {
  final qr = QrImage(
    QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.L),
  );
  final side = (qr.moduleCount + _qrQuietModules * 2) * _qrModulePx;
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()),
    ui.Paint()..color = const ui.Color(0xFFFFFFFF),
  );
  final dark = ui.Paint()..color = const ui.Color(0xFF000000);
  for (var row = 0; row < qr.moduleCount; row++) {
    for (var col = 0; col < qr.moduleCount; col++) {
      if (!qr.isDark(row, col)) continue;
      canvas.drawRect(
        ui.Rect.fromLTWH(
          ((col + _qrQuietModules) * _qrModulePx).toDouble(),
          ((row + _qrQuietModules) * _qrModulePx).toDouble(),
          _qrModulePx.toDouble(),
          _qrModulePx.toDouble(),
        ),
        dark,
      );
    }
  }
  final image = await recorder.endRecording().toImage(side, side);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  return png!.buffer.asUint8List();
}

/// The sequence length of the UR `part` (`UR:<type>/<seq>-<len>/<data>`) — how many fragments the
/// message was split into. A single-part UR has no `<seq>-<len>` segment at all.
int _urSequenceLength(String part) {
  final segments = part.split('/');
  if (segments.length < 3) return 1;
  final seq = RegExp(r'^\d+-(\d+)$').firstMatch(segments[1]);
  return seq == null ? 1 : int.parse(seq.group(1)!);
}

/// Encode `psbt` the way a hardware-wallet-facing wallet does — a `crypto-psbt` UR, fountain-split
/// into 400-byte fragments — and put the resulting QR codes in front of the sim camera. Returns the
/// UR's sequence length, so a scenario can tell a single static QR from an animated one.
///
/// The loop is deliberately several times the sequence length, and odd. Decoding a frame drops every
/// frame that arrives while it runs, so the scanner samples the loop at a roughly fixed stride; a
/// loop length sharing a factor with that stride would replay the same few parts forever and never
/// complete. Fountain parts past the sequence length are XOR mixes that decode just as well, so
/// lengthening the loop costs nothing — and it is what a real animated UR does anyway.
Future<String> _showPsbtQr(Uint8List psbt) async {
  final encoder = QrEncoder(bytes: psbt);
  final parts = <String>[await encoder.nextPart()];
  final total = _urSequenceLength(parts.first);
  final loop = total <= 1 ? 1 : total * 4 + 1;
  while (parts.length < loop) {
    parts.add(await encoder.nextPart());
  }
  final images = <Uint8List>[];
  for (final part in parts) {
    images.add(await _renderQrPng(part));
  }
  simCameraScene.show(images);
  return '$total';
}

/// Driver data channel for things the harness can't get off the widget tree by semantic label.
/// `clipboard` reads the app clipboard (e.g. a wallet receive address after its Copy button);
/// `setclip:<text>` writes it (e.g. to seed a recipient before a Paste button) — portably, via
/// Flutter's own Clipboard, so scenarios don't shell out to pbcopy/xclip. `add-device` grows the
/// virtual fleet at runtime (CLI parity with the tray + button) and returns the new device number;
/// `device-numbers` reports the app-side fleet (CSV of 1-based numbers) — the SINGLE source of truth
/// for which devices exist (the harness has no separate cache; the tray, button, and CLI all grow
/// this one pool). Test-only.
/// Dart-side cache of the coordinator's device list, fed by the app's own
/// [GlobalStreams.deviceListSubject] push. Exists so `recognized-device-ids`
/// never takes the sync FRB path onto the coordinator mutex from the main
/// isolate (see the handler). Lazily armed on first use — the subject
/// replays its latest update, so at most one 100 ms harness poll sees the
/// pre-subscription empty state.
DeviceListUpdate? _latestDeviceList;
StreamSubscription<DeviceListUpdate>? _deviceListWatch;

void _ensureDeviceListWatch() {
  _deviceListWatch ??= GlobalStreams.deviceListSubject.listen(
    (u) => _latestDeviceList = u,
  );
}

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
  // `tap-at:<x>,<y>` — positional tap in GLOBAL LOGICAL pixels. Framework PointerEvent.position is
  // already logical, so no devicePixelRatio scaling (multiplying would miss on every non-1x view).
  const tapAtPrefix = 'tap-at:';
  if (payload != null && payload.startsWith(tapAtPrefix)) {
    final v = WidgetsBinding.instance.platformDispatcher.views.first;
    final p = parseTapAt(payload.substring(tapAtPrefix.length));
    if (p == null) {
      throw 'sim_app: malformed tap-at payload "$payload" — expected tap-at:<x>,<y>';
    }
    final boundsErr = tapAtBoundsError(p, v.physicalSize / v.devicePixelRatio);
    if (boundsErr != null) throw 'sim_app: $boundsErr';
    dispatchLogicalTap(p, viewId: v.viewId);
    return 'ok';
  }
  const psbtQrPrefix = 'psbt-qr:';
  if (payload != null && payload.startsWith(psbtQrPrefix)) {
    return _showPsbtQr(base64Decode(payload.substring(psbtQrPrefix.length)));
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
      //
      // Read the Dart-side cache, NOT coord.deviceListState(): that is a sync FRB call behind the
      // coordinator's device-list mutex, and blocking here stalls the main isolate — silencing the very
      // [kSimBeatMarker] beat the harness charges this wait's deadline against. No update yet = nothing
      // recognized.
      _ensureDeviceListWatch();
      return (_latestDeviceList?.state.devices ?? const [])
          .map((d) => d.id.toHex())
          .join(',');
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
      _forceFrameIfIdle();
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
    case 'keyboard-visible':
      // The IME inset as THIS app sees it — the harness's positive gate for "the on-screen keyboard
      // is up" before typing through it (android real-IME mode), and for a safe dismissKeyboard.
      final v = WidgetsBinding.instance.platformDispatcher.views.first;
      return (v.viewInsets.bottom > 0).toString();
    case 'focused-text-length':
      // Exact UNTRIMMED length of the focused text field's value — the snapshot trims values, which
      // under-counts edge whitespace; the android REPLACE clear backspaces exactly this many times
      // and re-queries to VERIFY. Force a frame first so the read isn't stale mid-clear.
      _forceFrameIfIdle();
      final root = WidgetsBinding.instance.rootElement;
      if (root == null) throw 'sim_app: no root element attached';
      final len = focusedTextLength(root);
      if (len == null) {
        throw 'sim_app: no focused text field — nothing to clear/type into';
      }
      return '$len';
    case 'show-keyboard':
      // Re-request the IME for the current input connection. Right after a cold emulator boot the
      // IME service is still initializing and DROPS the show fired by the field gaining focus (the
      // app has window focus, the field is focused, but mInputShown stays false — verified live);
      // Android never retries a dropped show, so the harness nudges this while gating.
      await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
      return 'ok';
    case 'semantics-snapshot':
      // The current onstage render-object semantics surface — the same labels FlutterDriver's
      // `find.bySemanticsLabel` resolves. This is the eval/test introspection endpoint, not a raw
      // widget-tree dump.
      return _semanticsSnapshotJson();
    case 'psbt-qr-clear':
      // The scene persists until replaced, so a scenario that opens the scanner again would
      // instantly re-decode the last PSBT. Clearing makes the lens empty like a real one.
      simCameraScene.clear();
      return 'ok';
    case 'wallet-descriptor':
      // The wallet's output descriptor — what you'd export to Core/Sparrow so it can watch the
      // wallet and build spends of it. Checksummed, so it imports as-is.
      final keys = coord.keyState().keys;
      if (keys.isEmpty) throw 'sim_app: no wallet to describe';
      final key = keys.first;
      final network = key.bitcoinNetwork();
      if (network == null) {
        throw 'sim_app: wallet "${key.keyName()}" is not a bitcoin wallet';
      }
      return network.descriptorForKey(masterAppkey: key.masterAppkey());
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
    case 'device-record-backup':
      // The whole "write it down" half: capture + page + hold until the device's
      // BackupRecorded. Blocking (~40 s); the harness uses a dedicated timeout.
      return device.recordBackup();
    case 'device-backup-next':
      await device.backupDisplayNext();
      return 'ok';
    case 'device-backup-confirm':
      // Blocks for the whole hold (~2.6 s).
      await device.backupDisplayConfirm();
      return 'ok';
    case 'device-displayed-backup':
      // Privileged sim observation: the FULL backup text of the display-backup screen,
      // independent of which page is visible. Throws if no backup is on screen.
      return device.displayedBackup();
    case 'device-type-backup':
      // Blocking for the whole typing run (~a minute of real touches); the harness side
      // uses a dedicated timeout. The text may contain spaces but never ':', so the
      // remainder of the payload is the text.
      await device.typeBackup(text: parts.sublist(2).join(':'));
      return 'ok';
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
  Timer.periodic(const Duration(seconds: 1), (_) {
    // The beat proves the MAIN ISOLATE can schedule — background Rust threads
    // keep logging while a wedged isolate (e.g. blocked in a sync FRB call)
    // cannot print this. The harness charges its wait deadlines against time
    // without a beat, so this line is the signal that keeps a slow-but-alive
    // run from being failed by a wall clock.
    print(kSimBeatMarker);
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
      WidgetsBinding.instance.scheduleForcedFrame();
    }
  });
  return app.main();
}
