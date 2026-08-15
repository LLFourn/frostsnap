# sim-harness-parallel-robustness
# sim-harness-parallel-robustness — INVESTIGATION: why the sim suite flakes under parallel load

## Type

Investigation / analysis. The deliverable is a written diagnosis + a recommended, scoped set of
changes (which may spawn a follow-up implementation plan). Do NOT pre-commit to a fix in this plan —
first establish which failures are genuine harness-robustness gaps vs. mere machine over-subscription,
then recommend the smallest change that buys the most reliability.

## Problem

The driver e2e suite (`./simctl test`) is reliable at `--jobs 1` but flakes at `--jobs 2`+ on a loaded
host. Failures are non-deterministic — a different subset fails each run — which is the signature of
resource contention, not a logic regression. Observed live (2026-06-30) across several parallel runs.

## Observed failure signatures (evidence)

1. **App-startup semantics race.** App log: `set_semantics ... 'No root widget is attached; have you
   remembered to call runApp()?'`. The harness enables semantics with a fixed retry loop
   (`sim_harness.dart` `_launchApp`, `for i in 0..60` × 500ms = 30s, then logs `setSemantics never
   took`). Under load the app takes too long to attach `runApp`, the window is exhausted (or a later
   route rebuild drops semantics), and every subsequent `find.bySemanticsLabel` times out. Downstream
   symptoms: `device never confirmed the security code`, `Timeout while executing waitFor`.

2. **Device-recognition lag in keygen.** Failure: `tapped "Next" 8 times but "Device name 1" never
   appeared` — but the failure screenshot shows the app IS on the "Add devices" screen with the fields
   rendered. Cause: each device-name field is built ONE PER COORDINATOR-RECOGNIZED device
   (`lib/wallet_create.dart:841` `_inlineNameField(.., ConnectedDevice device, int index)`), wrapped in
   `Semantics(label: 'Device name ${index+1}')` (`:854`) with visible hint `Enter device name` (`:863`).
   The searchable label exists only AFTER the coordinator recognizes the device over the USB/serial
   handshake (`AnnounceAck` / "Wrote magic bytes"). `growFleetTo` guarantees POOL membership, NOT
   coordinator recognition — so under load `tapUntil('Next','Device name 1')` exhausts its ~8-try budget
   before recognition completes.

3. **Signing-share timing.** Failure: `signer N did not contribute its signature share (threshold
   counter never reached N/M)` under load — the per-device sign round (swipe review + hold-to-sign) did
   not land its share within the retry budget.

These all share ONE shape: an out-of-process find/assert losing to a slow app under contention. The
dual-instance scenario (`regtest_dual_send`) is the MOST exposed — it launches TWO apps, doubling
startup pressure — so it flakes first as `--jobs` rises.

## What today's machinery does and doesn't cover

- `isTransientFlake` (`simctl.dart`) retries a failed test ONLY when the output contains `Failed to
  fulfill SetFrameSync` or `Lost connection to device` (a connection drop) AND no real-assertion
  signature. NONE of the three signatures above match, so they are NOT retried — they fail outright.
- The host runner defaults `effJobs = files.length` (every test at once). On a developer host that
  OVER-SUBSCRIBES: N concurrent macOS Flutter apps + N regtest backends (bitcoind+electrs each).
- Stale orphan backends from earlier sessions were also stealing resources during these runs (now
  reaped). Don't conflate that one-off with the structural issue — but DO note machine load is a real
  variable; measure on a clean machine.

## Questions to answer

1. **Over-subscription vs. fragility.** On a CLEAN host, at what `--jobs` does the suite stay green?
   Is the right fix "cap concurrency to cores/RAM" (a runner default), "make each step robust", or both?
   Quantify before prescribing.
2. **Readiness over fixed retries.** Should app launch wait on a POSITIVE readiness signal (semantics
   actually usable — e.g. a known root widget resolves) instead of a fixed 60×500ms, and re-assert
   semantics after route pushes? Is there a signal the app already exposes?
3. **Gate keygen on recognition, not pool membership.** Can the harness wait on coordinator
   device-recognition (a count the app/driver-data can report) before the device-name step, instead of
   racing `find.bySemanticsLabel('Device name N')`? VERIFY any candidate is a real, queryable gating
   signal before recommending it (a label that only appears post-recognition is the symptom, not a
   usable gate).
4. **Retry coverage.** Should `isTransientFlake` be widened to treat the startup-semantics signature as
   transient (retry), or does that risk masking real breakage? Weigh masking risk explicitly.
5. **Resource-aware runner.** Should `effJobs` default to `min(files, f(cores, RAM))` and/or should the
   heaviest tests (multi-device keygen, dual-instance) be weighted so they don't all start at once?

## Deliverable

A written diagnosis answering the above with measurements, plus a prioritized recommendation: the
smallest set of changes that makes the suite reliable at a sensible default `--jobs` on a clean host.
If implementation is warranted, spin a separate impl plan — keep this one analysis-only.

## Non-goals

- Fixing the underlying app-startup time or device-handshake latency (app/firmware concerns).
- Anything that masks a genuine assertion failure to chase green.

## Links

Related: the existing [[project_keygen_finalize_unplug_race]] (a different keygen race) and
[[feedback_dont_conflate_test_flake_with_real_problem]] (critique the real issue, verify a signal is a
real gate before recommending it).
