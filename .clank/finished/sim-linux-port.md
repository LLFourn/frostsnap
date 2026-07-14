# sim-linux-port
# sim-linux-port — make the sim app + test harness run on Linux

## Goal

Make the Frostsnap sim (`./simctl` + the `*_drive.dart` e2e tests) run on a **Linux** machine, so a Linux
laptop can reproduce/debug/fix issues and add regression tests. Primary target: the **android** path
(`./simctl test --android`, the self-booting emulator tests from sim-unify-app-host). Secondary: the
**host desktop** path (`./simctl serve` / `./simctl test` against a Linux Flutter desktop app).

**Validation is DEFERRED to a real Linux machine** — this repo's dev box is macOS, so the plan makes the
code Linux-READY and ships a setup guide; the human runs it on a Linux laptop and reports failures, which
become follow-ups. Every task states its Linux acceptance so the human can check it there.

## Grounded context (what actually ties us to macOS)

Nothing hard-ties the ANDROID path — CI already builds the APK on `ubuntu-latest`
(`.github/actions/build-android`: flutter + rust `aarch64/armv7-linux-android` targets + Java + Android SDK
+ NDK r25c), and the regtest backend is a Rust `sim_regtest` binary that downloads Linux bitcoind/electrs
(via the `electrsd`/`bitcoind` crates). Our self-boot (`ensureSdkPackages` installs the emulator +
`system-images;android-34;...;x86_64` on x86_64 Linux → runs on KVM) is self-contained.

The mac-ties are in the HOST DESKTOP path + a few tools:
- `AppSession.ensureMacosSimAppBuilt` is macOS-only; the runner gates it `Platform.isMacOS`
  (`test_driver/simctl.dart:523`) with NO Linux equivalent → on Linux `hostAppBinary` is null.
- The app-launch path assumes a macOS `.app` bundle: `build/macos/.../Frostsnap.app/Contents/MacOS/Frostsnap`
  (`test_driver/sim_harness.dart:502`), and `shareHostAppDir` is gated `flutterDevice == 'macos' &&
  Platform.isMacOS` (`sim_harness.dart:788`, `798`).
- Screenshots are NOT mac-tied: the whole-app `shot` + failure-artifact screenshots already go through the
  cross-platform app-channel `AppSession.screenshot` (`simctl.dart:1353-1354`, `sim_harness.dart:350`, and
  the `1372` comment). The ONLY OS-tool screenshot is the host timeout diagnostic, which already branches
  `Platform.isMacOS` → `screencapture` / `Platform.isLinux` → `scrot` (`simctl.dart:772-778`).
- Old comments reference `osascript`-foregrounding the window (`sim_harness.dart:1373`) — macOS-only; the
  app-channel screenshot should make it moot on Linux.
- `lib/main.dart:183` + `lib/settings.dart:202` already have `Platform.isLinux` branches, so the APP itself
  is expected to run on Linux desktop.

## Task 1 — Android-on-Linux readiness (the primary target)

Audit the `--android` test path (`simctl.dart` dispatch → self-boot in `sim_harness.dart` provisionInstance
→ `emulator.dart` → regtest bridge) for any macOS-only assumption, and remove/branch it so
`./simctl test --android` is Linux-ready. Expect this to be SMALL — the android build already runs on Linux
CI and the self-boot is host-arch-aware (`hostArchIsArm()` picks the x86_64 image on Linux).
- Verify no `Platform.isMacOS`-gated code sits on the android path (the dispatch's host-binary gate is
  host-only and already skips when `--android`).
- Confirm the emulator boot flags (`-gpu auto`, `-no-snapshot`, etc.) + `adb` paths resolve from
  `androidSdkRoot()` on Linux; KVM is an ENV concern (documented in Task 3), not code.
- Screenshot/diagnostics on the android path go through adb, not `screencapture` — confirm.
- **Linux acceptance:** on a KVM-enabled x86_64 Linux box with the SDK base installed,
  `./simctl test --android regtest_receive` and `regtest_dual_send` go green (the human runs this).

## Task 2 — Linux host-desktop build + launch path

Give the host path a Linux equivalent of the macOS app so `./simctl serve` / `./simctl test` (no `--android`)
work on Linux desktop:
- Add `AppSession.ensureLinuxSimAppBuilt` mirroring `ensureMacosSimAppBuilt` (build the Flutter **linux**
  desktop app once: `flutter build linux --debug` with the sim dart-defines; the binary is
  `build/linux/x64/debug/bundle/Frostsnap` — `frostsnapp/linux/CMakeLists.txt:7` sets
  `BINARY_NAME "Frostsnap"`, so it is capital-F `Frostsnap`, NOT `frostsnapp`).
- Wire the runner dispatch (`simctl.dart:523`): `Platform.isMacOS → ensureMacosSimAppBuilt`,
  `Platform.isLinux → ensureLinuxSimAppBuilt`.
- Generalize the app-launch (`sim_harness.dart` ~471-520, 788-798): support `flutterDevice == 'linux'`
  (the linux bundle path + `shareHostAppDir` on Linux) alongside `'macos'`.
- **Display**: the Linux desktop app needs an X/Wayland display. Make the harness/runner work under **Xvfb**
  (headless) — document `xvfb-run` usage (Task 3) and ensure nothing requires a real display beyond that.
- **Linux acceptance:** under `xvfb-run`, `./simctl test regtest_receive` (host) goes green on Linux.

## Task 3 — Linux setup guide

The screenshot path is ALREADY cross-platform, so there is NO screenshot code to port (codex verified):
the whole-app `shot` + failure-artifact screenshots go through `AppSession.screenshot` over the app channel
(`simctl.dart:1353-1354`, `sim_harness.dart:350` + the `1372` comment), not `screencapture`. The ONLY
OS-tool screenshot is the host TIMEOUT-diagnostic capture, and `simctl.dart:772-778` already branches
`Platform.isMacOS` → `screencapture` / `Platform.isLinux` → `scrot`. So this task is documentation only —
including `scrot` as the Linux diagnostic dependency.

- Ship `frostsnapp/test_driver/LINUX_SETUP.md`: the exact deps + commands to bring up a Linux laptop —
  flutter (linux desktop enabled: `clang cmake ninja-build pkg-config libgtk-3-dev` etc.), rust +
  android targets, Java + Android SDK/NDK (or note our `ensureSdkPackages` auto-installs the emulator +
  image), **KVM** enablement (`/dev/kvm` perms / kvm group) for `--android`, **Xvfb** for the host path, and
  **`scrot`** for the host timeout-diagnostic screenshot. Include the one-liners to run each suite.
- **Acceptance:** the doc lets a fresh Ubuntu box reach a green `./simctl test --android regtest_receive`
  and (host) `xvfb-run ./simctl test regtest_receive` — validated by the human on the Linux laptop.

## Out of scope / notes

- CI wiring (a GitHub workflow that runs these) is a SEPARATE follow-up — this plan is about the code +
  local Linux runnability, not automation.
- Because validation happens off-box, land tasks conservatively (branch, don't rewrite the macOS path) so a
  Linux-only bug can't regress the working macOS flow.
