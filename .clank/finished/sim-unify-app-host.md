# sim-unify-app-host
# sim-unify-app-host — backend-agnostic app instances (collapse the android-pool special-case)

## Goal

A sim scenario should ask only for **app instances** and never know what backend hosts them. Today
`Scenario.runDual` (two app instances sharing one regtest chain) is **host-only** — it peeks at
`SIM_FLUTTER_DEVICE` and prints `SIM_TEST_SKIPPED` on android (`sim_harness.dart:166-170`). We want the
same test to run identically whether an instance is a **host window** or its **own android emulator**.

Priority is **design unification, not performance.** Emulator boot cost is acceptable. The measure of
success is that `runDual` (and every scenario) is backend-agnostic and that the android special-casing in
the runner collapses.

## Why it's host-only today (the actual leak, from architecture review)

An "app instance" is provisioned in two DIFFERENT places depending on backend:

- **host instance** = a cheap subprocess window, provisioned INSIDE the test process — `runDual` just calls
  `s.launch()` twice with window slots `base*2` / `base*2+1` (`sim_harness.dart:159-182`).
- **android instance** = a whole emulator, provisioned by the RUNNER's pool (`simctl.dart` `_runAndroidPool`
  + `_acquireEmulator`), which hands each worker EXACTLY ONE serial via `SIM_FLUTTER_DEVICE`.

So the test process can spin up a second window but not a second emulator. That asymmetry — not the bridge —
is why `runDual` can't run on android.

Grounded facts that de-risk this (from the review; keep these true or update if code moved):
- The regtest→emulator bridge is ALREADY per-serial: `bridgeRegtestToEmulator(session, serial)` does
  `adb -s <serial> reverse tcp:53321/53322 → dynamic host ports` (`regtest.dart:556-590`). `regtest.dart:539-542`
  states parallel emulators reuse the fixed emulator-side ports WITHOUT colliding. So two SEPARATE emulators
  bridged to one shared chain is already collision-free; the "fixed bridge ports collide" skip reason applies
  only to two instances on ONE emulator.
- `AppSession.launch(flutterDevice: ...)` already takes the target serial and `flutter run -d <serial>`
  installs/attaches per emulator (`sim_harness.dart:679-722`). Two AppSessions can target two serials.
- Each AppSession already gets its own app dir + VM service + process (`sim_harness.dart` `_launchApp`), so
  per-instance isolation is already in place.
- Emulator lifecycle (`_ensureAvd`, cold-boot on a deterministic port, `_provisionEmulator`, teardown) lives
  in the RUNNER (`simctl.dart`), not the test process — this is what must move/become callable below the seam.

## Design

One seam the test process owns — an **app host** that provisions an app-instance "device":

- `provisionInstance(index)` is the ONLY backend-aware code:
  - host → launch a window-slot app (unchanged behaviour).
  - android → boot an emulator on a slot-derived port, install the APK, attach, and bridge its serial to the
    scenario's shared chain (per-serial; already collision-free).
- Scenarios ask only for instances:
  `run(name, instances: N, (List<AppSession> apps, Scenario s) async { ... })`
  with `runScenario` = `instances: 1` and `runDual` = a thin `instances: 2` wrapper (keep the `(a, b, s)`
  convenience shape if desired).
- `AppSession` exposes `.platform` (host/android) for the RARE assertion that genuinely differs — the default
  path is identical across backends.
- Consequence: the runner (`simctl.dart`) stops special-casing android. It runs test processes uniformly with
  a `--jobs` concurrency cap and assigns each worker a base slot for port/AVD isolation (so concurrent tests'
  emulators don't clash — same slot idea, minus the pre-booted pool). `_runAndroidPool` + the allocator +
  lockfile registry are removed. Emulators are booted per-test and torn down after (self-contained).

Explicitly NOT in scope / deliberate trade-offs (call out for the reviewer):
- This reworks the pool from the shelved `parallel-android-tests` epic (Task 1's allocator). Pooling can be
  re-added LATER as a pure optimization behind the same seam if per-test boots ever hurt; not now.
- It touches ALL android tests (single-instance too switch from pool-acquired to self-booted), which is what
  makes it uniform. That is intended, not accidental.
- Keep the sim leaf-only invariant: the host/android difference must live ONLY in `provisionInstance` (and the
  extracted emulator library), never leak into scenario bodies.

## Tasks (staged so each step stays green + reviewable)

1. **Introduce the `provisionInstance` seam; host unchanged.** Factor the current single- and dual-launch paths
   through one `provisionInstance(index)` used by a `run(instances: N, body)` entrypoint. `runScenario`/`runDual`
   become thin wrappers. On host this is a pure refactor — behaviour and window-slot assignment identical.
   Acceptance: full host suite (incl. `regtest_dual_send`) green at `--jobs 5`, no behavioural change.

2. **Extract the emulator lifecycle into a library callable from the test process.** Move
   `_ensureAvd`/boot/`_provisionEmulator`/teardown out of the runner into a module (e.g. `emulator.dart`) the
   harness can call. Runner still uses it for now (no behaviour change yet). Acceptance: android single-instance
   suite still green via the runner; the emulator code is importable by `sim_harness.dart`.

3. **Android single-instance self-boot behind the seam.** `provisionInstance` on android boots its own emulator
   (slot-derived port/AVD), installs, attaches, bridges, and tears down — replacing the runner's pre-provision
   for single-instance tests. Acceptance: `regtest_receive`/`regtest_send`/`keygen` etc. green on android via
   the seam; emulators are booted+reaped per test (no orphans).

4. **`run(instances: N)` + android `runDual` across two emulators; delete the pool + the skip.** `provisionInstance`
   is called twice for `runDual`; each instance gets its own emulator + serial + bridge to the ONE shared chain.
   Remove `_runAndroidPool` + the allocator + the `sim_harness.dart:166` host-only skip. Runner runs all tests
   uniformly with `--jobs` + per-worker slot isolation. Acceptance: `regtest_dual_send` runs and PASSES on android
   (two emulators, A→B send over the shared chain) AND on host; full suite green on both backends; no orphaned
   emulators/backends after a run.

## Acceptance (whole plan)

- `regtest_dual_send` runs (not skipped) and passes on BOTH host and android, with zero scenario-body changes
  between backends.
- No `--android`-specific branching remains in scenario code; the only backend-aware code is `provisionInstance`
  + the extracted emulator library.
- The android pool (`_runAndroidPool`, allocator, lockfile registry) is deleted; the runner treats host and
  android uniformly.
- Emulators and per-session regtest backends are booted per-test and fully reaped after (verify no orphans).
- Honest validation: report actual host AND android pass tallies (android may be slower / capped lower — fine).

## Notes

- Android runs need booted AVDs + adb; validate on a machine with the emulator toolchain. Host validation is
  the fast inner loop; android is the acceptance gate for the unification.
- Watch the leaf-only invariant (`project_sim_epic_leaf_only_invariant`) — do not reimplement portable scenario
  logic per-backend; only the provision primitive differs.
