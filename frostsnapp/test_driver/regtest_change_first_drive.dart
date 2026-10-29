import 'dart:async';
import 'dart:io';

import 'package:frostsnap/sim_faucet.dart';

import 'sim_harness.dart';

// regtest CHANGE-INDEX end-to-end — the wallet's very first send must put its change on the FIRST
// change address (internal keychain, index 0). A 1-of-1 wallet receives a confirmed coin and sends
// a PARTIAL amount (never send-max: the tx must have a change output), signed on-device, broadcast
// and mined. The expected change address is derived OUTSIDE the app — the app's exported
// descriptor rewritten to the change keychain and expanded by bitcoind over `faucet.rpc`
// (the COMMANDS.md recipe; no fsim library code) — and the assertion is that address's
// electrs balance: coin-scoped, coinbase-immune.
//
// This is a regression test for fee-display burning change indices: `TxState::fee()` used to run
// the full `send_to` (reveal + mark-used) on every rebuild of the signer-selection page, so by the
// time "Sign transaction" built the real tx its change landed at internal index >= 1 and the gap
// between on-chain change outputs grew with every repaint. Fixed by `f15560fe [coord,app] Make
// the fee display pure`; this test is what keeps it fixed — it was committed red against the
// pre-fix base and turned green on the restack, which is how we know it detects the defect.
//
// Run: `./fsim test regtest_change_first`. Needs a display (Xvfb on Linux CI); first run downloads
// bitcoind + electrs.

/// Keychain `keychain` (0 = receive, 1 = change) at `index`, derived from the app's
/// exported descriptor using only bitcoind RPC over the faucet passthrough.
Future<String> deriveAppAddress(
  SimFaucet faucet,
  String descriptor, {
  required int keychain,
  required int index,
}) async {
  final single = descriptor.replaceAll('<0;1>', '$keychain').split('#').first;
  final info = await faucet.rpc('getdescriptorinfo', [single]);
  final canonical = (info as Map)['descriptor'] as String;
  final addrs = await faucet.rpc('deriveaddresses', [
    canonical,
    [index, index],
  ]);
  return (addrs as List).single as String;
}

const int _fundSats = 100000000;
const int _sendSats = 25000000;

/// Device hold-to-confirm button point (sim-3 calibration).
const int _confirmX = 120;
const int _confirmY = 215;

