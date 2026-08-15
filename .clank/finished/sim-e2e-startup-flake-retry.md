# sim-e2e-startup-flake-retry

The android e2e suite flakily fails a test at its FIRST driver interaction with
`DriverError: Failed to fulfill SetFrameSync due to remote error` (Original error: a `Collected` VM
sentinel), right after `[app] Lost connection to device`. It is non-deterministic — a different test
fails each run and passes the next (observed: `android_safe_area` fails at `--jobs 1` while `keygen`
passes; `keygen` fails at `--jobs 2` while `android_safe_area` passes) — so it is an infrastructure /
timing flake, not a logic bug.

Root cause (from `build/sim-failures/<test>/output.log`): on a freshly cold-booted emulator the app
janks hard at startup — `Choreographer: Skipped 98 frames`, `Davey! duration=1666ms`, "doing too much
work on its main thread" — and during that stall `flutter run` drops the VM-service connection. Every
harness driver call routes through `runUnsynchronized` (which toggles frame-sync), so the first command
after the drop fails with the SetFrameSync remote error and the whole test dies at its first `tapUntil`.
Worse under `--jobs 2` (two emulators contending) but happens at `--jobs 1` too.

Goal: a transient startup connection flake must not fail the run. A test that fails with the
connection-drop signature is retried from a FRESH app launch; a genuine assertion failure is NOT
retried; retries are always reported, never silent.

## Tasks

### Task 1 — Classify the transient startup flake
- In the runner (`_runOneTest`), add a predicate over the captured output that flags a non-zero exit as
  a TRANSIENT flake when the output matches the connection-drop signature — `Failed to fulfill
  SetFrameSync`, `Lost connection to device`, or a VM-service disconnect during startup — and does NOT
  contain a scenario `StateError`/assertion. A real failure must stay a real failure.

### Task 2 — Retry transient flakes from a fresh launch
- On a transient flake, re-run the test (a fresh `dart run` → fresh emulator app launch) up to a small
  bound (e.g. 2 retries). Report the outcome explicitly: `ok (retry k)` on eventual pass, or a FAILED
  result tagged transient when retries are exhausted. A non-transient failure returns immediately,
  unretried.
- Surface EVERY retry on the console and in the summary/JUnit (no silent masking) — e.g.
  `retried <test>: transient startup flake (k/N)` — so a chronically-flaky test stays visible rather
  than being quietly papered over.

### Task 3 — Regression test
- Cover the classify + retry seam: a synthetic run that emits the SetFrameSync/`Lost connection`
  signature and exits non-zero on its first attempt, then passes, is reported passed-on-retry; a run
  that emits a `StateError` is NOT retried and fails. Keep it host-runnable (drive the classifier and
  the retry loop directly; do not require a real emulator).

## Non-goals
- Reducing the app's heavy startup main-thread work (the underlying jank that drops the connection).
  That is a REAL app-perf issue — it would help real users on slow devices, not only the tests — but it
  is an app/FRB change and gets its own investigation. This plan makes the SUITE resilient to the flake;
  it does not pretend the jank is gone.
- Changing the pool, the per-test deadline, or the parallelism model.
- Retrying genuine assertion failures, or retrying a TIMEOUT (a wedged app is reaped, not a transient
  connection drop).
