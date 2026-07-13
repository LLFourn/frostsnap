# fsim-android-devices-count

`fsim up --android --devices N` delivers N devices, same as host. The requested device count becomes
the SEAM's job on every path, not a caller-specific afterthought.

## Why

Reproduced today (and reported by the PR-505 recording effort): `./fsim up --android --devices 2` →
`deviceNumbers()` is 1, `chain()` is `[1]`; the identical host command yields 2 / `[1, 2]`. Root
cause is a split responsibility: on HOST the device count rides the launch env, but the android APK
can't read the host env, so the count is baked as 1 and the fleet must be GROWN over the app channel
after launch. Only `Scenario.provisionInstance` (the test path) does that growth — the interactive
serve calls `provisionAppInstance` directly and "just holds the instances"
(`sim_harness.dart:302-310` comment), so its request for N devices is silently dropped on android.
The PR-505 workaround was hand-calling `session.addDevice()`.

## Scope — `frostsnapp/test_driver/sim_harness.dart`

- `provisionAppInstance` (the ONE backend-aware seam) owns the FULL readiness of [deviceCount] —
  growth AND recognition, one owner: after the app launches, grow the fleet over the app channel
  (the same `add-device` the tray/CLI use) until the app-side count matches, then wait for the
  chain-recognition handshake. NO caller receives an AppSession before the requested fleet is grown
  and recognized. Host keeps env-delivered launch counts but the recognition wait moves into the
  seam too (single readiness definition on both backends).
- `Scenario.provisionInstance` keeps ONLY its test bookkeeping (teardown registration) — growth and
  the recognition handshake leave it entirely; no duplicated or reconciled readiness.
- FAILURE-ATOMIC: growth/recognition adds a failure point AFTER `AppSession.launch`. On any
  post-launch provisioning failure the seam tears the launched AppSession down (`h.tearDown()` —
  which also reaps its emulator/bridge) before rethrowing; the existing catch
  (`sim_harness.dart:383`) only unbridges + kills the emulator, which would orphan the Flutter
  process and bypass AppSession-owned cleanup once launch has succeeded.
- Update the now-stale ownership comments (`sim_harness.dart:302-313` — "the serve just holds the
  instances" — and `:398-400`) to the new single-owner model.
- Verify no other direct `provisionAppInstance` caller intentionally relied on count-1.

## Tests
- COMMITTED regression for the DIRECT seam path (not only the Scenario path): prove
  `provisionAppInstance`-level readiness — requested count grown, chain recognized — is established
  before the seam returns, and that a post-launch growth/recognition failure tears the session down
  before rethrowing. Factor the settling/growth steps behind fakeable callbacks if a live app is
  too heavy for the failure case.
- `fsim test keygen_2of3 --android` stays green (the Scenario path through the seam).

## Acceptance
- `./fsim up --android --devices 2` → `(await session.deviceNumbers()).length == 2` and
  `session.chain() == [1, 2]` (the repro, now green).
- Host `./fsim up --devices 2` unchanged (2 / `[1, 2]`).
- `fsim test keygen_2of3 --android` green (the multi-device scenario path still provisions
  correctly through the seam).
- The committed direct-path regression green; `dart analyze test_driver` clean; host suite green.
  (The live CLI checks above are acceptance evidence, not review gates.)
