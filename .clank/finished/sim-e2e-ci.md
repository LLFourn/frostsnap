# sim-e2e-ci

Run the fsim e2e suite as a separate Linux CI job: a new `.github/workflows/sim-e2e.yml` that builds the
debug sim app once and drives the full `fsim test` roster headlessly under Xvfb.

## Why

The sim harness is the only automated coverage of real app flows (keygen, send/receive, recovery), and today
it only runs on developer machines. The tests are semantics-driven (FlutterDriver labels, not pixels), so a
virtual framebuffer is enough — the drive headers already anticipate "Xvfb on Linux CI". The job runs with
the fsim default of ZERO retries: the previously-known keygen-finalize flake's real fix has landed
(keygen-save-settle-delay, f3e19268, on this branch), so there is no current defect justifying a retry
budget. If a real flake appears later, it opts in with `--retries` + its own tracked rationale.

## Facts established (verified against this branch + CI)

- No firmware artifact needed: `BUNDLE_FIRMWARE` unset → `frostsnapp/rust/build.rs` skips bundling, so the
  job does NOT need `build-device-firmware`.
- Toolchain preamble = `.github/actions/set-up-app-build` minus its firmware step: just, rust stable,
  flutter via `frostsnapp/.fvmrc`, `fetch-cargo-deps`, `fetch-dart-deps`, `generate-frb`,
  `install-cargo-bins`; plus the `build-linux` apt list (`ninja-build libstdc++-12-dev libgtk-3-0
  libgtk-3-dev cmake clang`) and `xvfb` + Mesa software GL (`libgl1-mesa-dri`, `LIBGL_ALWAYS_SOFTWARE=1`).
- `fsim test` self-builds everything else: `ensureLinuxSimAppBuilt` (`flutter build linux --debug -t
  test_driver/sim_app.dart --dart-define=SIM=true`) and `cargo build -p sim_regtest` (electrsd downloads
  pinned bitcoind 28.2 + electrs into `target/` — cacheable via `cache-rust-target`).
- All 7 `*_drive.dart` tests run on host (`android_safe_area` trivially passes: bottomInset 0). Android
  emulator CI is OUT OF SCOPE.
- Sandbox: iterate on the `LLFourn/frostsnap` fork (viewer ADMIN; user authorized pushing branches + opening
  PRs there). Master lacks the harness, so test branches are cut from `full-app-sim-driver`.

## Task 1 — workflow + prove it green on the fork

Add `.github/workflows/sim-e2e.yml`:
- `on: pull_request` + `workflow_dispatch` ONLY — no scratch-branch push trigger in the merge-ready file
  (fork iteration may temporarily add one on the throwaway branch, never landed here).
- Single job `sim-e2e` on `ubuntu-22.04`: checkout → preamble (above) → apt deps + xvfb →
  `xvfb-run -a -s "-screen 0 1920x1080x24" dart run test_driver/fsim.dart test --jobs 2
  --junit sim-junit.xml` (workdir `frostsnapp`; `--jobs 2` for the 4-vCPU runner; NO `--retries` — the
  fsim default of 0 is the permanent CI signal).
- Upload `frostsnapp/build/sim-failures/` as an artifact on failure + the JUnit xml always.
- `cache-rust-target` with its own key (debug target dir incl. the electrsd downloads).

Validation loop (keeps this branch's history clean): sync the fork's master from upstream
(`gh repo sync LLFourn/frostsnap --branch master`; verified our branch merges into current org master with
0 conflicts — if the fork's master can't fast-forward, push `origin/master` to the fork as a base branch
instead; never force-push the fork's master). Then push a throwaway `sim-e2e-ci-test` branch (= this branch
+ workflow commit(s)) to the fork and open a DRAFT PR against the fork's master, giving a clean merge-ref so
the `pull_request` trigger runs. Iterate on the scratch branch (`gh run watch` on the fork); squash whatever
it took into ONE commit here once green, linking the green run in the commit message.

Acceptance:
- A green `sim-e2e` run on the fork covering the FULL roster (link in the commit message), with the JUnit
  artifact showing 7 tests, and wall time recorded in the plan/commit.
- Workflow file lands on this branch as one reviewed commit; no changes to existing jobs.
- If a test proves chronically broken under Xvfb (not flaky — broken), do NOT paper over it with retries or
  skips: record it in the plan and block for discussion.

## Out of scope

- Android emulator job (KVM/boot-time question — separate plan if wanted).
- Wiring into `test.yml` / branch protection: the workflow stands alone until the sim branch merges to
  master; gating decisions are the human's.
