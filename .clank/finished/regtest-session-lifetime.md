# regtest-session-lifetime
# Tie a per-session regtest node's lifetime to its owning test (kill-proof)

## Problem
Each e2e scenario gets its OWN regtest backend via `startRegtestSession` — a detached `sim_regtest`
process that owns bitcoind+electrs in its process group (datadir `rt-<owner-pid>`). It's reaped in
`runScenario`'s `try { … } finally { tearDown() }` → `RegtestSession.stop()`. That already ties the node
to the test for every GRACEFUL exit (pass or fail).

The gap is ABNORMAL death. The reap is Dart `finally` code, which does NOT run when:
- the runner SIGKILLs a hung/timed-out test (`_reapHungTest`),
- the test hard-crashes, or
- `simctl` is Ctrl-C'd.

A `SIGKILL` can't run a `finally`, and the backend is detached (own session, survives its parent), so
the node orphans — reparented to init (`ppid=1`), bitcoind/electrs still alive. Confirmed live this
session: one `rt-<pid>` backend whose owning test process was gone. The nodes are tiny (~60MB RSS each),
so this is process hygiene / correctness of the ownership model — NOT a performance fix.

## Goal / invariant
A per-session regtest node's lifetime is bound to its owning test process UNCONDITIONALLY — including
SIGKILL/crash/Ctrl-C — by construction, not by cleanup code a kill can skip. The binding is an invariant
of `RegtestSession`: you cannot obtain a session backend that isn't tied to its owner. This is NOT
opt-in — it lives inside the one function tests use (`startRegtestSession`), whose sole caller is the
test path (`sim_harness.dart`).

## Approach — OS death-pipe on stdin
Bind the node's life to a pipe the owner holds, so the kernel enforces the tie:
- `sim_regtest` already centralizes shutdown on one `Arc<AtomicBool> stop` (set today by a `down`
  command and the SIGINT/SIGTERM handler); flipping it makes `serve` return and `Regtest` DROP, which
  already reaps bitcoind/electrs. Self-reaping is just one more setter of `stop`.
- The owner (the Dart test process) holds the write end of a pipe; `sim_regtest` watches the read end
  for EOF. When the test dies ANY way, the kernel closes its fds → EOF → `stop` → drop → reap.

PID-reuse-immune, SIGKILL-proof, immediate, portable (no `PR_SET_PDEATHSIG`, which is Linux-only).
Strictly better than watching `--owner-pid` (PID-based; needs a poll or platform-specific event code),
and avoids a runner-side reaper SWEEP (post-hoc reconciliation that reacts after the leak and can't
cover a Ctrl-C of the runner itself).

## Tasks
1. **Rust (`tools/sim_regtest`)** — add a `--reap-on-owner-exit` flag. When set, spawn ONE watcher
   thread that blocks reading stdin and, on EOF, sets `stop` (the existing shutdown path). The thread
   holds no `Regtest` reference, so the clean single-threaded server and its drop→reap path are
   untouched. Without the flag, behaviour is unchanged (the shared daemon never watches stdin).
2. **Dart (`startRegtestSession`)** — spawn with `ProcessStartMode.detachedWithStdio` (keeps the setsid
   detachment that lets the process group be reaped together) and pass `--reap-on-owner-exit`;
   `RegtestSession` must HOLD the `Process` so `proc.stdin`'s write end stays open for the session
   (closed only by owner death or `stop()`). `> log 2>&1` still redirects stdout/stderr — only stdin is
   the death-pipe. Make this INTRINSIC: every `startRegtestSession` is tied; no flag a caller can drop.
3. Keep `RegtestSession.stop()` as the graceful fast-path (explicit reap on normal teardown); the
   death-pipe is the backstop for abnormal death.

## Out of scope
The shared daemon (`ensureRegtestBackend`, used only by interactive `simctl up` / standalone
`simctl regtest up` — no test owns it) stays as-is: a deliberate daemon reaped by `regtest down`/`clean`.
Optional future follow-up: tie the interactive serve node to the long-lived serve daemon with the same
pipe, leaving only the explicit `regtest up` daemon ownerless-by-design.

## Verify
- Integration: start a scenario, `SIGKILL` the test process mid-run (simulating `_reapHungTest`), assert
  the `rt-<pid>` `sim_regtest` process group is gone within ~1s (no `ppid=1` orphan, no live
  bitcoind/electrs).
- Regression: a normal pass still reaps via `stop()` (no behaviour change); `ps` shows no leaked backend
  after a clean run.
