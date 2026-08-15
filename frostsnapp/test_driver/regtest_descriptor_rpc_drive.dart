import 'dart:async';
import 'dart:io';

import 'package:frostsnap/sim_faucet.dart';

import 'sim_harness.dart';

// The faucet's raw-RPC escape hatch, proven end to end: a test-file-only recipe derives
// the app wallet's addresses INDEPENDENTLY of the app — its exported multipath
// descriptor rewritten to one keychain, re-checksummed by `getdescriptorinfo`, expanded
// by `deriveaddresses` — and external index 0 must equal the address the app itself
// displays. This is the exact derivation an on-chain change/receive-index assertion
// needs (e.g. "the first send's change lands on internal index 0"), demonstrated with
// ZERO fsim library code: everything below the harness surface is composed here.
//
// Run: `./fsim test regtest_descriptor_rpc`. Needs a display (Xvfb on Linux CI); first
// run downloads bitcoind + electrs.

/// Keychain `k` (0 = receive, 1 = change) at `index`, derived from the app's exported
/// descriptor using only bitcoind RPC — the COMMANDS.md recipe, verbatim.
Future<String> deriveAppAddress(
  SimHarness h,
  SimFaucet faucet, {
  required int keychain,
  required int index,
}) async {
  final descriptor = await h.walletDescriptor();
  if (!descriptor.contains('<0;1>')) {
    throw StateError('expected a multipath descriptor, got "$descriptor"');
  }
  final single = descriptor.replaceAll('<0;1>', '$keychain').split('#').first;
  final info = await faucet.rpc('getdescriptorinfo', [single]);
  final canonical = (info as Map)['descriptor'] as String;
  final addrs = await faucet.rpc('deriveaddresses', [
    canonical,
    [index, index],
  ]);
  return (addrs as List).single as String;
}

Future<void> main() async {
  await SimHarness.runScenario(
    'regtest_descriptor_rpc',
    (h) async {
      await h.createWallet(name: 'SimRpc');

      // The app's own claim: the address it displays on the Share Address sheet
      // (a fresh wallet's first receive — external keychain, index 0).
      await h.tap(RegExp('Receive'));
      await h.waitFor('Later');
      await h.tap('Later');
      await h.waitFor(RegExp('Share Address'));
      var displayed = '';
      for (var i = 0; i < 10 && !displayed.startsWith('bcrt1'); i++) {
        displayed = (await h.getTextByKey(
          'receiveAddress',
        )).replaceAll(RegExp(r'\s'), '');
        if (!displayed.startsWith('bcrt1')) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }
      if (!displayed.startsWith('bcrt1')) {
        throw StateError('expected a bcrt1 receive address, got "$displayed"');
      }

      final faucet = await h.faucet();
      try {
        final derived = await deriveAppAddress(
          h,
          faucet,
          keychain: 0,
          index: 0,
        );
        if (derived != displayed) {
          throw StateError(
            'independent derivation disagrees with the app: derived $derived, '
            'app displays $displayed',
          );
        }
        // The change keychain derives too (the half an index-burn assertion uses);
        // it must be a valid, DISTINCT address.
        final change = await deriveAppAddress(h, faucet, keychain: 1, index: 0);
        if (!change.startsWith('bcrt1') || change == derived) {
          throw StateError(
            'change derivation should yield a distinct bcrt1 address, got "$change"',
          );
        }
        stdout.writeln(
          'REGTEST_DESCRIPTOR_RPC_OK: independent derivation matches the app '
          '($derived); change keychain derives distinctly',
        );
      } finally {
        await faucet.close();
      }
    },
    deviceCount: 1,
    withRegtest: true,
  );
}
