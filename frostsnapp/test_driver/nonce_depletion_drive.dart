import 'dart:async';
import 'dart:io';

import 'sim_harness.dart';

// nonce-depletion e2e — the two "device has no nonces" failure modes, on a real 2-of-3 regtest
// wallet. The coordinator consumes a device's nonces once it has SENT the sign request out (the
// device enters sent_req_to_device), even if the signature is never completed; cancelling the
// session then burns them (CloseSignSession → consume). Repeated with a many-input send-max, this
// drains a device without ever broadcasting. Two recorded demonstrations:
//
//  1. SIGNER OUT: drain SimDev3 to zero, so its signer row shows "no nonces remaining" while the
//     wallet is still spendable by SimDev1 + SimDev2.
//  2. NO SPEND: drain SimDev2 too, dropping below threshold (only SimDev1 has nonces), so the
//     amount page blocks the spend with the "can't sign right now" dialog.
//
// Per-drain choreography: send-max (many inputs → large n_sigs), select [1, target], Sign
// transaction, CONNECT the target so the request goes out (the "Sign transaction with connected
// device" modal confirms it), UNPLUG it (the modal clears but it stays in sent_req_to_device),
// then tap the page-level Cancel (cancelSignSession, which consumes — the modal's Cancel only
// tears down the UI wrapper). SimDev1 anchors every drain session but is never connected, so it is
// released rather than consumed and stays full.
//
// Run: `./fsim test nonce_depletion --android --jobs 1 --nocapture --test-timeout 1800`.
// A host run performs the same assertions without recording.

const int _utxos = 30;
const int _utxoSats = 40000;

Future<T> _record<T>(AppSession h, String path, Future<T> Function() body) =>
    h.emulatorSerial != null ? h.record(path, body) : body();

Future<void> _openSend(AppSession h) async {
  await h.tap('Send');
  await h.waitFor(RegExp('Paste|Later'), timeout: const Duration(seconds: 30));
  if (await h.exists('Later')) await h.tap('Later');
  await h.waitFor('Paste');
}

/// Type the recipient and advance toward the amount page. Ends on the amount page (Send Max) or,
/// when the cap has dropped to zero, on the no-spend dialog ("sign right now") — the caller checks.
Future<void> _enterRecipient(AppSession h, String address) async {
  await h.enterFocusedText(address);
  await h.tapUntil(
    'Confirm recipient',
    RegExp("Send Max|Custom|sign right now"),
  );
  if (await h.exists(RegExp('Custom'))) {
    await h.tapUntil(RegExp('Custom'), 'Confirm');
    await h.tap('Confirm');
    await h.waitFor(RegExp("Send Max|sign right now"));
  }
}

