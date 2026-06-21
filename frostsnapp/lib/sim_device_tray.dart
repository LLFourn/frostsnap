import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:frostsnap/src/rust/api/sim.dart';

const double _trayWidth = 260;

/// Device dimensions of the virtual device framebuffer (sim-1). Pointer coords
/// are scaled back to this range before being injected via [SimDevice.touch].
const int _deviceWidth = 240;
const int _deviceHeight = 280;

/// Rendered width of a device in the tray — ~30% smaller than filling the tray, so
/// several devices fit without scrolling (sim-9). Touches map back through the actual
/// rendered box, so any render size stays accurate.
const double _deviceRenderWidth = 170;

/// Docked debug column rendering every [SimDevice] in [pool] live and routing
/// taps back as device touches. Only built on the SIM entrypoint (`kSim`).
///
/// Connection state is single-source: the authoritative `PortConnection` lives in
/// Rust and is read via [SimDevice.isConnected]. The tray owns every toggle (per
/// device and "plug all") and rebuilds on each, so all cells re-read that one source
/// — no per-cell mirror that bulk actions could leave stale.
class SimDeviceTray extends StatefulWidget {
  final DevicePool pool;

  const SimDeviceTray({super.key, required this.pool});

  @override
  State<SimDeviceTray> createState() => _SimDeviceTrayState();
}

class _SimDeviceTrayState extends State<SimDeviceTray> {
  late final Future<List<SimDevice>> _devices = widget.pool.devices();

  // The authoritative connection state (Rust PortConnection) can change from OUTSIDE
  // the tray — the device channel / simctl `set-connected` — and there is no change
  // stream to push those. Poll it so the header and every cell re-read isConnected()
  // and stay in sync however the state was changed, not just on the tray's own toggles.
  Timer? _connectionPoll;

  @override
  void initState() {
    super.initState();
    _connectionPoll = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _connectionPoll?.cancel();
    super.dispose();
  }

  void _toggle(SimDevice device) {
    device.setConnected(connected: !device.isConnected());
    setState(() {});
  }

