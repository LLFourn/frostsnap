# sim-dual-app-send
# sim-dual-app-send — two app instances, cross-wallet send/receive on one regtest chain

## Goal

Make the sim harness able to run **two app instances in a single scenario**, sharing one
regtest chain, and prove a real cross-wallet payment between them:

1. Instance **A** receives regtest funds (faucet → A's real receive address → mined/confirmed).
2. Instance **B** opens its receive flow and produces a receive address; the test copies it out.
3. Instance **A** opens its send flow and sends **half** of its funds to B's address.
4. Instance **B** sees the incoming payment land (unconfirmed → confirmed), cross-checked on-chain.

This is host-only (macOS). Two instances of one app package on a single Android emulator is not
supported (one install, one VM service, the fixed `adb reverse` bridge ports would collide), so the
dual scenario refuses to run off-host and skips cleanly there. The single-instance path stays fully
portable (host + emulator) and must not regress.

## The core model (and the smell it removes)

Today a scenario's **regtest chain is owned by one `AppSession`**: `runScenario` starts a per-session
backend, stashes it on `h._regtest`, and `AppSession.tearDown` → `_cleanup(regtest:)` reaps it. That
conflates *"a chain"* with *"an app instance"*. It is precisely why two apps cannot share a chain:
there is no owner that outlives a single app to hold the shared backend.

The correct model: **the regtest chain is a SCENARIO resource**, not an app-instance resource. App
instances are *launched against* a scenario's chain and own none of it. A single-instance scenario is
just the degenerate case (one instance). This is the architectural change; everything else follows.

Concretely, introduce a `Scenario` lifecycle that:
- owns the optional per-session `RegtestSession` (started before any app, reaped after all apps, in a
  `finally`) — and holds the `RegtestSession` for the whole scenario so the **death-pipe write end
  stays open** (regtest-session-lifetime: the backend self-reaps on owner death; do not drop that ref
  early);
- `launch({deviceCount, extraDartDefines})` → starts an `AppSession` pointed at the chain (merges the
  chain's `defines`), grows its fleet via `growFleetTo`, registers it for teardown, and injects a
  **borrowed** (non-owning) `RegtestSession?` reference so `AppSession.faucet()` keeps working;
- `faucet()` → the shared chain's faucet;
- on failure captures diagnostics for **every** launched instance;
- on teardown tears down **all** instances first, **then** reaps the chain, and asserts **no residue**
  for every app dir.

`runScenario` (unchanged signature) becomes a thin single-instance wrapper over `Scenario`. The 5
existing `*_drive.dart` scenarios must pass byte-for-byte equivalent — they are the regression oracle.

### What must NOT change
- The **shared persistent daemon** path — `ensureRegtestBackend` / `AppSession.launch(withRegtest:
  true)` used by interactive `simctl serve`. That is a *different* lifetime (no owner; reaped by
  `regtest down`/`clean`). It is out of scope and must be left exactly as-is.
- `AppSession.faucet()` must keep working for `regtest_receive_drive.dart` and `regtest_send_drive.dart`
  (the only two faucet callers) with **no edits to those test files**.
- The death-pipe / `RegtestSession._backend` ownership semantics (process holds the stdin write end).

## Tasks

### Task 1 — Extract the scenario lifecycle (pure refactor, regression-gated)

Move per-session regtest ownership off `AppSession` and into a `Scenario` lifecycle; re-express
`runScenario` as a single-instance wrapper.

- Add `Scenario` (in `test_driver/sim_harness.dart`) owning: the optional per-session `RegtestSession`
  + its `defines`/`unbridge` (the existing `_ScenarioRegtest` bundle moves here), the list of launched
  `AppSession`s, failure capture across all of them, teardown, and per-app-dir residue assertion.
- `AppSession`: drop the per-session regtest **ownership** (`_regtest` of type `_ScenarioRegtest`, the
  `_cleanup(regtest:)` arm, the `withRegtest`-driven per-session start inside `runScenario`). Replace
  with a **borrowed** `RegtestSession? _chain` that the `Scenario` injects at launch; `faucet()`
  delegates to it and `tearDown`/`_cleanup` no longer touch the chain at all.
- `runScenario(name, body, {deviceCount, flutterDevice, withRegtest, extraDartDefines})` → delegates to
  `Scenario`: start chain if `withRegtest`, `launch(deviceCount, extraDartDefines)`, `body(h)`.
- Teardown order: tear down each app (driver → process → app dir), **then** reap the chain. (Today
  `_cleanup` stops the chain first; moving it last means no app is talking to a dead chain mid-teardown.
  Benign, but call it out so reviewers verify it's not a leak/ordering hazard.)

**Acceptance (Task 1):**
- All 5 existing scenarios pass on host unchanged: `./simctl test keygen keygen-2of3 regtest_receive
  regtest_send android-safe-area` (android-safe-area is host-runnable; it just asserts trivially with no
  bottom inset on desktop). Each leaves **no residue** (no leftover app dir, no `rt-<pid>` dir, no
  orphan `sim_regtest`).
- `regtest_receive` and `regtest_send` still obtain their faucet via `h.faucet()` with zero edits to
  those files.
- The shared-daemon `serve` path is untouched (diff it: `ensureRegtestBackend`,
  `AppSession.launch(withRegtest:)`, `simctl serve`).
- The `RegtestSession` (and thus `_backend` death-pipe fd) is referenced for the whole scenario.

### Task 2 — Dual-instance entry point + the cross-wallet send test

- Add `Scenario`-level support for launching **two** instances with **distinct window slots**: thread a
  per-launch `windowSlot` override down through `AppSession.launch` →
  `_simLaunchEnvironment`/`FROSTSNAP_SIM_WINDOW_SLOT`, so the second window doesn't stack on the first.
  Derive each instance's slot from the inherited worker base slot + instance index (cosmetic;
  host-visual only).
- Add `runDualScenario(name, Future<void> Function(AppSession a, AppSession b, SimFaucet faucet) body)`
  (or document `Scenario.run` + two `launch` calls) that: starts one shared chain, host-only-guards,
  launches A then B (sequential, for deterministic diagnostics ordering), and tears both down + the
  chain.
- **Host-only guard:** if the resolved flutter device is not a desktop host, print a clear
  `SKIP (host-only: dual-instance)` line and exit 0 (so `./simctl test --android` stays green without a
  per-test registry). Document the runner-level alternative (teach the android pool to skip host-only
  tests) as a non-goal.
- New `test_driver/regtest_dual_send_drive.dart` implementing the flow with **1-of-1 wallets** on both
  instances (keeps the test focused on the cross-instance payment, not threshold mechanics — `createWallet`
  already does 1-of-1):
  1. **A**: keygen a 1-of-1 wallet (defaults to Regtest in the faucet-wired sim); open Receive (handle
     the unfinished-backups "Later" nudge), copy A's `bcrt1…` address; `faucet.fund(A, 1 BTC)`; wait for
     `Receiving`; `faucet.mine(1)`; wait for `Received`.
  2. **B**: keygen a 1-of-1 wallet; open Receive (handle "Later"); copy B's `bcrt1…` address **into a
     Dart string immediately** (see clipboard note below).
  3. **A**: open Send (handle "Later"), set recipient to B's address (seed via `a.setClipboard` + Paste,
     matching `regtest_send`), enter a **specific half amount** (0.5 BTC) in the `Amount` field — *verify
     the `AmountInput` unit and parsing against `lib/wallet_send.dart` during impl* — not Send Max; handle
     the optional feerate/`Custom` dialog exactly as `regtest_send` does; sign on A's single device (swipe
     review screens → hold-to-sign), `Broadcast`, wait for `Sending`, `faucet.mine(1)`, wait for `Sent`.
  4. **B**: wait for `Receiving` then (after the mine) `Received`.
  5. **Cross-check on-chain:** poll `faucet.addressBalanceSat(B_addr)` until it equals **exactly**
     50_000_000 sats (a fresh address receiving one output; coinbase-immune). Assert A shows `Sent`.
  6. Print a `REGTEST_DUAL_SEND_DRIVE_OK: …` line.

