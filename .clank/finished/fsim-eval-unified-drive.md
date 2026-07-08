# fsim-eval-unified-drive
# fsim-eval-unified-drive — one session core + a Dart-eval drive surface for test AND interactive

## Goal

Collapse `fsim`'s TWO parallel implementations of "a sim session" — interactive `fsim up`/`serve` vs
`fsim test` — into ONE dir-scoped session core with ONE drive language: Dart calling the harness API. The
interactive path ships LIVE Dart to a running session (`fsim eval "<dart>"` / `fsim repl`) instead of a fixed
command vocabulary; the test path runs a Dart file against the same core. This retires the hand-wired
`_dispatch` command table and the DEAD `ensureRegtestBackend()` launch path — the last place the
pre-`fsim-dir-scoped-sessions` model lingered. (Task 2 also FLATTENS the session dir — the regtest's files sit
at the root as `regtest.sock`/`.url`/`.log`, not a `regtest/` subdir — so the interactive and test session
dirs are one flat shape; `ensureRegtestBackend` STAYS only for the standalone `fsim regtest up`.) Net: a test
is `fsim eval` shipped as a file with harness-style output; a REPL is `fsim eval` kept open with interactive
output. Same core, same API.

## Grounded context (the duplication)

Two implementations of one thing — "a directory-scoped session = a regtest + N app instances, driven by Dart
against the harness":
- **Interactive** (`test_driver/fsim.dart` `_serve`): a long-lived daemon owns ONE `AppSession`, binds
  `<dir>/.fsim/control.sock` + `liveness.sock`, and answers a FIXED vocabulary — `_dispatch` hand-maps ~40
  `fsim tap/chain/hold/swipe/add-device/set-chain/clipboard/...` cases to harness methods.
- **Test** (`_runTests` → `_runOneTest` → `dart run <file>_drive.dart`): the test process IS the driver —
  `Scenario.run`/`runInstances`/`runDual` provisions N `AppSession`s and drives them IN-PROCESS by calling
  the SAME harness methods.

So the harness API (`AppSession.tap`, `createWallet`, `_requestData`, `faucet.mine`, …) is ALREADY the shared
drive layer — `_dispatch` and the test files are two front-ends onto it. What's duplicated + inconsistent is
the SESSION SETUP and the DRIVE LANGUAGE:
- Two roots: `<dir>/.fsim` (interactive) vs `simTmpRoot/rt-<pid>` (test).
- The regtest is ALREADY mostly unified (verified in Task 2, correcting an earlier misread): `startRegtestSession`
  (per-session, self-reaping) is the model for BOTH the interactive serve (`<dir>/.fsim/regtest`) AND every test
  (single-scenario AND dual go through `Scenario.run` → line 136 `_startChain` → `startRegtestSession(rt-<pid>)`;
  `Scenario.launch` then BORROWS that chain via `_regtest.defines`). What actually differs is only the ROOT scheme
  (`<dir>/.fsim` vs `simTmpRoot/rt-<pid>`). The SHARED `ensureRegtestBackend()` is (a) DEAD in the launch path —
  `sim_harness.dart:749` has NO `AppSession.launch(withRegtest: true)` caller after `fsim-dir-scoped-sessions`
  Task 2 (serve passes `false`; `Scenario.launch` borrows) — and (b) alive ONLY in the standalone `fsim regtest up`
  command (`regtest.dart:448`).
- Multi-instance (`runInstances`/`provisionInstance`) exists ONLY in the test path; interactive is stuck at
  one — which is why `fsim up --instances N` reads as new work rather than exposing what's there.
