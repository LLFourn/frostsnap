import 'dart:io';

import 'sim_harness.dart';

// sim-10 acceptance: bring up a 3-device DAISY CHAIN and prove chain semantics
// end-to-end through the real app. The coordinator sees ONE port yet registers all
// three (hop-by-hop relay), and unplugging a MID-CHAIN device drops it AND its
// downstream subtree — not just itself, as the old star would. We observe the
// coordinator's live connected-device count via the wallet-create "Continue with N
// devices" button: cutting device 2's link takes it 3 -> 1 (a star would show 2), and
// re-plugging restores the whole subtree to 3. runScenario asserts no residue.
//
// Run: `just sim-multi-drive`. Needs a display (Xvfb on Linux CI).

// Chain registration/teardown rides the coordinator's real ~100ms cadence hop by hop,
// so give the count changes a generous settle window.
const _settle = Duration(seconds: 90);

Future<void> main() async {
  await SimHarness.runScenario('multi-device', (h) async {
    // Three device channels over 1-based sockets, with distinct ids (distinct seeds).
    if (h.devices.length != 3) {
      throw StateError('expected 3 device channels, got ${h.devices.length}');
    }
    final ids = <String>{};
    for (var n = 1; n <= 3; n++) {
      if (!await File('${h.appDir.path}/device-$n.sock').exists()) {
        throw StateError('missing socket for device $n');
      }
      ids.add(await h.device(n).deviceId());
    }
    if (ids.length != 3) {
      throw StateError('device ids not distinct: $ids');
    }

    // Open the wallet-create device step, whose button text reflects the coordinator's
    // live connected count.
    await h.tapUntil(RegExp('Create a multi-sig wallet'), 'Wallet name');
    await h.enterText('Wallet name', 'ChainTest');
    await h.tapUntil('Next', RegExp('Continue with'));

    // All three chained devices register over the single coordinator port (relay ran).
    await h.waitFor('Continue with 3 devices', timeout: _settle);

    // Cut the MID-CHAIN link (device 2): on a chain this drops device 2 AND device 3,
    // leaving only device 1. (A star would leave two devices: "Continue with 2 devices".)
    await h.unplug(2);
    await h.waitFor('Continue with 1 device', timeout: _settle);
    await h.waitForAbsent('Continue with 3 devices', timeout: _settle);

    // Re-plug device 2: device 3's own link was never cut, so restoring device 2 brings
    // the whole subtree back.
    await h.plug(2);
    await h.waitFor('Continue with 3 devices', timeout: _settle);

    stdout.writeln(
      'MULTI_DEVICE_DRIVE_OK: 3-device chain; mid-chain unplug drops the subtree',
    );
  }, deviceCount: 3);
}
