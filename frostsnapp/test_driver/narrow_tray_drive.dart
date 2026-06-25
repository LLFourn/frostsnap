import 'dart:io';

import 'sim_harness.dart';

// sim-android-tray acceptance (narrow form factor): on a phone-sized surface the device console is
// NOT a docked panel but a SLIDE-IN tray — an edge handle opens it over the app; the in-tray + adds
// a device; a close affordance dismisses it. We force the narrow presentation on the wide desktop
// host via SIM_FORCE_NARROW (threaded through runScenario's extraDartDefines), so this stays
// host-runnable and deterministic — the real Android emulator is verified separately.
//
// Enumeration is proven the same way as the docked add path: the wallet-create "Continue with N
// devices" button reflects the coordinator's live connected count, so a device added via the
// slide-in + actually joined the bus (not merely a widget that appeared). Run:
// `./simctl test narrow_tray`. Needs a display.

const _settle = Duration(seconds: 90);

void _expect(Object? actual, Object? want, String what) {
  if (actual != want) throw StateError('$what: expected $want, got $actual');
}

void _expectChain(List<int> actual, List<int> want) =>
    _expect(actual.join(','), want.join(','), 'chain');

/// Poll [cond] until true or timeout — opening the tray and the + add are async.
Future<void> _waitUntil(Future<bool> Function() cond, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!await cond()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

Future<void> main() async {
  await SimHarness.runScenario(
    'narrow-tray',
    (h) async {
      // Forced narrow: the console is a slide-in, CLOSED at start — the edge handle is shown and the
      // panel content (the + button) is not in the tree.
      await h.waitFor('Open simulator');
      _expect(
        await h.exists('Add device'),
        false,
        'panel closed at start (no + button mounted)',
      );

      // Open via the edge handle; the console content becomes findable.
      await h.tap('Open simulator');
      await h.waitFor('Add device');

      // The in-tray + grows the fleet; the chain (the ChainRouter's truth, read over device(1)'s
      // socket) goes 1 -> 2.
      _expectChain(await h.chain(), [1]);
      await h.tap('Add device');
      await _waitUntil(
        () async => (await h.chain()).length == 2,
        'the in-tray + add to land',
      );
      _expectChain(await h.chain(), [1, 2]);

      // Close via the header close affordance; the panel (and its + button) leaves the tree, and the
      // edge handle returns.
      await h.tap('Close simulator');
      await h.waitForAbsent('Add device');
      await h.waitFor('Open simulator');

      // The device added via the slide-in + ENUMERATED to the coordinator: with the tray closed the
      // app is full-bleed and drivable, and wallet-create counts the live connected devices.
      await h.tapUntil(RegExp('Create a multi-sig wallet'), 'Wallet name');
      await h.enterText('Wallet name', 'NarrowGrow');
      await h.tapUntil('Next', RegExp('Continue with'));
      await h.waitFor('Continue with 2 devices', timeout: _settle);

      stdout.writeln(
        'NARROW_TRAY_DRIVE_OK: slide-in open + in-tray add + close, tail enumeration',
      );
    },
    deviceCount: 1,
    extraDartDefines: {'SIM_FORCE_NARROW': 'true'},
  );
}
