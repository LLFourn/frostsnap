import 'dart:io';

import 'regtest.dart' show androidSdkRoot;
import 'sim_harness.dart';

// e2e (EXPECTED GREEN): adding a key to a restoration ALREADY IN PROGRESS with
// NO screen lock must prompt to SET UP a screen lock ("Screen Lock Required"),
// NOT route to delete-and-recover ("Wallet needs recovery").
//
// A restoration in progress holds only plaintext accumulated shares — the app
// key never encrypts them (add_recovery_share_to_restoration stores a plaintext
// RestorationProgress2; the key is used only for a key-tolerant dup-check, and
// finish_restoring uses it only to ENCRYPT the finished key). So continuing a
// restoration ESTABLISHES a key, exactly like the final "Restore"
// (finishRestoring) — and setting up a lock screen preserves the accumulated
// progress rather than throwing it away. This is the CONTRAST to
// key_pin_clear_recovery_drive.dart: an operation on a COMPLETE wallet decrypts
// existing data and correctly routes to delete-and-recover; continuing a
// restoration does not.
//
// Android-only: the platform-channel Keystore path is what makes isDeviceSecure
// false after the lock is cleared. Run: ./fsim test recover_lock_required --android

Future<void> _clearScreenLock(AppSession h) async {
  final adb = '${androidSdkRoot()}/platform-tools/adb';
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
  stdout.writeln('recover_lock_required: screen lock removed');
}

Future<void> main() async {
  await SimHarness.runScenario('recover-lock-required', (h) async {
    if (h.emulatorSerial == null) {
      stdout.writeln(
        'RECOVER_LOCK_REQUIRED_SKIPPED: needs the Android Keystore path (run with --android)',
      );
      return;
    }

    // 1. A 2-of-3 wallet, then forget it from the app so we can restore it.
    await h.createWallet(name: 'Rec', deviceCount: 3, devicePrefix: 'Dev');
    await h.waitFor(RegExp('Receive'), timeout: const Duration(seconds: 120));
    await h.deleteWallet();
    await h.waitFor(
      RegExp('Restore wallet'),
      timeout: const Duration(seconds: 30),
    );

    // 2. Start restoring with device 1 — starts the restoration (needs no
    //    encryption key) and leaves it one key short.
    await h.tap(RegExp('Use an existing device key'));
    await h.waitFor(
      RegExp('Restore from device'),
      timeout: const Duration(seconds: 15),
    );
    await h.plug(1);
    await h.waitFor(RegExp('Key ready'), timeout: const Duration(seconds: 30));
    await h.tap('Restore');
    await h.waitFor(
      RegExp('1 more key to restore'),
      timeout: const Duration(seconds: 20),
    );
    stdout.writeln(
      'recover_lock_required: restoration in progress (1 of 2 keys)',
    );

    // 3. Remove the screen lock.
    await _clearScreenLock(h);

    // 4. Add the next device's key. Continuing establishes the finished key, so
    //    it must ask to set up a screen lock — not offer to delete a wallet.
    await h.unplug(1);
    await h.plug(2);
    await Future<void>.delayed(const Duration(seconds: 2));
    await h.tap(RegExp('Add key'));

    // 5. Assert the establish prompt, NOT the delete-and-recover dialog.
    await h.waitFor(
      RegExp('Screen Lock Required'),
      timeout: const Duration(seconds: 20),
    );
    if (await h.exists('Wallet needs recovery')) {
      throw StateError(
        'continuing a restoration wrongly offered delete-and-recover instead of '
        'prompting to set up a screen lock (progress would be lost)',
      );
    }
    stdout.writeln(
      'RECOVER_LOCK_REQUIRED_OK: continuing a restoration with no screen lock '
      'prompts to set one up (preserving progress), not delete-and-recover',
    );
    await h.tap('Cancel');
  }, deviceCount: 3);
}
