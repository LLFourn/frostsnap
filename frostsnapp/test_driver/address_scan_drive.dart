import 'dart:io';

import 'sim_harness.dart';

// The send page's recipient scanner reads the sim camera. It used to pick a scanner by platform
// (the real camera on Android and macOS), so a plain-text QR could not reach it at all. Scans a
// bare address, then a `bitcoin:` URI for a different one, and asserts the recipient the send flow
// accepted each time — read from the page, not assumed from the scan.
//
// Run: `./fsim test address_scan` (and with `--android`).
Future<void> main() async {
  await SimHarness.runScenario('address_scan', withRegtest: true, (h) async {
    final faucet = await h.faucet();
    final first = await faucet.faucetAddress();
    final second = await faucet.faucetAddress();
    await h.createWallet(name: 'SimScan');

    await h.tap('Send');
    await h.waitFor(
      RegExp('Paste|Later'),
      timeout: const Duration(seconds: 30),
    );
    if (await h.exists('Later')) await h.tap('Later');
    await h.waitFor('Scan');

    await _scan(h, first);
    await _expectRecipient(h, first);

    // Back to the recipient step, and a URI this time. Cleared first: the scene keeps showing its
    // last image, and the new scanner would read the old address before the URI went up.
    await h.hideQr();
    await h.tap(RegExp('^Recipient'));
    await h.waitFor('Scan');
    await _scan(h, 'bitcoin:$second?amount=0.001');
    await _expectRecipient(h, second);

    await h.hideQr();
    await faucet.close();
    stdout.writeln(
      'ADDRESS_SCAN_OK: a scanned address and a scanned bitcoin: URI each became the recipient',
    );
  });
}

Future<void> _scan(AppSession h, String text) async {
  await h.tap('Scan');
  await h.waitFor('Scan Address');
  await h.showQr(text);
  await h.waitForAbsent('Scan Address', timeout: const Duration(seconds: 20));
  // Regtest has no fee estimates, so the first recipient may bring up the feerate dialog; its
  // custom tile is always selectable.
  if (await h.exists(RegExp('Custom'))) {
    await h.tapUntil(RegExp('Custom'), 'Confirm');
    await h.tap('Confirm');
  }
}

/// The completed-recipient tile shows the address in groups of four.
Future<void> _expectRecipient(AppSession h, String address) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  List<String> tiles = const [];
  while (DateTime.now().isBefore(deadline)) {
    tiles = await h.semantics().grep(RegExp('^Recipient'));
    if (tiles.any((t) => t.replaceAll(RegExp(r'\s'), '').contains(address))) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  throw StateError(
    'expected the recipient to be $address, the page shows $tiles',
  );
}
