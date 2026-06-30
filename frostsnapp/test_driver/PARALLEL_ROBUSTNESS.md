# Sim e2e suite — parallel-load flakiness: diagnosis & recommendation

Deliverable of the `sim-harness-parallel-robustness` investigation. Observed live 2026-06-30 on the
`full-app-sim-driver` branch.

## Headline

The suite is reliable at `--jobs 1` and flakes intermittently from `--jobs 2` up. The flakes are
**timing fragility, not resource exhaustion** — so the primary fix is to replace fixed-retry / find-by-
label races with **positive readiness signals**, not to cap concurrency. A concurrency cap is at best a
secondary backstop; on its own it would not even fix `--jobs 2`.

### Why "not resource exhaustion" (the measurement that reframes Q1)

| Resource | Measured | Implication |
|---|---|---|
| Host | **18 cores, 128 GiB RAM** | Enormous headroom for ≤6 test workers |
| Per-scenario regtest chain | bitcoind ~61 MB + electrs ~14 MB + sim_regtest ~7 MB ≈ **82 MB** | Trivial |
| Flutter debug app | a few hundred MB | 6× ≈ a few GB — negligible vs 128 GiB |

At `jobs ≤ 6` neither RAM nor CPU is anywhere near saturation, yet flakes appear at **jobs = 2**. A
machine this large flaking at 2-way concurrency is the signature of fragility that loses to modest
**scheduling/timing jitter** (and likely macOS WindowServer/GPU serialization across several Flutter
surfaces delaying first-frame/`runApp` attachment), not of starvation. The now-reaped orphan backends
from earlier sessions were extra noise but are not the structural cause.

## Failure mechanisms (one shape, three sites)

All three are an out-of-process find/assert losing to a slow app under contention.

1. **App-startup semantics race.** `_launchApp` enables semantics with a FIXED budget —
   `for (i in 0..60) setSemantics(true)` × 500 ms, then logs `setSemantics never took`
   (`sim_harness.dart:714`). When `runApp` attaches late (log: `set_semantics ... No root widget is
   attached`), the window is exhausted (or a later route rebuild drops semantics) and every subsequent
   `find.bySemanticsLabel` times out. Symptoms: `device never confirmed the security code`,
   `Timeout while executing waitFor`.

2. **Device-recognition lag in keygen.** `tapUntil('Next','Device name 1')` times out even though the
   screenshot shows the "Add devices" screen rendered. Each device-name field is built **per
   coordinator-recognized device** (`wallet_create.dart:841` `_inlineNameField(.., ConnectedDevice,
   int index)`), wrapped in `Semantics(label: 'Device name ${index+1}')` (`:854`); its searchable label
   exists only AFTER the coordinator recognizes the device over the USB/serial handshake (`AnnounceAck`).
   `growFleetTo` guarantees **pool membership, not coordinator recognition** — so the label can lag the
   `tapUntil` budget.

3. **Signing-share timing.** `signer N did not contribute its signature share (threshold counter never
   reached N/M)` — the per-device sign round didn't land within its retry budget under load.

## What today's machinery covers (and doesn't)

- `isTransientFlake` (`simctl.dart`) retries ONLY connection-drop output (`Failed to fulfill
  SetFrameSync` / `Lost connection to device`) with no real-assertion signature. **None** of the three
  signatures above match, so they are never retried — they fail outright.
- Runner default `effJobs = (jobs ?? files.length).clamp(1, files.length)` — every test at once. Not the
  root cause here (headroom is huge), but it maximizes the concurrent timing jitter that triggers the
  fragility.

## Recommendation (prioritized)

**P1 — Replace fixed retries with positive readiness gates (the real fix; preserves throughput).**

- *Make device connection recognition-synchronous (mechanism 2) — the key ergonomic fix.* Waiting for a
  device to be recognized is a COMMON need, so the harness primitive should do it BY DEFAULT rather than
  every caller remembering a gate: **`connect` / `plug` / `AppDevice.setConnected(true)` should not return
  until the COORDINATOR has recognized the device** — and symmetrically `disconnect`/`unplug` should not
  return until it is gone. Then no caller (`createWallet`, signing, any future scenario) sprinkles an
  explicit wait, and the entire "label hasn't appeared yet" class vanishes BY CONSTRUCTION: connect means
  "connected AND recognized", not "told the pool to connect". A real queryable signal EXISTS to implement
  this — `coord.deviceListState().devices` (`lib/src/rust/api/coordinator.dart:115`; `coord` global at
  `lib/global.dart:14`) is the coordinator's own recognized-device list. Add a driver-data endpoint (e.g.
  `recognized-device-ids`) and have the connect/disconnect primitives poll it to the expected membership
  with a timeout. This is a true gate (the coordinator's state), not the symptom label, and it removes the
  per-site `tapUntil('Next','Device name N')` race entirely.
- *Semantics-readiness gate (mechanism 1).* After `setSemantics(true)`, wait for a POSITIVE signal that
  the tree is usable — e.g. `find.bySemanticsLabel` resolving a known first-screen/SIM marker — rather
  than trusting a fixed 60×500 ms loop; re-assert on the first post-launch screen. Turns "blind 30 s
  budget" into "proceed the instant semantics is actually live."
- *Signing (mechanism 3)* already keys off the `N/M` share counter; once P1a/P1b land, re-measure before
  touching it.

**P2 — Sane concurrency default as a backstop, NOT the primary fix.** Even with P1, stagger/cap is cheap
insurance: default `effJobs` to something like `min(files, max(2, cores/4))` and/or weight the heaviest
scenarios (multi-device keygen, the 2-app `regtest_dual_send`) so they don't all start their app
launches simultaneously. Guard against the trivial "serialize to `--jobs 1`" answer — the goal is
reliable at a SENSIBLE default on a clean host, which P1 is what actually buys.

**P3 — Retry classification as a safety net, last.** Only after P1, consider treating the
startup-semantics signature as transient in `isTransientFlake` (one retry). Weigh masking risk: scope it
narrowly to the `No root widget is attached` startup signature so it can't hide a real assertion failure.

## Measurements

**Observed flake rate this session** (host carried 2 live apps + earlier orphan backends — i.e. mild
EXTRA load, which only strengthens the fragility reading; not a pristine baseline):

| `--jobs` | Result |
|---|---|
| 1 | clean across multiple runs, including the 2-app `regtest_dual_send` |
| 2 | intermittent — e.g. `regtest_send` failed one run, passed others |
| 5 | frequent — 3/5 then 2/6 failed across two runs, a DIFFERENT subset each time |

With the resource model (18c / 128 GiB, ~82 MB per chain → no exhaustion at jobs ≤ 6), this is enough to
PRESCRIBE: the cause is timing fragility, and the fix is the P1 recognition-synchronous primitives. The
non-determinism (different tests fail each run) is the contention signature, not a per-test logic bug.

**The controlled idle-host sweep belongs in the impl plan, not here.** The measurement that actually
matters is flake-rate BEFORE vs AFTER the P1 fix on an idle host — it both validates the fix and
calibrates the P2 default. A standalone sweep now would (a) need an idle machine this investigation host
wasn't, and (b) re-measure a baseline we'd take again post-fix anyway. So it is specified as the impl
plan's before/after acceptance, not a separate academic run here.

## Next step

P1 is concrete and feasible, and the connection-recognition-synchronous design is the right shape (a
primitive that waits, so no test re-implements the wait). Recommend a SEPARATE implementation plan —
recognition-synchronous `connect`/`disconnect` first, then the positive semantics-ready gate — keeping
this investigation analysis-only per its non-goals.