  void _setAll(List<SimDevice> devices, bool connected) {
    for (final device in devices) {
      device.setConnected(connected: connected);
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The tray docks BESIDE the app's Navigator (so dialogs can't cover it), which
    // puts it outside the Navigator's Overlay/Material. Give it its own Overlay +
    // Material so Material widgets (IconButton ink) and Tooltips work in here.
    return SizedBox(
      width: _trayWidth,
      child: Overlay(
        initialEntries: [
          OverlayEntry(
            builder: (context) => Material(
              color: theme.colorScheme.surfaceContainerHighest,
              child: FutureBuilder<List<SimDevice>>(
                future: _devices,
                builder: (context, snapshot) {
                  final devices = snapshot.data;
                  if (devices == null) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final allConnected = devices.every((d) => d.isConnected());
                  // Power flows down the chain: a device is lit only if every link from
                  // the coordinator (device 1) down to it is connected, so cutting a link
                  // darkens that node AND its whole subtree. `connected` (a device's own
                  // parent link) still drives its plug icon; `powered` drives its screen.
                  final powered = <bool>[];
                  var reachable = true;
                  for (final device in devices) {
                    reachable = reachable && device.isConnected();
                    powered.add(reachable);
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Pinned header: stays put while the device list scrolls.
                      _TrayHeader(
                        deviceCount: devices.length,
                        allConnected: allConnected,
                        onToggleAll: () => _setAll(devices, !allConnected),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          children: [
                            for (var i = 0; i < devices.length; i++)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 8,
                                ),
                                child: _SimDeviceCell(
                                  device: devices[i],
                                  connected: devices[i].isConnected(),
                                  powered: powered[i],
                                  onToggle: () => _toggle(devices[i]),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TrayHeader extends StatelessWidget {
  final int deviceCount;
  final bool allConnected;
  final VoidCallback onToggleAll;

  const _TrayHeader({
    required this.deviceCount,
    required this.allConnected,
    required this.onToggleAll,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$deviceCount ${deviceCount == 1 ? 'device' : 'devices'}',
              style: theme.textTheme.labelLarge,
            ),
          ),
          TextButton.icon(
            onPressed: onToggleAll,
            icon: Icon(
              allConnected ? Icons.usb_off_rounded : Icons.usb_rounded,
              size: 16,
            ),
            label: Text(allConnected ? 'Unplug all' : 'Plug all in'),
          ),
        ],
      ),
    );
  }
}

class _SimDeviceCell extends StatefulWidget {
  final SimDevice device;
  // This device's own parent link (drives the plug icon/toggle).
  final bool connected;
  // Whether the device has power — reachable from the coordinator through all links
  // above it (drives the screen: a node whose ancestor link is cut goes dark too).
  final bool powered;
  final VoidCallback onToggle;

  const _SimDeviceCell({
    required this.device,
    required this.connected,
    required this.powered,
    required this.onToggle,
  });

  @override
  State<_SimDeviceCell> createState() => _SimDeviceCellState();
}

class _SimDeviceCellState extends State<_SimDeviceCell> {
  StreamSubscription<SimFrame>? _subscription;
  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    _subscription = widget.device.frames().listen(_onFrame);
  }

  void _onFrame(SimFrame frame) {
    ui.decodeImageFromPixels(
      frame.data,
      frame.width,
      frame.height,
      ui.PixelFormat.rgba8888,
      (image) {
        if (!mounted) {
          image.dispose();
          return;
        }
        setState(() {
          _image?.dispose();
          _image = image;
        });
      },
    );
  }

  // Map a pointer position within the rendered widget back to device pixels,
  // using the actual rendered box size (not a fixed scale) so the full 0..239 /
  // 0..279 range is reachable whatever size the tray gives the viewport.
  void _touchAt(Offset local, Size rendered, {required bool liftUp}) {
    final x = (local.dx / rendered.width * _deviceWidth).round().clamp(
      0,
      _deviceWidth - 1,
    );
    final y = (local.dy / rendered.height * _deviceHeight).round().clamp(
      0,
      _deviceHeight - 1,
    );
    widget.device.touch(x: x, y: y, liftUp: liftUp);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connected = widget.connected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Tooltip(
                message: widget.device.id(),
                child: Text(
                  'Device ${widget.device.number()}',
                  style: theme.textTheme.labelMedium,
                ),
              ),
            ),
            IconButton(
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              tooltip: connected ? 'Disconnect (unplug)' : 'Connect (plug in)',
              icon: Icon(connected ? Icons.usb_rounded : Icons.usb_off_rounded),
              onPressed: widget.onToggle,
            ),
          ],
        ),
        const SizedBox(height: 4),
        Center(child: _screen(theme, widget.powered)),
      ],
    );
  }

  // The device render box, fixed at [_deviceRenderWidth]. When the device is not powered
  // (its parent link, or any link above it, is cut) the screen is OFF — a dark panel, NOT
  // the live framebuffer — and it accepts no touches. Driven by [powered] alone,
  // independent of whether the device thread keeps emitting frames in the background.
  Widget _screen(ThemeData theme, bool powered) {
    final width = _deviceRenderWidth;
    final height = _deviceRenderWidth * _deviceHeight / _deviceWidth;
    final image = _image;

    if (!powered) {
      return SizedBox(
        width: width,
        height: height,
        child: ColoredBox(
          color: Colors.black,
          child: Center(
            child: Icon(
              Icons.usb_off_rounded,
              color: theme.colorScheme.outline,
              size: 28,
            ),
          ),
        ),
      );
    }

    final rendered = Size(width, height);
    return Listener(
      onPointerDown: (e) => _touchAt(e.localPosition, rendered, liftUp: false),
      onPointerUp: (e) => _touchAt(e.localPosition, rendered, liftUp: true),
      onPointerCancel: (e) => _touchAt(e.localPosition, rendered, liftUp: true),
      child: SizedBox(
        width: width,
        height: height,
        child: image == null
            ? const Center(child: CircularProgressIndicator())
            : RawImage(
                image: image,
                width: width,
                height: height,
                fit: BoxFit.fill,
                filterQuality: FilterQuality.none,
              ),
      ),
    );
  }
}
