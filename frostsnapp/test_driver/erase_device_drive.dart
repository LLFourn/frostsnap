import 'dart:async';
import 'dart:io';

import 'sim_harness.dart';

// Erasing a device, end to end through the app the way a human does it: build a wallet
// on the device, then Device Details → Advanced → Erase, and confirm on the DEVICE with
// its real swipe-and-hold. What must happen afterwards is one thing said three ways —
// the device that comes back is NOT the device that was erased:
//
//   * the erase dialog stops waiting (it hides when the erased device leaves the
//     connected set) and hands over to "Device Erased",
//   * the slot reports a new device id,
//   * the app meets a nameless stranger — no "SimDev1", no wallet re-attached to it.
//
// All three used to fail together, and for one reason: the sim minted device identity
// from the sim seed, so a wiped device re-derived its OLD id, every id-keyed record
// re-attached on the re-announce, and the dialog's device never "left". The identity now
// lives in the flash header the erase destroys (see the fsim-erase-identity plan).
//
// Run: `./fsim test erase_device [--android]`.

/// Device hold-to-confirm button point (sim-3 calibration).
const int _confirmX = 120;
const int _confirmY = 215;

/// Erasing is destructive, so its confirm hold is far longer than keygen's — the device
/// screen asks for 8 seconds, and a hold that releases early resets the widget's
/// progress rather than accumulating it.
const Duration _eraseHold = Duration(milliseconds: 9500);

Future<void> main() async {
  await SimHarness.runScenario('erase_device', (h) async {
    await h.createWallet(name: 'EraseTest');
    // createWallet finishes with the fleet unplugged; the erase flow needs the device
    // present (the dialog only shows while its device is connected).
    await h.device(1).setConnected(true);
    final idBefore = await h.device(1).deviceId();

    // The human path to the button: the connected-devices list → this device → Advanced.
    // That list is a navigation-drawer destination: always on stage on a wide window,
    // behind the menu button on a phone.
    if (!await h.exists(RegExp('Connected Devices'))) {
      await h.tap('Open navigation menu');
      await h.waitFor(RegExp('Connected Devices'));
    }
    await h.tap(RegExp('Connected Devices'));
    await h.tapUntil(RegExp('SimDev1'), 'Device Details');
    await h.tapUntil('Advanced', 'Erase');
    await h.tap('Erase');
    await h.waitFor(RegExp('Confirm on device'));

    // Confirm on the device: page past the warning, then hold. Each attempt pages
    // FIRST, so one that raced the prompt's render (the app dialog appears before the
    // device screen does) simply retries instead of holding on the warning page — and
    // the swipe's release lands before the hold's press, so it never cuts a hold short.
    var idAfter = idBefore;
    for (var attempt = 0; attempt < 6 && idAfter == idBefore; attempt++) {
      await h
          .device(1)
          .swipe(120, 240, 120, 80, const Duration(milliseconds: 250));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await h.device(1).holdConfirm(_confirmX, _confirmY, _eraseHold);
      idAfter = await h.device(1).deviceId();
    }
    if (idAfter == idBefore) {
      throw StateError(
        'the erased device kept its identity ($idBefore) — a wiped device must '
        'come back as a different device',
      );
    }

    // The dialog stops waiting on a device that is never coming back.
    await h.waitFor(
      RegExp('Device Erased'),
      timeout: const Duration(seconds: 60),
    );

    // The stranger: connected, nameless, and attached to no wallet. Asserted with the
    // device list still up behind the success dialog — dismissing it pops the list
    // (Device Details closes itself once its device is gone for good).
    // The list entry is one composite label — the tile's title over its subtitle
    // ("Unnamed" above "~", i.e. no wallet) — so match rather than compare.
    await h.waitFor(RegExp('Unnamed'), timeout: const Duration(seconds: 30));
    if (await h.exists(RegExp('SimDev1'))) {
      throw StateError(
        'the erased device came back as SimDev1 — the app re-attached records '
        'that belong to a device that no longer exists',
      );
    }
    if (await h.exists(RegExp('Wallet available for recovery'))) {
      throw StateError(
        'the erased device is being offered as a recovery source for a wallet '
        'whose share it no longer holds',
      );
    }
    await h.tap('OK');

    // The wallet's OWN account of who can unlock it. The connected-devices checks
    // above cannot cover this: the erased device is offline afterwards, so it would be
    // missing from that list whether or not its share was actually dropped from the
    // access structure. This is the assertion that fails if deleteShare regresses.
    // Get back to the bare wallet screen before using its toolbar. Whatever is stacked
    // over it is MODAL, and a barrier swallows taps aimed at what shows through behind
    // it — the tap then waits for a target it can never reach instead of failing. On a
    // wide window the device list is a sheet, so one dismissal is enough; on a phone it
    // is a PAGE reached through the navigation drawer, so leaving it lands back on that
    // open drawer, which must be dismissed too.
    await h.waitForAbsent(RegExp('Device Erased'));
    await h.dismissSheetOrDialog();
    if (h.emulatorSerial != null) {
      // BACK left that page on the drawer it was opened from. A second BACK would
      // leave the wallet route too — i.e. quit the app — so close the drawer the way a
      // person does, by touching the screen beside it.
      final m = await h.viewMetrics();
      await h.tapAppAt(m.width * 0.9, m.height * 0.5);
    }
    await h.waitFor(RegExp('Receive'));
    await h.tapTooltip('More');
    await h.tapUntil(
      // A tile's label is its title AND subtitle merged, and the title alone ('Keys')
      // is a substring of the page it opens — so match the subtitle.
      RegExp('View wallet access structure'),
      RegExp('can be unlocked with'),
    );
    if (await h.exists(RegExp('SimDev1'))) {
      throw StateError(
        'the erased device is still a key holder of EraseTest — its share was '
        'destroyed with its flash, so the wallet must no longer count it',
      );
    }

    stdout.writeln(
      'ERASE_DEVICE_OK: the wiped device came back as a stranger '
      '($idBefore -> $idAfter), the dialog handed over to "Device Erased", '
      'nothing re-attached to it, and the wallet dropped it as a key holder',
    );
  }, deviceCount: 1);
}