- `fsim-dir-scoped-sessions` Task 4 was a reconciliation pass (prove `.fsim` and `rt-<pid>` don't collide) —
  the tell that the model is duplicated.
- Two drive vocabularies: tests write Dart (harness calls); the CLI writes fixed strings that `_dispatch`
  maps to the same harness calls.

The enabler: the sim runs in JIT/debug with a VM service (flutter_driver already speaks it). The VM service
`evaluate` RPC compiles + runs a Dart expression against a target isolate/scope — the mechanism the Dart
debugger's expression-eval + REPL tools use. So a live daemon CAN run shipped Dart against a scope that
exposes the session/harness API.

## Design

- ONE session model + ONE flat layout: both the interactive daemon and the test runner provision a
  per-session self-reaping regtest via `startRegtestSession`, driven by the same harness API. (Multi-INSTANCE
  provisioning via `provisionInstance` is the TEST path's only for now — the serve does a single
  `AppSession.launch`; Task 4 extracts the shared instance-provisioning helper the serve's `up --instances N`
  and `Scenario.provisionInstance` both use.) Task 2 retires the DEAD `ensureRegtestBackend` launch branch AND
  flattens the
  session dir so the regtest's files sit at the root (`regtest.sock`/`.url`/`.log`, no `regtest/` subdir) —
  making the interactive (`<dir>/.fsim`) and test (`rt-<pid>`) dirs one shape (a test = interactive minus the
  three daemon-only files: `control.sock`, `serve.log`, `liveness.sock`). `ensureRegtestBackend` stays only
  for the standalone `fsim regtest up`.
- ONE drive API: the harness (`AppSession` + `faucet` + the device API), exposed on the DRIVER side (the
  daemon, where the harness lives — the app stays a `requestData` responder) as a well-known console scope:
  `session` / `instances[K]` / `faucet` / the device API.
- Interactive = the session core kept alive + Dart shipped to it. The daemon runs with its OWN VM service
  enabled; `fsim eval "<dart>"` evaluates the snippet against the daemon's live isolate scope (STATE PERSISTS
  across evals — the daemon isolate is long-lived, so `var a = await session.receiveAddress()` then a later
  `await faucet.fund(a, …)` works). `fsim repl` is a prompt over the same eval.
- Test = a Dart file run against the session core. A test file is a PROGRAM (imports/helpers/`main()`), not an
  expression, so `fsim test file.dart` stays `dart run` (mechanism B below), launching a fresh session on the
  unified core. (ATTACHING a full-program test file to a live `up` session is the deferred follow-up — see
  Task 4; live-session driving is already via `eval`/`repl`.) Test-harness output (pass/fail/timing/failure
  artifacts) vs eval's REPL result — one core, two presentations.
- The `_dispatch` command table RETIRES: anything a `fsim tap/chain/...` did becomes `fsim eval
  "session.X(...)"`; any new harness method is instantly drivable — the CLI-parity principle becomes
  structural, not a chase.

Two eval mechanisms and why the split:
- (A) VM-service `evaluate` against the daemon's long-lived isolate — fast, STATEFUL across calls (a REPL
  needs this), but expression-oriented (fixed scope, no new imports/top-level decls; `await` support has
  caveats). Powers `eval`/`repl`.
- (B) `dart run` a full program on the session core — full Dart (imports/helpers), fresh scope per run,
  `dart run` startup cost. Powers `test` (already how `_runOneTest` works). Attaching a whole file to a LIVE
  `up` session (rather than launching fresh) is the deferred Task-4 follow-up.
Both meet at the session core + the harness API — that's where the actual duplication is.

## Task 1 — SPIKE: prove VM-service `evaluate` carries drive snippets against a live harness

