import 'dart:convert';
import 'dart:io';

import 'sim_harness.dart';

// sim-8 end-to-end: a full 1-of-1 keygen driven OUT OF PROCESS through the SimHarness. The keygen
// sequence (create → name → generate → device hold-confirm → unplug-to-finalize → wallet home) now
// lives in the reusable `AppSession.createWallet` flow (android-layout-e2e), so any test can reach a
// created wallet; this test's job is to keep that flow GREEN on the host — a regression in the flow
// (or an app-copy desync the flow targets by label) surfaces here.
//
// Devices are driven over the APP channel (driver-data → the FRB pool), the same on host and
// emulator — see `createWallet`. Run: `./fsim test keygen`. Needs a display (Xvfb on Linux CI).

const _confirmX = 120;
const _confirmY = 215;

Future<void> main() async {
  // runScenario auto-captures diagnostics (screenshot + device framebuffer + error +
  // app logs to build/sim-failures/keygen/) on any failure, then tears down.
  await SimHarness.runScenario('keygen', (h) async {
    await h.tapUntil(RegExp('Create a multi-sig wallet'), 'Wallet name');
    await h.enterText('Wallet name', 'SimTest');
    await h.tapUntil('Next', 'Device name 1');
    await h.enterText('Device name 1', 'SimDev1');
    await h.tapUntil('Continue with 1 device', 'Continue anyway');
    await h.tapUntil('Continue anyway', 'Generate keys');

    final semantics = h.semantics();
    final labels = await semantics.labels();
    if (!labels.contains('Generate keys')) {
      throw StateError(
        'semantics labels did not include "Generate keys": $labels',
      );
    }
    final grep = await semantics.grep('Generate keys');
    if (!grep.contains('Generate keys') || !await h.exists('Generate keys')) {
      throw StateError(
        'semantics grep did not match the targetable "Generate keys" label: $grep',
      );
    }
    final pretty = await semantics.pretty();
    if (!pretty.contains('Generate keys')) {
      throw StateError(
        'semantics pretty output omitted "Generate keys": $pretty',
      );
    }
    final snapshot = jsonDecode(await semantics.json()) as Map<String, dynamic>;
    if (snapshot['nodes'] is! List) {
      throw StateError(
        'semantics json did not contain a nodes list: $snapshot',
      );
    }

    await h.tapUntil('Generate keys', RegExp('Security Check'));

    var confirmed = false;
    for (var attempt = 0; attempt < 8 && !confirmed; attempt++) {
      await h.device(1).holdConfirm(_confirmX, _confirmY);
      confirmed = await h.exists('Yes');
    }
    if (!confirmed) {
      throw StateError('device never confirmed the security code');
    }

    await h.tap('Yes');
    await h.waitFor('Saving wallet to devices');
    await h.waitForAbsent(
      RegExp('Unplug devices to continue'),
      timeout: const Duration(milliseconds: 100),
    );
    await h.waitForAbsent(
      'Saving wallet to devices',
      timeout: const Duration(seconds: 10),
    );
    await h.waitFor(RegExp('Unplug devices to continue'));
    await h.device(1).setConnected(false);
    await h.waitFor(RegExp('Receive'));

    stdout.writeln('KEYGEN_DRIVE_OK: 1-of-1 wallet saved before unplug prompt');
  });
}
