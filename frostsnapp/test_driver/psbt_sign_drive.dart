import 'dart:async';
import 'dart:io';

import 'sim_harness.dart';

// PSBT signing end-to-end — the interop half of the wallet: a transaction this app did NOT build.
// Keygen a 2-of-3 wallet, export its descriptor to the regtest node as a watch-only wallet, receive
// several UTXOs, then have BITCOIND build the spend (`walletcreatefundedpsbt`). The PSBT comes back
// as the `crypto-psbt` animated QR another wallet would display, is read through the app's real
// scanner (QR grid detection, UR fountain assembly, PSBT parse, ownership validation), signed by a
// two-device subset, broadcast, and confirmed.
//
// This is the Sparrow/Core → Frostsnap flow: nothing about the transaction — inputs, change,
// key origins, feerate — comes from the app's own transaction builder, so it is the app's PSBT
// INTEROP that is under test, not a round-trip of its own encoding.
//
// The one thing the sim substitutes is the lens (see lib/sim_camera.dart): the QR images are
// reported to the same FrameScanner the camera lenses feed. Everything downstream of the frame
// is real.
//
// Cross-check: the node wallet balance is dominated by maturing coinbase, so it can't isolate a
// single payment. The PSBT pays a FRESH node address and we assert ITS electrs (per-script) balance
// is exactly the amount paid — coinbase-immune proof the PSBT's own transaction confirmed.
//
// Run: `./fsim test psbt_sign [--android]`. Needs a display (Xvfb on Linux CI); first run
// downloads bitcoind + electrs.

/// A 2-of-3 wallet: three devices, two required to sign.
const int _deviceCount = 3;
const int _threshold = 2;

/// Device hold-to-confirm button point (sim-3 calibration) for the transaction signing confirm.
const int _confirmX = 120;
const int _confirmY = 215;

/// Fund the wallet as several separate UTXOs, and pay more than all but one of them is worth, so
/// bitcoin's coin selection MUST spend every one. Each extra taproot input adds ~150 bytes of key
/// origin and witness utxo to the PSBT, which is what pushes it past a single 400-byte UR fragment
/// and makes the QR genuinely ANIMATED — the multi-part fountain assembly is most of what the
/// scanner does, so a one-frame PSBT would leave it untested.
const int _utxoCount = 4;
const int _utxoSats = 40000000;
const int _paySats = 140000000;

