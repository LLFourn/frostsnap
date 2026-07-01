import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:frostsnap/copy_feedback.dart';
import 'package:frostsnap/sim_faucet.dart';
import 'package:frostsnap/src/rust/api/sim.dart';
import 'package:frostsnap/wallet.dart' show SatoshiText;

const double _trayWidth = 384;

/// Below this width (e.g. a phone) the console can't dock beside the app without crushing it, so
/// [SimTrayShell] presents it as a slide-in panel instead. Roughly the Material compact/expanded
/// line.
const double _narrowBreakpoint = 900;

/// Force the narrow (slide-in) presentation regardless of width — lets the slide-in be driven on a
/// wide desktop host (the narrow-tray e2e passes this), so it needs no emulator to test.
const bool _kCompileForceNarrow = bool.fromEnvironment('SIM_FORCE_NARROW');

bool get _forceNarrow {
  final value = Platform.environment['SIM_FORCE_NARROW'];
  return value == null ? _kCompileForceNarrow : value == 'true';
}

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

/// The SIM debug console content (`kSim`): a faucet card ("Test BTC", when a regtest backend is
/// wired) above the device manager — the connected daisy chain in order (top = the device on the
/// coordinator USB port) and the disconnected devices. Every device action recomputes the ordered
/// list and calls [DevicePool.setChain], the single source of truth.
///
/// This is the pure content — it makes NO width/dock assumption. [SimTrayShell] presents it either
/// docked beside the app (wide) or as a slide-in panel (narrow). When [onClose] is set (slide-in
/// mode) the header shows a close affordance.
class SimTrayContent extends StatefulWidget {
  final DevicePool pool;

  /// The faucet control socket, when the session was launched with a regtest backend; enables
  /// the "Test BTC" card. Null in an offline sim — the card is hidden.
  final String? regtestControlSocket;

  /// When set, the header shows a close button (the slide-in shell wires it to dismiss the panel).
  final VoidCallback? onClose;

  const SimTrayContent({
    super.key,
    required this.pool,
    this.regtestControlSocket,
    this.onClose,
  });

  @override
  State<SimTrayContent> createState() => _SimTrayContentState();
}

