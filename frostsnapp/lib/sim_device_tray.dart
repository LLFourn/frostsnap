import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:frostsnap/sim_faucet.dart';
import 'package:frostsnap/src/rust/api/sim.dart';

const double _trayWidth = 384;

/// Device dimensions of the virtual device framebuffer (sim-1). Pointer coords
/// are scaled back to this range before being injected via [SimDevice.touch].
const int _deviceWidth = 240;
const int _deviceHeight = 280;

/// A connected device's live screen is rendered large enough to actually drive; a disconnected
/// one is a small dark thumbnail.
const double _chainScreenWidth = 152;
const double _offScreenWidth = 69;

/// "OK" / "pending" indicator colours for the faucet status light — instrument-panel cues that
/// read instantly against the dark console, independent of the cyan accent.
const Color _liveColor = Color(0xFF3DDC97);
const Color _pendingColor = Color(0xFFE0A458);

/// Docked debug console for the SIM entrypoint (`kSim`). A faucet card ("Test BTC", when a
/// regtest backend is wired) sits above the device manager: the connected daisy chain in order
/// (top = the device on the coordinator USB port) and the disconnected devices. Every device
/// action recomputes the ordered list and calls [DevicePool.setChain], the single source of truth.
class SimDeviceTray extends StatefulWidget {
  final DevicePool pool;

