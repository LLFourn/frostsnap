import 'dart:io';

import 'regtest.dart' show androidSdkRoot;
import 'sim_harness.dart';

// e2e KEY MISMATCH (android-keystore-fallback): top-level restoration must
// report the ordinary duplicate-wallet error when a device share names an
// access structure the app already has. That result must not depend on whether
// the app key is correct, wrong, or unavailable because this check does not
// decrypt existing wallet data.
//
// Decrypt-existing operations (signing, backup inspection, and adding a share
// to an existing wallet) still route key failures to "Wallet needs recovery";
// their focused sibling drivers cover that behavior.
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
  stdout.writeln('key_mismatch: screen lock removed');
}

Future<void> _expectDuplicate(AppSession h, String keyState) async {
  await h.tap(RegExp('Use an existing device key'));
  await h.waitFor(
    RegExp('Restore from device'),
    timeout: const Duration(seconds: 15),
  );
  await h.waitFor(
    RegExp("existing wallet 'Mis'.*cannot be used to start a new restoration"),
    timeout: const Duration(seconds: 20),
  );
  if (await h.exists('Wallet needs recovery')) {
    throw StateError(
      '$keyState app key incorrectly routed a top-level duplicate to recovery',
    );
  }
  stdout.writeln(
    'key_mismatch: $keyState app key reports the ordinary duplicate error',
  );
  await h.tap('Cancel');
  await h.waitFor(RegExp('Use an existing device key'));
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

    // 2. Open the top-level restoration flow with Mis's device connected.
    await h.device(1).setConnected(true);
    await h.tap('Open navigation menu');
    await h.tapUntil(
      RegExp('Create or restore'),
      RegExp('Use an existing device key'),
    );

    // 3. The duplicate result is identical with the correct hardware key, the
    //    forced empty (wrong) key, and no available Keystore key at all.
    await _expectDuplicate(h, 'correct');

    await _setForceEmptyKey(h, true);
    await _expectDuplicate(h, 'wrong');

    await _setForceEmptyKey(h, false);
    await _clearScreenLock(h);
    await _expectDuplicate(h, 'unavailable');

    stdout.writeln(
      'KEY_MISMATCH_OK: top-level duplicate restoration reports the ordinary '
      'error with correct, wrong, and unavailable app keys',
    );
  }, deviceCount: 1);
}
