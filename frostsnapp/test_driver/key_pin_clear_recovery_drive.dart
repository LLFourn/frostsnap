import 'dart:io';

import 'regtest.dart' show androidSdkRoot;
import 'sim_harness.dart';

// e2e (EXPECTED RED — pins the getOrCreate-wrong-surface bug): on an EXISTING
// wallet, an operation (show-backup) after the SCREEN LOCK IS REMOVED must route
// to the delete-and-recover dialog ("Wallet needs recovery"). The wallet's
// enclave key is gone; a new lock screen would only mint a DIFFERENT key that
// can't decrypt it, so "set up a screen lock to continue" is a false promise.
//
// It does NOT do that today: with no lock screen `isDeviceSecure()` is false, so
// the shared `getOrCreate` surface (`SecureKeyProvider.getEncryptionKey`) short-
// circuits to the `_NoLockScreenDialog` ("Screen Lock Required") retry loop BEFORE
// the `ActionError_WrongEncryptionKey` → delete-and-recover catch can fire.
//
// THIS TEST IS EXPECTED TO FAIL until sign/show-backup (and the other existing-
// wallet operations) use a "get the EXISTING key" surface that routes
// NO_LOCK_SCREEN to delete-and-recover. See the queued fix plan. Its GREEN sibling
// `key_delete_recovery_drive.dart` drives the same operation with a *deleted* (i.e.
// wrong-but-available) key and already routes correctly — the contrast localises
// the bug to the unavailable-key path.
//
// Android-only. Run: ./fsim test key_pin_clear_recovery --android

Future<void> _clearScreenLock(AppSession h) async {
  final adb = '${androidSdkRoot()}/platform-tools/adb';
  // fsim provisions the emulator with PIN 0000; removing it invalidates the
  // auth-bound AndroidKeyStore key and makes isDeviceSecure() false.
  final res = await Process.run(adb, [
    '-s',
    h.emulatorSerial!,
    'shell',
    'locksettings',
    'clear',
    '--old',
    '0000',
  ]);
  if (res.exitCode != 0) {
    throw StateError('adb locksettings clear failed: ${res.stderr}');
  }
  stdout.writeln(
    'key_pin_clear: screen lock removed (enclave key now unavailable)',
  );
}

Future<void> main() async {
  await SimHarness.runScenario('key-pin-clear-recovery', (h) async {
    if (h.emulatorSerial == null) {
      stdout.writeln(
        'KEY_PIN_CLEAR_RECOVERY_SKIPPED: needs the Android Keystore path (run with --android)',
      );
      return;
    }

    // 1. A wallet created under the hardware Keystore key (PIN 0000).
    await h.createWallet(name: 'Pin', deviceCount: 1, devicePrefix: 'Dev');
    await h.waitFor(RegExp('Receive'), timeout: const Duration(seconds: 120));
    stdout.writeln('key_pin_clear: wallet Pin created under the hardware key');

    // 2. Remove the screen lock — the enclave key is now unavailable. For an
    //    EXISTING wallet this is unrecoverable.
    await _clearScreenLock(h);

    // 3. Try the show-backup operation on the still-present wallet.
    await h.openDeviceBackup(device: 1);
    await h.tap('Show secret backup');

    // 4. It MUST route to delete-and-recover. FAILS today: the app shows the
    //    "Screen Lock Required" setup prompt instead, so this times out.
    await h.waitFor(
      'Wallet needs recovery',
      timeout: const Duration(seconds: 20),
    );
    stdout.writeln(
      'KEY_PIN_CLEAR_RECOVERY_OK: show-backup with no screen lock routes to '
      'delete-and-recover',
    );
    await h.tap('Not now');
    await h.waitForAbsent('Wallet needs recovery');
  }, deviceCount: 1);
}
