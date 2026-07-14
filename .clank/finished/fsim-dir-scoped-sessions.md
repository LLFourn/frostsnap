# fsim-dir-scoped-sessions
# fsim-dir-scoped-sessions — the session directory IS the session id (+ app-follows-serve on crash)

## Goal

Make an `fsim` session scoped to a DIRECTORY (default the cwd, or `--dir <path>`), so multiple agents /
checkouts can each run their own isolated `fsim up` + drive it concurrently without colliding — the way the
test runner already isolates per worker. The directory is the unique id: no `--session` flag, no shared
machine-global state. And make a hard-killed (SIGKILL'd/crashed) serve leave NOTHING behind — its regtest
(Task 2) AND its app window (Task 5). Fixes two frictions a real agent hit (below).

## Grounded context (why today's fsim collides)

Every interactive-session resource is anchored to a machine-GLOBAL root, not the session:
- `simTmpRoot()` = `${systemTemp}/frostsnap-sim` — a fixed path shared by ALL checkouts on the machine.
- control socket `_socketPath` = `${simTmpRoot()}/control.sock` — fixed, so one daemon; a 2nd `fsim up`
  just reuses-or-refuses the first.
- regtest = the shared `ensureRegtestBackend()` at `${simTmpRoot()}/regtest/control.sock`, deliberately
  PERSISTENT (reaped only by `clean`, never `down`).
- interactive emulator = fixed port `_interactivePort = 5554`.

Proven in the wild: the `full-app-sim-driver` worktree AND a separate `frostsnap-ci` checkout were both bound
to the same `$TMPDIR/frostsnap-sim/regtest/control.sock`; one session's `fsim clean` deleted the shared root
out from under the other's live backend, orphaning its `bitcoind` (a `sim_regtest`+`bitcoind`+`electrs` trio).

Two frictions this must fix:
- **(4)** `fsim down` does NOT reap the auto-spawned regtest backend — only `clean` does.
- **(5)** `fsim clean` deletes the shared root, killing OTHER sessions' backends (the collision above).

The isolation building blocks already exist and run green under `--jobs N` in the test runner:
`startRegtestSession(<dir>)` (a private chain that SELF-REAPS on owner death via the death-pipe —
`regtest-session-lifetime`), slot-derived window slots, and `provisionInstance`'s self-booted per-slot
emulators (`sim-unify-app-host`). This plan applies that model to the INTERACTIVE `up`/`serve`/client path.

## Design (settled)

- Session IDENTITY: the canonical INVOCATION cwd, or `--dir <path>`. No `--session` flag — where you run it
  IS the id.
- Launcher contract (load-bearing): the repo-root `./fsim` wrapper `cd`s into `frostsnapp/` before
  `dart run`, so Dart's `Directory.current` is the PACKAGE dir, NOT where the user ran `./fsim`. The wrapper
  captures `FSIM_INVOCATION_CWD="$PWD"` BEFORE that `cd` and forwards it; the Dart side resolves the identity
  as `--dir <path>` if given, else that env (canonicalized) — NEVER `Directory.current`. And `up`'s DETACHED
  `serve` spawn forwards the same `--dir` so the invoking client and the daemon it launches resolve the SAME
  state root.
- Disposable STATE ROOT: a named, gitignored child of the identity dir — `<dir>/.fsim/`. ALL session state
  lives under IT: control socket, regtest control socket + datadir, liveness socket, app dir, screenshots.
  The identity dir itself is NEVER the delete target — this is the load-bearing distinction: `clean` wipes
  only `<dir>/.fsim/`, so it can never `rm -rf` your worktree, and nothing scatters into the repo root.
- Socket-path guard: at startup, if the LONGEST unix-socket path under the state root would exceed the OS
  `sun_path` limit, ERROR OUT clearly ("session dir too long for a unix socket, use a shorter --dir") — no
  hashed-temp indirection; one rule, fail fast.
- Client routing: `fsim <cmd>` resolves its control socket from `<cwd-or---dir>/.fsim/`, so it always targets
  its own session's daemon.
- `down` reaps THIS session's backend (fixes 4); `clean` reaps + deletes ONLY `<dir>/.fsim/` after the
  daemon/backend checks (fixes 5). bitcoind/electrs speak TCP, so their datadirs are fine at any depth — only
  the unix sockets have the length constraint.

## Task 1 — directory-scoped state root + socket-path guard

Update the repo-root `./fsim` wrapper to capture the invocation cwd (`FSIM_INVOCATION_CWD="$PWD"`) BEFORE its
`cd frostsnapp` and forward it. Resolve the session identity in Dart as `--dir <path>` if given, else that
env canonicalized (NEVER `Directory.current`, which the wrapper has moved to the package dir), and derive the
state root `<dir>/.fsim/`. Route the control socket + all interactive artifacts through the STATE ROOT
instead of the fixed `_socketPath`/global `simTmpRoot()`. Add the startup socket-path-length check on the
state root (error, don't truncate/hash). `serve`, `up` (incl. its idempotent reuse/refuse AND its DETACHED
serve spawn, which must forward `--dir` so the daemon lands on the same root), the `fsim <cmd>` client,
`shot`, and `clean` all resolve the SAME `<dir>/.fsim/`. `up`'s shape-compatibility check stays, now per-dir.
- **Acceptance:** `./fsim up` run from a dir X (≠ `frostsnapp`) creates `X/.fsim/` and a subsequent
  `./fsim <cmd>` from X targets that daemon; two `fsim up` in different dirs run at once, each answering its
  own client; a deep `--dir` fails fast; state lands under `<dir>/.fsim/`, not the cwd or the global root.

## Task 2 — per-session regtest; `down`/`clean` scoped to the state root

`serve` starts its regtest via `startRegtestSession(<dir>/.fsim/regtest)` (the self-reaping-on-owner-death
chain) instead of the shared persistent `ensureRegtestBackend()`, holds it for the daemon's lifetime, and
reaps it in shutdown (the death-pipe is the backstop for a hard kill). A `regtestDirOverride` points
`fsim regtest` + `clean` at this session's own backend; the test runner leaves it null (shared backend
unchanged). `down` reaps this session's backend (friction 4); `clean` reaps + deletes ONLY `<dir>/.fsim/` —
never the cwd/worktree (friction 5).
- **Acceptance:** `fsim down` leaves zero orphaned `sim_regtest`/`bitcoind`/`electrs`; `fsim clean` deletes
  only `<dir>/.fsim/` and cannot touch a live backend in dir B; a killed session's backend still self-reaps
  (death-pipe).

