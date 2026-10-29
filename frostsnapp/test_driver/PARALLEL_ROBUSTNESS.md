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

- The runner retries NOTHING by default — each test runs once and a failure is a failure. `--retries N`
  opts into up to N blind re-runs (for CI) that re-run ANY failure. So none of the three signatures above
  are retried by default — they fail outright.
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

**P3 — Opt-in retries as a safety net, last.** Only after P1, consider running CI with a small
`--retries` budget (e.g. 1) to ride out residual startup jitter. Weigh masking risk: a blind retry re-runs
ANY failure, so a persistently broken test still fails, but a rare real flake near a race could be papered
over — keep the budget minimal and treat any test that only passes on retry as a bug to fix, not accept.

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

---

## Validation results (sim-harness-readiness-gates, Task 3)

Measured on host (18c/128 GiB) with 2 unrelated Frostsnap apps live — mild extra render load; the
before/after comparison is fair (load constant across both). Full suite; before = pre-fix baseline
(`12ec1f5^`), after = recognition-sync + semantics-ready gates.

### Before vs after at `--jobs 5` (3 reps each)

| version | failed per rep (/6) | total |
|---|---|---|
| before | 0, 2, 3 | 5 failed / 18 |
| after  | 2, 3, 0 | 5 failed / 18 |