class _SimTrayContentState extends State<SimTrayContent> {
  // The fleet (which GROWS via the + button or an external simctl/driver-data add) and the
  // chain config (mutable from outside the tray) have no change stream, so poll: every tick
  // re-reads the device list into [_devices] and rebuilds (build() re-reads chain()), so the
  // UI converges for EVERY writer — not just the tray's own mutations.
  List<SimDevice>? _devices;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _poll = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => unawaited(_refresh()),
    );
  }

  Future<void> _refresh() async {
    final devices = await widget.pool.devices();
    if (mounted) setState(() => _devices = devices);
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

  // Add a new virtual device to the fleet (it joins the chain tail). Refresh after so it
  // shows immediately rather than waiting for the next poll tick.
  Future<void> _addDevice() async {
    try {
      await widget.pool.addDevice();
    } finally {
      await _refresh();
    }
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
    // The console renders OUTSIDE the app's Navigator (the shell mounts it above the app, so
    // dialogs can't cover it). That puts it outside the Navigator's Overlay/Material, so give it
    // its own Overlay + Material so Material widgets (ink, fields, tooltips) work in here.
    return Overlay(
      initialEntries: [
        OverlayEntry(
          builder: (context) => Material(
            color: theme.colorScheme.surfaceContainerLowest,
            child: Builder(
              builder: (context) {
                final devices = _devices;
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
                      onClose: widget.onClose,
                      onAddDevice: () => unawaited(_addDevice()),
                      onToggleAll: () => _apply(
                        allConnected
                            ? const []
                            : [for (final d in devices) d.number()],
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        // Clear the bottom system inset (Android gesture/nav bar) so the last card
                        // isn't hidden behind it.
                        padding: EdgeInsets.fromLTRB(
                          12,
                          4,
                          12,
                          16 + MediaQuery.paddingOf(context).bottom,
                        ),
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
                                  onConnect: () => _setConnected(device, true),
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
    );
  }
}

/// Presents [SimTrayContent] responsively over the app. On a WIDE surface the console docks beside
/// the app in a fixed-width column (desktop ergonomics: drive a device while a dialog is up). On a
/// NARROW surface (a phone) the app is full-bleed and the console slides in from the right over a
/// scrim, opened by a right-edge handle. In BOTH modes the console renders ABOVE the app's
/// Navigator (the shell is mounted by `MaterialApp.builder`), so it overlays in-app dialogs and
/// stays interactable while one is up.
/// The harness captures the whole sim surface (app + tray) by `toImage`-ing this RepaintBoundary
/// OFF-SCREEN (see sim_app.dart `app-screenshot`) — fresh regardless of window foreground state and
/// per-instance, replacing the macOS osascript-foreground `driver.screenshot()` hack.
final GlobalKey simAppScreenshotKey = GlobalKey();

class SimTrayShell extends StatefulWidget {
  final Widget app;
  final DevicePool pool;
  final String? regtestControlSocket;

  const SimTrayShell({
    super.key,
    required this.app,
    required this.pool,
    this.regtestControlSocket,
  });

  @override
  State<SimTrayShell> createState() => _SimTrayShellState();
}

class _SimTrayShellState extends State<SimTrayShell>
    with SingleTickerProviderStateMixin {
  // 0 = closed (off-screen right), 1 = fully open. Position/scrim/handle all read this RAW value
  // so a drag tracks the finger 1:1; the eased curve is applied by animateTo/animateBack (open/
  // close) and the spring by fling — none of which a CurvedAnimation wrapper would allow mid-drag.
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );

  // The edge handle shows the live device count. The console polls its own (richer) list, but it
  // is only mounted while the panel is open, so the shell keeps a light count poll of its own.
  int _deviceCount = 0;
  Timer? _countPoll;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshCount());
    _countPoll = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => unawaited(_refreshCount()),
    );
  }

  Future<void> _refreshCount() async {
    final n = (await widget.pool.devices()).length;
    if (mounted && n != _deviceCount) setState(() => _deviceCount = n);
  }

  @override
  void dispose() {
    _countPoll?.cancel();
    _anim.dispose();
    super.dispose();
  }

  void _open() => _anim.animateTo(1, curve: Curves.easeOutCubic);
  void _close() => _anim.animateBack(
    0,
    duration: const Duration(milliseconds: 250),
    curve: Curves.easeInCubic,
  );

  // Drag the handle/panel horizontally: leftward opens, rightward closes, 1:1 with the finger.
  void _onDrag(DragUpdateDetails d, double panelWidth) {
    _anim.value = (_anim.value - d.primaryDelta! / panelWidth).clamp(0.0, 1.0);
  }

  // On release a decisive flick wins (velocity in controller units/sec); otherwise settle to
  // whichever side the panel is nearer.
  void _onDragEnd(DragEndDetails d, double panelWidth) {
    final v = -d.velocity.pixelsPerSecond.dx / panelWidth;
    if (v.abs() >= 0.5) {
      _anim.fling(velocity: v);
    } else if (_anim.value >= 0.5) {
      _open();
    } else {
      _close();
    }
  }

  Widget _content({VoidCallback? onClose}) => SimTrayContent(
    pool: widget.pool,
    regtestControlSocket: widget.regtestControlSocket,
    onClose: onClose,
  );

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final narrow = _forceNarrow || width < _narrowBreakpoint;

    final Widget surface;
    if (!narrow) {
      surface = Row(
        textDirection: TextDirection.ltr,
        children: [
          Expanded(child: widget.app),
          SizedBox(width: _trayWidth, child: _content()),
        ],
      );
    } else {
      // Narrow: app full-bleed; the console slides in from the right over a scrim. The panel is only
      // in the tree while open/animating, so a closed tray streams no device frames.
      final panelWidth = (width * 0.88).clamp(0.0, _trayWidth + 24).toDouble();
      surface = Stack(
        textDirection: TextDirection.ltr,
        children: [
          widget.app,
          AnimatedBuilder(
            animation: _anim,
            builder: (context, _) {
              final t = _anim.value;
              return Stack(
                children: [
                  if (t > 0)
                    Positioned.fill(
                      key: const ValueKey('sim-tray-scrim'),
                      child: GestureDetector(
                        onTap: _close,
                        child: ColoredBox(
                          color: Colors.black.withValues(alpha: 0.5 * t),
                        ),
                      ),
                    ),
                  if (t < 1)
                    Positioned(
                      key: const ValueKey('sim-tray-handle'),
                      top: 0,
                      bottom: 0,
                      right: 0,
                      child: Center(
                        // Tap the handle to open, or drag it inward (from the edge) to pull the
                        // panel in with your finger.
                        child: GestureDetector(
                          onHorizontalDragUpdate: (d) => _onDrag(d, panelWidth),
                          onHorizontalDragEnd: (d) => _onDragEnd(d, panelWidth),
                          child: Opacity(
                            opacity: 1 - t,
                            child: _EdgeHandle(
                              deviceCount: _deviceCount,
                              onOpen: _open,
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (t > 0)
                    Positioned(
                      key: const ValueKey('sim-tray-panel'),
                      top: 0,
                      bottom: 0,
                      right: (t - 1) * panelWidth,
                      width: panelWidth,
                      // Swipe the panel right to dismiss it (a horizontal drag; the content's own
                      // vertical scroll and taps are a different gesture axis, so they don't clash).
                      child: GestureDetector(
                        onHorizontalDragUpdate: (d) => _onDrag(d, panelWidth),
                        onHorizontalDragEnd: (d) => _onDragEnd(d, panelWidth),
                        child: Material(
                          elevation: 16,
                          child: _content(onClose: _close),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      );
    }
    return RepaintBoundary(key: simAppScreenshotKey, child: surface);
  }
}

/// The right-edge affordance that opens the slide-in console on a narrow screen: a frosted,
/// primary-tinted pill hugging the edge with the live device count and a grip — it reads as "pull
/// me in". `semanticLabel: 'Open simulator'` so flutter_driver opens it the same as a human.
class _EdgeHandle extends StatelessWidget {
  final int deviceCount;
  final VoidCallback onOpen;

  const _EdgeHandle({required this.deviceCount, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    // container + ExcludeSemantics so this exposes EXACTLY one node labelled 'Open simulator' — the
    // inner count Text would otherwise merge in ("Open simulator\n$n") and break the exact-label
    // match flutter_driver / the e2e use. The real pointer tap still reaches the GestureDetector.
    return Semantics(
      button: true,
      container: true,
      label: 'Open simulator',
      child: ExcludeSemantics(
        child: GestureDetector(
          onTap: onOpen,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 14),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.97),
              borderRadius: const BorderRadius.horizontal(
                left: Radius.circular(16),
              ),
              border: Border.all(color: cs.outlineVariant),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.28),
                  blurRadius: 12,
                  offset: const Offset(-3, 0),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.developer_board_rounded,
                  size: 16,
                  color: cs.primary,
                ),
                const SizedBox(height: 8),
                Container(
                  width: 20,
                  height: 20,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '$deviceCount',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Icon(
                  Icons.drag_indicator_rounded,
                  size: 16,
                  color: cs.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TrayHeader extends StatelessWidget {
  final int deviceCount;
  final int connectedCount;
  final bool allConnected;
  final VoidCallback onAddDevice;
  final VoidCallback onToggleAll;

  /// Slide-in mode only: dismiss the panel. Null when docked (no close affordance).
  final VoidCallback? onClose;

  const _TrayHeader({
    required this.deviceCount,
    required this.connectedCount,
    required this.allConnected,
    required this.onAddDevice,
    required this.onToggleAll,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    // The console renders edge-to-edge (it's mounted outside the app's Scaffold), so on a phone the
    // system status bar overlaps the top. Let the header's coloured bar fill to the top edge, but
    // pad its content down past the status bar so the buttons stay tappable (app-bar style).
    final topInset = MediaQuery.paddingOf(context).top;
    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: cs.outlineVariant)),
      ),
      padding: EdgeInsets.fromLTRB(
        onClose != null ? 6 : 16,
        14 + topInset,
        12,
        14,
      ),
      child: Row(
        children: [
          if (onClose != null) ...[
            IconButton(
              onPressed: onClose,
              visualDensity: VisualDensity.compact,
              tooltip: 'Close simulator',
              icon: const Icon(
                Icons.chevron_right_rounded,
                semanticLabel: 'Close simulator',
              ),
            ),
            const SizedBox(width: 2),
          ],
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
          IconButton.filledTonal(
            onPressed: onAddDevice,
            visualDensity: VisualDensity.compact,
            tooltip: 'Add device',
            // semanticLabel (not the tooltip) is what flutter_driver matches on, so the
            // harness/e2e can drive this the same as a human.
            icon: const Icon(
              Icons.add_rounded,
              size: 18,
              semanticLabel: 'Add device',
            ),
          ),
          const SizedBox(width: 8),
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
  int? _blockHeight;
  String? _electrumUrl;
  String? _nodeAddress;
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
      final height = await faucet.blockHeight();
      // The URL and node address never change, so fetch each once and keep it (faucetAddress()
      // hands out a fresh address per call, so caching is what keeps the displayed one stable).
      final url = _electrumUrl ?? await faucet.electrumUrl();
      final nodeAddress = _nodeAddress ?? await faucet.faucetAddress();
      if (mounted) {
        setState(() {
          _balanceSat = balance;
          _blockHeight = height;
          _electrumUrl = url;
          _nodeAddress = nodeAddress;
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

  /// Paste the clipboard into the fund-address field (the prefix-icon button).
  Future<void> _pasteAddress() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text != null && text.isNotEmpty) _addressController.text = text;
  }

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
          // Reuse the app's SatoshiText so the faucet balance is grouped and the ₿ is sized
          // exactly like every other amount in the app.
          live
              ? SatoshiText(
                  value: balance!,
                  align: TextAlign.start,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: cs.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                )
              : Text('––––', style: theme.textTheme.headlineSmall?.merge(mono)),
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
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.layers_rounded, size: 13, color: cs.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(
                _blockHeight == null ? 'block …' : 'block ${_blockHeight!}',
                style: theme.textTheme.bodySmall
                    ?.merge(mono)
                    .copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // The regtest node's own wallet address — a handy destination to send test coins back
          // to. Copyable (faucetAddress() vends a fresh address each call; the displayed one is
          // cached so it stays put).
          Row(
            children: [
              Icon(
                Icons.account_balance_rounded,
                size: 13,
                color: cs.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _nodeAddress ?? 'node address …',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.merge(mono)
                      .copyWith(color: cs.onSurfaceVariant),
                ),
              ),
              if (_nodeAddress != null)
                IconButton(
                  iconSize: 15,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 28,
                    minHeight: 28,
                  ),
                  tooltip: 'Copy node address',
                  icon: const Icon(Icons.copy_rounded),
                  onPressed: () => copyToClipboardQuietly(_nodeAddress!),
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
              prefixIcon: IconButton(
                icon: const Icon(Icons.content_paste_rounded, size: 18),
                tooltip: 'Paste address',
                onPressed: () => unawaited(_pasteAddress()),
              ),
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
  // Device-coord start of the current press — lets pointer-up tell a tap/hold from a drag (swipe).
  int? _downX;
  int? _downY;

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

  (int, int) _deviceCoords(Offset local, Size rendered) {
    final x = (local.dx / rendered.width * _deviceWidth).round().clamp(
      0,
      _deviceWidth - 1,
    );
    final y = (local.dy / rendered.height * _deviceHeight).round().clamp(
      0,
      _deviceHeight - 1,
    );
    return (x, y);
  }

  void _pointerDown(Offset local, Size rendered) {
    final (x, y) = _deviceCoords(local, rendered);
    _downX = x;
    _downY = y;
    widget.device.touch(x: x, y: y, liftUp: false);
  }

  // A predominantly VERTICAL drag past the threshold becomes a swipe (the virtual device infers
  // SlideUp/SlideDown — the same path `./simctl swipe` uses). Horizontal or near-stationary
  // movement finishes the original press as a tap/hold (a horizontal swipe would toggle the
  // device's debug log, which is out of scope here).
  void _pointerUp(Offset local, Size rendered) {
    final (x, y) = _deviceCoords(local, rendered);
    final sx = _downX;
    final sy = _downY;
    _downX = null;
    _downY = null;
    const dragThreshold = 12;
    if (sx != null && sy != null) {
      final dx = (x - sx).abs();
      final dy = (y - sy).abs();
      if (dy > dragThreshold && dy >= dx) {
        widget.device.swipe(x1: sx, y1: sy, x2: x, y2: y, ms: 250);
        return;
      }
    }
    widget.device.touch(x: x, y: y, liftUp: true);
  }

  void _pointerCancel(Offset local, Size rendered) {
    _downX = null;
    _downY = null;
    final (x, y) = _deviceCoords(local, rendered);
    widget.device.touch(x: x, y: y, liftUp: true);
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
    // The device screen is a touchscreen: it must "suck in" every gesture so the enclosing
    // scrolling list (and the slide-in panel's drag-to-close) can't steal a swipe meant for the
    // device. An EagerGestureRecognizer wins the gesture arena immediately, so neither the ListView
    // nor the panel ever claims a drag that started here; the Listener still injects the raw touch.
    return RawGestureDetector(
      gestures: {
        EagerGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
              EagerGestureRecognizer.new,
              (_) {},
            ),
      },
      child: Listener(
        onPointerDown: (e) => _pointerDown(e.localPosition, rendered),
        onPointerUp: (e) => _pointerUp(e.localPosition, rendered),
        onPointerCancel: (e) => _pointerCancel(e.localPosition, rendered),
        child: screen,
      ),
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
