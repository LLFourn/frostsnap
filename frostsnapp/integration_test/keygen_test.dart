// End-to-end keygen driver (sim-7): a 1-of-1 keygen completed by sending button
// presses to BOTH the app (by KeygenKeys, via WidgetTester) and the device (by
// SimDevice.touch into the concurrent device thread). Runs entirely in the app's
// own isolate — no VM service / flutter_driver — over the real coordinator +
// in-memory transport.
//
// Run (needs a display, or Xvfb on Linux):
//   flutter test integration_test/keygen_test.dart -d macos --dart-define=SIM=true
//
// The device confirm is a real wall-clock hold-to-confirm (>=2000ms) on the
// concurrent device thread, so we let real time elapse via tester.runAsync()
// delays and pump() between them (NOT pump inside runAsync) to advance the
// stream-driven app UI.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frostsnap/global.dart';
import 'package:frostsnap/keygen_keys.dart';
import 'package:frostsnap/main.dart' as app;
import 'package:frostsnap/wallet_create.dart';
import 'package:integration_test/integration_test.dart';

/// The keygen security-code hold-to-confirm control on the device's KeygenCheck
/// screen (calibrated in sim-3: low-center of the 240x280 framebuffer).
const int _confirmX = 120;
const int _confirmY = 215;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('1-of-1 keygen via app buttons + device touch', (tester) async {
    await app.main();
    await tester.pumpAndSettle();

    final pool = simDevicePool;
    expect(
      pool,
      isNotNull,
      reason: 'sim pool missing — run with --dart-define=SIM=true',
    );
    final device = (await pool!.devices()).first;

    // Brief visible pause so a watcher can see the launched app before the
    // driver starts acting (harmless to the assertions).
    await tester.runAsync(() => Future.delayed(const Duration(seconds: 3)));
    await tester.pump();

    // Advance real wall-clock (the device + coordinator run on real OS threads,
    // off the tester's fake clock) while pumping the app, until [condition] holds.
    // [each] runs before each step (used to re-assert the held device touch).
    Future<void> pumpUntil(
      bool Function() condition, {
      Duration timeout = const Duration(seconds: 30),
      void Function()? each,
      String? reason,
    }) async {
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        if (condition()) return;
        each?.call();
        await tester.runAsync(
          () => Future.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
      fail('timed out after $timeout: ${reason ?? 'condition not met'}');
    }

    bool present(Key key) => find.byKey(key).evaluate().isNotEmpty;

    // 1. Enter the create-multisig flow.
    await tester.tap(find.byKey(KeygenKeys.createMultisigEntry));
    await tester.pumpAndSettle();

    // 2. Name the wallet, advance.
    await tester.enterText(
      find.byKey(KeygenKeys.walletNameField),
      'Sim Wallet',
    );
    await tester.pump();
    await tester.tap(find.byKey(KeygenKeys.primaryButtonForStep('name')));
    await tester.pumpAndSettle();

    // 3. Name the (already-connected) device, advance. Typing the name drives the
    //    coordinator's updateNamePreview, which sets the device's pending name
    //    directly (no device-side confirm needed for naming).
    await tester.enterText(
      find.byKey(KeygenKeys.deviceNameField),
      'Sim Device',
    );
    await tester.pump();
    await tester.tap(find.byKey(KeygenKeys.primaryButtonForStep('devices')));
    await tester.pumpAndSettle();

    // 4. Nonce replenish auto-advances to the threshold step (threshold defaults
    //    to 1 for a single device). Wait for, then tap, Generate keys.
    await pumpUntil(
      () => present(KeygenKeys.primaryButtonForStep('threshold')),
      reason: 'reach the threshold/Generate-keys step',
    );
    await tester.tap(find.byKey(KeygenKeys.primaryButtonForStep('threshold')));
    await tester.pump();

    // 5. Device confirm: hold the keygen security-code button on the device until
    //    the app reaches all-acks and shows the "Final check" dialog (confirmYes).
    //    Re-assert the touch each loop (the button latches Pressed; re-asserting
    //    guards the race where CheckKeyGen lands before the device renders it).
    await pumpUntil(
      () => present(KeygenKeys.confirmYes),
      timeout: const Duration(seconds: 60),
      each: () => device.touch(x: _confirmX, y: _confirmY, liftUp: false),
      reason: 'device confirms the security code (all acks)',
    );

    // 6. Confirm the codes match -> finalizeKeygen.
    await tester.tap(find.byKey(KeygenKeys.confirmYes));

    // 7. A successful finalize pops the create flow (Navigator.pop with the
    //    AccessStructureRef). Success = the create page is gone.
    await pumpUntil(
      () => find.byType(WalletCreatePage).evaluate().isEmpty,
      reason: 'create flow dismisses after a successful finalize',
    );
    expect(find.byType(WalletCreatePage), findsNothing);
  });
}
