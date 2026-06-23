import 'dart:async';
import 'dart:io';

import 'package:frostsnap/sim_faucet.dart';

import 'regtest.dart' show regtestControlSocket;
import 'sim_harness.dart';

// regtest-bitcoin-receiving end-to-end: create a (default-Regtest) wallet, fund its REAL receive
// address from the faucet, and assert the wallet sees the coins over the genuine electrum sync
// path — no faucet mock, no manual GUI tapping. `withRegtest: true` brings up (or attaches to)
// the sim_regtest backend and points the app's regtest wallet at its electrs.
//
// Run: `./simctl test regtest_receive` (or `dart run test_driver/regtest_receive_drive.dart`).
// Needs a display (Xvfb on Linux CI); first run downloads bitcoind + electrs.

/// The keygen security-code confirm button on the device's KeygenCheck screen (sim-3 calibration).
const int _confirmX = 120;
const int _confirmY = 215;

/// Fund a whole 1 BTC so the asserted balance is unmistakable.
const int _fundSats = 100000000;

Future<void> main() async {
  await SimHarness.runScenario('regtest_receive', (h) async {
    // 1. Keygen a 1-of-1 wallet. In a faucet-wired sim it defaults to Regtest, so its receive
    //    addresses are regtest (bcrt1…) and faucet funds land.
    // Name avoids the substring "Receive" so `RegExp('Receive')` later targets only the Receive
    // button, not the wallet's own card/title.
    await h.tapUntil(RegExp('Create a multi-sig wallet'), 'Wallet name');
    await h.enterText('Wallet name', 'SimRegtest');
    await h.tapUntil('Next', 'Device name 1');
    await h.enterText('Device name 1', 'SimDev');
    await h.tapUntil('Continue with 1 device', 'Continue anyway');
    await h.tapUntil('Continue anyway', 'Generate keys');
    await h.tapUntil('Generate keys', RegExp('Security Check'));

    var confirmed = false;
    for (var i = 0; i < 6 && !confirmed; i++) {
      await h.device(1).holdConfirm(_confirmX, _confirmY);
      confirmed = await h.exists('Yes');
    }
    if (!confirmed) {
      throw StateError('device never confirmed the security code');
    }
    await h.tapUntil('Yes', RegExp('Unplug devices to continue'));
    await h.unplug();
    await h.waitFor(RegExp('Receive'));

    // 2. Open Receive and copy the wallet's address. A fresh wallet has incomplete backups, so a
    //    "secure your wallet" nudge intercepts Receive; choosing "Later" makes the wallet proceed
    //    to open the receive sheet. The address Text has no stable label, so read it from the
    //    clipboard via the Copy button.
    await h.tap(RegExp('Receive'));
    await h.waitFor('Later');
    await h.tap('Later');
    // The Share Address tile merges its title with the trailing "Address #N" into one composite
    // semantics label, so match a substring.
    await h.waitFor(RegExp('Share Address'));
    await h.tap('Copy');

    // Copy is async; poll the clipboard until the address lands.
    var address = '';
    for (var i = 0; i < 10 && !address.startsWith('bcrt1'); i++) {
      address = (await h.getClipboard()).trim();
      if (!address.startsWith('bcrt1')) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    if (!address.startsWith('bcrt1')) {
      throw StateError(
        'expected a regtest (bcrt1) receive address, got: "$address"',
      );
    }

    // 3. Fund it from the faucet — the same SimFaucet client `./simctl regtest fund` uses; the
    //    backend sends and auto-mines one block, so the receive confirms.
    final faucet = await SimFaucet.connect(regtestControlSocket);
    try {
      await faucet.fund(address, _fundSats);
    } finally {
      await faucet.close();
    }

    // 4. The app's REAL electrum sync should reflect the received 1 BTC as the wallet balance
    //    (allow generous time for electrs to index + the streaming client to pick it up).
    await h.waitFor(
      RegExp(r'1\.00 000 000'),
      timeout: const Duration(seconds: 90),
    );
    stdout.writeln(
      'REGTEST_RECEIVE_DRIVE_OK: wallet received 1 BTC over real electrum sync',
    );
  }, withRegtest: true);
}
