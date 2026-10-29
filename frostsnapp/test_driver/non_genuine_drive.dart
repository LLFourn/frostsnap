import 'dart:io';

import 'sim_harness.dart';

// Every way a connected device can fail to prove itself genuine must show as such, and none may
// take a case colour: the colour comes only from a certificate proven on this connection.
//
// Run: `./fsim test non_genuine [--android]`.

/// v0.4.0's release digest (frostsnap_comms/src/firmware_version.rs): the newest firmware that
/// predates the genuine check.
const _v0_4_0 =
    '037c345c9db9866d30e219ae56de5efe3905a4050a82df362590d5017e709df0';

Future<void> main() async {
  await SimHarness.runScenario('non_genuine', (h) async {
    await h.addDevice();
    await h.addDevice(factory: SimFactory.untrusted);
    await h.addDevice(factory: SimFactory.blank);
    final old = await h.addDevice();
    // The coordinator reads the digest at the next announce, so replug.
    await h.device(old).setFirmwareDigest(_v0_4_0);
    await h.disconnect(old);
    await h.connect(old);

    if (!await h.exists(RegExp('Connected Devices'))) {
      await h.tap('Open navigation menu');
      await h.waitFor(RegExp('Connected Devices'));
    }
    await h.tap(RegExp('Connected Devices'));

    final expected = <Pattern, int>{
      RegExp(r'^\w+ case, Genuine\. '): 1,
      'Case colour unknown, Unverified. Show genuine-check details': 2,
      'Case colour unknown, Update to verify. Show genuine-check details': 1,
      RegExp(r'^\w+ case, (Unverified|Update to verify)\. '): 0,
    };
    // A genuine device reads Unverified until its proof lands, so wait for the settled picture.
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (true) {
      final counts = {
        for (final label in expected.keys)
          label: await h.hitTestableCount(label),
      };
      if (expected.keys.every((label) => counts[label] == expected[label])) {
        break;
      }
      if (!DateTime.now().isBefore(deadline)) {
        throw StateError(
          'expected one genuine coloured device, two unverified and one needing an update, '
          'none of the rest coloured; got $counts',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    stdout.writeln(
      'NON_GENUINE_OK: untrusted, blank and old firmware show uncoloured',
    );
  }, deviceCount: 0);
}
