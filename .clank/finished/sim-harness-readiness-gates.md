# sim-harness-readiness-gates
# sim-harness-readiness-gates — recognition-synchronous device presence + positive semantics-ready gate

## Goal

Eliminate the parallel-load flakiness diagnosed in `frostsnapp/test_driver/PARALLEL_ROBUSTNESS.md` by
replacing fixed-retry / find-by-label races with POSITIVE readiness signals, so the suite is reliable at
a sensible default `--jobs` on an idle host. Two structural fixes + a measured validation:

1. **Device presence is recognition-synchronous** — the harness primitive waits, so no test re-implements
   a wait and the "label hasn't appeared yet" race class vanishes by construction.
2. **App launch waits on a positive semantics-ready signal** instead of a blind fixed-retry loop.
3. **Before/after idle-host flake sweep** validates the fix and calibrates any concurrency default.

This is harness/test-driver work (`test_driver/` + the SIM driver-data handler), not device-HAL — it does
not touch the leaf DeviceHal primitives.

## Context (the diagnosis this implements)

`PARALLEL_ROBUSTNESS.md` (plan sim-harness-parallel-robustness, finalized): on an 18c/128 GiB host the
suite flakes from `--jobs 2` despite ~82 MB/chain — timing fragility, not resource exhaustion. Three
failures share one shape: an out-of-process find/assert losing to a slow app/device. The verified
recognition signal is `coord.deviceListState().devices` (`lib/src/rust/api/coordinator.dart:115`; `coord`
global at `lib/global.dart:14`) — the SAME list that renders the keygen `Device name N` fields
(`lib/wallet_create.dart:225/944`), so gating on it is a true gate, not the symptom label.

## Tasks

### Task 1 — Recognition-synchronous device presence (the key fix)

The model: a device is "present" only when the COORDINATOR has recognized it (finished the
announce/`AnnounceAck` handshake), NOT merely when it is in the sim pool/chain. `growFleetTo` guarantees
pool membership; recognition is a DISTINCT, later gate. Make the harness wait on recognition everywhere a
device appears/disappears:

- **Driver-data endpoint** (`sim_app.dart`): add `recognized-device-ids` →
  `coord.deviceListState().devices` ids (CSV). This is the coordinator's authoritative recognized list.
- **Connect/disconnect primitives** (`sim_harness.dart` `AppDevice.setConnected`, `connect`/`plug`,
  `disconnect`/`unplug`): after toggling the pool, POLL the endpoint until the device's id is present
  (connect) / absent (disconnect), with a clear timeout (fail loudly, never hang). Map pool number → id
  via the existing `device-id:<n>`.
- **Initial fleet bring-up** (`Scenario.launch` / `growFleetTo`): the keygen race is on the devices
  connected AT LAUNCH (SIM_DEVICE_COUNT), so after the pool reaches `deviceCount`, also wait until ALL
  `deviceCount` devices are recognized before returning. (Either fold into `growFleetTo` or a sibling
  `awaitRecognized(deviceCount)`.)
- Once this lands, the `tapUntil('Next','Device name 1')` race is gone by construction; do NOT add per-site
  waits — the primitive owns it.

**Acceptance:** `createWallet`'s device-name step no longer races (the `Device name N` label is present
because recognition is gated); a timeout surfaces a clear error, never a hang; all existing scenarios pass.

### Task 2 — Positive semantics-ready gate

Replace the blind `for i in 0..60: setSemantics(true)` × 500 ms loop (`sim_harness.dart` `_launchApp`):
after enabling semantics, wait for a POSITIVE signal that the tree is usable — `find.bySemanticsLabel`
resolving a known stable first-screen/SIM marker — before returning from launch, and re-assert if a later
route rebuild drops it. Turns "blind 30 s budget" into "proceed the instant find-by-label actually works".

**Acceptance:** under load, launches no longer proceed into a tree where `find.bySemanticsLabel` silently
fails; the `setSemantics never took` → downstream-timeout path is gone or fails fast with a clear cause.

### Task 3 — Validation sweep + concurrency default (NEEDS AN IDLE HOST)

The diagnosis deferred the controlled measurement to here as before/after acceptance.

- On an IDLE host (no live apps, no orphan backends): run the full suite ~10× at `--jobs ∈ {1,2,3,5}`
  BEFORE (current `master`/baseline) and AFTER Tasks 1–2; record failures by signature.
- Expected: the recognition/semantics signatures disappear; reliability at a sensible default improves.
- ONLY IF still flaky after P1: add the secondary concurrency default (`effJobs` →
  `min(files, max(2, cores/4))`) and/or weight the heaviest scenarios (multi-device keygen, the 2-app
  `regtest_dual_send`) so their launches don't all start at once. Do NOT lead with a cap — P1 is the fix.
- Coordinate timing with the user for the idle-host window.

**Acceptance:** a recorded before/after table showing the load signatures eliminated, and a justified
final `--jobs` default.

## Regression watch — reviewers, SCOUR
Changing connect/disconnect to block until recognition affects EVERY scenario that touches a device. Both
reviewers verify, with file:line evidence:
1. No new HANGS — every recognition wait has a bounded timeout that throws a clear error; a device that
   never recognizes fails fast, not forever (esp. disconnect-then-recognition-absent).
2. No semantic change that breaks existing flows — daisy-chain cascade on disconnect still works;
   connecting the head that cascades still resolves recognition for the right device(s).
3. The recognized-device-ids endpoint reads the coordinator's list (not the pool) — confirm it's the same
   list that renders the UI, so the gate matches what tests assert against.
4. Initial-fleet recognition wait doesn't deadlock when deviceCount devices legitimately take time, and is
   a no-op-fast on host where recognition is quick.
5. Full existing suite green at `--jobs 1` (oracle) AND improved at `--jobs ≥ 2` (Task 3 data).

## Non-goals
- Retry-classification broadening (`isTransientFlake` for the startup signature) — last-resort safety net
  only, out of scope unless P1+P2 prove insufficient.
- Fixing the underlying app/firmware announce-handshake latency (app concern, not the harness).
