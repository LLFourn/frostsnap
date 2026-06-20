import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:frostsnap/src/rust/api/sim.dart';

const double _trayWidth = 260;

/// Device dimensions of the virtual device framebuffer (sim-1). Pointer coords
/// are scaled back to this range before being injected via [SimDevice.touch].
const int _deviceWidth = 240;
const int _deviceHeight = 280;

/// Docked debug column rendering every [SimDevice] in [pool] live and routing
/// taps back as device touches. Only built on the SIM entrypoint (`kSim`).
class SimDeviceTray extends StatefulWidget {
  final DevicePool pool;

  const SimDeviceTray({super.key, required this.pool});

  @override
  State<SimDeviceTray> createState() => _SimDeviceTrayState();
}

class _SimDeviceTrayState extends State<SimDeviceTray> {
  late final Future<List<SimDevice>> _devices = widget.pool.devices();

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
                  return ListView(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    children: [
                      for (final device in devices)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 8,
                          ),
                          child: _SimDeviceCell(device: device),
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

class _SimDeviceCell extends StatefulWidget {
  final SimDevice device;

  const _SimDeviceCell({required this.device});

  @override
  State<_SimDeviceCell> createState() => _SimDeviceCellState();
}

class _SimDeviceCellState extends State<_SimDeviceCell> {
  StreamSubscription<SimFrame>? _subscription;
  ui.Image? _image;
  late bool _connected = widget.device.isConnected();

  @override
  void initState() {
    super.initState();
    _subscription = widget.device.frames().listen(_onFrame);
  }

  // Simulate plug/unplug: flips the coordinator-side port presence. The device
  // thread keeps running, so its screen keeps rendering while "unplugged".
  void _toggleConnected() {
    final next = !_connected;
    widget.device.setConnected(connected: next);
    setState(() => _connected = next);
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
    final image = _image;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                widget.device.id(),
                style: theme.textTheme.labelSmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              tooltip: _connected ? 'Disconnect (unplug)' : 'Connect (plug in)',
              icon: Icon(
                _connected ? Icons.usb_rounded : Icons.usb_off_rounded,
              ),
              onPressed: _toggleConnected,
            ),
          ],
        ),
        const SizedBox(height: 4),
        LayoutBuilder(
          builder: (context, constraints) {
            // Fit the 240x280 device into the tray's available width, keeping aspect.
            final width = constraints.maxWidth;
            final height = width * _deviceHeight / _deviceWidth;
            final rendered = Size(width, height);
            return Listener(
              onPointerDown: (e) =>
                  _touchAt(e.localPosition, rendered, liftUp: false),
              onPointerUp: (e) =>
                  _touchAt(e.localPosition, rendered, liftUp: true),
              onPointerCancel: (e) =>
                  _touchAt(e.localPosition, rendered, liftUp: true),
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
          },
        ),
      ],
    );
  }
}
