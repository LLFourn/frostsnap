import 'dart:async';
import 'dart:io';

import 'package:frostsnap/sim_faucet.dart';

import 'sim_harness.dart';

// Films the device sign prompt's self-spend screens: four hand-built PSBTs — an
// ordinary send (unchanged), a pure self-spend, a send that also pays one of our
// own receive addresses, and a self-spend whose fee trips the proportional
// high-fee warning (impossible before the self screen existed) — plus the app's
// own Send flow paying the wallet's own receive address. Each signing is
// sampled off the device framebuffer (device(1).screen) into
// build/self-spend-videos/<scenario>/frame_*.png for ffmpeg assembly.
//
// The PSBTs are built node-level (createpsbt + descriptorprocesspsbt over the
// wallet's own descriptor) for exact control of outputs and fee; the final
// scenario goes through the Send flow itself, which classifies recipients the
// wallet derives as Local since recognise-own-address.
//
// Run: `./fsim test self_spend_videos`.

const int _confirmX = 120;
const int _confirmY = 215;

/// One funded UTXO per scenario so no scenario depends on another's broadcast.
const List<int> _utxoSats = [10000000, 10000000, 10000000, 1000000];

class _Scenario {
  const _Scenario(this.name, this.utxo, this.pages);

  final String name;
  final int utxo;

  /// Device page count for the scripted walkthrough (swipes = pages - 1); a
  /// recovery loop covers a missed swipe, so this only paces the film.
  final int pages;
}

String _btc(int sats) {
  final s = sats.toString().padLeft(9, '0');
  return '${s.substring(0, s.length - 8)}.${s.substring(s.length - 8)}';
}

class _ScreenSampler {
  _ScreenSampler(this.h, this.dir);

  final AppSession h;
  final Directory dir;
  Timer? _timer;
  int _n = 0;
  bool _busy = false;

