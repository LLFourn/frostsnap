import 'dart:io';

import 'regtest.dart' show androidSdkRoot;
import 'sim_harness.dart';

// e2e KEY MISMATCH (android-keystore-fallback): a wallet whose data was
// encrypted under the hardware Keystore key while the app now supplies the
// empty fallback key — the state an old-keymaster phone lands in once the
// empty-key fallback kicks in. Uses the debug-only `frostsnap_force_empty_key`
// global setting to flip the key the app supplies LIVE (SecureKeyManager reads
// it on every getOrCreateKey), so we create a wallet under the hardware key and
// then act on it under the empty key.
//
// This drives the RISKIEST mismatch path — starting a restoration for a wallet
// the app still has but can no longer decrypt — and asserts it routes to the
// TYPED delete-and-recover dialog ("Wallet needs recovery"), NOT a false
// "share belongs elsewhere", an opaque failure, or a panic. That single flow
// exercises the whole design's hard part:
//   - find_share SKIPS the undecryptable complete wallet (otherwise the check
//     would report ShareBelongsElsewhere instead of the mismatch);
//   - the explicit access-structure check reports the mismatch as a typed
//     error the Dart side catches;
//   - start_restoring_key_from_recover_share returns that typed error rather
//     than assert-panicking.
// The sign and show-backup mismatch paths share the same typed-error → dialog
// plumbing and were validated interactively (see the PR description).
//
// Android-only: the mismatch needs the platform-channel Keystore path; a
// desktop host always uses the empty key so there is nothing to mismatch.
// Run: ./fsim test key_mismatch --android

Future<void> _setForceEmptyKey(AppSession h, bool on) async {
  final adb = '${androidSdkRoot()}/platform-tools/adb';
  final res = await Process.run(adb, [
    '-s',
    h.emulatorSerial!,
    'shell',
    'settings',
    'put',
    'global',
    'frostsnap_force_empty_key',
    on ? '1' : '0',
  ]);
  if (res.exitCode != 0) {
    throw StateError('adb settings put failed: ${res.stderr}');
  }
  stdout.writeln('key_mismatch: frostsnap_force_empty_key=${on ? 1 : 0}');
}

Future<void> main() async {
  await SimHarness.runScenario('key-mismatch', (h) async {
    if (h.emulatorSerial == null) {
      stdout.writeln(
        'KEY_MISMATCH_SKIPPED: needs the Android Keystore path (run with --android)',
      );
      return;
    }

    // 1. A wallet created under the hardware Keystore key. createWallet leaves
    //    us at the wallet home with the device disconnected.
    await _setForceEmptyKey(h, false);
    await h.createWallet(name: 'Mis', deviceCount: 1, devicePrefix: 'Dev');
    await h.waitFor(RegExp('Receive'), timeout: const Duration(seconds: 120));
    stdout.writeln('key_mismatch: wallet Mis created under the hardware key');

    // 2. The app now supplies the empty fallback key: every wallet-data read
    //    is a key mismatch.
    await _setForceEmptyKey(h, true);

    // 3. Start a restoration from the device that still holds Mis's share,
    //    while Mis still exists but can't be decrypted.
    await h.device(1).setConnected(true);
    await h.tap('Open navigation menu');
    await h.tapUntil(
      RegExp('Create or restore'),
      RegExp('Use an existing device key'),
    );
    await h.tap(RegExp('Use an existing device key'));
    await h.waitFor(
      RegExp('Restore from device'),
      timeout: const Duration(seconds: 15),
    );

    // 4. It must route to the typed delete-and-recover dialog — not a panic,
    //    not a false "share belongs elsewhere".
    await h.waitFor(
      'Wallet needs recovery',
      timeout: const Duration(seconds: 20),
    );
    stdout.writeln(
      'KEY_MISMATCH_OK: restore-into-existing routes to the typed '
      'delete-and-recover dialog (dup check skipped the undecryptable wallet, '
      'no panic)',
    );
    await h.tap('Not now');
    await h.waitForAbsent('Wallet needs recovery');
  }, deviceCount: 1);
}
