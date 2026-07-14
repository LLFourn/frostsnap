# android-sim-disable-cdcacm

Android sim tests run `flutter run -t test_driver/sim_app.dart --dart-define=SIM=true`, so Dart uses
`api.loadSim(...)` and simulated devices. The native Android shell still boots the normal
`MainActivity`, though, and `MainActivity.configureFlutterEngine()` unconditionally registers
`CdcAcmPlugin`. That is why `./simctl test --android` logs `CdcAcmPlugin attached/detached` even when
the app is a SIM build.

Goal: Android SIM builds must not register or run real USB/CDC-ACM native plumbing. They should keep
the simulated device pool as the only device transport, while preserving native pieces the sim still
uses such as `SecureKeyManager`.

## Tasks

### Task 1 — Expose `--dart-define=SIM=true` to Android native code
- Update `frostsnapp/android/app/build.gradle` to decode Flutter's `dart-defines` Gradle property and
  derive a boolean for the `SIM` define.
- Enable/generated `BuildConfig` if needed, and add a native boolean such as
  `BuildConfig.FROSTSNAP_SIM`.
- Keep default/non-sim builds unchanged: if `SIM` is absent or false, `FROSTSNAP_SIM` must be false.
- This should work for the existing command shape used by the harness:
  `flutter run -t test_driver/sim_app.dart -d <android> --flavor direct --dart-define=SIM=true`.

### Task 2 — Gate real USB registration in `MainActivity`
- In `frostsnapp/android/app/src/main/kotlin/com/frostsnap/MainActivity.kt`, skip
  `flutterEngine.plugins.add(CdcAcmPlugin())` when `BuildConfig.FROSTSNAP_SIM` is true.
- Also skip USB attach intent handling in sim mode; there is no real USB device path in sim tests.
- Keep `SecureKeyManager` registration active in sim mode because Android wallet creation still needs
  secure-key behavior.
- Log a short native line in sim mode, e.g. `SIM build: skipping CdcAcmPlugin`, so test output makes
  the intended path obvious.

### Task 3 — Verify sim and non-sim behavior
- Add a focused Android build/compile check that proves the Kotlin/Gradle wiring compiles, e.g.
  `./gradlew :app:compileDirectDebugKotlin` from `frostsnapp/android`.
- Run a small Android sim test such as
  `./simctl test app_channel_device --android --jobs 1 --test-timeout 240 --nocapture`.
- Confirm the sim test output no longer contains `CdcAcmPlugin attached` or `(FD Mode) detached`, and
  does contain the explicit sim-skip log.
- Ensure normal app builds still compile with `FROSTSNAP_SIM=false` so real USB remains available
  outside the test/sim entrypoint.

## Non-goals
- Replacing `flutter run` for Android test launching.
- Changing Dart sim device-pool behavior; Dart already uses `api.loadSim(...)` when `SIM=true`.
- Removing `SecureKeyManager` from sim builds.
- Reworking the Android manifest/source-set split unless it is required to make native USB inert in
  SIM builds.
