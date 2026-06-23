import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:frostsnap/sim_faucet.dart';
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

  /// The faucet control socket, when the session was launched with a regtest backend; enables
  /// the "Test BTC" column. Null in an offline sim — the column is hidden.
  final String? regtestControlSocket;

  const SimDeviceTray({
    super.key,
    required this.pool,
    this.regtestControlSocket,
  });

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

  // Connect/disconnect one device. Routes through the device's set_connected so the router
  // applies the daisy-chain semantics in ONE place: connect plugs into the tail, disconnect
  // cuts the chain there (the device and everything downstream go to the disconnected pool).
  void _setConnected(SimDevice? device, bool connected) {
    device?.setConnected(connected: connected);
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
                      if (widget.regtestControlSocket != null) ...[
                        _FaucetPanel(socketPath: widget.regtestControlSocket!),
                        const Divider(height: 1),
                      ],
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
                                    _setConnected(byNumber[n], false),
                              ),
                            ),
                            const VerticalDivider(width: 1),
                            Expanded(
                              child: _OffColumn(
                                disconnected: disconnected,
                                onConnect: (n) =>
                                    _setConnected(byNumber[n], true),
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
                        key: ValueKey(device.number()),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        // Mirror the chain cell, but the screen is dark (the device is
                        // powered off) and not touchable; the action reconnects it.
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
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
                                _denseIcon(
                                  Icons.add_link_rounded,
                                  'Connect (add to chain)',
                                  () => onConnect(device.number()),
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Center(
                              child: _DeviceScreen(
                                device: device,
                                interactive: false,
                              ),
                            ),
                          ],
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
class _ChainCell extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
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
            _denseIcon(
              Icons.keyboard_arrow_up_rounded,
              'Move up',
              isHead ? null : onMoveUp,
            ),
            _denseIcon(
              Icons.keyboard_arrow_down_rounded,
              'Move down',
              isTail ? null : onMoveDown,
            ),
            _denseIcon(Icons.link_off_rounded, 'Disconnect', onDisconnect),
          ],
        ),
        const SizedBox(height: 2),
        Center(child: _DeviceScreen(device: device, interactive: true)),
      ],
    );
  }
}

/// A device's live screen, used in both tray columns. Subscribes to the device's frame
/// stream and paints each frame; the stream replays the current framebuffer on subscribe,
/// so a powered-off device — whose framebuffer was cleared to black on disconnect (sim-13) —
/// paints dark immediately. Touchable only when [interactive] (the connected chain cell); a
/// disconnected device is shown going dark but is not drivable.
class _DeviceScreen extends StatefulWidget {
  final SimDevice device;
  final bool interactive;

  const _DeviceScreen({required this.device, required this.interactive});

  @override
  State<_DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends State<_DeviceScreen> {
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
    final image = _image;
    const width = _chainRenderWidth;
    const height = _chainRenderWidth * _deviceHeight / _deviceWidth;
    const rendered = Size(width, height);
    final screen = SizedBox(
      width: width,
      height: height,
      child: image == null
          ? const ColoredBox(color: Colors.black)
          : RawImage(
              image: image,
              width: width,
              height: height,
              fit: BoxFit.fill,
              filterQuality: FilterQuality.none,
            ),
    );
    if (!widget.interactive) {
      return screen;
    }
    return Listener(
      onPointerDown: (e) => _touchAt(e.localPosition, rendered, liftUp: false),
      onPointerUp: (e) => _touchAt(e.localPosition, rendered, liftUp: true),
      onPointerCancel: (e) => _touchAt(e.localPosition, rendered, liftUp: true),
      child: screen,
    );
  }
}

/// The "Test BTC" column: drives the regtest faucet (sim-only, shown when the session has a
/// backend). Shows the faucet's spendable balance and the electrum URL the wallet syncs against,
/// mines blocks, and sends test coins to ANY address you paste in (copy a receive address from
/// the wallet, paste it here, Fund) — deliberately wallet-agnostic, so the tray needs no
/// knowledge of the open wallet. Each action opens a short-lived [SimFaucet] connection because
/// the backend serves one client at a time (a held socket would starve `./simctl`).
class _FaucetPanel extends StatefulWidget {
  final String socketPath;

