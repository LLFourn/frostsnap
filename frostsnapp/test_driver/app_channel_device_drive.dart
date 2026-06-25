import 'dart:io';

import 'sim_harness.dart';

// app-channel-only-device-driving Task 1: smoke-test the device-driving endpoints added to the app
// channel (_driveDevice / driver-data), so `device(n)` can route over them on host AND emulator
// instead of the host-only `device-<n>.sock`. Drives each new endpoint DIRECTLY over the app channel
// and asserts a sensible response; the chain assertions are deterministic round-trips this test
// drives (set-chain → is-connected/chain), not dependent on initial state. Host-runnable.
// Run: `./simctl test app_channel_device`.
Future<void> main() async {
  await AppSession.runScenario('app-channel-device', (h) async {
    final d = h.driver;
    Future<String> req(String cmd) =>
        d.runUnsynchronized(() => d.requestData(cmd));

    // device-id: a non-empty stable id.
    final id = await req('device-id:1');
    if (id.isEmpty) throw 'device-id:1 returned empty';

    // set-chain → chain / is-connected round-trip (the pool is the single source of truth).
    await req('device-set-chain:1');
    if (await req('device-chain') != '1') {
      throw 'expected chain "1" after set-chain:1, got "${await req('device-chain')}"';
    }
    if (await req('device-is-connected:1') != 'true') {
      throw 'expected device 1 connected after set-chain:1';
    }
    await req('device-set-chain:'); // empty = unplug everything
    if (await req('device-chain') != '') {
      throw 'expected empty chain after set-chain:, got "${await req('device-chain')}"';
    }
    if (await req('device-is-connected:1') != 'false') {
      throw 'expected device 1 disconnected after empty set-chain';
    }
    await req('device-set-chain:1'); // restore

    // device-screen: a base64 PNG ("iVBOR" is the base64 of the PNG magic \x89PNG\r). The endpoint
    // snapshots the framebuffer DIRECTLY (not via the frame stream), so it never steals the live tray
    // subscriber — assert it round-trips, then again AFTER driving the device, proving it's a
    // repeatable, non-destructive snapshot.
    void expectPng(String shot, String when) {
      if (!shot.startsWith('iVBOR')) {
        throw 'device-screen:1 $when is not a base64 PNG (got "${shot.substring(0, shot.length.clamp(0, 12))}…")';
      }
    }

    expectPng(await req('device-screen:1'), 'before tap');

    // device-tap: composes touch down+up; just assert it doesn't throw.
    await req('device-tap:1:120:140');

    expectPng(await req('device-screen:1'), 'after tap');

    stdout.writeln(
      'APP_CHANNEL_DEVICE_OK: id/chain/set-chain/is-connected/screen(x2)/tap all respond over the app channel',
    );
  });
}
