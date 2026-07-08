# sim-7-e2e-keygen-driver
# sim-7: end-to-end keygen driver (the deliverable)

## Goal
A single deterministic run that completes a **1-of-1 keygen by sending button presses to BOTH the
app and the device** — the stated epic goal: "an app running with a single virtual device … run
through keygen … by sending button presses to the app and the device."

## Core model (read first)
One **in-process Flutter `integration_test`**, two targeting schemes:
- **app** steps tap widgets by the `KeygenKeys` handles (sim-6) via `WidgetTester` (`find.byKey` +
  `tester.tap`/`enterText`). This runs **in the app's own isolate** — *not* over the Dart VM
  service — so the FRB-isolate reachability concern the research doc flagged (Axis 5) does not
  apply. `flutter_driver`/VM-service are NOT needed.
- **device** steps call `SimDevice.touch(x, y, liftUp)` directly (the same `simDevicePool` global
  the tray uses) — the device thread (sim-4) runs concurrently, so injected touches drive the real
  `FrostyUi` and the resulting `DeviceToCoordinator` messages round-trip over the in-memory pipe to
  the app's real `FfiCoordinator`.
Everything is one process: app + coordinator + device thread. This is the durable, replayable
artifact; the *interactive* computer-use path (a human/agent screenshotting + tapping the sim-5
tray) is a bonus already enabled by sim-5/6.

## Two facts that shape the implementation
1. **Only ONE device touch is needed — the keygen security-code confirm.** Unlike sim-3 (whose
   Rust `SimCoordinator` named the device via `Prompt`, needing a device name-confirm hold), the
   **app names the device via `updateNamePreview`** (`NameCommand::Preview`,
   wallet_create.dart:100/250/505), which sets the device's `pending_device_name` **directly**
   (`device_loop.rs:471`) — no device-side hold. So entering the device name in the app's keyed
   `deviceNameField` is the whole naming step; the device only has to hold-to-confirm the keygen
   security code (reuse sim-3's calibration: a held touch at ~(120,215) on the `KeygenCheck`
   screen, sustained ≥`HOLD_TO_CONFIRM_TIME_MS` (2000 ms) of real wall-clock).
2. **Real-time holds vs the tester clock.** The device hold is a wall-clock time-integral on the
   device thread; `tester.pump()` advances Flutter's fake clock, not the device's. So drive the
   device touch + the ≥2 s hold inside `tester.runAsync(() async { … await Future.delayed(…) })`
   while periodically `pump`ing the app so the coordinator-thread messages surface. Give generous
   real-time margin (the coordinator's ~100 ms magic cadence is also wall-clock).

## Tasks
1. Add the one missing handle sim-6 didn't key: `KeygenKeys.walletNameField` (the name-step
   `TextField`, `_nameController`) — small edit to `keygen_keys.dart` + `wallet_create.dart` (the
   tap-walk needs to type the wallet name deterministically). flutter analyze must stay clean.
2. Create `frostsnapp/integration_test/keygen_test.dart`. `IntegrationTestWidgetsFlutterBinding
   .ensureInitialized()`; `testWidgets(...)` calls the app's `main()` (run with
   `--dart-define=SIM=true` so it takes the `loadSim` branch) then `pumpAndSettle`. Grab the device
   via the `simDevicePool` global. (test_driver/integration_test.dart + the integration_test dep
   already exist.)
3. App tap-walk (by `KeygenKeys`): create-multisig entry → enter wallet name (`walletNameField`) →
   `primaryButtonForStep('name')` → enter device name (`deviceNameField`) →
   `primaryButtonForStep('devices')` → (nonce-replenish auto-advances) → set threshold = 1
   (`thresholdSelector`) → `primaryButtonForStep('threshold')` (Generate keys).
4. Device confirm (by touch, in `tester.runAsync`): once the app shows the Security Check, hold the
   keygen confirm on the device — `device.touch(120, 215, liftUp:false)` (re-assert each loop), let
   ≥2 s wall-clock pass while pumping, until the app's keygen state reaches all-acks.
