import 'dart:async';
import 'dart:io';

import 'package:frostsnap/sim_faucet.dart';

import 'regtest.dart' show regtestControlSocket;
import 'sim_harness.dart';

// regtest SEND end-to-end — the second half of the wallet lifecycle, on a real 2-of-3 wallet.
// Keygen across THREE devices (threshold 2), receive faucet BTC (confirmed), then SEND the whole
// balance back to the regtest node's own wallet address: the tx is built in the app and signed by
// a TWO-device subset (the third stays unplugged), broadcast and confirmed over the real
// electrs/bitcoind backend. No faucet mock, no GUI pixel-tapping — the destination address and the
// cross-check both come from the faucet control socket.
//
// Cross-check: the node wallet balance is dominated by maturing coinbase, so it can't isolate a
// single payment. Instead we send to a FRESH node address and assert ITS electrs (per-script)
// balance equals the sent amount — coinbase-immune proof the funds left the wallet and arrived.
//
// Run: `./simctl test regtest_send`. Needs a display (Xvfb on Linux CI); first run downloads
// bitcoind + electrs.

/// A 2-of-3 wallet: three devices, two required to sign.
const int _deviceCount = 3;
const int _threshold = 2;

/// Device hold-to-confirm button point (sim-3 calibration) — for both the keygen security code
/// and the transaction signing confirm.
const int _confirmX = 120;
const int _confirmY = 215;

/// Fund a whole 1 BTC so the send (send-max) and the node-side delta are unmistakable.
const int _fundSats = 100000000;

