import 'dart:io';

import 'sim_harness.dart';

// e2e (EXPECTED GREEN): on an EXISTING wallet, an operation that can no longer
// decrypt because the secure key was DELETED must route to the typed
// delete-and-recover dialog ("Wallet needs recovery").
//
// Uses `session.deleteSecureKey()` — the real `AndroidKeyStore` deleteEntry — so
// the next key access mints a DIFFERENT key than the one that encrypted the
// wallet. The show-backup operation then throws `ActionError_WrongEncryptionKey`,
// which the fix catches → delete-and-recover dialog. This is the
// wrong-but-available-key path the android-keystore-fallback fix already handles;
// it PASSES, guarding both that path and the deleteSecureKey drive API.
//
// Its sibling `key_pin_clear_recovery_drive.dart` drives the SAME operation with
// the screen lock REMOVED (an *unavailable* key) and is expected to FAIL until the
// operation surface stops using getOrCreate — see the queued fix plan.
//
// Android-only: the mismatch needs the platform-channel Keystore path.
// Run: ./fsim test key_delete_recovery --android

Future<void> main() async {
  await SimHarness.runScenario('key-delete-recovery', (h) async {
    if (h.emulatorSerial == null) {
      stdout.writeln(
        'KEY_DELETE_RECOVERY_SKIPPED: needs the Android Keystore path (run with --android)',
      );
      return;
    }

    // 1. A wallet created under the hardware Keystore key.
    await h.createWallet(name: 'Del', deviceCount: 1, devicePrefix: 'Dev');
    await h.waitFor(RegExp('Receive'), timeout: const Duration(seconds: 120));
    stdout.writeln(
      'key_delete_recovery: wallet Del created under the hardware key',
    );

    // 2. Delete the app's secure key. The next getOrCreateKey mints a NEW key,
    //    so Del's data can no longer be decrypted. Prove the delete was real.
    await h.deleteSecureKey();
    if (await h.secureKeyExists()) {
      throw StateError('deleteSecureKey did not remove the key');
    }
    stdout.writeln(
      'key_delete_recovery: secure key deleted (secureKeyExists=false)',
    );

    // 3. Try the show-backup operation on the still-present-but-undecryptable wallet.
    await h.openDeviceBackup(device: 1);
    await h.tap('Show secret backup');

    // 4. Must route to the typed delete-and-recover dialog — the wrong-key path
    //    the fix handles (ActionError_WrongEncryptionKey → showWalletKeyMismatchDialog).
    await h.waitFor(
      'Wallet needs recovery',
      timeout: const Duration(seconds: 20),
    );
    stdout.writeln(
      'KEY_DELETE_RECOVERY_OK: show-backup with a deleted key routes to '
      'delete-and-recover',
    );
    await h.tap('Not now');
    await h.waitForAbsent('Wallet needs recovery');
  }, deviceCount: 1);
}