No change in rate — BUT the failure SIGNATURES shifted. The launch races the gates target —
`No root widget is attached`, `Device name N never appeared` — are GONE after the fix. The residual
after-fix failures are a DIFFERENT class the gates don't address: `device never confirmed the security
code` (the keygen hold-to-confirm gesture not registering) and 20–90s `waitFor`/driver timeouts (the
apps are simply too slow under load). Before-fix failures included those PLUS the now-eliminated launch
races and slow-sync `waitFor` timeouts.

### After-fix calibration (highest reliable parallelism)

| `--jobs` | reps | result |
|---|---|---|
| 1 | many (whole session) | reliable — always green |
| 2 | 2+ | flaky (a rep failed 1) |
| 3 | 3 | flaky (a rep failed 2) |
| 5 | 3 | flaky (most reps fail) |

Only `--jobs 1` is reliable on this (contended) host. An idle host would raise the ceiling, but not
measured.

### Conclusion — the ACTUAL root cause (supersedes the "render ceiling / cap to serial" guesses above)

Both the "fragility" framing AND the later "render-throughput ceiling → cap to serial / render-quiescence"
reading were WRONG — and inverted: the problem is not too MUCH rendering, it's too LITTLE.

Tracing a reproduced `device never confirmed` failure with reliable (forced-frame) screenshots showed the
app had actually reached `Confirm on device ✓` and was stuck *before* the "Final check / Yes" dialog —
then RECOVERED ~48s later as load lifted (so: not a hang, a stall). The stall is in `wallet_create.dart`
keygen: `await keygenController.removeActionNeeded(id)` → `awaitDismissed()` blocks on the action dialog's
POP, which only advances on a PAINTED frame (the dialog pops itself via a frame-gated `ListenableBuilder`
+ exit animation). The sim window launches backgrounded (`NO_ACTIVATE`), and macOS PAUSES vsync for a
backgrounded/occluded window — so under load it stops painting: the dialog never dismisses, the keygen
`await` never returns, and (same cause) the `flutter_driver` semantics tree the harness searches goes
stale. ONE condition — a non-painting window — produced ALL three symptoms (stale screenshots, stale
finds, stuck keygen). The heavy concurrent tests (`regtest_send`/`regtest_dual_send` signing) just
desynchronize the phases so a confirm overlaps a load spike; homogeneous ×10 runs never hit it.

**Fix (landed; sim-harness only — NO production keygen change):** a slow **1 Hz `scheduleForcedFrame()`
heartbeat** in agent-driven sim mode (`sim_app.dart`) keeps the frame pipeline alive even when the engine
has disabled frames (`framesEnabled == false`), so frame-gated work un-sticks without a 60fps burn. Plus
the failure-diagnostics screenshot now renders OFF-SCREEN via `RenderRepaintBoundary.toImage` and forces a
frame first, so a capture is fresh regardless of window state (the old `driver.screenshot()` + osascript
foreground returned stale frames and broke for multi-window scenarios).

**Consequence — the heartbeat sets an OBSERVATION FLOOR (and this is the residual signing flake):** a
backgrounded window now repaints only on the 1 Hz beat, so the semantics tree is at most ~1 s stale. Any
BOUNDED "is it there now?" read SHORTER than a beat can poll entirely within the gap and miss a state that
already changed but hasn't repainted. The gate reviewer reproduced exactly this where I'd overclaimed
"reliable": `regtest_dual_send` failing 2/2 at `--jobs 5` with `A device did not contribute its signature
share (1/1)` (passes standalone) — the share HAD landed, but the signing loop's `exists('1/1')` was an
**800 ms** check that expired before the next forced frame painted the counter, so it gave up. (My own ~17
reps stayed green only by luck — the beat happened to land inside the 800 ms.) So the heartbeat fixed the
frame-STARVATION class but, at 1 Hz, ANY sub-second semantics read becomes a heartbeat race. The earlier
"12/12 / parallel reliable" headline was therefore premature.

**Follow-up fix (the floor made explicit):** `sim_harness.dart` now has `_heartbeat` (1 s) and `_minObserve`
(2 s = 2 beats, for margin) constants, and every bounded semantics read is raised to ≥ a beat — `exists`
800 ms → 2 s, the `tapUntil` re-check 500 ms → 2 s, and `_settledBottomRight`'s sample interval 120 ms → 1 s
(so two "settled" reads come from DIFFERENT frames). Reads that bypass the semantics tree and hit
coordinator state directly over the VM service (`recognized-device-ids`, `chain`) are unaffected — their
100 ms polls stay. No scenario changed; the fix is in the harness primitives, so it covers every `exists`
caller at once. The MECHANISM is the proof here: a sub-beat read cannot reliably observe a once-per-beat
repaint; raising it past a beat removes the race.

**What the re-measurement actually found (and a real app bug it surfaced):** the first `--jobs 5` rep after
the floor fix had `regtest_dual_send` reach `DRIVE_OK` — i.e. the signing-share race did NOT recur; the
floor fix worked — yet the rep was still marked FAILED. The cause was a SEPARATE, pre-existing app bug, not
a harness issue: `_WalletSendPageState.scrollToTop` (`wallet_send.dart`) guarded a post-delay scroll with
`if (context.mounted)`, but that method has no `context` parameter, so `context` is the `State.context`
GETTER — which THROWS "this widget has been unmounted" on a defunct State. The send page is popped during
the `Future.delayed` (the send just finished), so the callback fired post-dispose and the guard itself threw
an unhandled exception. flutter_driver surfaces an app-side unhandled exception to the driving process, so
the test correctly went non-zero (loose exceptions SHOULD fail the test). Fixed by using the State's own
non-throwing `mounted`. This is exactly the harness earning its keep: the parallel load shook out a latent
production crash that single-runs hid.

- The recognition-sync + semantics-ready gates and the heartbeat all stay; this floor fix is what makes the
  heartbeat actually deliver parallel reliability rather than trade one race for another.
- `--jobs` default: **left as-is (all-at-once)** (resolves the earlier doc-vs-code default mismatch: the doc
  no longer claims a serial default).
- `SIM_PAUSE_ON_FAILURE=1` (hold a failed window alive + capture a screenshot trail) is kept as the
  diagnostic that made the stall observable — it's what showed the stall recovering rather than hanging.

### Task 3 continued — the signing false-negative (the ACTUAL dual_send fix) + the got-0 clipboard race (FIXED)

The floor fix above did NOT resolve `regtest_dual_send`. Re-measuring after it, dual_send reached `DRIVE_OK`
in some reps but still failed `A device did not contribute its signature share (1/1)` in others. Reliable
forced-frame screenshots settled it: at the failure the app had **fully signed** — "Signed", "Tap to
broadcast", confetti — signing WORKED. The failure was a harness FALSE NEGATIVE: the signing loop keyed off
the **transient `1/1` share-counter**, which the 1 Hz heartbeat can skip painting entirely (a sub-heartbeat
UI state may never be composited between two forced frames), so `exists('1/1')` never saw it even though
signing had completed and the UI had already advanced to "Signed".

The rule this teaches is stronger than the floor fix: **you can only reliably observe UI states that PERSIST
for ≥ one heartbeat.** The `1/1` counter doesn't. Fix: key the LAST share off the persistent `'Signed'`
completion state (renders only once `signingDone` — `wallet_tx_details.dart` — and stays until broadcast),
not the transient counter; INTERMEDIATE shares keep the `i/threshold` counter (it stays up while signing is
unfinished). Applied to `regtest_dual_send_drive.dart` (1-of-1) and `regtest_send_drive.dart` (last of the
2-of-3). Validation: `regtest_dual_send` green **5/5 at `--jobs 5`** (was ~3/5 reps failing); signing passes
every rep.

**got-0 — ROOT-CAUSED and FIXED (a shared-clipboard race).** With signing reliable, `regtest_send` reached
its post-broadcast on-chain cross-check every run, where it intermittently threw `node address should have
received ~1 BTC; got 0` (~1/4 at `--jobs 5`, reproduced on a clean host). It is NOT electrs indexing lag
(that hypothesis was refuted — an instrumented per-second poll showed the balance present and correct on the
FIRST poll even with 15/18 cores burned) and NOT signing. The captured `GOT0-DIAG` timeline was decisive:
`received=0` flat for the full 30 s at a CONSTANT height, while the app had already shown `'Sent'` — so the
app's tx confirmed at that height, just did not pay `nodeAddr`.

Root cause: the harness seeds the recipient with `setClipboard(addr)` + tap **Paste**, and reads receive
addresses with tap **Copy** + `getClipboard`. Flutter's `Clipboard` is the macOS **system pasteboard — one
global object shared by all N app processes** under `--jobs N`. So parallel tests RACE it: a concurrent
`setClipboard` clobbers another test's recipient between its set and its Paste → that test pays the WRONG
(another test's) address → its own `nodeAddr` stays 0. Every fact fits: `'Sent'` (paid, wrong address), flat
0 (never received), only under parallel load, ~1/4.

Fix — **no clipboard in any address path**, both directions:
- WRITE (recipient): `autofocus: true` on the send recipient field (`wallet_send.dart`, matching the amount
  field) so the harness **types** the address in (`enterFocusedText`) via each app's OWN VM service.
- READ (receive address): key the address Text (`ValueKey('receiveAddress')`, `wallet_receive.dart`) and read
  it per-app with a new `getTextByKey` (`spacedHex` groups it, so strip whitespace) — no Copy, no clipboard.
- Applied across `regtest_send`, `regtest_dual_send`, `regtest_receive`.

Validation: full suite **16/16 green at `--jobs 5`** (two ×8 rounds), zero got-0 — vs ~1/4 failing before.

`--jobs` default: **all-at-once, and now genuinely reliable** — the last parallel-load failure class is gone.
Net across the plan: recognition/semantics gates + 1 Hz heartbeat + observation floor + the wallet_send crash
fix + the persistent-signal signing fix + clipboard-free address transfer. Parallel sim runs are reliable.