  const _FaucetPanel({required this.socketPath});

  @override
  State<_FaucetPanel> createState() => _FaucetPanelState();
}

class _FaucetPanelState extends State<_FaucetPanel> {
  final _addressController = TextEditingController();
  final _amountController = TextEditingController(text: '1');
  Timer? _poll;
  int? _balanceSat;
  String? _electrumUrl;
  bool _busy = false;
  String? _fundResult;

  @override
  void initState() {
    super.initState();
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _addressController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_busy) return;
    SimFaucet? faucet;
    try {
      faucet = await SimFaucet.connect(widget.socketPath);
      final balance = await faucet.balanceSat();
      // The URL never changes, so fetch it once and keep it.
      final url = _electrumUrl ?? await faucet.electrumUrl();
      if (mounted) {
        setState(() {
          _balanceSat = balance;
          _electrumUrl = url;
        });
      }
    } catch (_) {
      // Backend not (yet) reachable; keep the last-known values rather than flicker.
    } finally {
      await faucet?.close();
    }
  }

  /// Run [action] against a short-lived faucet connection, surfacing its outcome (or error) in
  /// the panel and refreshing the balance after.
  Future<void> _run(Future<String> Function(SimFaucet) action) async {
    setState(() {
      _busy = true;
      _fundResult = null;
    });
    SimFaucet? faucet;
    String result;
    try {
      faucet = await SimFaucet.connect(widget.socketPath);
      result = await action(faucet);
    } catch (e) {
      result = '$e';
    } finally {
      await faucet?.close();
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _fundResult = result;
      });
    }
    await _refresh();
  }

  Future<void> _mine() => _run((f) async {
    await f.mine(1);
    return 'mined 1 block';
  });

  Future<void> _fund() {
    final address = _addressController.text.trim();
    final btc = double.tryParse(_amountController.text.trim());
    if (address.isEmpty) {
      setState(() => _fundResult = 'enter an address');
      return Future.value();
    }
    if (btc == null || btc <= 0) {
      setState(() => _fundResult = 'enter a positive amount');
      return Future.value();
    }
    final sats = (btc * 100000000).round();
    return _run((f) async {
      final txid = await f.fund(address, sats);
      return 'sent ${_formatBtc(sats)} BTC · ${txid.substring(0, 12)}…';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final balance = _balanceSat;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Test BTC', style: theme.textTheme.labelLarge),
              ),
              TextButton.icon(
                onPressed: _busy ? null : _mine,
                icon: const Icon(Icons.add_box_rounded, size: 16),
                label: const Text('Mine'),
              ),
            ],
          ),
          Text(
            balance == null
                ? 'Faucet: connecting…'
                : 'Faucet: ${_formatBtc(balance)} BTC',
            style: theme.textTheme.bodyMedium,
          ),
          if (_electrumUrl != null)
            Text(
              _electrumUrl!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          const SizedBox(height: 6),
          TextField(
            controller: _addressController,
            style: theme.textTheme.bodySmall,
            decoration: const InputDecoration(
              labelText: 'Fund address',
              hintText: 'paste a receive address',
              isDense: true,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              SizedBox(
                width: 96,
                child: TextField(
                  controller: _amountController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: theme.textTheme.bodySmall,
                  decoration: const InputDecoration(
                    labelText: 'Amount (BTC)',
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: _busy ? null : _fund,
                  child: const Text('Fund'),
                ),
              ),
            ],
          ),
          if (_fundResult != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _fundResult!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }
}

/// Sats as a fixed-precision BTC string (8 decimals collapsed to 4 for the tray).
String _formatBtc(int sats) => (sats / 100000000).toStringAsFixed(4);

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
