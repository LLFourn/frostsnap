import 'dart:io';

import 'regtest.dart' show androidSdkRoot;
import 'sim_harness.dart';

// e2e (EXPECTED GREEN): forced empty-key fallback AT KEYGEN. On old keymasters
// (e.g. Pixel 2 XL / Android 11) the Keystore can fail to create the app's key
// even in the TEE, which used to throw and break keygen so no wallet could be
// created at all. SecureKeyManager reports KEY_CREATION_FAILED and
// AndroidSecureKeyProvider.getOrCreateKey falls back to the empty key.
//
// Sets `frostsnap_force_empty_key` (the SecureKeyManager debug hook) BEFORE
// keygen, so the very first key the wallet requests comes back as
// KEY_CREATION_FAILED and exercises the Dart fallback. The wallet is then
// created end-to-end under the empty key, and a decrypt-requiring operation
// (show-backup) confirms the same empty key round-trips the data it wrote — a
// genuinely working wallet, not just a keygen that didn't throw.
//
// Scope: this drives the forced native error-result -> Dart fallback ->
// successful keygen path. The actual old-keymaster createKey() exception catch
// inside SecureKeyManager.kt stays real-device / code-review coverage.
//
// Android-only: a desktop host always uses the empty key, so there is nothing
// to force.
// Run: ./fsim test key_empty_key --android

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
  stdout.writeln('key_empty_key: frostsnap_force_empty_key=${on ? 1 : 0}');
}

Future<void> main() async {
  await SimHarness.runScenario('key-empty-key', (h) async {
    if (h.emulatorSerial == null) {
      stdout.writeln(
        'KEY_EMPTY_KEY_SKIPPED: needs the Android Keystore path (run with --android)',
      );
      return;
    }

    // 1. Force the Keystore to report KEY_CREATION_FAILED before ANY key is
    //    requested, so keygen must fall back to the empty key.
    await _setForceEmptyKey(h, true);

    // 2. Create a wallet. Its keygen key request hits the forced failure and
    //    falls back to the empty key; createWallet only returns once the wallet
    //    home ("Receive") is reached, so reaching it proves keygen survived.
    await h.createWallet(name: 'Emp', deviceCount: 1, devicePrefix: 'Dev');
    await h.waitFor(RegExp('Receive'), timeout: const Duration(seconds: 120));
    stdout.writeln(
      'key_empty_key: wallet Emp created under the empty-key fallback',
    );

    // 3. Prove it is genuinely usable. With the flag still set, getOrCreateKey
    //    returns the same empty key that encrypted the wallet, so a
    //    decrypt-requiring operation (show-backup) must succeed and display the
    //    backup rather than routing to "Wallet needs recovery".
    await h.openDeviceBackup(device: 1);
    await h.tap('Show secret backup');
    await h.waitFor(RegExp('Write down'), timeout: const Duration(seconds: 20));

    stdout.writeln(
      'KEY_EMPTY_KEY_OK: keygen fell back to the empty key and the wallet '
      'decrypts under it',
    );
  }, deviceCount: 1);
}