**Acceptance (Task 2):**
- `./simctl test regtest_dual_send` is **green on host**; two windows are visibly non-overlapping.
- `./simctl test regtest_dual_send --android` **skips cleanly** (exit 0, SKIP line), and a full
  `./simctl test --android` run stays green.
- B's on-chain address balance == 50_000_000 sats; A's wallet shows both `Received` and `Sent`.
- No residue: both app dirs gone, the shared `rt-<pid>` dir gone, no orphan `sim_regtest`/bitcoind/electrs.

## Known constraints / footguns (reviewers: confirm the test respects these)
- **Shared system clipboard on host.** Both Frostsnap processes share one `NSPasteboard`; the clipboard
  is NOT per-instance isolated. The flow must serialize clipboard use: read B's address into a Dart
  variable right after B copies it (before any later `setClipboard`), then seed A's recipient. Do not
  assume `b.getClipboard()` and `a.setClipboard()` touch different clipboards.
- **Failure-screenshot foregrounding.** `_bringAppToFront` activates by app name ("Frostsnap"); with two
  instances it may foreground the wrong window for a diagnostic screenshot. Diagnostics-only, not
  correctness. Note it; activating by PID is a possible later polish, not in scope.
- **Window slots are cosmetic.** Overlap or wrap is host-visual only; never let slot assignment affect
  correctness or teardown.

