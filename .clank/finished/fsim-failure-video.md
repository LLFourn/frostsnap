# fsim-failure-video

`fsim test --record-failures`: when a test FAILS (after any `--retries` budget), re-run it once solo with
screen recording; save the mp4 into that test's failure-artifacts dir. The re-run is diagnostic only — the
verdict stands.

## Why

CI failures currently yield end-state screenshots + logs (`_captureFailure` → `build/sim-failures/<test>/`,
uploaded by sim-e2e.yml) — good, but a video of the whole run shows HOW it got there. Recording everything
always is wasteful and muddy (parallel tests share one X display / android caps at 180s); recording a solo
re-run of just the failed test is clean and cheap. Verdict-neutrality follows fsim-opt-in-retries: the
re-run never flips a failure to green.

## Design

- New `fsim test` flag `--record-failures` (default off). After a test's FINAL result is failed (post
  `--retries`), the runner re-runs that one test with a platform recorder bracketing the child process.

- **A distinct POST-BATCH diagnostic phase — never another ordinary attempt.** `_runBounded` runs peers
  concurrently until the whole batch completes, and `_runOneTest` CLEARS the test's artifacts dir on entry —
  so a rerun hooked per-result would record other Xvfb windows AND destroy the original failure evidence.
  Committed model: freeze the primary results after `_runBounded` returns, then process the final failures
  SEQUENTIALLY (solo — nothing else on the display/emulator) in a diagnostic phase. Diagnostic results are
  never appended to `results` and never feed retry/JUnit/summary/exit decisions.
- **Original evidence is inviolable.** The diagnostic child writes to a separate location
  (`<test>/rerun/`, via an artifacts-dir override — no clearing of the primary dir): the original
  `error.txt`, `output.log`, screenshots, and device frames stay byte-for-byte intact. The video
  (`rerun-N.mp4` segments) and `rerun-passed.txt` live at the test dir root → the sim-e2e.yml
  `sim-failures` upload picks everything up with NO CI change.
- **ANDROID-ONLY (user rescope): recording requires `--android`** — the recorder is `adb -s <serial>
  shell screenrecord` from the runner, on any host OS. The diagnostic child SELF-BOOTS its emulator, so:
  launch the child, wait boundedly for `sys.boot_completed` on the deterministic slot serial, then
  start/churn 180s screenrecord segments (to `/data/local/tmp` — `/sdcard` is briefly unwritable right
  after boot); the child LEAVES its emulator running (`SIM_KEEP_EMULATOR=1`) so the runner can
  SIGINT-finalize + pull, then the runner reaps the slot. Cleanup (recorder finalize + emulator reap) is
  try/finally-invariant — it runs even when the child/boot/pull throws.
  `--record-failures` WITHOUT `--android` is rejected at parse time on every host (surface reflects
  capability). A host x11grab recorder was built + validated on fork CI, then REMOVED by user decision:
  the linux CI job stays a fast desktop-app job (screenshots + logs on failure suffice there), and
  putting the android emulator in CI just to record videos would be slow + flaky — if an android CI job
  ever exists, it gets these videos for free.
- Verdict, JUnit, and summary are unchanged by the re-run. If the re-run PASSES, say so on stderr and
  write `rerun-passed.txt` alongside the video (flake evidence, verdict still failed).
- Recording the re-run (not the original) is deliberate: the original may run in parallel with other tests
  on a shared display, and pre-emptive recording taxes every green test. Trade-off: a flaky failure may not
  reproduce on the re-run — that's what `rerun-passed.txt` documents.
- Help text documents the flag + platform support; COMMANDS.md untouched (runner flag, not a session verb).

## Task 1 — implement + validate

- Flag parsing (reject `--record-failures` without `--android` at parse time on every host), the
  post-batch sequential diagnostic phase in the runner, the android boot-wait + chained-screenrecord
  backend with try/finally-invariant cleanup, artifacts as above.
- Unit-test the pure logic: record only on final failure and only when the flag is set; the usage
  rejection (no `--android` → error, with `--android` → allowed on any host); the deferred/sequential
  diagnostic scheduling (an async sequential runner: max concurrency one, order preserved, a failing item
  never blocks later items); and that frozen primary results are preserved untouched.
- Validate ANDROID locally: `fsim test <deliberately-failing> --android --record-failures` on the emulator
  → rerun mp4 segment(s) in the failure dir (emulator env permitting — HVF exhaustion may require a host
  reboot; if blocked, say so rather than fake it).
- Validate the parse-time rejection (`--record-failures` without `--android`).

## Out of scope

- Host recording (linux x11grab was built + fork-CI-validated, then removed by user rescope; macOS
  screencapture never started) — the linux sim-e2e CI job keeps failure screenshots + logs only.
- Running android-emulator tests in CI (slow + flaky on runners; separate experiment if ever wanted —
  it would inherit these videos for free).