  void start() {
    dir.createSync(recursive: true);
    _timer = Timer.periodic(const Duration(milliseconds: 125), (_) async {
      // A slow capture must not stack behind itself; dropping frames is fine.
      if (_busy) return;
      _busy = true;
      try {
        final path = '${dir.path}/frame_${'$_n'.padLeft(5, '0')}.png';
        _n++;
        await h.device(1).screen(path);
      } catch (_) {
        // Sampling must never kill the drive.
      } finally {
        _busy = false;
      }
    });
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    while (_busy) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}

/// Film device 1 signing: sample its framebuffer while [trigger] dispatches the
/// sign request, walk the prompt at film pace, hold to sign, then broadcast and
/// dismiss so the next scenario starts from the wallet home.
Future<void> _filmSigning(
  AppSession h,
  SimFaucet faucet,
  String name,
  int pages,
  Future<void> Function() trigger,
) async {
  final sampler = _ScreenSampler(h, Directory('build/self-spend-videos/$name'))
    ..start();
  try {
    await trigger();

    // Paced walkthrough for the film: settle on each page, then swipe.
    await Future<void>.delayed(const Duration(seconds: 2));
    for (var i = 0; i < pages - 1; i++) {
      await h
          .device(1)
          .swipe(120, 240, 120, 80, const Duration(milliseconds: 250));
      await Future<void>.delayed(const Duration(milliseconds: 1800));
    }
    await h
        .device(1)
        .holdConfirm(_confirmX, _confirmY, const Duration(milliseconds: 3400));
    var ok = await h.exists(RegExp('Signed'));
    for (var round = 0; round < 8 && !ok; round++) {
      await h
          .device(1)
          .swipe(120, 240, 120, 80, const Duration(milliseconds: 250));
      await h
          .device(1)
          .holdConfirm(
            _confirmX,
            _confirmY,
            const Duration(milliseconds: 3400),
          );
      ok = await h.exists(RegExp('Signed'));
    }
    if (!ok) {
      throw StateError('$name: the device never signed');
    }
    await Future<void>.delayed(const Duration(milliseconds: 800));
  } finally {
    await sampler.stop();
  }

  // Broadcasting keeps the wallet's activity truthful but isn't what's on
  // film, and this sheet's labels vary by flow — so try, don't gate.
  var canBroadcast = false;
  for (var i = 0; i < 15 && !canBroadcast; i++) {
    canBroadcast = await h.exists(RegExp('Broadcast'));
    if (!canBroadcast) {
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }
  if (canBroadcast) {
    await h.tap(RegExp('Broadcast'));
    await Future<void>.delayed(const Duration(seconds: 2));
    await faucet.mine(1);
    await Future<void>.delayed(const Duration(seconds: 3));
  }
  await h.dismissSheetOrDialog();
  await Future<void>.delayed(const Duration(seconds: 1));
  stdout.writeln('SELF_SPEND_VIDEO_OK: $name');
}

Future<int> _voutOf(SimFaucet faucet, String txid, String address) async {
  final tx = await faucet.rpc('getrawtransaction', [txid, true]) as Map;
  for (final v in tx['vout'] as List) {
    final out = v as Map;
    if ((out['scriptPubKey'] as Map)['address'] == address) {
      return out['n'] as int;
    }
  }
  throw StateError('no output of $txid pays $address');
}

Future<String> _singleDescriptor(
  SimFaucet faucet,
  String multipath,
  int keychain,
) async {
  final single = multipath.replaceAll('<0;1>', '$keychain').split('#').first;
  final info = await faucet.rpc('getdescriptorinfo', [single]) as Map;
  return info['descriptor'] as String;
}

Future<void> main() async {
  await SimHarness.runScenario(
    'self_spend_videos',
    (h) async {
      await h.createWallet(name: 'SelfSpend', deviceCount: 1);

      final faucet = await h.faucet();
      try {
        // Reveal the wallet's first receive address; it doubles as the
        // self-payment target (ownership, not novelty, is what's on film).
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

        // Vouts must be resolved while the txs are still in the mempool:
        // the node runs without -txindex, so getrawtransaction goes blind
        // once they confirm.
        final utxos = <(String, int)>[];
        for (final sats in _utxoSats) {
          final txid = await faucet.fund(address, sats);
          utxos.add((txid, await _voutOf(faucet, txid, address)));
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
        await h.dismissSheetOrDialog();
        await h.waitForAbsent(RegExp('Share Address'));

        final descriptor = await h.walletDescriptor();
        final recvDesc = await _singleDescriptor(faucet, descriptor, 0);
        final chgDesc = await _singleDescriptor(faucet, descriptor, 1);
        final changeAddr =
            ((await faucet.rpc('deriveaddresses', [
                          chgDesc,
                          [0, 0],
                        ]))
                        as List)
                    .single
                as String;
        final foreignAddr = await faucet.faucetAddress();

        final scenarios = <(_Scenario, List<Map<String, String>>)>[
          (
            const _Scenario('ordinary-send', 0, 4),
            [
              {foreignAddr: _btc(6000000)},
              {changeAddr: _btc(3998000)},
            ],
          ),
          (
            const _Scenario('pure-self-spend', 1, 3),
            [
              {address: _btc(9998000)},
            ],
          ),
          (
            const _Scenario('send-plus-self-output', 2, 5),
            [
              {foreignAddr: _btc(4000000)},
              {address: _btc(3000000)},
              {changeAddr: _btc(2998000)},
            ],
          ),
          (
            // 70k fee on 930k moved: 7.5% — over the 5% rule, under the 100k
            // absolute rule, so this films the previously-dead warning path.
            const _Scenario('high-fee-self-spend', 3, 4),
            [
              {address: _btc(930000)},
            ],
          ),
        ];

        for (final (scenario, outputs) in scenarios) {
          final (txid, vout) = utxos[scenario.utxo];
          final raw = await faucet.rpc('createpsbt', [
            [
              {'txid': txid, 'vout': vout},
            ],
            outputs,
            0,
          ]);
          final processed =
              await faucet.rpc('descriptorprocesspsbt', [
                    raw,
                    [recvDesc, chgDesc],
                  ])
                  as Map;
          final psbt = processed['psbt'] as String;

          await h.tapTooltip('More');
          await h.tapUntil(
            RegExp('Sign a partially signed bitcoin transaction'),
            RegExp('Sign PSBT'),
          );
          await h.tap(RegExp('SimDev1'));
          if (!await h.device(1).isConnected()) {
            await h.plug(1);
          }
          await h.tapUntil('Scan', RegExp('Scan PSBT'));

          await _filmSigning(
            h,
            faucet,
            scenario.name,
            scenario.pages,
            () async {
              await h.showPsbtQr(psbt);
              // With the signer already plugged the app opens straight into the
              // signing sheet, whose merged labels the driver finder can't wait
              // on — so pace on time and let the Signed poll synchronize.
              await Future<void>.delayed(const Duration(seconds: 6));
              await h.hideQr();
            },
          );
        }

        // The fifth film goes through the app's OWN Send flow: after
        // recognise-own-address, a recipient the wallet derives is classified
        // Local, so a send-max to our own receive address reaches the device
        // as a pure self-spend.
        await h.tap('Send');
        await h.waitFor(
          RegExp('Paste|Later'),
          timeout: const Duration(seconds: 30),
        );
        if (await h.exists('Later')) await h.tap('Later');
        await h.waitFor('Paste');
        await h.enterFocusedText(address);
        await h.tapUntil('Confirm recipient', RegExp('Send Max|Custom'));
        if (await h.exists(RegExp('Custom'))) {
          await h.tapUntil(RegExp('Custom'), 'Confirm');
          await h.tap('Confirm');
        }
        await h.waitFor(RegExp('Send Max'));
        await h.tap(RegExp('Send Max'));
        await h.tapUntil('Confirm amount', RegExp('Select Signers'));
        // 1-of-1 may arrive pre-selected; a tap would deselect it.
        if (!await h.exists(RegExp('Sign transaction'))) {
          await h.tap(RegExp('SimDev1'));
        }
        await h.waitFor(RegExp('Sign transaction'));
        await _filmSigning(h, faucet, 'app-send-to-self', 3, () async {
          await h.tap(RegExp('Sign transaction'));
          await Future<void>.delayed(const Duration(seconds: 4));
        });

        stdout.writeln('SELF_SPEND_VIDEOS_DRIVE_OK: 5 scenarios filmed');
      } finally {
        await faucet.close();
      }
    },
    deviceCount: 1,
    withRegtest: true,
  );
}
