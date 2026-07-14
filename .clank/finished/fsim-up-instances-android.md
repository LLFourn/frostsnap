# fsim-up-instances-android
# fsim-up-instances-android — `fsim up --instances N` on Android too (retire the host-only carveout)

## Goal
`fsim up --instances N --android` boots N distinct emulators sharing ONE regtest chain, each driveable via
`instances[K]` in `fsim eval`/`repl` — identical to host multi-instance and to the `regtest_dual_send --android`
test that ALREADY does exactly this. Delete the `--instances N (N>1) is host-only` reject
(`fsim.dart:1546-1550`). This is not new capability; it's finishing the unification the sim epic set out to do —
the interactive serve is the last place with a SECOND, parallel Android-emulator model.

## The duplicated model (why the reject exists today)
Two Android-emulator-provisioning models never got unified — this is the carveout:

- **The shared seam already does Android multi-instance.** `Scenario.provisionAppInstance`
  (`sim_harness.dart:232`), on Android (`!_isHost`, ~:250), derives a per-instance `deviceIndex = base *
  maxInstancesPerTest + index`, `bootEmulator`s its OWN emulator on `emulatorPort(deviceIndex)` (pool range
  `frostsnap_sim_pool_*`, 5582↑), `bridgeRegtestToEmulator(chain, serial)`, launches the app on that serial, and
  records `_emulatorSerial`/`_unbridge` for reaping. This is precisely how `regtest_dual_send --android` boots
  two emulators on one chain. The mechanism is done and tested.
- **The interactive serve keeps its OWN single-emulator model.** `fsim-dir-scoped-sessions` Task 3 gave `_serve`
  a separate path: `_claimAndBootSessionEmulator` (`fsim.dart`) pre-claims + boots ONE emulator from a DISTINCT
  interactive range (`frostsnap_sim_session_*`, 5680↓), `_resolvePlatform` returns that serial as `platform`,
  and `_serve` bridges the chain to that ONE serial (`fsim.dart:1571-1592`) BEFORE the instance loop runs.

So `up --instances N --android` would have the serve boot+bridge one emulator, then `provisionAppInstance`
self-boot N more from a different range — a collision. Rather than reconcile the two models, `_serve` rejects
N>1 on Android (`fsim.dart:1546`). That reject is the "duplicated-model / reconciliation carveout" smell the
epic was meant to eliminate. (For the record: this was approved at gate in `fsim-eval-unified-drive` Task 4 —
the deferral should have been challenged, since the seam already supported it.)

## Design (the unification)
Make the interactive serve provision ALL its instances — N≥1, host AND Android — through the ONE seam
`provisionAppInstance`, and RETIRE `_serve`'s separate Android-emulator pre-claim/bridge. After this, `_serve`
owns only: resolve the target platform, start the session regtest, then `provisionAppInstance` × N (which
self-boots + bridges each Android emulator itself), and reap what it provisioned on `down`/`clean`.

The one real problem to solve is **emulator port/AVD allocation across BOTH interactive sessions AND concurrent
test workers**, within Android's bounded console-port space (~5554–5682, even ports; the interactive 5680↓ and
test 5582↑ ranges already grow toward each other — flagged in the dir-scoped review). Requirements:
- Two concurrent `up --instances N --android` sessions must get disjoint emulators.
- A `fsim up --android` session must not collide with a concurrent `fsim test --android` run's pool emulators.
- `provisionAppInstance` derives its emulator from `deviceIndex = slot * maxInstancesPerTest + index`. Today
  `slot` comes from the ambient `FROSTSNAP_SIM_WINDOW_SLOT` env the runner sets per worker; make it an EXPLICIT
  parameter instead (Task 1) so the interactive serve — one process provisioning N in-process — can pass a
  claimed slot it could never set in its own env. The fix is a slot-allocation scheme that partitions
  `deviceIndex` (hence port/AVD) space so interactive sessions and test workers never overlap — the interactive
  serve CLAIMS a session slot (reuse the existing lockfile arbitration) mapped to a `deviceIndex` range
  reserved-disjoint from the test workers' bases. Pick ONE port/AVD naming scheme (the seam's
  `emulatorPort`/`emulatorAvd`) and retire the parallel `interactiveSessionPort`/`interactiveSessionAvd`.

