# sim-test-harness

`./simctl test` runs the e2e drivers across the emulator pool, but it is not yet a *test harness*:

- **Log spam, not results.** It dumps each test's raw app logcat (EGL frame stats, `frostsnap/rust`
  DEBUG, etc.) to the console. You can't see what's running or what passed without scrolling hundreds
  of lines.
- **No timeouts → it can hang forever.** A stuck `waitFor` ("waitFor message is taking a long time…")
  has no ceiling; a flaky keygen black-screen render hang stalled a run for **40 minutes** instead of
  failing the one test.
- **Diagnostics only on a thrown error.** `runScenario._captureFailure` writes screenshots + logs to
  `build/sim-failures/<test>/` only when a test THROWS. A hang/timeout captures nothing and tells you
  nothing.

Goal: make it a boring, reliable, CI-grade runner that behaves like `cargo test` — declare the tests,
run them, print clean per-test pass/fail + a summary, capture full output + screenshots to a known
directory on ANY failure or timeout, and never hang.

## Core model

A test is `{name, status: ok|failed|timeout|skipped, duration, artifactsDir}`. The runner, for each
test: captures its output to a per-test artifacts dir (NOT the console), enforces a hard deadline, and
on failure/timeout captures screenshots (app + every reachable device) + logs there. The console shows
ONLY cargo-test-style status; raw output lives on disk (or streams with `--nocapture`). Applies to both
host and `--android`.

## Tasks

### Task 1 — No more hangs: bounded waits + per-test timeout (+ clean reap)
- Audit `sim_harness.dart`: EVERY FlutterDriver op (`waitFor`, `waitForAbsent`, `tap`, `tapUntil`,
  `exists`, `enterText`, `getClipboard`, the `device(n)` ops) must pass a bounded timeout, so a stuck
  app FAILS the scenario (→ caught → diagnostics) instead of hanging. `waitFor` is the known offender.
- Runner: each test process gets a hard per-test deadline (default e.g. 300s, `--test-timeout N` to
  override). On expiry → status TIMEOUT, capture diagnostics (Task 2), then KILL the test and reap its
  resources: release its pool emulator and tear down its per-session regtest backend (no leaked
  bitcoind/electrs/emulator/flutter process), and carry on with the remaining tests.
- The harness driver timeouts are the first line; the runner deadline is the backstop for a wedged
  process that can't even reach its own `catch`.

### Task 2 — Diagnostics on EVERY failure + timeout, in a known place
- One location per test: `build/sim-failures/<test>/` — app screenshot, every device framebuffer,
  error + stack, AND the test's full captured stdout/stderr (`output.log`).
- In-test failures already self-capture via `_captureFailure`; keep that. ADD the timeout path: a hung
  process can't self-capture, so the RUNNER captures externally before killing — on android an
  `adb exec-out screencap` of the emulator + `logcat` dump (+ device framebuffers if the VM service is
  still answering); on host a `screencapture` of the app window. Always write the partial `output.log`.
- The summary prints the path for each non-pass: `… see build/sim-failures/<test>/`.

### Task 3 — cargo-test output + CI-ready
- Default: capture each test's raw output (incl. app logcat) to its `output.log`, NOT the console.
  Console shows: a `running N tests` header, per-test `test <name> ... ok | FAILED | TIMEOUT (12.3s)`,
  and a final `test result: P passed; F failed; T timed out; S skipped; finished in Ys`, with a
  `failures:` section listing each non-pass (name + one-line reason + artifacts path).
- `--nocapture` / `-v` streams raw output live for debugging (like `cargo test --nocapture`).
- CI fidelity: exit non-zero on any fail/timeout, zero only when all run tests pass (skips don't fail);
  no interactive prompts; optional `--junit <path>` (JUnit XML) so CI can ingest per-test results; a
  short README note on running the suite in CI (one command, where artifacts land, exit-code meaning).

## Non-goals
- Changing what the tests DO — this is harness, reporting, and reliability, not test logic.
- Replacing flutter_driver — keep it; just bound every call + capture its output.
- The android emulator pool concurrency ceiling and the flaky keygen render hang itself (separate
  issues; this plan makes the harness REPORT them cleanly + bound them, not eliminate the flake).