  /// The faucet control socket, when the session was launched with a regtest backend; enables
  /// the "Test BTC" card. Null in an offline sim — the card is hidden.
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
  // there is no change stream, so poll it: every build re-reads chain() and converges however
  // it was changed (tray actions, plug-all, or an external set-chain).
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
    // The tray docks BESIDE the app's Navigator (so dialogs can't cover it), which puts it
    // outside the Navigator's Overlay/Material. Give it its own Overlay + Material so Material
    // widgets (ink, fields, tooltips) work in here.
    return SizedBox(
      width: _trayWidth,
      child: Overlay(
        initialEntries: [
          OverlayEntry(
            builder: (context) => Material(
              color: theme.colorScheme.surfaceContainerLowest,
              child: FutureBuilder<List<SimDevice>>(
                future: _devices,
                builder: (context, snapshot) {
                  final devices = snapshot.data;
                  if (devices == null) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final chain = widget.pool.chain();
                  final byNumber = {for (final d in devices) d.number(): d};
                  // Connected devices in chain order (skip any number the pool no longer knows,
                  // defensively); everything else is disconnected, in number order.
                  final connected = [
                    for (final n in chain)
                      if (byNumber[n] != null) byNumber[n]!,
                  ];
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
                        connectedCount: connected.length,
                        allConnected: allConnected,
                        onToggleAll: () => _apply(
                          allConnected
                              ? const []
                              : [for (final d in devices) d.number()],
                        ),
                      ),
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                          children: [
                            if (widget.regtestControlSocket != null) ...[
                              _FaucetCard(
                                socketPath: widget.regtestControlSocket!,
                              ),
                              const SizedBox(height: 16),
                            ],
                            _SectionLabel(
                              'Chain',
                              trailing: connected.isEmpty
                                  ? null
                                  : '${connected.length}',
                            ),
                            const SizedBox(height: 8),
                            if (connected.isEmpty)
                              const _EmptyHint(
                                icon: Icons.power_off_rounded,
                                text: 'No devices connected',
                              )
                            else
                              for (var i = 0; i < connected.length; i++)
                                Padding(
                                  key: ValueKey(connected[i].number()),
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: _ChainCard(
                                    device: connected[i],
                                    position: i + 1,
                                    isHead: i == 0,
                                    onDisconnect: () =>
                                        _setConnected(connected[i], false),
                                  ),
                                ),
                            if (disconnected.isNotEmpty) ...[
                              const SizedBox(height: 16),
                              _SectionLabel(
                                'Disconnected',
                                trailing: '${disconnected.length}',
                              ),
                              const SizedBox(height: 8),
                              for (final device in disconnected)
                                Padding(
                                  key: ValueKey(device.number()),
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: _OffCard(
                                    device: device,
                                    onConnect: () =>
                                        _setConnected(device, true),
                                  ),
                                ),
                            ],
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
  final int connectedCount;
  final bool allConnected;
  final VoidCallback onToggleAll;

  const _TrayHeader({
    required this.deviceCount,
    required this.connectedCount,
    required this.allConnected,
    required this.onToggleAll,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: cs.outlineVariant)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      child: Row(
        children: [
          Icon(Icons.developer_board_rounded, size: 20, color: cs.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'SIMULATOR',
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.5,
                  ),
                ),
                Text(
                  '$connectedCount of $deviceCount connected',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          FilledButton.tonalIcon(
            onPressed: onToggleAll,
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            icon: Icon(
              allConnected ? Icons.usb_off_rounded : Icons.usb_rounded,
              size: 16,
            ),
            label: Text(allConnected ? 'Unplug all' : 'Plug in all'),
          ),
        ],
      ),
    );
  }
}

/// An uppercase, letter-spaced section heading with an optional count chip.
class _SectionLabel extends StatelessWidget {
  final String label;
  final String? trailing;

  const _SectionLabel(this.label, {this.trailing});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Row(
      children: [
        Text(
          label.toUpperCase(),
          style: theme.textTheme.labelMedium?.copyWith(
            color: cs.onSurfaceVariant,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              trailing!,
              style: theme.textTheme.labelSmall?.copyWith(
                color: cs.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// A floating card surface — the one container shape used throughout the console.
class _Card extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final Color? color;

  const _Card({
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: child,
    );
  }
}

class _EmptyHint extends StatelessWidget {
  final IconData icon;
  final String text;

  const _EmptyHint({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return _Card(
      padding: const EdgeInsets.symmetric(vertical: 22),
      child: Column(
        children: [
          Icon(icon, color: cs.onSurfaceVariant, size: 22),
          const SizedBox(height: 6),
          Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// The "Test BTC" faucet card: a live balance read-out + electrum status, a Mine control, and a
/// generic fund-an-address form. Wallet-agnostic by design — paste any receive address — so the
/// tray needs no knowledge of the open wallet. Each action opens a short-lived [SimFaucet]
/// connection (the backend serves one client at a time, so a held socket would starve `./simctl`).
class _FaucetCard extends StatefulWidget {
  final String socketPath;

  const _FaucetCard({required this.socketPath});

  @override
  State<_FaucetCard> createState() => _FaucetCardState();
}

class _FaucetCardState extends State<_FaucetCard> {
  final _addressController = TextEditingController();
  final _amountController = TextEditingController(text: '1');
  Timer? _poll;
  int? _balanceSat;
  String? _electrumUrl;
  bool _busy = false;
  String? _result;
  bool _resultIsError = false;

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

  /// Run [action] against a short-lived faucet connection, surfacing its outcome (or error) and
  /// refreshing the balance after.
  Future<void> _run(Future<String> Function(SimFaucet) action) async {
    setState(() {
      _busy = true;
      _result = null;
    });
    SimFaucet? faucet;
    String result;
    var error = false;
    try {
      faucet = await SimFaucet.connect(widget.socketPath);
      result = await action(faucet);
    } catch (e) {
      result = '$e';
      error = true;
    } finally {
      await faucet?.close();
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _result = result;
        _resultIsError = error;
      });
    }
    await _refresh();
  }

  Future<void> _mine() => _run((f) async {
    await f.mine(1);
    return 'Mined 1 block';
  });

  Future<void> _fund() {
    final address = _addressController.text.trim();
    final btc = double.tryParse(_amountController.text.trim());
    if (address.isEmpty) {
      setState(() {
        _result = 'Enter an address to fund';
        _resultIsError = true;
      });
      return Future.value();
    }
    if (btc == null || btc <= 0) {
      setState(() {
        _result = 'Enter a positive amount';
        _resultIsError = true;
      });
      return Future.value();
    }
    final sats = (btc * 100000000).round();
    return _run((f) async {
      final txid = await f.fund(address, sats);
      return 'Sent ${_formatBtc(sats)} ₿ · ${txid.substring(0, 10)}…';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final mono = TextStyle(
      fontFamily: 'monospace',
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final live = _balanceSat != null;
    final balance = _balanceSat;

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _StatusDot(color: live ? _liveColor : _pendingColor),
              const SizedBox(width: 8),
              Text(
                'TEST BTC',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _busy ? null : _mine,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                icon: const Icon(Icons.bolt_rounded, size: 18),
                label: const Text('Mine'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Faucet balance',
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                live ? _formatBtc(balance!) : '––––',
                style: theme.textTheme.headlineSmall
                    ?.merge(mono)
                    .copyWith(color: cs.onSurface, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 6),
              Text(
                '₿',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: cs.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                Icons.lan_rounded,
                size: 13,
                color: live ? _liveColor : cs.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _electrumUrl ?? 'connecting to electrum…',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.merge(mono)
                      .copyWith(color: cs.onSurfaceVariant),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Divider(height: 1, color: cs.outlineVariant),
          ),
          TextField(
            controller: _addressController,
            style: theme.textTheme.bodyMedium?.merge(mono),
            decoration: InputDecoration(
              labelText: 'Fund address',
              hintText: 'paste a receive address',
              isDense: true,
              filled: true,
              fillColor: cs.surfaceContainerHighest,
              prefixIcon: const Icon(Icons.content_paste_rounded, size: 18),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              SizedBox(
                width: 116,
                child: TextField(
                  controller: _amountController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: theme.textTheme.bodyMedium?.merge(mono),
                  decoration: InputDecoration(
                    labelText: 'Amount',
                    suffixText: '₿',
                    isDense: true,
                    filled: true,
                    fillColor: cs.surfaceContainerHighest,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : _fund,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send_rounded, size: 18),
                  label: const Text('Fund'),
                ),
              ),
            ],
          ),
          if (_result != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Row(
                children: [
                  Icon(
                    _resultIsError
                        ? Icons.error_outline_rounded
                        : Icons.check_circle_outline_rounded,
                    size: 15,
                    color: _resultIsError ? cs.error : _liveColor,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _result!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _resultIsError ? cs.error : cs.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  final Color color;

  const _StatusDot({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 6),
        ],
      ),
    );
  }
}

/// One connected device in the chain: position badge, live (touchable) screen, identity, and
/// reorder/disconnect controls. The head carries a coordinator/USB marker (top = USB port).
class _ChainCard extends StatelessWidget {
  final SimDevice device;
  final int position;
  final bool isHead;
  final VoidCallback onDisconnect;

  const _ChainCard({
    required this.device,
    required this.position,
    required this.isHead,
    required this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return _Card(
      padding: const EdgeInsets.all(10),
      child: Stack(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _DeviceScreen(
                device: device,
                width: _chainScreenWidth,
                interactive: true,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        _PositionBadge(position),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Device ${device.number()}',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        // room for the corner disconnect button
                        const SizedBox(width: 28),
                      ],
                    ),
                    const SizedBox(height: 4),
                    if (isHead)
                      Row(
                        children: [
                          Icon(Icons.usb_rounded, size: 13, color: cs.primary),
                          const SizedBox(width: 4),
                          Text(
                            'coordinator port',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: cs.primary,
                            ),
                          ),
                        ],
                      ),
                    Tooltip(
                      message: device.id(),
                      child: Text(
                        device.id(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Positioned(
            top: 0,
            right: 0,
            child: _denseIcon(
              Icons.link_off_rounded,
              'Disconnect',
              onDisconnect,
              color: cs.error,
            ),
          ),
        ],
      ),
    );
  }
}

/// A disconnected device: dimmed dark thumbnail + identity + a connect action.
class _OffCard extends StatelessWidget {
  final SimDevice device;
  final VoidCallback onConnect;

  const _OffCard({required this.device, required this.onConnect});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return _Card(
      color: cs.surfaceContainer,
      padding: const EdgeInsets.all(10),
      child: Row(
        children: [
          Opacity(
            opacity: 0.5,
            child: _DeviceScreen(
              device: device,
              width: _offScreenWidth,
              interactive: false,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Device ${device.number()}',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Tooltip(
                  message: device.id(),
                  child: Text(
                    device.id(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonalIcon(
            onPressed: onConnect,
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            icon: const Icon(Icons.add_link_rounded, size: 16),
            label: const Text('Connect'),
          ),
        ],
      ),
    );
  }
}

/// A small primary-tinted badge showing a device's 1-based position in the chain.
class _PositionBadge extends StatelessWidget {
  final int position;

  const _PositionBadge(this.position);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      width: 20,
      height: 20,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: cs.primary.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '$position',
        style: theme.textTheme.labelSmall?.copyWith(
          color: cs.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// A device's live screen. Subscribes to the device's frame stream and paints each frame; the
/// stream replays the current framebuffer on subscribe, so a powered-off device — whose
/// framebuffer was cleared to black on disconnect (sim-13) — paints dark immediately. Touchable
/// only when [interactive].
class _DeviceScreen extends StatefulWidget {
  final SimDevice device;
  final double width;
  final bool interactive;

  const _DeviceScreen({
    required this.device,
    required this.width,
    required this.interactive,
  });

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
    final width = widget.width;
    final height = width * _deviceHeight / _deviceWidth;
    final rendered = Size(width, height);
    final screen = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
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

/// Sats as a fixed-precision BTC string (8 decimals collapsed to 4 for the tray).
String _formatBtc(int sats) => (sats / 100000000).toStringAsFixed(4);

Widget _denseIcon(
  IconData icon,
  String tooltip,
  VoidCallback? onPressed, {
  Color? color,
}) {
  return IconButton(
    iconSize: 18,
    visualDensity: VisualDensity.compact,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
    tooltip: tooltip,
    color: color,
    icon: Icon(icon),
    onPressed: onPressed,
  );
}
