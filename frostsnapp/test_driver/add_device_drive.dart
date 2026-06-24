import 'dart:io';

import 'sim_harness.dart';

// runtime-add-devices acceptance: the virtual fleet GROWS at runtime, and a device added by
// EITHER writer — the harness/`./simctl add-device` OR the tray + button — joins the chain TAIL
// and enumerates to the coordinator (real daisy-chain hot-plug, not a star). The harness keeps
// its own device-channel cache, which the tray writer never touches; ensureDevices() reconciles
// it against the app-side fleet so device(n) can never go stale or misindex.
//
// Enumeration is proven via the wallet-create "Continue with N devices" button (the coordinator's
// live connected count), not just socket existence — a green-but-wrong "socket appeared" check
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
    _expect(h.devices.length, 1, 'initial device channels');
    _expectChain(await h.chain(), [1]);

    // (1) CLI/harness add: addDevice() grows the fleet to three, each joining the chain tail.
    _expect(await h.addDevice(), 2, 'first add -> device 2');
    _expect(await h.addDevice(), 3, 'second add -> device 3');
    _expect(h.devices.length, 3, 'harness cache grew with the adds');
    _expectChain(await h.chain(), [1, 2, 3]);
    _expect(await h.device(2).isConnected(), true, 'added device 2 connected');
    _expect(await h.device(3).isConnected(), true, 'added device 3 connected');

    // The added devices ENUMERATED to the coordinator (not just sockets): the wallet-create
    // device step counts the live connected devices.
    await h.tapUntil(RegExp('Create a multi-sig wallet'), 'Wallet name');
    await h.enterText('Wallet name', 'GrowTest');
    await h.tapUntil('Next', RegExp('Continue with'));
    await h.waitFor('Continue with 3 devices', timeout: _settle);

    // (2) Tray-side add (the resync case): the TRAY + button adds device 4, so the harness
    // channel cache goes momentarily stale; ensureDevices() reconciles it without misindexing.
    await h.tap('Add device');
    // The + handler is async; wait until the app's chain shows the new tail. chain() reads the
    // shared ChainRouter over device(1)'s socket, so it sees the tray's add independent of the
    // (stale) harness cache.
    await _waitUntil(
      () async => (await h.chain()).length == 4,
      'the tray add to land',
    );
    _expectChain(await h.chain(), [1, 2, 3, 4]);
    _expect(h.devices.length, 3, 'harness cache stale before resync');
    await h.ensureDevices();
    _expect(h.devices.length, 4, 'resync picked up the tray-added device');

    // device(n) addresses DISTINCT sockets (no misindex): four distinct device ids, and the
    // tray-added device reports connected over its own resynced channel.
    final ids = <String>{};
    for (var n = 1; n <= 4; n++) {
      ids.add(await h.device(n).deviceId());
    }
    _expect(ids.length, 4, 'each device channel addresses a distinct device');
    _expect(
      await h.device(4).isConnected(),
      true,
      'resynced device 4 connected',
    );

    // The tray-added device also enumerated to the coordinator (the live count bumped).
    await h.waitFor('Continue with 4 devices', timeout: _settle);

    stdout.writeln(
      'ADD_DEVICE_DRIVE_OK: runtime add via CLI + tray, harness resync, tail enumeration',
    );
  }, deviceCount: 1);
}