5. App confirm: tap `KeygenKeys.confirmYes`; await `finalizeKeygen`.
6. Assert a finalized 1-of-1 wallet exists (the app's key/wallet state shows the new
   `AccessStructureRef`). Add a `just` recipe to run it (`flutter test integration_test/keygen_test.dart
   --dart-define=SIM=true`; offscreen under Xvfb on Linux CI; a display on macOS).

## Connect/disconnect control (manual plug/unplug)
A small per-device **connect/disconnect toggle** in the sim tray so a human (or the driver) can
simulate unplugging/replugging the USB device and watch the app react.

**Seam — `VirtualSerial::available_ports()` only.** This is the exact signal the real
`UsbSerialManager` uses to detect plug/unplug: each poll it diffs `available_ports()`, calls
`disconnect()` (→ `DeviceChange::Disconnected`, dropping the device from the app) for a port that
vanished, and re-opens + magic-handshakes a port that (re)appeared (`usb_serial_manager.rs`
:121/181/237). So the mechanism is one shared `connected: Arc<AtomicBool>` per `PortEntry`;
`available_ports()` skips entries that are `false`. **No coordinator change, no embedded change.**

**Reconnect is already handled by the portable `DeviceLoop`.** The device thread keeps running across
the toggle — only coordinator-side port *presence* flips. When the coordinator re-opens and re-writes
magic bytes, an `Established` device sees magic-bytes-while-established and `soft_reset`s back to
`PowerOn`, re-`Announce`ing (device_loop.rs:414-416 + the coord's `awaiting_magic` retry). So the
feature stays **leaf-only** (sim USB-transport leaf + FRB + Dart UI); no portable logic is touched.

7. **Connect/disconnect.**
   - `VirtualSerial`: give each `PortEntry` a shared `connected: Arc<AtomicBool>` (default true);
     `available_ports()` filters on it. `single(..)` creates the flag and exposes the `Arc` so
     `load_sim` can hand it to the matching `SimDevice`.
   - FRB: `SimDevice.setConnected(bool)` + `isConnected()` (`#[frb(sync)]`) flip/read the flag, so a
     tray toggle needs no Rust round-trip.
   - Dart: a small icon toggle in `_SimDeviceCell` (`sim_device_tray.dart`) — unplug when connected,
     plug-in when not — reflecting state; must not disturb the framebuffer/touch wiring.
   - Fallback (only if a re-handshake proves flaky from stale buffered pipe bytes): drain the
     device's pipe buffers on the connected→true edge (a `HostEnd`/`ByteChannel` clear). Not default.

## Acceptance
- The `integration_test` **compiles and analyzes clean** (`flutter analyze`) and is the committed,
  documented driver; `cargo check -p rust_lib_frostsnapp` builds; production paths untouched; esp
  builds; no SDL. These are the reviewers' disk-observable gate.
- **`cargo test -p frostsnap_virtual_device` is green** — the sim crate's own suite guards the whole
  device/transport leaf (registration, render, keygen, connect/disconnect) and must pass before any
  commit touching the sim. Its thread-timed tests must *wait* for conditions, never assert on a
  race.
- The connect/disconnect toggle builds + analyzes clean; **manual plug/unplug round-trips** (the
  device disappears from the app on disconnect and reappears + re-announces on reconnect) is the
  user's / CI's visual check, same split as the live keygen run below.
- **The actual run** (the test completing a 1-of-1 keygen → finalized wallet) is the **user's /
  CI's** verification — it needs a display (or Xvfb); the clank reviewers run commands, not a GUI.
  Document the exact run command. (Same split as sim-5: buildable artifact reviewed; live run is
  the human/CI step.)

## Open risk / fallback
If the in-process `integration_test` can't cleanly interleave the real-time device hold with the
tester clock (the `runAsync` + concurrent-thread timing), fall back to a **Rust orchestrator**
(the sim-3 `SimCoordinator` shape, but over the app's FFI types) paired with computer-use for the
visual app taps on the sim-5 tray — same keygen, same `KeygenKeys`, different harness. Note which
path landed and why.

## Depends on
sim-5 (sim app + tray + `simDevicePool`) and sim-6 (`KeygenKeys`); reuses sim-3's calibrated
device keygen-confirm touch.
