import 'dart:async';
import 'dart:io';

import 'package:frostsnap/sim_faucet.dart';

import 'sim_harness.dart';

// nonce-limit e2e — coin selection is capped by what the devices' signing nonces can sign, on a
// real 2-of-3 regtest wallet. A fresh nonce stream holds 30 nonces and a signing session draws
// one per input from a single stream, so 30 is a device's per-transaction ceiling. Two
// demonstrations (recorded on android, asserted everywhere):
//
//  1. TRUNCATION: 33 utxos (30 big + 3 small), send-max → the "Send amount limited" dialog,
//     and the built tx spends exactly the 30 big coins — proven by the node-side received
//     amount — then signs and broadcasts. An uncapped 33-input selection could not sign.
//  2. SUCCESS: an ordinary small send for contrast — no dialog, exact amount arrives.
//
// The "a device has no nonces" failure modes (the signer-row marking and the no-spend dialog) are
// a separate scenario, nonce_depletion_drive.
//
// Run: `./fsim test nonce_limit --android --jobs 1 --nocapture --test-timeout 1800`.
// A host run performs the same assertions without recording.

const int _deviceCount = 3;
const int _threshold = 2;

/// Device hold-to-confirm button point (sim-3 calibration), for keygen and signing alike.
const int _confirmX = 120;
const int _confirmY = 215;

/// 30 big coins fill a fresh nonce stream exactly; the 3 small ones exist to be left behind.
/// Distinct sizes make "truncate to the largest" visible in the node-side received amount.
const int _bigCount = 30;
const int _bigSats = 50000;
const int _smallCount = 3;
const int _smallSats = 10000;

const int _successSendSats = 15000;

/// Send-max on the capped wallet delivers the [_bigCount] largest coins minus fees; these bound
/// the node-side received amount (below 30 coins, or all 33, both fall outside).
const int _cappedFloor = _bigCount * _bigSats - 30000;
const int _cappedCeil = _bigCount * _bigSats;

/// Record [body] on android; on host just run it (recording needs an emulator screen).
Future<T> _record<T>(AppSession h, String path, Future<T> Function() body) =>
    h.emulatorSerial != null ? h.record(path, body) : body();

/// Whether any send-flow page (recipient / amount / signers / tx-details) is on screen. The
/// bottom-nav "Send"/"Receive" buttons are always present, so they can't signal the flow — these
/// page-specific labels can.
Future<bool> _inSendFlow(AppSession h) async {
  for (final marker in const [
    'Paste',
    'Send Max',
    'Select Signers',
    'Transaction Details',
  ]) {
    if (await h.exists(RegExp(marker))) return true;
  }
  return false;
}

/// Back out of the send flow (any page, including a nested tx-details sheet) until the wallet
/// home is showing again.
Future<void> _abortSendFlow(AppSession h) async {
  for (var i = 0; i < 12; i++) {
    if (!await _inSendFlow(h)) return;
    await h.dismissSheetOrDialog();
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
  throw StateError('could not back out of the send flow to the wallet home');
}

/// Open the Send flow from the wallet home, past the fresh-wallet backup nudge.
Future<void> _openSend(AppSession h) async {
  await h.tap('Send');
  await h.waitFor(RegExp('Paste|Later'), timeout: const Duration(seconds: 30));
  if (await h.exists('Later')) await h.tap('Later');
  await h.waitFor('Paste');
}

/// Type the recipient and advance to the amount page, confirming the custom-feerate dialog when
/// regtest has no fee estimates. Ends on the amount page — or on the no-spend dialog when the
/// nonce cap blocks the flow at entry (the caller checks which).
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

/// The available amount in sats parsed off the amount page. SatoshiText renders 8-decimal BTC
/// ("0.01 498 233 ₿"), so its digits ARE the zero-padded sat value. The amount lives in the Send
/// Max button's label when semantics merge, else in the page's lone ₿-bearing label.
Future<int> _sendMaxSats(AppSession h) async {
  final labels = await h.semantics().grep(RegExp('Send Max'));
  if (labels.isEmpty) throw StateError('no Send Max label on screen');
  var digits = labels.first.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.isEmpty) {
    final btc = await h.semantics().grep(RegExp('₿'));
    if (btc.isEmpty) {
      throw StateError('no amount found near Send Max (labels: $labels)');
    }
    digits = btc.first.replaceAll(RegExp(r'[^0-9]'), '');
  }
  return int.parse(digits);
}

/// Disconnect every device so the next flow starts clean. A device left connected across flows
/// keeps its own pending-action modal ("Sign transaction with connected device") on screen,
/// which occludes the tx-details signature counter, and — connected — it silently replenishes
/// nonces, undoing a drain.
Future<void> _disconnectAll(AppSession h) async {
  for (var n = _deviceCount; n >= 1; n--) {
    if (await h.device(n).isConnected()) await h.unplug(n);
  }
}

/// Sign the started session with [signers] connected ONE AT A TIME, then broadcast. Only the
/// current signer is connected, so once it confirms its own action-modal closes and the
/// tx-details counter is readable: intermediate signers tick "i/threshold", the LAST signer
/// flips the tile to the persistent "Signed" state (its N/N frame can vanish unpainted).
Future<void> _signAndBroadcast(AppSession h, List<int> signers) async {
  await _disconnectAll(h);
  for (var i = 0; i < signers.length; i++) {
    if (i > 0) await h.unplug(signers[i - 1]);
    await h.plug(signers[i]);
    final isLast = i == signers.length - 1;
    final signal = isLast ? RegExp('Signed') : RegExp('${i + 1}/$_threshold');
    var ok = false;
    for (var round = 0; round < 10 && !ok; round++) {
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
      throw StateError('signer ${signers[i]} never contributed its share');
    }
  }
  await _disconnectAll(h);
  await h.tap(RegExp('Broadcast'));
  await h.waitFor(RegExp('Sending'), timeout: const Duration(seconds: 30));
}