Future<void> main() async {
  await SimHarness.runScenario(
    'regtest_change_first',
    (h) async {
      // 1. A 1-of-1 wallet — the smallest wallet that can sign — then receive 1 BTC, confirmed.
      await h.createWallet(name: 'SimChange');

      await h.tap(RegExp('Receive'));
      await h.waitFor('Later');
      await h.tap('Later');
      await h.waitFor(RegExp('Share Address'));
      var address = '';
      for (var i = 0; i < 10 && !address.startsWith('bcrt1'); i++) {
        address = (await h.getTextByKey(
          'receiveAddress',
        )).replaceAll(RegExp(r'\s'), '');
        if (!address.startsWith('bcrt1')) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }
      if (!address.startsWith('bcrt1')) {
        throw StateError('expected a bcrt1 receive address, got "$address"');
      }

      final faucet = await h.faucet();
      try {
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
        await h.dismissSheetOrDialog();
        await h.waitForAbsent(RegExp('Share Address'));

        // 2. Send a partial amount to a fresh node address. Recipient is TYPED via this app's own
        //    VM service, not the process-global clipboard (parallel test apps share one pasteboard).
        final nodeAddr = await faucet.faucetAddress();
        await h.tap('Send');
        await h.waitFor(
          RegExp('Paste|Later'),
          timeout: const Duration(seconds: 30),
        );
        if (await h.exists('Later')) await h.tap('Later');
        await h.waitFor('Paste');
        await h.enterFocusedText(nodeAddr);
        await h.tapUntil('Confirm recipient', RegExp('Send Max|Custom'));

        // Feerate dialog (only when no feerate is pre-set): the custom tile is always selectable.
        if (await h.exists(RegExp('Custom'))) {
          await h.tapUntil(RegExp('Custom'), 'Confirm');
          await h.tap('Confirm');
        }

        // Amount: a quarter of the balance, typed in sats into the autofocused field (the
        // AmountInput default unit) — NOT Send Max, so the tx must carry a change output.
        await h.waitFor(RegExp('Send Max'));
        await h.enterFocusedText('$_sendSats');
        await h.tapUntil('Confirm amount', RegExp('Select Signers'));

        // 3. Sign on the single device and broadcast. The last (only) signer's share flips the
        //    tile to the persistent "Signed" state, which is the reliable wait target.
        await h.waitFor(RegExp('Select Signers'));
        await h.tap(RegExp('SimDev1'));
        await h.waitFor(RegExp('Sign transaction'));
        await h.tap(RegExp('Sign transaction'));

        await h.plug(1);
        var signed = false;
        for (var round = 0; round < 8 && !signed; round++) {
          await h
              .device(1)
              .swipe(120, 240, 120, 80, const Duration(milliseconds: 250));
          await h
              .device(1)
              .holdConfirm(
                _confirmX,
                _confirmY,
                const Duration(milliseconds: 3200),
              );
          signed = await h.exists(RegExp('Signed'));
        }
        if (!signed) {
          throw StateError('the device never contributed its signature share');
        }
        await h.tap(RegExp('Broadcast'));
        await h.waitFor(
          RegExp('Sending'),
          timeout: const Duration(seconds: 30),
        );
        await faucet.mine(1);
        await h.waitFor(RegExp('Sent'), timeout: const Duration(seconds: 90));

        // 4. Observation, OUTSIDE the expectation: the app's own descriptor, the address it
        //    implies for change index 0, and what electrs says landed there. A failure in any of
        //    this is a broken backend or a descriptor regression — a plain FAILED, never a known
        //    defect.
        final descriptor = await h.walletDescriptor();
        final expectedChange = await deriveAppAddress(
          faucet,
          descriptor,
          keychain: 1,
          index: 0,
        );
        const wantChange = _fundSats - _sendSats; // less the fee
        var changeAt0 = 0;
        for (var i = 0; i < 30 && changeAt0 == 0; i++) {
          changeAt0 = await faucet.addressBalanceSat(expectedChange);
          if (changeAt0 == 0) {
            await Future<void>.delayed(const Duration(seconds: 1));
          }
        }
        // Locate where the change actually went, so the failure names the defect (a burned index)
        // rather than just "not at 0". Also observation: still outside the expectation.
        var landed = 'nowhere in internal indices 0..9';
        if (changeAt0 == 0) {
          for (var index = 1; index < 10; index++) {
            final candidate = await deriveAppAddress(
              faucet,
              descriptor,
              keychain: 1,
              index: index,
            );
            if (await faucet.addressBalanceSat(candidate) > 0) {
              landed = 'at internal index $index';
              break;
            }
          }
        }

        // 5. THE assertion: fixed by f15560fe (fee display made pure), and this is what keeps
        //    it fixed — a rebuild that burns a change index puts the change somewhere else.
        if (changeAt0 == 0) {
          throw StateError(
            'first send\'s change should be on the first change address '
            '(internal index 0, $expectedChange) but landed $landed — '
            'change indices were burned before the transaction was built',
          );
        }

        // 6. Independent of the expectation: the right amount came back as change.
        if (changeAt0 > wantChange || changeAt0 < wantChange * 99 ~/ 100) {
          throw StateError(
            'change output should be ~$wantChange sats (less fee); got $changeAt0',
          );
        }
        stdout.writeln(
          'REGTEST_CHANGE_FIRST_DRIVE_OK: change ($changeAt0 sats) on the first change address',
        );
      } finally {
        await faucet.close();
      }
    },
    deviceCount: 1,
    withRegtest: true,
  );
}