De-risk the one open technical question FIRST, throwaway-quality. Run the fsim daemon with its own VM service
enabled; wire a minimal `fsim eval "<dart>"` that reaches the daemon's isolate and `evaluate`s the snippet
against a scope exposing a `session`. Confirm it handles the shapes drive code needs — a harness method call,
`await`, a `for` loop — AND that STATE PERSISTS across two separate evals (long-lived isolate). Write down the
concrete limits (statements vs expressions, `await` support in the installed Dart, imports, whether the
client connects to the daemon's VM service directly or `control.sock` relays to it). If evaluate can't carry
drive snippets, record the fallback (mechanism B for `eval` too, or a thin retained command set) and adjust
the later tasks BEFORE any refactor.
- **Acceptance:** on a running daemon, `fsim eval "await session.<call>; <expr>"` runs and returns a result;
  a second `fsim eval` observes state set by the first; the limits + chosen transport are documented. No
  production wiring — this only answers "does eval carry the drive surface, statefully?"

## Task 2 — retire the dead backend + FLATTEN the session layout to one shape

Two parts:

**(1) Dead backend — DONE (milestone 1).** The REGTEST + session setup is shared: both the interactive serve
AND every test go through `startRegtestSession` + the same harness API. (INSTANCE provisioning is NOT yet
unified — the serve launches a single bare `AppSession.launch`, while `Scenario.provisionInstance` owns the
N-instance path; Task 4 extracts the shared instance-provisioning helper both call.) Deleted the dead
`ensureRegtestBackend` branch in `_launchApp` (no `AppSession.launch(withRegtest: true)`
caller) + its `withRegtest`/`regtestElectrumUrl` plumbing — no shared backend left in either provisioning
path. The standalone `fsim regtest up` (`regtest.dart:448`) keeps `ensureRegtestBackend` as an explicit
standalone persistent chain (its own thing, not a session) — correct, so it stays.

**(2) Flatten the session dir.** Today the regtest lives in a `regtest/` SUBDIR
(`<root>/regtest/control.sock`, `electrum_url`, `backend.log`) ONLY because `startRegtestSession(dir)` is
written to OWN a dir and hardcodes `<dir>/control.sock` — and in an interactive session the root's
`control.sock` is already the daemon's, so the regtest can't own the root. Since `sim_regtest` takes the
socket/url as PATHS (`--control-socket`, `--url-file`), parameterize `startRegtestSession` to place the
regtest's files FLAT at the session root with distinct names — `regtest.sock`, `regtest.url`, `regtest.log` —
and drop the subdir. Then interactive (`<dir>/.fsim`) and test (`rt-<pid>`) session dirs are ONE flat shape:
```
control.sock  serve.log  liveness.sock   ← interactive-only (the daemon's 3 extra files)
regtest.sock  regtest.url  regtest.log    ← the chain (both)
emulator-serial                           ← android only
app-<K>/                                   ← per-instance app state (a dir by nature)
```
A test is genuinely an interactive session MINUS those three daemon files — not a different structure. The
`.fsim/regtest/...` socket-length fragility disappears (`.../regtest.sock` is well under the 100-char guard),
so no forced root-name unification is needed: the roots differ (`.fsim` vs `rt-<pid>`) but the layout inside
is one shape.

OWNERSHIP/CLEANUP (load-bearing — this flatten's real hazard): today `RegtestSession` OWNS its whole *dir* —
`stop()` and `reapRegtestSessionDir()` RECURSIVELY DELETE it (`regtest.dart:299`, `:331`). That is only safe
because the regtest currently owns a DEDICATED dir (`rt-<pid>` / `.fsim/regtest`). Once the regtest's files
share the session root with the daemon files (`control.sock`, `serve.log`, `liveness.sock`) and the app dirs,
the regtest must own only its OWN paths — `regtest.sock`, `regtest.url`, `regtest.log`. So `RegtestSession`
must stop tracking a dir-to-recursively-delete: `stop()` + timeout reaping reap the backend PROCESS GROUP (as
today) and then delete ONLY those named files — NEVER `delete(recursive)` on the session root. (bitcoind/
electrs datadirs already live in separate `createTemp` dirs, reaped by the process-group kill, not by removing
the regtest dir, so nothing else depends on the recursive delete.) Also update the reap call sites + the
app-side `SIM_REGTEST_CONTROL_SOCKET` consumer for the flat paths.

- **Acceptance:** no shared regtest backend in the provisioning paths (only standalone `fsim regtest up`); the
  regtest's files are FLAT at the session root (`regtest.sock`/`.url`/`.log`, no `regtest/` subdir) for BOTH
  interactive + tests; a graceful stop / a timeout reap removes ONLY the regtest's own files + reaps the
  backend process group — the session root, daemon files, and app dirs SURVIVE a regtest reap (no
  `delete(recursive)` on the session root); `./fsim test ... --jobs N` stays green; `fsim up` then
  `fsim regtest fund/mine` still drives the chain (the app tray + CLI reach the moved socket).

## Task 3 — `eval` + `repl`; retire the `_dispatch` command table

Expose the driver-side console scope (`session`, `instances[K]`, `faucet`, the device API) and implement
`fsim eval "<dart>"` (evaluate against the daemon's live isolate, state persisting across calls) + `fsim repl`
(a prompt over eval, result/error styled interactively). Migrate the drive surface to the harness API and
DELETE `_dispatch` (the ~40 `fsim tap/chain/hold/...` cases), keeping only genuinely non-drive verbs
(`up`/`serve`/`down`/`info`/`clean`/`regtest`/`shot`). Update the usage + the CLI-parity story: everything the
tray/old-commands did is `fsim eval "session.X(...)"`.
- **Acceptance:** each retired command has an `fsim eval "..."` equivalent that does the same thing on a live
  session; `_dispatch` is gone; `fsim repl` drives a session interactively with persistent state; no
  advertised-but-broken command surface remains.

## Task 4 — `test` + `up --instances N` on the unified core; two output presentations

`fsim test file.dart` runs the file (`dart run`, full program) against the session core, launching a fresh
session, with test-harness output (pass/fail/timing + failure artifacts). (Attaching a full-program test file
to a live `up` session is the deferred follow-up below.)
`fsim up --instances N` holds N `AppSession`s on the session's ONE regtest, each drivable through the eval
scope (`instances[K]`). One core; `test` and `eval`/`repl` differ only in presentation.

**Instance-provisioning unification (prerequisite, surfaced while scoping Task 4):** `up --instances N` needs
the serve to provision N `AppSession`s on one regtest, but today only the Scenario path does N-instance —
`Scenario.provisionInstance` (host: `launch` with a per-instance window slot; android: a per-instance
emulator + regtest bridge) — while the serve does a single bare `AppSession.launch`. These are NOT unified:
Task 2's re-scope was right that the REGTEST is shared (`startRegtestSession`), but the INSTANCE provisioning
is not. So Task 4 first extracts a shared instance-provisioning helper — `(regtest, flutterDevice, appDirRoot,
index, total, deviceCount, defines) -> AppSession` — that BOTH the serve (`up --instances N`) and
`Scenario.provisionInstance` call, so the "N windows on one chain" shape has ONE implementation (no duplicated
launch loop). Android multi-instance under `up` may defer/skip like `runDual`'s host-only cases; host is the
primary `up --instances N` target.

**Status — DELIVERED + gate-accepted:** the shared seam (`Scenario.provisionAppInstance`, called by BOTH the
serve and `Scenario.provisionInstance`), `fsim up --instances N` + the `instances[K]` console scope, the
android single-instance guard (`--android --instances N>1` rejected before booting), and the two output
presentations (`fsim test` harness-style, `fsim eval`/`repl` REPL-style) are all in. `fsim test` is green on
the unified core (keygen/regtest_receive/regtest_dual_send).

**Attach — deferred follow-up.** ATTACHING a `dart run` full-program `_drive.dart` test file to a LIVE `up`
session is a DIFFERENT mechanism than the shared-seam work above, not a quick finish: a test file launches its
OWN app via `Scenario.run`, so attach means the daemon publishes each app's VM-service URI and `Scenario.run`
(under an attach flag) builds an `AppSession` by connecting a NEW flutter_driver client to the live app
(`AppSession.attach(uri)`) instead of launching — with two-drivers-on-one-app correctness (the daemon's driver
+ the attached one) to settle. Live-session Dart DRIVING already exists via `fsim eval`/`repl` on the SAME
shared core, so this is a dev-loop convenience (reuse a test file against a running `up`), not a gap in the
core. Pull it back into scope if the speedup is wanted.
- **Acceptance:** `fsim test` green on the unified core (DONE); `fsim up --instances 2` opens two windows on
  one chain, both driveable via `fsim eval` (DONE); test output (harness-style) and eval output (REPL-style)
  are each appropriate (DONE); host-only multi-instance skips cleanly (DONE — `--android --instances N>1`
  rejected). The `fsim test`-FILE attach to a live session is the deferred follow-up above; live-session
  driving is via `eval`/`repl`.

## Notes

- Phased deliberately: Task 1 answers the one open technical question BEFORE the refactor; Task 2 retires the
  dead/shared backend from the session paths (mostly the pre-existing sharing + a dead-code deletion — see its
  re-scope, not a big rewrite); Tasks 3-4 are the front-ends (the real payoff). Each is a reviewable milestone;
  Task 1's + Task 2's findings reshape the later work.
- Leaf/kSim invariant holds: host/runner orchestration + Dart lifecycle + a driver-side eval; no
  esp/embedded, device, or wallet-logic changes. The app stays a `requestData` responder throughout.
- `fsim eval` runs arbitrary Dart in the daemon — expected + fine for a dev/sim harness (not a security
  surface).
- Safety valve: if the Task-1 spike shows evaluate can't carry a stateful REPL (state/await/statements), fall
  back to mechanism (B) for `eval` (per-snippet `dart run` that re-attaches — slower, and stateless unless we
  persist a scratch context) or keep a thin command set. Decide at the spike, not mid-refactor.