/// Wait for the node to index [address] receiving an amount in [floor, ceil]; returns it.
Future<int> _awaitReceived(
  SimFaucet faucet,
  String address,
  int floor,
  int ceil,
) async {
  var received = 0;
  for (var i = 0; i < 40 && (received < floor || received > ceil); i++) {
    received = await faucet.addressBalanceSat(address);
    if (received < floor || received > ceil) {
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }
  return received;
}

Future<void> main() async {
  await SimHarness.runScenario(
    'nonce_limit',
    (h) async {
      final videoDir = Directory('build/nonce_limit_videos')
        ..createSync(recursive: true);
      String video(String name) => '${videoDir.path}/$name.mp4';

      await h.createWallet(
        name: 'SimNonce',
        deviceCount: _deviceCount,
        devicePrefix: 'SimDev',
      );

      // Receive address off the Share Address sheet (per-app keyed read, not the clipboard —
      // the system clipboard is process-global under parallel jobs).
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
        for (var i = 0; i < _bigCount; i++) {
          await faucet.fund(address, _bigSats);
        }
        for (var i = 0; i < _smallCount; i++) {
          await faucet.fund(address, _smallSats);
        }
        await faucet.mine(1);
        await h.waitFor(
          RegExp('Received'),
          timeout: const Duration(seconds: 90),
        );
        await h.dismissSheetOrDialog();
        await h.waitForAbsent(RegExp('Share Address'));

        // ---- 1. TRUNCATION ----
        // An unrecorded pass first, doubling as the sync barrier: the capped available amount
        // only lands in range once (enough of) the 33 utxos are indexed. availableAmount is
        // shown on the Send Max button and rebuilds as the wallet syncs, so polling reads it.
        await _openSend(h);
        await _enterRecipient(h, await faucet.faucetAddress());
        var available = 0;
        for (var round = 0; round < 90; round++) {
          available = await _sendMaxSats(h);
          if (available >= _cappedFloor && available <= _cappedCeil) break;
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        if (available < _cappedFloor || available > _cappedCeil) {
          throw StateError(
            'capped available never reached [$_cappedFloor, $_cappedCeil]; last: $available '
            '(expected the $_bigCount largest utxos minus fees once synced)',
          );
        }
        await _abortSendFlow(h);

        // The recorded pass: a fresh flow re-arms the once-per-flow dialog. Recording starts
        // after recipient entry — typing an address through the android IME would eat most of
        // screenrecord's 180s cap.
        final truncAddr = await faucet.faucetAddress();
        await _openSend(h);
        await _enterRecipient(h, truncAddr);
        await _record(h, video('1-truncation'), () async {
          await h.tap(RegExp('Send Max'));
          await h.waitFor(RegExp('Send amount limited'));
          await h.screenshot('nonce-limit-dialog');
          await h.tap('OK');
          await h.tapUntil('Confirm amount', RegExp('Select Signers'));
          await _startSigners(h, [1, 2]);
          await _signAndBroadcast(h, [1, 2]);
        });
        await faucet.mine(1);
        await h.waitFor(RegExp('Sent'), timeout: const Duration(seconds: 90));
        await _abortSendFlow(h);

        // Node-side proof of "truncate to the largest": the 30 big coins (minus fee) arrived,
        // the 3 small ones did not.
        final truncReceived = await _awaitReceived(
          faucet,
          truncAddr,
          _cappedFloor,
          _cappedCeil,
        );
        if (truncReceived < _cappedFloor || truncReceived > _cappedCeil) {
          throw StateError(
            'truncated send-max should deliver the $_bigCount largest coins minus fee '
            '([$_cappedFloor, $_cappedCeil]); node got $truncReceived',
          );
        }

        // ---- 2. SUCCESS ----
        // Small send from the leftover small coins: under the cap, so no dialog, exact arrival.
        final successAddr = await faucet.faucetAddress();
        await _openSend(h);
        await _enterRecipient(h, successAddr);
        await _record(h, video('2-success'), () async {
          await h.enterFocusedText('$_successSendSats');
          if (await h.exists(RegExp('Send amount limited'))) {
            throw StateError('nonce dialog fired for an under-cap send');
          }
          await h.tapUntil('Confirm amount', RegExp('Select Signers'));
          await _startSigners(h, [1, 2]);
          await _signAndBroadcast(h, [1, 2]);
        });
        await faucet.mine(1);
        await h.waitFor(RegExp('Sent'), timeout: const Duration(seconds: 90));
        await _abortSendFlow(h);
        final successReceived = await _awaitReceived(
          faucet,
          successAddr,
          _successSendSats,
          _successSendSats,
        );
        if (successReceived != _successSendSats) {
          throw StateError(
            'ordinary send should deliver exactly $_successSendSats sats; node got $successReceived',
          );
        }

        stdout.writeln(
          'NONCE_LIMIT_DRIVE_OK: send-max truncated to the $_bigCount largest coins '
          '(node got $truncReceived), ordinary send exact ($successReceived)',
        );
      } finally {
        await faucet.close();
      }
    },
    deviceCount: _deviceCount,
    withRegtest: true,
  );
}

/// Select [signers] on the signers page, tap Sign transaction, and leave on the tx-details page.
Future<void> _startSigners(AppSession h, List<int> signers) async {
  for (final d in signers) {
    await h.tap(RegExp('SimDev$d'));
  }
  await h.waitFor(RegExp('Sign transaction'));
  await h.tap(RegExp('Sign transaction'));
}
