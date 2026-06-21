import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:frostsnap/src/rust/api/sim.dart';

const double _trayWidth = 320;

/// Device dimensions of the virtual device framebuffer (sim-1). Pointer coords
/// are scaled back to this range before being injected via [SimDevice.touch].
const int _deviceWidth = 240;
const int _deviceHeight = 280;

/// Rendered width of a connected device's live screen in the chain column.
const double _chainRenderWidth = 132;

/// Docked debug column for the SIM entrypoint (`kSim`). Two columns: the LEFT is the
/// connected daisy chain in order (top = the device on the coordinator USB port), the
/// RIGHT is the disconnected devices. Moving a device between columns connects/disconnects
/// it and the up/down arrows reorder it within the chain — every action recomputes the
/// ordered list and calls [DevicePool.setChain], the single source of truth.
class SimDeviceTray extends StatefulWidget {
  final DevicePool pool;

  const SimDeviceTray({super.key, required this.pool});

  @override
  State<SimDeviceTray> createState() => _SimDeviceTrayState();
}

class _SimDeviceTrayState extends State<SimDeviceTray> {
  late final Future<List<SimDevice>> _devices = widget.pool.devices();

  // The chain config can change from OUTSIDE the tray (simctl / the device channel), and
  // there is no change stream, so poll it: every cell re-reads chain() and converges
  // however it was changed (tray actions, plug-all, or an external set-chain).
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _apply(List<int> order) {
    widget.pool.setChain(order: order);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The tray docks BESIDE the app's Navigator (so dialogs can't cover it), which puts
    // it outside the Navigator's Overlay/Material. Give it its own Overlay + Material so
    // Material widgets (IconButton ink) and Tooltips work in here.
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
                  final chain = widget.pool.chain();
                  final byNumber = {for (final d in devices) d.number(): d};
                  // LEFT: connected devices in chain order (skip any number the pool no
                  // longer knows, defensively).
                  final connected = [
                    for (final n in chain)
                      if (byNumber[n] != null) byNumber[n]!,
                  ];
                  // RIGHT: everything not in the chain, in number order.
                  final disconnected = [
                    for (final d in devices)
                      if (!chain.contains(d.number())) d,
                  ];
                  final allConnected = disconnected.isEmpty;

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _TrayHeader(
                        deviceCount: devices.length,
                        allConnected: allConnected,
                        onToggleAll: () => _apply(
                          allConnected
                              ? const []
                              : [for (final d in devices) d.number()],
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: _ChainColumn(
                                connected: connected,
                                onMoveUp: (n) => _apply(_moved(chain, n, -1)),
                                onMoveDown: (n) => _apply(_moved(chain, n, 1)),
                                onDisconnect: (n) =>
                                    _apply([...chain]..remove(n)),
                              ),
                            ),
                            const VerticalDivider(width: 1),
                            Expanded(
                              child: _OffColumn(
                                disconnected: disconnected,
                                onConnect: (n) => _apply([...chain, n]),
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

  // The chain with [number] shifted by [delta] positions (clamped to the ends).
  List<int> _moved(List<int> chain, int number, int delta) {
    final order = [...chain];
    final i = order.indexOf(number);
    final j = i + delta;
    if (i < 0 || j < 0 || j >= order.length) return order;
    order
      ..removeAt(i)
      ..insert(j, number);
    return order;
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

/// LEFT column: the connected chain, top = the coordinator (USB) end.
class _ChainColumn extends StatelessWidget {
  final List<SimDevice> connected;
  final void Function(int number) onMoveUp;
  final void Function(int number) onMoveDown;
  final void Function(int number) onDisconnect;

  const _ChainColumn({
    required this.connected,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
          child: Text('Chain', style: theme.textTheme.labelSmall),
        ),
        Expanded(
          child: connected.isEmpty
              ? Center(
                  child: Text(
                    'No devices\nconnected',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.only(bottom: 8),
                  children: [
                    for (var i = 0; i < connected.length; i++)
                      Padding(
                        key: ValueKey(connected[i].number()),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        child: _ChainCell(
                          device: connected[i],
                          isHead: i == 0,
                          isTail: i == connected.length - 1,
                          onMoveUp: () => onMoveUp(connected[i].number()),
                          onMoveDown: () => onMoveDown(connected[i].number()),
                          onDisconnect: () =>
                              onDisconnect(connected[i].number()),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// RIGHT column: disconnected devices (screen off), each with a connect action.
class _OffColumn extends StatelessWidget {
  final List<SimDevice> disconnected;
  final void Function(int number) onConnect;

  const _OffColumn({required this.disconnected, required this.onConnect});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
          child: Text('Disconnected', style: theme.textTheme.labelSmall),
        ),
        Expanded(
          child: disconnected.isEmpty
              ? Center(
                  child: Text(
                    'All\nconnected',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.only(bottom: 8),
                  children: [
                    for (final device in disconnected)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        child: Card(
                          margin: EdgeInsets.zero,
                          color: theme.colorScheme.surfaceContainerHigh,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(10, 2, 2, 2),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Tooltip(
                                    message: device.id(),
                                    child: Text(
                                      'Device ${device.number()}',
                                      style: theme.textTheme.labelMedium,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  iconSize: 18,
                                  visualDensity: VisualDensity.compact,
                                  tooltip: 'Connect (add to chain)',
                                  icon: const Icon(Icons.add_link_rounded),
                                  onPressed: () => onConnect(device.number()),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// One connected device in the chain: live screen + reorder/disconnect controls.
class _ChainCell extends StatefulWidget {
  final SimDevice device;
  final bool isHead;
  final bool isTail;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;
  final VoidCallback onDisconnect;

  const _ChainCell({
    required this.device,
    required this.isHead,
    required this.isTail,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onDisconnect,
  });

  @override
  State<_ChainCell> createState() => _ChainCellState();
}

class _ChainCellState extends State<_ChainCell> {
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
    final width = _chainRenderWidth;
    final height = _chainRenderWidth * _deviceHeight / _deviceWidth;
    final rendered = Size(width, height);
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
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            _denseIcon(
              Icons.keyboard_arrow_up_rounded,
              'Move up',
              widget.isHead ? null : widget.onMoveUp,
            ),
            _denseIcon(
              Icons.keyboard_arrow_down_rounded,
              'Move down',
              widget.isTail ? null : widget.onMoveDown,
            ),
            _denseIcon(
              Icons.link_off_rounded,
              'Disconnect',
              widget.onDisconnect,
            ),
          ],
        ),
        const SizedBox(height: 2),
        Center(
          child: Listener(
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
          ),
        ),
      ],
    );
  }

  Widget _denseIcon(IconData icon, String tooltip, VoidCallback? onPressed) {
    return IconButton(
      iconSize: 16,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      tooltip: tooltip,
      icon: Icon(icon),
      onPressed: onPressed,
    );
  }
}
