import 'dart:async';
import 'dart:io';

import 'sim_harness.dart';

// Restore-from-db end-to-end (fsim-app-restart): build a wallet on runtime-added
// devices, fund it, SAVE each device's durable state, then kill and relaunch the app
// IN PLACE — same sqlite db — and assert the restore: the wallet is present with its
// balance after resync, the devices come back FROM their saved states under fresh
// numbers with the same identities and their names, and a send signs on-device,
// broadcasts, and confirms. This is the app-persistence path no other e2e touches:
// every other scenario starts from a virgin database.
//
// Run: `./fsim test app_restart [--android]`. Needs a display (Xvfb on Linux CI);
// first run downloads bitcoind + electrs.

const int _fundSats = 100000000;
const int _sendSats = 25000000;

/// Device hold-to-confirm button point (sim-3 calibration).
const int _confirmX = 120;
const int _confirmY = 215;

Future<void> main() async {
  await SimHarness.runScenario(
    'app_restart',
    (h) async {
      // 1. A 1-of-1 wallet on a RUNTIME-added device (deviceCount: 0 — the fleet is
      //    built by the test, exactly what a restarted session must also do).
      final dev = await h.addDevice();
      stdout.writeln('device: $dev');
      await h.createWallet(name: 'SimRestart');

      // 2. Receive a confirmed coin.
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

        // 3. Pocket the device (unplug → save state), then RESTART the app in place.
        final idBefore = await h.device(dev).deviceId();
        final fleetBefore = await h.deviceNumbers();
        await h.disconnect(dev);
        final saved = await h.saveDeviceState(dev);
        await h.restartApp();

        // 4. The db restored: the wallet is back by NAME with zero devices attached,
        //    and the balance returns once the chain resyncs.
        await h.waitFor(
          RegExp('SimRestart'),
          timeout: const Duration(seconds: 60),
        );
        final atRestart = await h.deviceNumbers();
        if (atRestart.isNotEmpty) {
          throw StateError(
            'a restarted app must meet zero devices, got $atRestart',
          );
        }

        // 5. The device comes back from its saved state: EXACTLY the number the
        //    old generation promised next (the seed is honored precisely, even on
        //    android where the relaunched APK's baked-in device is converged away
        //    first), with the SAME identity, recognized under its wallet name.
        final promisedNext = fleetBefore.reduce((a, b) => a > b ? a : b) + 1;
        final restored = await h.addDeviceFromSavedState(saved);
        if (restored != promisedNext) {
          throw StateError(
            'numbering must continue EXACTLY across the restart '
            '(fleet was $fleetBefore, expected $promisedNext, got $restored)',
          );
        }
        if (await h.device(restored).deviceId() != idBefore) {
          throw StateError('the restored device must keep its identity');
        }
        // Recognition gate: setConnected is idempotent on the already-connected
        // device and WAITS until the coordinator has re-registered the chain —
        // the device announces under its persisted name from the restored db.
        await h.device(restored).setConnected(true);

        // 6. The restored wallet + device still SIGN: a partial send (change must
        //    exist), signed on-device, broadcast, mined, and marked Sent.
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
        if (await h.exists(RegExp('Custom'))) {
          await h.tapUntil(RegExp('Custom'), 'Confirm');
          await h.tap('Confirm');
        }
        await h.waitFor(RegExp('Send Max'));
        await h.enterFocusedText('$_sendSats');
        await h.tapUntil('Confirm amount', RegExp('Select Signers'));
        await h.tap(RegExp('SimDev1'));
        await h.waitFor(RegExp('Sign transaction'));
        await h.tap(RegExp('Sign transaction'));
        var signed = false;
        for (var round = 0; round < 8 && !signed; round++) {
          await h
              .device(restored)
              .swipe(120, 240, 120, 80, const Duration(milliseconds: 250));
          await h
              .device(restored)
              .holdConfirm(
                _confirmX,
                _confirmY,
                const Duration(milliseconds: 3200),
              );
          signed = await h.exists(RegExp('Signed'));
        }
        if (!signed) {
          throw StateError(
            'the restored device never contributed its signature',
          );
        }
        await h.tap(RegExp('Broadcast'));
        await h.waitFor(
          RegExp('Sending'),
          timeout: const Duration(seconds: 30),
        );
        await faucet.mine(1);
        await h.waitFor(RegExp('Sent'), timeout: const Duration(seconds: 90));

        // 7. Edge paths, in ONE extra relaunch: the restart span is one generation
        //    transaction, so an overlapping restart must be rejected MID-SPAN (after
        //    the new app is up, before converge/seed/readiness), and a failure there
        //    must be a FAILED restart — terminal, firing the daemon-teardown signal.
        final reached = Completer<void>();
        final release = Completer<void>();
        h.restartPostLaunchGate = () async {
          reached.complete();
          await release.future;
          throw StateError('injected post-launch failure');
        };
        final failing = h.restartApp();
        await reached.future.timeout(const Duration(minutes: 4));
        Object? overlap;
        try {
          await h.restartApp();
        } catch (e) {
          overlap = e;
        }
        if (!'$overlap'.contains('already in flight')) {
          throw StateError(
            'an overlapping restart must be rejected mid-span, got: $overlap',
          );
        }
        release.complete();
        Object? failure;
        try {
          await failing;
        } catch (e) {
          failure = e;
        }
        if (!'$failure'.contains('injected post-launch failure')) {
          throw StateError(
            'a post-launch failure must fail the restart, got: $failure',
          );
        }
        h.restartPostLaunchGate = null;
        Object? afterDead;
        try {
          await h.restartApp();
        } catch (e) {
          afterDead = e;
        }
        if (!'$afterDead'.contains('dead')) {
          throw StateError(
            'a failed restart must be terminal, got: $afterDead',
          );
        }
        final teardown = await h.appExitCode.timeout(
          const Duration(seconds: 15),
        );
        if (teardown != -1) {
          throw StateError(
            'a failed restart must fire the daemon-teardown signal '
            '(marker -1), got $teardown',
          );
        }

        stdout.writeln(
          'APP_RESTART_OK: db restored (wallet + balance), device $dev came back '
          'as $restored with its identity, the restored pair signed a send, and '
          'the failed-restart edge paths held (overlap rejected, terminal death)',
        );
      } finally {
        await faucet.close();
      }
    },
    deviceCount: 0,
    withRegtest: true,
  );
}
