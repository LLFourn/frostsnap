import 'dart:convert';
import 'dart:io';

import 'sim_harness.dart';

// fsim-app-pixel-tap: e2e regression for the CHANNEL wiring the unit tests can't reach — tapTooltip
// through the snapshot resolver + find.byTooltip, and tapAppAt driven from the snapshot's global
// bounds (the same logical coordinate space). Uses the sim tray's tooltip-only controls
// ('Disconnect' has no semantic label). Runs on host AND android: `./fsim test app_tap [--android]`.
Future<void> main() async {
  await AppSession.runScenario('app-tap', (h) async {
    // The tooltip-only controls live in the SIM TRAY. The wide host window shows it expanded
    // inline; the narrow android layout collapses it to a rail — open it there so the SAME
    // scenario runs on both.
    if (!await h.exists('Add device')) {
      await h.tap('Open simulator');
      await h.waitFor('Add device');
    }

    // Unknown tooltip → the diagnostic listing, never a raw finder timeout.
    Object? unknown;
    try {
      await h.tapTooltip('Rename');
    } catch (e) {
      unknown = e;
    }
    if (!'$unknown'.contains('no on-stage tooltip') ||
        !'$unknown'.contains('Add device')) {
      throw StateError('unknown-tooltip diagnostics missing, got: $unknown');
    }

    // Ambiguous pattern → error listing every match.
    Object? ambiguous;
    try {
      await h.tapTooltip(RegExp('Add device|Disconnect'));
    } catch (e) {
      ambiguous = e;
    }
    if (!'$ambiguous'.contains('ambiguous') ||
        !'$ambiguous'.contains('Disconnect')) {
      throw StateError(
        'ambiguous-tooltip diagnostics missing, got: $ambiguous',
      );
    }

    // A tooltip-only control (no semantic label) through the ONE resolver path; effect observed via
    // app state — device 1 leaves the chain.
    await h.tapTooltip('Disconnect');
    await _poll(
      () async => (await h.chain()).isEmpty,
      'chain did not empty after tapTooltip("Disconnect")',
    );
    await h.connect(1);

    // tapAppAt at a control's GLOBAL-bounds center (same logical space as the snapshot): tapping
    // 'Add device' grows the fleet — observable app state, not pixels.
    final before = (await h.deviceNumbers()).length;
    final nodes = jsonDecode(await h.semantics().json())['nodes'] as List;
    final add = nodes.firstWhere((n) => n['tooltip'] == 'Add device') as Map;
    final b = add['bounds'] as Map;
    await h.tapAppAt(
      ((b['left'] as num) + (b['width'] as num) / 2).toDouble(),
      ((b['top'] as num) + (b['height'] as num) / 2).toDouble(),
    );
    await _poll(
      () async => (await h.deviceNumbers()).length == before + 1,
      'device count did not grow after tapAppAt on the Add device bounds center',
    );

    // Out-of-bounds → clear error naming the logical view size, no dispatch.
    Object? oob;
    try {
      await h.tapAppAt(99999, 5);
    } catch (e) {
      oob = e;
    }
    if (!'$oob'.contains('outside the view')) {
      throw StateError('out-of-bounds diagnostics missing, got: $oob');
    }

    stdout.writeln('APP_TAP_OK: tooltip resolver + positional tap verified');
  });
}

Future<void> _poll(Future<bool> Function() done, String timeoutError) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!await done()) {
    if (DateTime.now().isAfter(deadline)) throw StateError(timeoutError);
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}
