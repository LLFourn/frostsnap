# sim-android-build-once

Android `simctl test --jobs N` does not parallelize the way the host does. Every launch runs under a
global `flutter-build.lock` (`sim_harness.dart:188`, taken `blockingExclusive`), and on android that
lock wraps the entire `flutter run` up to the app's VM service coming up (`sim_harness.dart:381-398`) —
the build + install + launch. So N tests REBUILD the same APK one at a time (~40s each, serialized);
only the post-launch test EXECUTION overlaps. Booting N emulators barely helps — the serialized builds
dominate. Observed at `--jobs 5`: `android_safe_area` finished at 41.9s while the other four were still
queued behind the build lock, not yet built.

The host path already avoids this: it builds the app binary ONCE up front and threads it into every test
as `hostAppBinary` (`SIM_HOST_APP_BINARY`), reusing it — so host tests genuinely run in parallel. Android
re-builds per test. The APK is identical across tests anyway (same `test_driver/sim_app.dart`, same
`SIM=true`; only the host-side driver SCENARIO differs).

Goal: android builds the sim APK ONCE and reuses it across all pooled tests, so `--jobs N` becomes "one
build + N parallel installs/executions" instead of "N serialized rebuilds" — matching the host's
build-once model.

## Tasks

### Task 1 — Build the android sim APK once, thread it to the tests
- In `_runAndroidPool` (`simctl.dart`), build the debug sim APK once before the workers (e.g.
  `flutter build apk --debug -t test_driver/sim_app.dart --flavor direct --dart-define=SIM=true`) and
  pass its path to each test the same way the host passes `hostAppBinary` — a new env, e.g.
  `SIM_ANDROID_APP_BINARY`.
- The single build still holds `flutter-build.lock`; the per-test launches must NOT (they only install
  to their own emulator + launch, which doesn't touch `build/`).

### Task 2 — Launch from the prebuilt APK
- In `AppSession.launch`'s android branch (`sim_harness.dart:381`), when `SIM_ANDROID_APP_BINARY` is set,
  run `flutter run --use-application-binary=<apk> -d <serial> …` instead of the building `flutter run`,
  and do not take the build lock for it. The VM-service wait + driver connect are unchanged.

### Task 3 — Reconcile per-test config that's currently a compile-time define (LOAD-BEARING)
- A shared APK cannot carry per-test `--dart-define`s. The host gets away with reuse because the host
  app reads per-test settings from the inherited process ENVIRONMENT — but an android app runs on the
  emulator and does NOT inherit the host env. So anything currently passed per test as `--dart-define`
  (notably `SIM_DEVICE_COUNT`, also `SIM_AGENT_OWNS_KEYBOARD`) must be applied at RUNTIME after launch.
- Bake into the shared APK only what's invariant (`SIM=true`). Deliver the per-test device count at
  runtime — e.g. via a driver-data call right after connect (the harness already drives devices over the
  app channel: `deviceNumbers()` / add-device) — so the app spins up the test's count rather than a
  baked-in one.
- This is where it goes wrong silently: get it wrong and a 3-device test runs with 1 device and still
  "passes" the early steps. Assert the effective per-test device count (`deviceNumbers()` / the
  "Continue with N devices" coordinator signal) so a mismatch is a HARD failure.

### Task 4 — Verify parallelism + correctness
- `simctl test --android --jobs N`: assert exactly ONE build happens (one `flutter build` / one
  build-lock acquisition), the per-test launches genuinely overlap (timings interleave rather than
  stepping ~40s apart), and every test still passes with its correct device count.

## Non-goals
- Changing the host path (already build-once).
- The pool allocator, the per-test deadline, or the flake-retry.
- Pre-installing the APK out of band — let `flutter run --use-application-binary` do the install.
- Sharing one prebuilt APK across worktrees (each worktree builds its own; this is within one run).