## Regression watch — reviewers, SCOUR for these
We have repeatedly reintroduced regressions on this branch. Both reviewers (codex commit-tier, ruthless
gate-tier) must explicitly verify, with file:line evidence:
1. **Single-instance behavior is unchanged.** All 5 existing `*_drive.dart` pass on host; `runScenario`'s
   observable behavior (defines passed to the app, fleet growth, failure capture, residue assertion) is
   equivalent. Diff `_cleanup`/`tearDown` for any dropped step.
2. **Exactly-once chain reap, after the apps.** No double-stop (was-AppSession + now-Scenario), no leak.
   Verify `AppSession.tearDown` no longer reaps the chain and `Scenario` reaps it exactly once in a
   `finally`, even when `body` throws and even when `launch` throws mid-way (partial-launch cleanup).
3. **Death-pipe intact.** The `RegtestSession` (`_backend`) is held for the whole scenario; SIGKILL-the-
   owner still self-reaps (regression test `regtest_owner_reap_test.dart` still passes). The borrowed
   chain ref on `AppSession` must never close `_backend.stdin`.
4. **`faucet()` still works for both faucet scenarios** with no edits to those files.
5. **Shared-daemon / `serve` path untouched** (`ensureRegtestBackend`, `AppSession.launch(withRegtest:)`,
   `simctl serve` interactive flow).
6. **No new residue** anywhere: app dirs, `rt-<pid>` dirs, `sim_regtest`/bitcoind/electrs processes,
   `adb reverse` entries (host path adds none).
7. **Android suite still green** — the dual test skips, the existing tests are unaffected.

Beyond local bugs: confirm the *model* is right — the chain is owned by the scenario, app instances
borrow it, and single-instance is genuinely the one-instance case of the same lifecycle (no parallel,
duplicated scenario-lifecycle code paths that can drift).

## Non-goals
- Two instances on one Android emulator (or multi-emulator dual). Host-only.
- Multi-threshold (N-of-M) wallets in the dual test — 1-of-1 keeps it focused.
- A per-test host-only registry in the runner (the in-scenario skip suffices).
- Reworking the shared persistent `serve` daemon lifetime.
