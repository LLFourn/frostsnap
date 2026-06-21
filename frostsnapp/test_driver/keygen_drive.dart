import 'dart:io';

import 'sim_harness.dart';

// sim-8 end-to-end: a full 1-of-1 keygen driven entirely OUT OF PROCESS through the
// SimHarness — app taps by semantic label (flutter_driver) + device gestures (the
// device socket) — on a clean disposable app dir, including the "Only one device"
// dialog and the post-keygen unplug-to-finish.
//
// Targeting is INLINE by the controls' accessible names (no shared constants file, by
// design): if app copy changes, update the matching string here — a desync surfaces as
// this test failing. The device confirm-button point (120,215) is the keygen security
// screen's calibration (sim-3), supplied to the generic device.holdConfirm.
//
// Run: `just sim-keygen-drive` (or `cd frostsnapp && dart run
// test_driver/keygen_drive.dart`). Needs a display (Xvfb on Linux CI).

/// The keygen security-code confirm button on the device's KeygenCheck screen.
const int _confirmX = 120;
const int _confirmY = 215;

Future<void> main() async {
  // runScenario auto-captures diagnostics (screenshot + device framebuffer + error +
  // app logs to build/sim-failures/keygen/) on any failure, then tears down.
  await SimHarness.runScenario('keygen', (h) async {
    // Each navigating step uses tapUntil(<button>, <landmark on the next screen>) so a
    // tap that lands before the control is interactable is retried, not silently lost.

    // 1. Create-multisig (a card; its title merges with the subtitle in semantics, so
    //    match a substring) -> name the wallet -> advance.
    await h.tapUntil(RegExp('Create a multi-sig wallet'), 'Wallet name');
    await h.enterText('Wallet name', 'SimTest');
    await h.tapUntil('Next', 'Device name');

    // 2. Name the connected device -> advance -> confirm the single-device dialog.
    await h.enterText('Device name', 'SimDev');
    await h.tapUntil('Continue with 1 device', 'Continue anyway');
    await h.tapUntil('Continue anyway', 'Generate keys');

    // 3. Threshold defaults to 1-of-1; generate keys -> security check. (Dialog body
    //    text merges into one semantics node, so match landmarks as a substring.)
    await h.tapUntil('Generate keys', RegExp('Security Check'));

    // 4. Device confirms the security code via hold-to-confirm. Re-assert until the
    //    app shows the Final-check dialog (guards the device-render race).
    var confirmed = false;
    for (var i = 0; i < 6 && !confirmed; i++) {
      await h.device(1).holdConfirm(_confirmX, _confirmY);
      confirmed = await h.exists('Yes');
    }
    if (!confirmed) {
      throw StateError('device never confirmed the security code');
    }

    // 5. Confirm the codes match -> "unplug to continue" -> disconnect to finish.
    await h.tapUntil('Yes', RegExp('Unplug devices to continue'));
    await h.unplug();

    // 6. Success: the wallet home appears (its Receive action shows only there).
    await h.waitFor(RegExp('Receive'));
    stdout.writeln('KEYGEN_DRIVE_OK: 1-of-1 wallet created via both channels');
  });
}