## Task 3 — `up --android`: a per-session self-booted emulator

Interactive `up --android` uses the FIXED interactive emulator (port 5554, AVD `frostsnap_sim`), so two
concurrent `up --android` sessions collide on it. Give each session its own emulator by CLAIMING a free slot
— the piece `provisionInstance` gets from the runner's worker index, which an interactive session lacks.

- Slot claiming: interactive sessions draw from a DEDICATED slot range (`frostsnap_sim_session_*`, ports 5680
  down), distinct from both the test pool (5582 up) and the single interactive `frostsnap_sim` (5554), so
  concurrent interactive sessions AND a running test suite never collide. Claim the first free slot under a
  MACHINE-GLOBAL per-slot lock: atomic exclusive-create records the OWNER PID; the lock is STRICT on live
  owners (a live owner is never stolen, however long its first-run AVD/system-image download takes) and
  reclaimed only when the owner PID is gone, or — for a lock that never wrote its pid — past a short write
  grace. Under the lock, a FRESH `adb devices` recheck skips a slot a peer already booted + released (a
  snapshot would be stale). Bound the range; error clearly if all are busy.
- Per-slot boot: `ensureAvd(<session-avd-for-slot>)` (created on-demand, name-isolated) + `bootEmulator(port)`
  (`-wipe-data`, clean per session), reusing `emulator.dart`'s `bootEmulator`/`ensureAvd`/`killEmulator`.
