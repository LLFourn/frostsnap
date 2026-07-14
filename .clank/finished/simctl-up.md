# simctl-up
# Ergonomic sim CLI: one idempotent `up`, a non-focus-stealing window, a shared regtest backend

## Goal
Three fixes so the sim is pleasant to drive — and so one regtest backend can be SHARED without
heavy isolation:
1. `./simctl up`: ONE idempotent command that brings the sim up and returns only when it's ready —
   no backgrounding + readiness polling by the caller, no fragile `> serve.log` redirect.
2. The sim app window must NOT steal focus when it launches. It can stay visible (no headless
   tricks) — we just don't want it grabbing the foreground/keyboard while you work.
3. ONE shared, persistent regtest backend — so sequential test runs REUSE it (no per-test node
   spin-up), AND a single test can drive MULTIPLE app instances (multiple "users" on one blockchain,
   each its own DB/wallet) without an app's teardown reaping the node from under the others.

## Why
Driving the sim today means: background `serve`, hand-roll readiness loops, and dodge the
caller-log-redirect gotcha. Launching the app also steals focus. And every `*_drive.dart` test
brings up its OWN regtest node: `ensureRegtestBackend` spawns one `owned:true` and the harness
teardown stops it, so the next sequential test starts a fresh node (slow) and — critically for the
future multi-user model — the FIRST app's teardown would pull the shared node out from under any
other app instances in the same test. Decided explicitly OUT of scope: per-session isolation /
`SIMCTL_SESSION`, offscreen/headless render tricks, Linux/Xvfb, and running many INDEPENDENT tests
concurrently against the shared chain (a shared chain makes their transient-state assertions race).

## Tasks
1. **serve self-logs + `./simctl up`.** `serve` writes its own output (its lines + the flutter
   `[app]`/`[app:err]` lines) to `${simTmpRoot}/serve.log` itself (e.g. an optional log `IOSink`
   into `SimHarness.launch`, default stderr) instead of relying on the caller's `>` redirect — kills
   the orphaned-log gotcha and lets it run detached. `./simctl up [serve flags]`: if a daemon is
   already live → `{ok:true, already:true}`, exit 0; else launch `serve` detached, poll the control
   socket until it answers (bounded; allow a cold build), exit 0. So `./simctl up --regtest --count
   3` brings everything up and returns only once ready — the caller never backgrounds or polls.
   **Live-daemon compatibility (committable rule, not "whenever a daemon is live"):** the daemon
   records its launch shape — device count, regtest on/off, keyboard mode — as metadata (a file by
   the control socket and/or an `info` reply on the control socket). `./simctl up` returns
   `{ok:true, already:true}` ONLY when a live daemon's recorded shape MATCHES the requested shape a
   fresh launch WOULD produce (count; regtest = `--regtest` OR an already-running backend that serve
   would auto-attach to; keyboard mode) — so `up` must compute its requested-regtest the SAME way
   `serve` does, else a plain `up` over a live backend would launch a regtest daemon and the next
   identical `up` would wrongly mismatch. On a real mismatch (e.g. `up --count 3 --regtest` against a
   live count-1 daemon) it exits non-zero with a clear "a different-shape daemon is running —
   `./simctl down` first" error. It must NEVER silently report a mismatched daemon as ready.
2. **Window doesn't steal focus (sim-only).** Launch the sim app WITHOUT activating it / making it
   key (e.g. background-launch the built `.app`, and/or don't `makeKeyAndOrderFront` on first show /
   set an activation policy so it doesn't jump to the foreground). The window stays visible; it just
   doesn't grab focus from whatever you're doing. No offscreen/headless tricks. This MUST be
   sim-only: gate it on the sim launch path (kSim / how the harness + `serve` launch the app) so a
   NORMAL production macOS app launch is unchanged, and it must not disturb the `flutter_driver`
   VM-service path the harness drives over.
3. **One shared, DELIBERATELY PERSISTENT regtest backend (single ownership model — no menu).**
   Drop the `owned:true`-then-stop behavior: tests, serves, and `./simctl test` runs only START the
   node if absent or ATTACH if present, and NEVER tear it down on their own teardown. The node is a
   persistent shared resource reaped ONLY by an explicit `./simctl regtest down` or `./simctl clean`.
   Crash cleanup is the existing `bind_control_socket` singleton, which reclaims a stale socket left
   by a dead node on the next start — so there's no lease/refcount to get wrong. What this enables:
   sequential `./simctl test` runs REUSE the one node (no per-test spin-up); and a SINGLE test can
   launch multiple app instances (each via `SimHarness.launch`, with its own app dir / DB / wallet)
   against the one blockchain — the future multi-user model (e.g. Alice and Bob on separate
   "computers" transacting on one chain) — with NO app's teardown reaping the node from under the
   others. A node persists after a run for reuse; reaped only by `./simctl regtest down` / `clean`.
   Each app uses a unique app dir + device sockets, so the chain is the only shared state.

## Acceptance
- `./simctl up [--regtest --count N]` exits 0 only once app+devices+(backend) are ready; a second
  matching `./simctl up` is a no-op (`already:true`). The caller never backgrounds or polls; `serve`
  self-logs regardless of how it's launched.
- `./simctl up` against a live daemon of a DIFFERENT shape (count / regtest / keyboard mode) exits
  non-zero with a clear "down first" error — it never falsely reports a mismatched daemon ready.
- Launching the sim does NOT steal focus from the active app, and production (non-sim) macOS launch
  is unchanged.
- `./simctl test` (all tests) runs sequentially against ONE shared regtest backend — not one node
  per test — and no test/serve teardown stops it, so a later test ATTACHES rather than respawning.
- A single test can launch multiple app instances (each its own app dir / DB / wallet) against one
  blockchain with no app's teardown reaping the node from under the others — the foundation for the
  future multi-user scenario.
- The shared node is reaped ONLY by `./simctl regtest down` / `./simctl clean` (which also reclaims a
  crashed node's stale socket); after those, no orphan bitcoind/electrs/app remains.
- Sim-only tooling; existing device/faucet commands unchanged; analyze + format + cargo green.

## Out of scope (decided)
No `SIMCTL_SESSION` per-session isolation, no offscreen/headless render, no Linux/Xvfb. The window
stays a normal (visible) macOS window that simply doesn't steal focus, and the regtest backend is
deliberately SHARED rather than isolated per test/session. Also dropped: running many INDEPENDENT
tests concurrently against the shared chain — a shared chain makes their transient-state assertions
(e.g. the receive test's "Receiving") race. The shared node's real job is sequential reuse + the
future single-test-multiple-apps (multi-user) model; building that multi-app test scenario is itself
a separate future plan, not part of this one.

## Depends on
sim-8-dual-channel-harness (SimHarness + the simctl control socket); sim_regtest (the faucet backend).
