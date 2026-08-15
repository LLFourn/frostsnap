import 'dart:io';

import 'sim_harness.dart';

// fsim-paper-backup e2e: the FULL paper-backup cycle through the app. Create a 1-of-1 wallet,
// have the device DISPLAY the backup (capture its text via the privileged sim observation — the
// pen-and-paper analog — then drive the real paged display with swipes and the final
// hold-to-confirm), DELETE the wallet, and restore it onto a FRESH device by TYPING the captured
// text on the device's real on-screen keyboards. Asserts wallet identity: same name and same
// receive address. Run: `./fsim test backup_restore [--android]`.

/// Read the wallet's receive address off the keyed Text (per-app, never the process-global
/// clipboard) — the wallet's identity: the same key derives the same address at index 0.
Future<String> _receiveAddress(AppSession h) async {
  await h.tap(RegExp('Receive'));
  // A freshly created/recovered wallet nudges to secure a backup first; "Later" proceeds.
  if (await h.exists('Later')) await h.tap('Later');
  await h.waitFor(
    RegExp('Share Address'),
    timeout: const Duration(seconds: 20),
  );
  var address = '';
  final addr = RegExp(r'^(bc|tb|bcrt)1');
  for (var i = 0; i < 20 && !addr.hasMatch(address); i++) {
    address = (await h.getTextByKey(
      'receiveAddress',
    )).replaceAll(RegExp(r'\s'), '');
    if (!addr.hasMatch(address)) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }
  if (!addr.hasMatch(address)) {
    throw StateError('expected a bech32 receive address, got: "$address"');
  }
  await h.dismissSheetOrDialog();
  await h.waitForAbsent(RegExp('Share Address'));
  return address;
}

Future<void> main() async {
  // With regtest: the session's default network is regtest, so the created
  // wallet MUST be bcrt1… — and the restore must come back on the SAME
  // network (this e2e caught restoration pinning mainnet: the same key
  // restored as bc1…, which the final exact-address assertion now forbids).
  await SimHarness.runScenario('backup_restore', withRegtest: true, (h) async {
    await h.createWallet(name: 'PaperTest');
    final address = await _receiveAddress(h);
    stdout.writeln('address: $address');
    if (!address.startsWith('bcrt1')) {
      throw StateError(
        'a regtest session must create a bcrt1… wallet, got $address',
      );
    }

    // The backup flow needs the device plugged in.
    await h.connect(1);

    // Open the backup checklist and start the device's backup.
    await h.tapUntil(RegExp('unfinished backups'), RegExp('Backup keys'));
    await h.tapUntil('Backup', RegExp('Show secret backup'));
    await h.tap('Show secret backup');

    // The whole "write it down" half is ONE call: it captures the text (the
    // pen-and-paper read), drives the real paged display with widget-owned
    // geometry, and completes only on the device's own BackupRecorded for
    // this display run.
    final backupText = await h.device(1).recordBackup();
    stdout.writeln('recorded backup: ${backupText.split(' ').length} words');
    await h.waitFor(RegExp('Backed up'));
    await h.tap('Done');

    // The paper is now the only path back: forget the wallet coordinator-side
    // and retire the original device — the fresh device 2 starts blank.
    await h.disconnect(1);
    final deleted = await h.deleteWallet();
    if (deleted != 1)
      throw StateError('expected to delete 1 wallet, got $deleted');
    final n = await h.addDevice();
    stdout.writeln('new device: $n');
    await h.connect(n);
    await h.waitFor(RegExp('Restore wallet'));
    await h.tap(RegExp('load a physical backup'));
    await h.tapUntil(
      'Begin restoration',
      RegExp('name of the wallet being restored'),
    );
    await h.enterText(RegExp('name of the wallet being restored'), 'PaperTest');
    // No network step: restoration defaults to the session's network exactly
    // like creation does (this e2e caught it pinning mainnet — the same key
    // then derives a bcrt1/bc1 address mismatch, which the final assertion
    // enforces forever).
    // The backup sheet records the wallet's threshold, so the restorer knows it.
    await h.tapUntil('Continue', RegExp("I'm not sure"));
    await h.tap(RegExp('I know the threshold'));
    await h.enterText(RegExp('Number of keys needed'), '1');
    await h.tapUntil('Continue', RegExp('Give the device a name'));
    await h.enterFocusedText('PaperDev2');
    await h.tapUntil(
      'Continue',
      RegExp('Enter [Pp]hysical [Bb]ackup|Enter backup on device'),
    );

    // The mechanical paper-entry: type the captured text on the fresh device's
    // real on-screen keyboards.
    stdout.writeln('typing backup on device $n');
    await h.device(n).typeBackup(backupText);
    stdout.writeln('typing done');
    await h.waitFor(RegExp('restored successfully'));
    await h.tap('Close');

    // One typed key satisfies the 1-of-1 threshold: finish the restoration.
    await h.waitFor(RegExp('Ready to restore'));
    await h.tapUntil('Restore', RegExp('Receive'));

    // Wallet identity: the same name and the same key (address at index 0).
    if (!await h.exists(RegExp('PaperTest'))) {
      throw StateError('restored wallet is not named PaperTest');
    }
    final restored = await _receiveAddress(h);
    if (restored != address) {
      throw StateError(
        'restored wallet derives a DIFFERENT address: created $address, restored $restored',
      );
    }
    stdout.writeln(
      'BACKUP_RESTORE_OK: typed paper backup restored the same wallet ($address)',
    );
  });
}
