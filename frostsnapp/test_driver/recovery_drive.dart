import 'dart:io';

import 'sim_harness.dart';

// e2e wallet RECOVERY: create a 2-of-3 wallet, DELETE it from the app (the coordinator forgets it; the
// devices keep their shares), then RECOVER it by plugging the devices in one at a time and driving the
// WalletRecoveryFlow. Asserts the SAME wallet comes back — same name AND same receive address (same key),
// and 2-of-3 is enforced (one key is "not enough"). Runs on both backends: `./fsim test recovery` (host
// desktop, needs a display) and `./fsim test recovery --android` (its own self-booted emulator).

/// Open the receive sheet and read the derived address off its keyed Text (per-app, NOT the process-global
/// clipboard). Returns to wallet home. The address is the wallet's identity here: a given key derives a
/// deterministic address at index 0, so recovering the SAME key reproduces it.
Future<String> _receiveAddress(AppSession h) async {
  await h.tap(RegExp('Receive'));
  // A freshly created/recovered wallet nudges to secure a backup before Receive; "Later" proceeds.
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
  await SimHarness.runScenario('recovery', (h) async {
    // 1. Setup: a 2-of-3 wallet (3 devices → recommended threshold). Record its identity (receive address),
    //    then forget the wallet from the app.
    await h.createWallet(name: 'Rec', deviceCount: 3, devicePrefix: 'Dev');
    await h.waitFor(RegExp('Receive'), timeout: const Duration(seconds: 120));
    final addrBefore = await _receiveAddress(h);
    stdout.writeln('recovery: 2-of-3 wallet created, address=$addrBefore');

    final deleted = await h.deleteWallet();
    if (deleted != 1) {
      throw StateError('expected 1 wallet deleted, got $deleted');
    }
    await h.waitFor(
      RegExp('Restore wallet'),
      timeout: const Duration(seconds: 30),
    );
    stdout.writeln('recovery: wallet deleted, at the create/restore landing');

    // 2. Enter recovery (the tile subtitle is unique; "Restore wallet" alone matches the header too).
    await h.tap(RegExp('Use an existing device key'));
    await h.waitFor(
      RegExp('Restore from device'),
      timeout: const Duration(seconds: 15),
    );

    // 3. Recover by plugging the devices ONE AT A TIME (discovery reads exactly one device; two plugged in
    //    gives "Multiple devices detected"). The "Key ready" confirm button is "Restore" for the FIRST key
    //    (it STARTS the restoration) and "Add to wallet" for each key ADDED to the in-progress one.
    Future<void> confirmKeyReady() async {
      await h.waitFor(
        RegExp('Key ready'),
        timeout: const Duration(seconds: 30),
      );
      if (await h.exists('Restore')) {
        await h.tap('Restore');
      } else {
        await h.tap(RegExp('Add to wallet'));
      }
    }

    // Device 1 → "Key ready" (Dev1 part of 'Rec') → Restore → progress page.
    await h.plug(1);
    await confirmKeyReady();
    stdout.writeln('recovery: device 1 restored');

    // 2-of-3, ONE key collected → NOT recovered, and the app needs EXACTLY one more key. Assert the
    // concrete message so a wrong needed-count (e.g. "2 more keys") cannot satisfy the test.
    await h.waitFor(
      RegExp('Not enough shares'),
      timeout: const Duration(seconds: 20),
    );
    if (!await h.exists(RegExp('1 more key to restore'))) {
      throw StateError(
        'expected "1 more key to restore wallet" after 1 of 2 keys (2-of-3 semantics)',
      );
    }

    // Device 2 → unplug device 1 (free the single-device slot) + plug device 2, then "Add key" opens the
    // discovery which reads the connected device 2 → "Key ready" → Add to wallet.
    await h.unplug(1);
    await h.plug(2);
    await Future<void>.delayed(const Duration(seconds: 2));
    await h.tap(RegExp('Add key'));
    await confirmKeyReady();
    stdout.writeln('recovery: device 2 added (threshold reached)');

    // 4. Enough keys → "Ready to restore" → finalize.
    await h.waitFor(
      RegExp('Ready to restore'),
      timeout: const Duration(seconds: 20),
    );
    await h.tap('Restore');
    await h.waitFor(RegExp('Receive'), timeout: const Duration(seconds: 60));
    // Same WALLET: the recovered wallet's name 'Rec' is shown at home (exact match — 'Rec' as a RegExp
    // would also hit the "Rec" in "Receive").
    if (!await h.exists('Rec')) {
      throw StateError('recovered wallet name is not "Rec"');
    }
    stdout.writeln('recovery: wallet Rec recovered, back at home');

    // 5. Same KEY: the recovered wallet derives the SAME address as the original (name alone is not enough —
    //    this rules out a same-name-but-different-key restore).
    final addrAfter = await _receiveAddress(h);
    if (addrAfter != addrBefore) {
      throw StateError(
        'recovered wallet address $addrAfter != original $addrBefore — a DIFFERENT key was restored',
      );
    }
    stdout.writeln(
      'RECOVERY_OK: 2-of-3 wallet recovered from 2 devices, same key ($addrAfter)',
    );
  }, deviceCount: 3);
}
