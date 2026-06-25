import 'dart:io';

import 'sim_harness.dart';

// android-layout-e2e: runs on the Android emulator and FAILS when the backup sheet's "Show secret
// backup" action button is rendered behind the system navigation bar (a bottom safe-area bug).
//
// It reaches the sheet through the reusable flows (createWallet → openDeviceBackup), then asserts
// the button sits above the bottom system inset. The assertion needs a REAL bottom inset, so it only
// catches the bug on the emulator (the 3-button nav bar) — on a desktop host bottomInset is 0 and it
// trivially passes. Run: `./simctl test android_safe_area --android`.
Future<void> main() async {
  await AppSession.runScenario('android-safe-area', (h) async {
    await h.createWallet(name: 'Backup');
    await h.openDeviceBackup();
    // The "Record backup information" sheet is up; its primary action must clear the nav bar.
    await h.expectAboveBottomInset('Show secret backup');
    stdout.writeln(
      'ANDROID_SAFE_AREA_OK: the backup action bar clears the nav bar',
    );
  });
}
