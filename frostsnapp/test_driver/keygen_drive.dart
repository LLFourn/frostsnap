import 'dart:io';

import 'sim_harness.dart';

// sim-8 end-to-end: a full 1-of-1 keygen driven OUT OF PROCESS through the SimHarness. The keygen
// sequence (create → name → generate → device hold-confirm → unplug-to-finalize → wallet home) now
// lives in the reusable `AppSession.createWallet` flow (android-layout-e2e), so any test can reach a
// created wallet; this test's job is to keep that flow GREEN on the host — a regression in the flow
// (or an app-copy desync the flow targets by label) surfaces here.
//
// Devices are driven over the APP channel (driver-data → the FRB pool), the same on host and
// emulator — see `createWallet`. Run: `./simctl test keygen`. Needs a display (Xvfb on Linux CI).

Future<void> main() async {
  // runScenario auto-captures diagnostics (screenshot + device framebuffer + error +
  // app logs to build/sim-failures/keygen/) on any failure, then tears down.
  await SimHarness.runScenario('keygen', (h) async {
    await h.createWallet(name: 'SimTest');
    stdout.writeln('KEYGEN_DRIVE_OK: 1-of-1 wallet created via createWallet');
  });
}
