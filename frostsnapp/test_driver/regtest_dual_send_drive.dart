import 'dart:async';
import 'dart:io';

import 'sim_harness.dart';

// Cross-wallet send/receive across TWO app instances sharing ONE regtest chain (sim-dual-app-send).
// Instance A creates a wallet and receives 1 BTC from the faucet (confirmed). Instance B creates its own
// wallet and yields a receive address. A then SENDS half (0.5 BTC) to B's address, signs on its device,
// broadcasts and mines; B sees the payment arrive over the real electrum sync. Cross-checked on-chain:
// B's fresh address receives EXACTLY 0.5 BTC — the fee comes from A's change, so the figure is
// coinbase/fee-immune. No faucet mock, no GUI pixel-tapping.
//
// HOST-ONLY (Scenario.runDual): two instances of one app package can't coexist on one Android emulator,
// so this skips cleanly there. Run: `./simctl test regtest_dual_send`. Needs a display (Xvfb on Linux
// CI); first run downloads bitcoind + electrs.

/// Device hold-to-confirm button point (sim-3 calibration) — used for tx signing here.
const int _confirmX = 120;
const int _confirmY = 215;

const int _fundSats = 100000000; // 1 BTC funded into A
const int _sendSats = 50000000; //  0.5 BTC sent A → B (half)

Future<void> main() async {
  await Scenario.runDual('regtest_dual_send', (a, b, s) async {
    // 1. A: create a (Regtest) 1-of-1 wallet and receive 1 BTC, confirmed.
    await a.createWallet(name: 'WalletA', devicePrefix: 'DevA');
    final aAddr = await _openReceiveAddress(a);

    final faucet = await s.faucet();
    try {
      await faucet.fund(aAddr, _fundSats);
      await a.waitFor(
        RegExp('Receiving'),
        timeout: const Duration(seconds: 90),
      );
      await faucet.mine(1);
      await a.waitFor(RegExp('Received'), timeout: const Duration(seconds: 90));
      await a.dismissSheetOrDialog();
      await a.waitForAbsent(RegExp('Share Address'));

      // 2. B: create its own wallet and read its receive address (per-app; see _openReceiveAddress).
      await b.createWallet(name: 'WalletB', devicePrefix: 'DevB');
      final bAddr = await _openReceiveAddress(b);
      await b.dismissSheetOrDialog();
      await b.waitForAbsent(RegExp('Share Address'));

      // 3. A: send HALF to B's address. TYPE it into A's autofocused recipient field (per-app), NOT the
      //    shared clipboard — the macOS pasteboard is process-global, so under --jobs N the other parallel
      //    tests clobber it and a Paste can send to the WRONG address (got-0).
      await a.tap('Send');
      await a.waitFor(
        RegExp('Paste|Later'),
        timeout: const Duration(seconds: 30),
      );
      if (await a.exists('Later')) await a.tap('Later');
      await a.waitFor(
        'Paste',
      ); // recipient step shown; its field is autofocused
      await a.enterFocusedText(bAddr);
      await a.tapUntil('Confirm recipient', RegExp('Send Max|Custom'));
      // Optional feerate dialog (only when no feerate is set): the custom tile is always selectable.
      if (await a.exists(RegExp('Custom'))) {
        await a.tapUntil(RegExp('Custom'), 'Confirm');
        await a.tap('Confirm');
      }
      // Amount step: the Amount field autofocuses and defaults to SATOSHI, so type the raw sats — not
      // Send Max. If the entry didn't register, "Confirm amount" stays disabled and tapUntil throws.
      await a.waitFor(RegExp('Send Max'));
      await a.enterFocusedText('$_sendSats');
      await a.tapUntil('Confirm amount', RegExp('Select Signers'));

      // 1-of-1 signer: the device is listed regardless of connection (selection is nonce-based), so
      // tick it with the device still unplugged — that flips the button to "Sign transaction".
      await a.tap(RegExp('DevA1'));
      await a.waitFor(RegExp('Sign transaction'));
      await a.tap(RegExp('Sign transaction'));

      // 4. Sign on A's single device: plug it, swipe the review screens up to the 3s hold-to-sign, and
      //    wait for the tx to reach the persistent "Signed" state. DON'T key off the "1/1" share counter:
      //    this is the last (here, only) share, so the moment it lands signing is DONE and the UI replaces
      //    the counter with "Signed" — the "1/1" frame can vanish before any paint captures it (with the
      //    sim's 1Hz forced-frame heartbeat a sub-second state may never be painted at all). DON'T key off
      //    "Broadcast" either: that control prebuilds in a faded cross-fade and reads present before signing
      //    is done. "Signed" only renders once signingDone (wallet_tx_details.dart) and stays up until we
      //    broadcast, so it is both correct and observable.
      await a.plug(1);
      var signed = false;
      for (var round = 0; round < 8 && !signed; round++) {
        await a
            .device(1)
            .swipe(120, 240, 120, 80, const Duration(milliseconds: 250));
        await a
            .device(1)
            .holdConfirm(
              _confirmX,
              _confirmY,
              const Duration(milliseconds: 3200),
            );
        signed = await a.exists(RegExp('Signed'));
      }
      if (!signed) {
        throw StateError(
          'A device did not sign the transaction (never reached the Signed state)',
        );
      }
      await a.tap(RegExp('Broadcast'));
      await a.waitFor(RegExp('Sending'), timeout: const Duration(seconds: 30));

      // 5. B sees the incoming payment (unconfirmed) over the shared chain, then confirm with a mine.
      await b.waitFor(
        RegExp('Receiving'),
        timeout: const Duration(seconds: 90),
      );
      await faucet.mine(1);
      await b.waitFor(RegExp('Received'), timeout: const Duration(seconds: 90));
      await a.waitFor(RegExp('Sent'), timeout: const Duration(seconds: 90));

      // 6. Cross-check on-chain: B's fresh address received EXACTLY half (fee paid from A's change).
      var got = 0;
      for (var i = 0; i < 30 && got < _sendSats; i++) {
        got = await faucet.addressBalanceSat(bAddr);
        if (got < _sendSats) {
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }
      if (got != _sendSats) {
        throw StateError(
          'B address should have received exactly $_sendSats sats; got $got',
        );
      }
      stdout.writeln(
        'REGTEST_DUAL_SEND_DRIVE_OK: A sent $_sendSats to B (a second app); '
        'B on-chain balance=$got',
      );
    } finally {
      await faucet.close();
    }
  });
}

/// Open [h]'s Receive sheet (dismissing the fresh-wallet "secure your wallet" nudge with Later) and
/// return the wallet's regtest (bcrt1) address, read PER-APP off the Share Address sheet's keyed Text —
/// NOT via Copy→system clipboard, which is process-global and raced by the other parallel test apps.
Future<String> _openReceiveAddress(AppSession h) async {
  await h.tap(RegExp('Receive'));
  await h.waitFor('Later');
  await h.tap('Later');
  await h.waitFor(RegExp('Share Address'));
  var address = '';
  for (var i = 0; i < 10 && !address.startsWith('bcrt1'); i++) {
    // spacedHex groups the address with whitespace; strip it back to the raw address.
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
  return address;
}
