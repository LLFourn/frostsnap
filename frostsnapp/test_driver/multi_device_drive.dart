import 'dart:io';

import 'sim_harness.dart';

// sim-12 acceptance: the chain is a runtime config driven through chain()/setChain(). We
// exercise the dynamic API directly and verify both the config (chain()) and the
// coordinator's live connected count (the wallet-create "Continue with N devices" button):
//   - initial full chain [1,2,3] -> "Continue with 3 devices" (all register over one port);
//   - setChain([2]) -> only device 2 (connected independently of device 1) -> 1 device;
//   - setChain([3,1]) -> a head-changing reorder (device 3 is now the head) -> 2 devices;
//   - disconnect(2) re-closes the chain (the others stay) rather than dropping a subtree.
// runScenario asserts no residue. Run: `just sim-multi-drive`. Needs a display.

// Each re-cable pulses the coordinator port and re-enumerates hop-by-hop over the real
// ~100ms cadence, so give the count changes a generous settle window.
const _settle = Duration(seconds: 90);

void _expectChain(List<int> actual, List<int> want) {
  if (actual.join(',') != want.join(',')) {
    throw StateError('expected chain $want, got $actual');
  }
}

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
    // Initial config: the full chain in number order.
    _expectChain(await h.chain(), [1, 2, 3]);

    // Open the wallet-create device step, whose button reflects the coordinator's live
    // connected count. All three register over the one port (relay ran).
    await h.tapUntil(RegExp('Create a multi-sig wallet'), 'Wallet name');
    await h.enterText('Wallet name', 'ChainTest');
    await h.tapUntil('Next', RegExp('Continue with'));
    await h.waitFor('Continue with 3 devices', timeout: _settle);

    // Explicit setChain to a single device: device 2 alone on the coordinator port,
    // connected independently of device 1.
    await h.setChain([2]);
    _expectChain(await h.chain(), [2]);
    await h.waitFor('Continue with 1 device', timeout: _settle);

    // Explicit head-changing reorder: device 3 becomes the head, device 1 downstream.
    await h.setChain([3, 1]);
    _expectChain(await h.chain(), [3, 1]);
    await h.waitFor('Continue with 2 devices', timeout: _settle);

    // Restore the full chain.
    await h.setChain([1, 2, 3]);
    await h.waitFor('Continue with 3 devices', timeout: _settle);

    // Disconnecting a mid-chain device re-closes the chain (the others stay connected).
    await h.disconnect(2);
    _expectChain(await h.chain(), [1, 3]);
    await h.waitFor('Continue with 2 devices', timeout: _settle);
    await h.connect(2);
    await h.waitFor('Continue with 3 devices', timeout: _settle);

    stdout.writeln(
      'MULTI_DEVICE_DRIVE_OK: setChain isolation + head-changing reorder + re-close',
    );
  }, deviceCount: 3);
}
