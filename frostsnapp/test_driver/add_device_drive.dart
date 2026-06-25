import 'dart:io';

import 'sim_harness.dart';

// runtime-add-devices acceptance: the virtual fleet GROWS at runtime, and a device added by
// EITHER writer — the harness/`./simctl add-device` OR the tray + button — joins the chain TAIL
// and enumerates to the coordinator (real daisy-chain hot-plug, not a star). There is ONE source
// of truth for the fleet (the app-side `simDevicePool`, read via `deviceNumbers()`), so a tray add
// is visible to the harness immediately — no device-channel cache, no resync.
//
// Enumeration is proven via the wallet-create "Continue with N devices" button (the coordinator's
// live connected count), not just fleet membership — a green-but-wrong "device appeared" check
// would not prove the device actually joined the bus. Run: `./simctl test add_device`. Needs a
// display.

// A tail add re-handshakes hop-by-hop at the coordinator's ~100ms cadence, so give the live
// count a generous settle window.
const _settle = Duration(seconds: 90);

void _expect(Object? actual, Object? want, String what) {
  if (actual != want) throw StateError('$what: expected $want, got $actual');
}

void _expectChain(List<int> actual, List<int> want) =>
    _expect(actual.join(','), want.join(','), 'chain');

/// Poll [cond] until true or timeout — the tray + handler (and any add) is async.
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
  await SimHarness.runScenario('add-device', (h) async {
    // Start with a single device.
    _expect((await h.deviceNumbers()).length, 1, 'initial fleet');
    _expectChain(await h.chain(), [1]);

    // (1) CLI/harness add: addDevice() grows the fleet to three, each joining the chain tail.
    _expect(await h.addDevice(), 2, 'first add -> device 2');
    _expect(await h.addDevice(), 3, 'second add -> device 3');
    _expect((await h.deviceNumbers()).length, 3, 'fleet grew with the adds');
    _expectChain(await h.chain(), [1, 2, 3]);
    _expect(await h.device(2).isConnected(), true, 'added device 2 connected');
    _expect(await h.device(3).isConnected(), true, 'added device 3 connected');

    // The added devices ENUMERATED to the coordinator (not just sockets): the wallet-create
    // device step counts the live connected devices.
    await h.tapUntil(RegExp('Create a multi-sig wallet'), 'Wallet name');
    await h.enterText('Wallet name', 'GrowTest');
    await h.tapUntil('Next', RegExp('Continue with'));
    await h.waitFor('Continue with 3 devices', timeout: _settle);

    // (2) Tray-side add: the TRAY + button adds device 4. The fleet has ONE source of truth (the
    // app-side simDevicePool), so the harness sees it immediately — no cache, no resync.
    await h.tap('Add device');
    // The + handler is async; wait until the app's chain shows the new tail.
    await _waitUntil(
      () async => (await h.chain()).length == 4,
      'the tray add to land',
    );
    _expectChain(await h.chain(), [1, 2, 3, 4]);
    _expect(
      (await h.deviceNumbers()).length,
      4,
      'fleet reflects the tray add directly (no resync)',
    );

    // device(n) addresses DISTINCT devices: four distinct device ids, device 4 connected.
    final ids = <String>{};
    for (var n = 1; n <= 4; n++) {
      ids.add(await h.device(n).deviceId());
    }
    _expect(ids.length, 4, 'each device handle addresses a distinct device');
    _expect(
      await h.device(4).isConnected(),
      true,
      'tray-added device 4 connected',
    );

    // The tray-added device also enumerated to the coordinator (the live count bumped).
    await h.waitFor('Continue with 4 devices', timeout: _settle);

    stdout.writeln(
      'ADD_DEVICE_DRIVE_OK: runtime add via CLI + tray, one fleet source, tail enumeration',
    );
  }, deviceCount: 1);
}
