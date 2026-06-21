import 'dart:async';
import 'dart:io';

import 'sim_harness.dart';

// sim-12 end-to-end: a full 2-of-3 keygen over a dynamic chain. Bring up 4 devices,
// disconnect one, and run keygen across the remaining 3 — exercising multi-device naming,
// the default 2-of-3 threshold, and a per-device security-check confirm. Driven OUT OF
// PROCESS through the SimHarness: app by semantic label (flutter_driver) + each device by
// hold-to-confirm over its socket. Run: `just sim-keygen-2of3`. Needs a display.

/// The keygen security-code confirm button on each device's KeygenCheck screen (sim-3).
const int _confirmX = 120;
const int _confirmY = 215;

/// Multi-device steps (naming, nonce replenish, hop-by-hop confirm) ride the coordinator's
/// real cadence over the chain, so allow a generous settle.
const _settle = Duration(seconds: 120);

/// A short pause to let the create-flow rebuild catch up after a text entry — with four
/// devices' frame streams churning, the "Next"/"Continue" enable can lag a beat behind the
/// keystroke, and the driver is otherwise faster than the UI here.
Future<void> _breathe() => Future<void>.delayed(const Duration(seconds: 2));

Future<void> main() async {
  await SimHarness.runScenario('keygen-2of3', (h) async {
    // Start the wallet with all four devices connected, then drop one at the device step.
    await h.tapUntil(RegExp('Create a multi-sig wallet'), 'Wallet name');
    await h.enterText('Wallet name', 'Tri');
    await _breathe();
    await h.tapUntil('Next', RegExp('Continue with'));

    // Disconnect one device -> a 3-device chain (the remaining name fields re-index to
    // 1..3). Wait for the count to settle after the re-cable before naming.
    await h.disconnect(4);
    await h.waitFor('Continue with 3 devices', timeout: _settle);
    await h.enterText('Device name 1', 'Aaa');
    await h.enterText('Device name 2', 'Bbb');
    await h.enterText('Device name 3', 'Ccc');
    await _breathe();

    // 3 devices -> the threshold defaults to 2-of-3; advance through "preparing devices"
    // to the Generate keys button, then start keygen.
    await h.tapUntil('Continue with 3 devices', 'Generate keys');
    await h.tapUntil('Generate keys', RegExp('Security Check'));

    // Each device confirms the security code via hold-to-confirm; the app shows the
    // final-check 'Yes' once all three have ack'd. Re-assert each round (the per-device
    // CheckKeyGen lands hop-by-hop, so a device may not be showing it on the first pass).
    var confirmed = false;
    for (var round = 0; round < 12 && !confirmed; round++) {
      for (var n = 1; n <= 3; n++) {
        await h
            .device(n)
            .holdConfirm(
              _confirmX,
              _confirmY,
              const Duration(milliseconds: 3000),
            );
      }
      confirmed = await h.exists('Yes');
    }
    if (!confirmed) {
      throw StateError('the three devices never confirmed the security code');
    }

    // Codes match -> unplug all devices to finish -> wallet home.
    await h.tapUntil('Yes', RegExp('Unplug devices to continue'));
    await h.setChain([]);
    await h.waitFor(RegExp('Receive'), timeout: _settle);

    stdout.writeln(
      'KEYGEN_2OF3_OK: 2-of-3 wallet created over a 3-device chain',
    );
  }, deviceCount: 4);
}