Keep the death-pipe / dir-scoped invariants: each session owns its regtest under `<dir>/.fsim`; `down`/`clean`
reap EXACTLY this session's emulators (by recorded serial) + regtest — never a global sweep.

## Tasks (staged, each green)
### Task 1 — one Android-emulator allocation across interactive + test
Define a single slot→(port, AVD) scheme via `provisionAppInstance`/`emulator.dart` that partitions the bounded
console-port space between interactive sessions and test workers so neither collides with the other or with a
peer. Make the slot an EXPLICIT seam input, not ambient env: `provisionAppInstance` currently reads
`Platform.environment['FROSTSNAP_SIM_WINDOW_SLOT']` in-process, but the interactive serve can't mutate its OWN
env for its own later reads — so add an explicit `slot` parameter to `provisionAppInstance`. The interactive
serve CLAIMS a session slot (reuse the current lockfile liveness arbitration) and PASSES it; the test path
reads its per-worker `FROSTSNAP_SIM_WINDOW_SLOT` and passes THAT (the env-read moves out of the seam to the
test caller). Retire `interactiveSessionPort`/`interactiveSessionAvd`/the separate range.
- **Acceptance:** the allocation is documented; two concurrent interactive sessions AND a concurrent test run
  get provably-disjoint emulator ports/AVDs; the bounded-port ceiling (max concurrent emulators) is stated and
  errors clearly when exhausted.

### Task 2 — `_serve` provisions all instances through the seam (N≥1, host + Android)
Route `_serve` (host AND Android) through `provisionAppInstance` × N on the session's ONE regtest; DELETE
`_claimAndBootSessionEmulator`'s role in serve + the pre-launch single-emulator bridge. Make the SEAM own the
Android regtest defines: `provisionAppInstance` today CALLS `bridgeRegtestToEmulator(chain, serial)` but
DISCARDS its returned defines — only `Scenario.provisionInstance` works, by separately passing
`_regtest.defines` — so a direct serve caller would launch with NO `SIM_REGTEST_*`. Fix it IN the seam:
`provisionAppInstance` merges `bridgeRegtestToEmulator(...).defines` into the app's dart-defines for Android,
so EVERY direct caller (serve included) gets the right regtest endpoints and the serve passes no regtest
defines of its own. Record ALL N emulator serials so `down`/`clean` reap each (`killEmulator` by recorded
serial; never a global sweep). Delete the `--instances N>1 --android` reject (`fsim.dart:1548`).
Single-instance Android `up --android` still works (the N=1 case of the same path).
- **Acceptance:** `fsim up --instances 2 --android` boots TWO emulators on ONE regtest, both driveable via
  `fsim eval "instances[0/1]…"`; a cross-wallet send A→B over the shared chain works (the interactive analogue
  of `regtest_dual_send`); `fsim up --android` (single) still works; `down` reaps BOTH emulators + the regtest,
  zero orphans; `fsim clean` reaps a hard-killed session's emulators by recorded serial. `fsim test --android`
  (incl. `regtest_dual_send`) stays green and a concurrent interactive session doesn't disturb it.

## Notes / constraints
- The Android paths ARE validatable on this box (emulator toolchain + AVDs under
  `/opt/homebrew/share/android-commandlinetools`, HVF on) — CONFIRMED for Task 1: `fsim up --android` boots
  `emulator-5646` (= `emulatorPort(interactiveGlobalSlot(0)*2)`, disjoint from the test pool 5582–5644), drives
  it over the bridge, and `down` reaps it. Report real host + Android tallies from here.
- This plan UNIFIES the Android regtest bridge: it RETIRES `_serve`'s dynamic adb-reverse bridge in favor of
  the seam's fixed-baked-port bridge (the build-once APK's ports + the seam's per-serial adb-reverse via
  `bridgeRegtestToEmulator`), so afterwards serve and tests share ONE Android bridge. The earlier "serve
  dynamic vs test fixed" asymmetry is ELIMINATED, not preserved.
- Out of scope: the session-root scheme (`rt-<pid>` vs `<dir>/.fsim`, socket-length) — a genuine socket-length
  constraint, unchanged here.
- Provenance: this plan removes a carveout that landed in `fsim-eval-unified-drive` Task 4 and was approved at
  the ruthless gate; it's the cleanup, not a feature request.
