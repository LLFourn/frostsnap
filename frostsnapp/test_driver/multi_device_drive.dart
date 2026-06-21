import 'dart:io';

import 'sim_harness.dart';

// sim-9 acceptance: bring up a 3-device fleet through the SimHarness and assert the
// multi-device plumbing — three independent device channels with distinct ids, each
// plugging/unplugging on its own — then tear everything down with no residue
// (runScenario asserts the disposable app dir is gone afterwards).
//
// Run: `just sim-multi-drive`. Needs a display (Xvfb on Linux CI).

Future<void> main() async {
  await SimHarness.runScenario('multi-device', (h) async {
    if (h.devices.length != 3) {
      throw StateError('expected 3 devices, got ${h.devices.length}');
    }

    // Each device's socket is present under the 1-based naming.
    for (var n = 1; n <= 3; n++) {
      final sock = File('${h.appDir.path}/device-$n.sock');
      if (!await sock.exists()) {
        throw StateError('missing socket for device $n: ${sock.path}');
      }
    }

    // Three DISTINCT device ids (distinct deterministic seeds -> distinct keys).
    final ids = <String>{};
    for (var n = 1; n <= 3; n++) {
      ids.add(await h.device(n).deviceId());
    }
    if (ids.length != 3) {
      throw StateError('device ids not distinct: $ids');
    }

    // All start connected.
    for (var n = 1; n <= 3; n++) {
      if (!await h.device(n).isConnected()) {
        throw StateError('device $n should start connected');
      }
    }

    // Unplugging device 2 leaves ONLY device 2 disconnected.
    await h.unplug(2);
    if (await h.device(2).isConnected()) {
      throw StateError('device 2 should be unplugged');
    }
    if (!await h.device(1).isConnected() || !await h.device(3).isConnected()) {
      throw StateError('unplugging device 2 must not affect devices 1 and 3');
    }

    // Replugging restores it.
    await h.plug(2);
    if (!await h.device(2).isConnected()) {
      throw StateError('device 2 should reconnect');
    }

    stdout.writeln(
      'MULTI_DEVICE_DRIVE_OK: 3 independent devices, distinct ids',
    );
  }, deviceCount: 3);
}