Future<void> _abortToHome(AppSession h) async {
  for (var i = 0; i < 14; i++) {
    final inFlow =
        await h.exists(RegExp('Send Max')) ||
        await h.exists(RegExp('Select Signers')) ||
        await h.exists(RegExp('Transaction Details')) ||
        await h.exists('Paste');
    if (!inFlow) return;
    await h.dismissSheetOrDialog();
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
}

/// From a fresh home, walk to the signers page of a send-max transaction.
Future<void> _toSignersPage(AppSession h, String nodeAddr) async {
  await _openSend(h);
  await _enterRecipient(h, nodeAddr);
  await h.tap(RegExp('Send Max'));
  if (await h.exists('OK')) await h.tap('OK');
  await h.tapUntil('Confirm amount', RegExp('Select Signers'));
}

/// One drain of [target]: from the signers page, start a session [1, target], let the request
/// reach the connected target, then cancel it so the coordinator consumes target's nonces.
Future<void> _burnRound(AppSession h, int target) async {
  await h.tap(RegExp('SimDev1'));
  await h.tap(RegExp('SimDev$target'));
  await h.waitFor(RegExp('Sign transaction'));
  await h.tap(RegExp('Sign transaction'));
  await h.waitFor(
    RegExp('Transaction Details'),
    timeout: const Duration(seconds: 20),
  );
  await h.plug(target);
  await h.waitFor(
    RegExp('Sign transaction with connected device|Confirm on device'),
    timeout: const Duration(seconds: 30),
  );
  await h.unplug(target);
  await h.waitForAbsent(
    RegExp('Sign transaction with connected device'),
    timeout: const Duration(seconds: 15),
  );
  await h.tap(RegExp(r'^Cancel$'));
  await h.waitFor(
    RegExp('No Bitcoin will be sent'),
    timeout: const Duration(seconds: 15),
  );
  await h.tap(RegExp('Sure'));
  await _abortToHome(h);
}

Future<void> main() async {
  await SimHarness.runScenario(
    'nonce_depletion',
    (h) async {
      final videoDir = Directory('build/nonce_limit_videos')
        ..createSync(recursive: true);
      String video(String name) => '${videoDir.path}/$name.mp4';

      await h.createWallet(
        name: 'Deplete',
        deviceCount: 3,
        devicePrefix: 'SimDev',
      );
      await h.waitFor(RegExp('Receive'), timeout: const Duration(seconds: 120));

      await h.tap(RegExp('Receive'));
      if (await h.exists('Later')) await h.tap('Later');
      await h.waitFor(RegExp('Share Address'));
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
      await h.dismissSheetOrDialog();
      await h.waitForAbsent(RegExp('Share Address'));

      final faucet = await h.faucet();
      try {
        for (var i = 0; i < _utxos; i++) {
          await faucet.fund(address, _utxoSats);
        }
        await faucet.mine(1);
        await h.waitFor(
          RegExp('Received'),
          timeout: const Duration(seconds: 90),
        );
        final nodeAddr = await faucet.faucetAddress();

        // ---- 1. SIGNER OUT: drain SimDev3 to the marking ----
        var dev3Out = false;
        for (var round = 0; round < 12 && !dev3Out; round++) {
          await _toSignersPage(h, nodeAddr);
          dev3Out = await h.exists(RegExp('no nonces remaining'));
          if (dev3Out) break;
          await _burnRound(h, 3);
        }
        if (!dev3Out) {
          throw StateError(
            'SimDev3 never reached the "no nonces remaining" marking',
          );
        }
        await _abortToHome(h);

        // Recorded: SimDev3 marked out while SimDev1 + SimDev2 can still sign. Recipient typed
        // before recording (the android IME would eat the 180s cap).
        await _openSend(h);
        await _enterRecipient(h, nodeAddr);
        await _record(h, video('5-device-out-of-nonces'), () async {
          await h.tap(RegExp('Send Max'));
          if (await h.exists('OK')) await h.tap('OK');
          await h.tapUntil('Confirm amount', RegExp('Select Signers'));
          await h.waitFor(RegExp('no nonces remaining'));
          await h.screenshot('device-out-of-nonces');
          // Prove the wallet is still spendable: SimDev1 + SimDev2 reach the threshold.
          await h.tap(RegExp('SimDev1'));
          await h.tap(RegExp('SimDev2'));
          if (!await h.exists(RegExp('Sign transaction'))) {
            throw StateError(
              'SimDev1 + SimDev2 could not reach threshold — wallet not spendable',
            );
          }
        });
        await _abortToHome(h);

        // ---- 2. NO SPEND: drain SimDev2 too, dropping below threshold ----
        var noSpend = false;
        for (var round = 0; round < 12 && !noSpend; round++) {
          await _openSend(h);
          await _enterRecipient(h, nodeAddr);
          noSpend = await h.exists(RegExp("sign right now"));
          if (noSpend) {
            if (await h.exists('OK')) await h.tap('OK');
            await _abortToHome(h);
            break;
          }
          await h.tap(RegExp('Send Max'));
          if (await h.exists('OK')) await h.tap('OK');
          await h.tapUntil('Confirm amount', RegExp('Select Signers'));
          await _burnRound(h, 2);
        }
        if (!noSpend) {
          throw StateError(
            'the amount page never blocked the spend after draining SimDev2 + SimDev3',
          );
        }

        // Recorded: the no-spend dialog. Recipient typed before recording.
        await _openSend(h);
        await h.enterFocusedText(nodeAddr);
        await _record(h, video('6-no-spend-possible'), () async {
          await h.tapUntil(
            'Confirm recipient',
            RegExp("Custom|sign right now"),
          );
          if (await h.exists(RegExp('Custom'))) {
            await h.tapUntil(RegExp('Custom'), 'Confirm');
            await h.tap('Confirm');
          }
          await h.waitFor(RegExp("sign right now"));
          await h.screenshot('no-spend-dialog');
          await h.tap('OK');
        });
        await _abortToHome(h);

        stdout.writeln(
          'NONCE_DEPLETION_DRIVE_OK: SimDev3 drained to the signer-row marking (wallet still '
          'spendable by SimDev1+SimDev2), then SimDev2 drained below threshold to the no-spend dialog',
        );
      } finally {
        await faucet.close();
      }
    },
    deviceCount: 3,
    withRegtest: true,
  );
}