- Record the claimed serial under `<dir>/.fsim` so `down`/`clean` reap EXACTLY this session's emulator —
  never a global sweep that could kill a concurrent test's pool emulator. Bridge the session's OWN regtest
  (Task 2) to the emulator over adb-reverse, per-serial per session.
- **Acceptance:** two `fsim up --android` in different dirs boot + drive DISTINCT emulators concurrently;
  each `down` reaps only its own session's emulator (no orphans); a concurrent `fsim test --android` run's
  pool emulators are untouched; an exhausted slot range errors clearly rather than colliding.

## Task 4 — reconcile the test runner with the dir model

The `test` runner isolates per worker (`simTmpRoot()/rt-<pid>` + slot-derived pool emulators) under the
shared global root, so an interactive `fsim clean` must not nuke a live test chain. The chosen (smaller)
convergence is to make `clean` refuse to touch anything outside its own session — delivered by Tasks 1-3:
`clean` deletes ONLY `<dir>/.fsim` and reaps ONLY the session's own regtest + emulator (no global sweeps),
while the runner reaps ONLY its own slots and dispatches BEFORE any interactive session root is resolved.
Make it explicit (usage text + a boundary comment) and confirm.
- **Acceptance:** an interactive `fsim clean` can't disturb a concurrent `fsim test` run, and vice versa;
  the parallel suite stays green at `--jobs N`.

## Task 5 — app follows serve lifetime: a hard-killed serve must not orphan the app window

After Task 2 the serve cleanly OWNS its regtest (a hard kill self-reaps it via the death-pipe), but the app —
a `flutter run` child — is only reaped on a graceful `down` or by closing its window; a serve SIGKILL
reparents and orphans the app (OBSERVED: a `kill -9` of the serve left a zombie `Frostsnap.app`). macOS has no
`PR_SET_PDEATHSIG`, so the robust fix is for the DEPENDENT (the app) to notice the OWNER (serve) is gone — the
app-level analogue of the regtest death-pipe. HOST DESKTOP ONLY: an app inside an emulator can't reach a host
unix socket and its "window" is the emulator, owned separately (Task 3).

Serve (host): bind a dedicated liveness unix socket `<dir>/.fsim/liveness.sock`, accept + RETAIN each
connection (so it isn't GC'd), and pass its path to the app through the PER-LAUNCH ENVIRONMENT (the same
channel `SIM_APP_DIR`/`SIM_REGTEST_*` ride — the host path direct-launches a PREBUILT binary whose
`--dart-define`s were baked at build, so a per-session define is impossible). Close it AFTER `tearDown` so
the watcher only fires on a hard kill; skip it for an emulator target. App (`main.dart`, kSim-gated): read
`SIM_SERVE_LIVENESS_SOCKET` from `Platform.environment` first (`String.fromEnvironment` fallback); if set,
connect (retrying briefly for the launch race) and `exit(0)` when the connection drops OR can't be
established — since the serve binds before launch, an unreachable configured socket means the owner is gone.
- **Acceptance:** on host, `fsim up` then `kill -9` the serve daemon → the app window closes ON ITS OWN (no
  orphaned `Frostsnap.app`); a graceful `down` and closing the window still tear down cleanly; a non-sim
  build never connects; an emulator launch is unaffected. Together with Task 2, a hard-killed serve then
  leaves NOTHING — no regtest, no app, no window.

## Notes

- The directory being the id means agents just `cd` to their own scratch/worktree dir (or pass `--dir`) —
  matching how they already work in isolated worktrees.
- Keep the leaf/kSim-only invariant: host/runner orchestration + Dart lifecycle + a sim-gated liveness
  watcher in `main.dart`; no esp/embedded, device, or wallet-logic changes.
- (Tasks 1-4 were the plan `fsim-dir-scoped-sessions`; Task 5 was its companion plan
  `fsim-app-follows-serve-lifetime`, merged here into the single commit that delivers them.)
