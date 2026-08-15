import 'dart:io';

import 'emulator.dart' show emulatorForegroundFinding, provisionEmulator;
import 'regtest.dart' show androidSdkRoot;
import 'sim_harness.dart';

// The address-lookup team's session, driven as they drove it: a wallet page with the "unfinished
// backups" banner, a recording running, the emulator locked, then `tapTooltip('More')`. A locked
// emulator renders no frames. A command whose condition already holds still returns — the tap on
// an on-screen control is even delivered — but anything waiting on a NEW frame waits forever: the
// sheet the tap opens never draws. That read as the app stuck on its own banner. The failure must
// lead with the lock, and unlocking must let the same session carry on, recording included.
//
// Android only; on a host it has nothing to lock and says so. Run:
// `./fsim test emulator_locked --android`.
Future<void> main() async {
  await AppSession.runScenario('emulator-locked', (h) async {
    final serial = h.emulatorSerial;
    if (serial == null) {
      stdout.writeln('EMULATOR_LOCKED_SKIPPED: no emulator on a host run');
      return;
    }
    final sdk = androidSdkRoot();
    final adb = '$sdk/platform-tools/adb';
    Future<void> key(String code) =>
        Process.run(adb, ['-s', serial, 'shell', 'input', 'keyevent', code]);

    await h.createWallet(name: 'Locked');
    await h.waitFor(RegExp('unfinished backups'));
    final clip = '${h.appDir.path}/locked.mp4';
    await h.startRecording();

    // Sleep then wake: with the PIN the sim sets, waking lands on the keyguard, over the app.
    await key('KEYCODE_SLEEP');
    await Future<void>.delayed(const Duration(seconds: 3));
    await key('KEYCODE_WAKEUP');
    await Future<void>.delayed(const Duration(seconds: 2));
    if (await emulatorForegroundFinding(sdk, serial) == null) {
      throw StateError('the emulator did not lock, so this proves nothing');
    }

    final failures = <String>[];
    Future<void> attempt(Future<void> Function() command) async {
      try {
        await command();
      } catch (e) {
        failures.add('$e');
      }
    }

    const sheet = 'View wallet access structure';
    await attempt(() => h.tapTooltip('More'));
    await attempt(
      () => h.waitFor(RegExp(sheet), timeout: const Duration(seconds: 8)),
    );
    if (failures.isEmpty) {
      throw StateError(
        'a locked emulator drew the More sheet, so this proves nothing',
      );
    }
    for (final failure in failures) {
      final message = failure.replaceFirst(RegExp(r'^Bad state: '), '');
      if (!message.startsWith('the emulator is not showing the app') ||
          !message.contains('locked')) {
        throw StateError(
          'the failure should lead with the lock, got: $failure',
        );
      }
    }

    // `fsim up` over a locked emulator: provisioning unlocks it, or fails saying it did not.
    await provisionEmulator(sdk, serial);
    if (await emulatorForegroundFinding(sdk, serial) case final still?) {
      throw StateError(
        'provisioning left the emulator unable to show the app: $still',
      );
    }

    // The same session, no restart. The More tap was delivered while locked, so its sheet draws now
    // that the app renders; if the tap never went out, sending it again is the carrying on.
    if (!await h.exists(RegExp(sheet))) await h.tapTooltip('More');
    await h.waitFor(RegExp(sheet), timeout: const Duration(seconds: 20));
    await h.stopRecording(clip);
    if (await File(clip).length() == 0) {
      throw StateError('the recording across the lock came back empty');
    }

    stdout.writeln(
      'EMULATOR_LOCKED_OK: tapTooltip("More") on a locked emulator named the lock, provisioning '
      'unlocked it, and the same session opened the sheet and finished its recording',
    );
  });
}