Future<void> main() async {
  await SimHarness.runScenario(
    'regtest_send',
    (h) async {
      // 1. Keygen a 2-of-3 wallet across all three devices. In a faucet-wired sim it defaults to
      //    Regtest, so its receive addresses are regtest (bcrt1…) and faucet funds land. The
      //    threshold slider defaults to the recommended 2-of-3, so no adjustment is needed.
      await h.tapUntil(RegExp('Create a multi-sig wallet'), 'Wallet name');
      await h.enterText('Wallet name', 'SimRegtest');
      await h.tapUntil('Next', 'Device name 1');
      for (var d = 1; d <= _deviceCount; d++) {
        await h.enterText('Device name $d', 'SimDev$d');
      }
      await h.tapUntil('Continue with $_deviceCount devices', 'Generate keys');
      await h.tapUntil('Generate keys', RegExp('Security Check'));

      // Every device shows the same security code and must hold-to-confirm; the app reveals "Yes"
      // once all three have. Hold all three each round (a hold on an already-confirmed device is a
      // no-op) until that happens.
      var confirmed = false;
      for (var round = 0; round < 6 && !confirmed; round++) {
        for (var d = 1; d <= _deviceCount; d++) {
          await h.device(d).holdConfirm(_confirmX, _confirmY);
        }
        confirmed = await h.exists('Yes');
      }
      if (!confirmed) {
        throw StateError('devices never confirmed the security code');
      }
      await h.tapUntil('Yes', RegExp('Unplug devices to continue'));
      // Disconnecting the head of the daisy chain cascades to every device below it.
      await h.unplug(1);
      await h.waitFor(RegExp('Receive'));

      // 2. Receive 1 BTC to the wallet's real address. Open Receive (a "secure your wallet" nudge
      //    intercepts a fresh wallet — choose Later), copy the address off the clipboard.
      await h.tap(RegExp('Receive'));
      await h.waitFor('Later');
      await h.tap('Later');
      await h.waitFor(RegExp('Share Address'));
      await h.tap('Copy');
      var address = '';
      for (var i = 0; i < 10 && !address.startsWith('bcrt1'); i++) {
        address = (await h.getClipboard()).trim();
        if (!address.startsWith('bcrt1')) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }
      if (!address.startsWith('bcrt1')) {
        throw StateError('expected a bcrt1 receive address, got "$address"');
      }

      final faucet = await SimFaucet.connect(regtestControlSocket);
      try {
        // Fund (broadcasts UNCONFIRMED), see it pending, then mine to confirm it.
        await faucet.fund(address, _fundSats);
        await h.waitFor(
          RegExp('Receiving'),
          timeout: const Duration(seconds: 90),
        );
        await faucet.mine(1);
        await h.waitFor(
          RegExp('Received'),
          timeout: const Duration(seconds: 90),
        );

        // Close the receive sheet to get back to the wallet home (where Send lives).
        await h.tap('Close');
        await h.waitForAbsent(RegExp('Share Address'));

        // 3. SEND the whole balance back to a FRESH node address (so its electrs balance reflects
        //    exactly this payment). The whole build + signer selection runs with EVERY device
        //    UNPLUGGED; signers are connected later, one at a time, only to sign.
        final nodeAddr = await faucet.faucetAddress();
        final signers = [1, 2];

        // The app's recipient field is pasted from the clipboard — seed it portably (no pbcopy/xclip).
        await h.setClipboard(nodeAddr);

        // Open Send (the same backup nudge may intercept; choose Later), paste the recipient.
        await h.tap('Send');
        await h.waitFor(
          RegExp('Paste|Later'),
          timeout: const Duration(seconds: 30),
        );
        if (await h.exists('Later')) await h.tap('Later');
        // Paste advances to the amount step — unless no feerate is set yet, in which case a feerate
        // dialog intercepts first (regtest's fallbackfee usually pre-sets one, so it's optional).
        await h.tapUntil('Paste', RegExp('Send Max|Custom'));

        // Feerate dialog (only when no feerate is set): the ETA tiles need fee estimates regtest may
        // lack, but the custom tile is always selectable — pick it and confirm its pre-filled value.
        if (await h.exists(RegExp('Custom'))) {
          await h.tapUntil(RegExp('Custom'), 'Confirm');
          await h.tap('Confirm');
        }

        // Amount: send the whole balance, then advance to the signer selection. The Send Max
        // button's label includes the available amount, so match it as a substring.
        await h.waitFor(RegExp('Send Max'));
        await h.tap(RegExp('Send Max'));
        await h.tapUntil('Confirm amount', RegExp('Select Signers'));

        // Signers: the selector lists all three devices regardless of connection (selection is
        // nonce-based), so tick the two intended signers with EVERYTHING still unplugged (each tap
        // toggles, so tap once each), then start signing once "$_threshold required" is met.
        await h.waitFor(RegExp('Select Signers'));
        for (final d in signers) {
          await h.tap(RegExp('SimDev$d'));
        }
        await h.waitFor(RegExp('Sign transaction'));
        await h.tap(RegExp('Sign transaction'));

        // 4. Confirm the transaction ON each signing device, ONE CONNECTED AT A TIME — the send was
        //    built with everything unplugged and we never have two signers connected at once (as on
        //    real hardware). For each signer: plug it (unplugging the previous one first), walk the
        //    tx-review screens (amount, address, fee) — each advances on a swipe-up — to the
        //    3-second hold-to-sign and hold until its share lands. The gotShares/threshold counter
        //    ticks "i/$_threshold" as each share is collected; "Broadcast" appears at the last one.
        for (var i = 0; i < signers.length; i++) {
          if (i > 0) await h.unplug(signers[i - 1]);
          await h.plug(signers[i]);
          final progressed = (i == signers.length - 1)
              ? RegExp('Broadcast')
              : RegExp('${i + 1}/$_threshold');
          var ok = false;
          for (var round = 0; round < 8 && !ok; round++) {
            await h
                .device(signers[i])
                .swipe(120, 240, 120, 80, const Duration(milliseconds: 250));
            await h
                .device(signers[i])
                .holdConfirm(
                  _confirmX,
                  _confirmY,
                  const Duration(milliseconds: 3200),
                );
            ok = await h.exists(progressed);
          }
          if (!ok) {
            throw StateError(
              'signer ${signers[i]} did not contribute its signature share',
            );
          }
        }
        await h.tap(RegExp('Broadcast'));
        await h.waitFor(
          RegExp('Sending'),
          timeout: const Duration(seconds: 30),
        );

        // 5. Mine to confirm the send; the wallet flips it to "Sent" (confirmed, outgoing).
        await faucet.mine(1);
        await h.waitFor(RegExp('Sent'), timeout: const Duration(seconds: 90));

        // Close the tx-details dialog and confirm the wallet's activity list shows BOTH the receive
        // and the send — the full lifecycle is reflected, not just the last action.
        await h.tap('Close');
        await h.waitForAbsent(RegExp('Transaction Details'));
        await h.waitFor(RegExp('Received'));
        await h.waitFor(RegExp('Sent'));

        // 6. Cross-check on the real chain: the fresh node address received ~the whole balance
        //    (less the fee). Poll for electrs to index the confirmation.
        const minReceived = _fundSats * 99 ~/ 100;
        var received = 0;
        for (var i = 0; i < 30 && received < minReceived; i++) {
          received = await faucet.addressBalanceSat(nodeAddr);
          if (received < minReceived) {
            await Future<void>.delayed(const Duration(seconds: 1));
          }
        }
        if (received < minReceived || received >= _fundSats) {
          throw StateError(
            'node address should have received ~$_fundSats sats (less fee); got $received',
          );
        }
        stdout.writeln(
          'REGTEST_SEND_DRIVE_OK: $_threshold-of-$_deviceCount device-signed send confirmed; '
          'node received $received sats',
        );
      } finally {
        await faucet.close();
      }
    },
    deviceCount: _deviceCount,
    withRegtest: true,
  );
}