Future<void> main() async {
  await SimHarness.runScenario(
    'psbt_sign',
    (h) async {
      // 1. Keygen a 2-of-3 wallet (three devices, the recommended threshold of 2). In a
      //    faucet-wired sim it defaults to Regtest, so faucet funds land on its addresses.
      await h.createWallet(name: 'SimPsbt', deviceCount: _deviceCount);

      final faucet = await h.faucet();
      try {
        // 2. Export the wallet to the node, exactly as you would to Core or Sparrow: one
        //    checksummed descriptor, imported watch-only. From here the node can see the wallet's
        //    coins and spend them into a PSBT.
        final descriptor = await h.walletDescriptor();
        if (!descriptor.startsWith('tr(') || !descriptor.contains('#')) {
          throw StateError(
            'expected a checksummed taproot descriptor, got "$descriptor"',
          );
        }
        await faucet.watchDescriptor(descriptor);

        // 3. Receive several UTXOs to the wallet's real address (see [_utxoCount]).
        await h.tap(RegExp('Receive'));
        await h.waitFor('Later');
        await h.tap('Later');
        await h.waitFor(RegExp('Share Address'));
        var address = '';
        for (var i = 0; i < 10 && !address.startsWith('bcrt1'); i++) {
          // Read the address per-app off its keyed Text (spacedHex groups it with whitespace) — NOT
          // via Copy→system clipboard, which is process-global and raced by parallel test apps.
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

        for (var i = 0; i < _utxoCount; i++) {
          await faucet.fund(address, _utxoSats);
        }
        await h.waitFor(
          RegExp('Receiving'),
          timeout: const Duration(seconds: 90),
        );
        await faucet.mine(1);
        await h.waitFor(
          RegExp('Received'),
          timeout: const Duration(seconds: 90),
        );

        const funded = _utxoCount * _utxoSats;
        var confirmedSats = 0;
        for (var i = 0; i < 30 && confirmedSats < funded; i++) {
          confirmedSats = await faucet.addressBalanceSat(address);
          if (confirmedSats < funded) {
            await Future<void>.delayed(const Duration(seconds: 1));
          }
        }
        if (confirmedSats != funded) {
          throw StateError(
            'wallet address should hold $funded sats over $_utxoCount utxos; got $confirmedSats',
          );
        }

        // Close the receive view → wallet home. Portable across layouts: the wide layout has a
        // Close button; the compact emulator bottom sheet is back-dismissed.
        await h.dismissSheetOrDialog();
        await h.waitForAbsent(RegExp('Share Address'));

        // 4. THE NODE builds the transaction — coin selection, change, feerate and taproot key
        //    origins are all bitcoind's. The app has never seen it.
        final nodeAddr = await faucet.faucetAddress();
        final psbt = await faucet.createPsbt(nodeAddr, _paySats);

        // 5. Open Sign PSBT and pick the signers (selection is nonce-based, so it works with every
        //    device unplugged). "Scan" only enables once exactly $_threshold are ticked.
        final signers = [1, 2];
        await h.tapTooltip('More');
        // The tile's own label is its title AND subtitle merged, so match the subtitle — the title
        // alone is a substring of the page it opens.
        await h.tapUntil(
          RegExp('Sign a partially signed bitcoin transaction'),
          RegExp('Sign PSBT'),
        );
        for (final d in signers) {
          await h.tap(RegExp('SimDev$d'));
        }
        await h.tapUntil('Scan', RegExp('Scan PSBT'));

        // 6. Put the PSBT in front of the camera as the animated QR another wallet would show. The
        //    scanner reads it frame by frame; when the fountain completes, the app pops the scanner
        //    with the decoded PSBT and opens the transaction, which starts signing.
        final parts = await h.showPsbtQr(psbt);
        if (parts < 2) {
          throw StateError(
            'PSBT fit in $parts QR part(s) — the animated multi-part path went untested; '
            'the funding pattern must force more inputs',
          );
        }
        await h.waitFor(
          RegExp('Transaction Details'),
          timeout: const Duration(seconds: 120),
        );
        await h.hideQr();

        // 7. Confirm the tx ON each signing device, ONE CONNECTED AT A TIME (as on real hardware):
        //    plug it (unplugging the previous), swipe up through the review screens to the hold-to-
        //    sign, and wait for this signer's share to land. INTERMEDIATE signers tick the
        //    gotShares counter ("1/$_threshold", …); the LAST one completes signing, which removes
        //    the counter before any paint can capture it — so key the last share off the persistent
        //    "Signed" state instead. NOT "Broadcast": that control is prebuilt in a faded
        //    AnimatedCrossFade branch whose semantics leak on Android.
        for (var i = 0; i < signers.length; i++) {
          if (i > 0) await h.unplug(signers[i - 1]);
          await h.plug(signers[i]);
          final isLast = i == signers.length - 1;
          final signal = isLast
              ? RegExp('Signed')
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
            ok = await h.exists(signal);
          }
          if (!ok) {
            throw StateError(
              'signer ${signers[i]} did not contribute its signature share '
              '(${isLast ? 'never reached the Signed state' : 'counter never reached ${i + 1}/$_threshold'})',
            );
          }
        }

        // 8. Broadcast the now-complete transaction and confirm it.
        await h.tap(RegExp('Broadcast'));
        await h.waitFor(
          RegExp('Sending'),
          timeout: const Duration(seconds: 30),
        );
        await faucet.mine(1);
        await h.waitFor(RegExp('Sent'), timeout: const Duration(seconds: 90));

        // 9. Cross-check on the real chain: the node address received EXACTLY what the PSBT said to
        //    pay it — the transaction that confirmed is the one bitcoind built, unaltered.
        var received = 0;
        for (var i = 0; i < 30 && received < _paySats; i++) {
          received = await faucet.addressBalanceSat(nodeAddr);
          if (received < _paySats) {
            await Future<void>.delayed(const Duration(seconds: 1));
          }
        }
        if (received != _paySats) {
          throw StateError(
            'node address should have received exactly $_paySats sats; got $received',
          );
        }
        stdout.writeln(
          'PSBT_SIGN_DRIVE_OK: bitcoind-built PSBT scanned over $parts QR parts, '
          '$_threshold-of-$_deviceCount device-signed, broadcast; node received $received sats',
        );
      } finally {
        await faucet.close();
      }
    },
    deviceCount: _deviceCount,
    withRegtest: true,
  );
}
