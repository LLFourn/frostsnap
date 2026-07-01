# Running the sim on Linux

The sim harness (`./simctl` + the `test_driver/*_drive.dart` e2e tests) runs on Linux — a native place to
reproduce bugs, fix them, and add regression tests. Two backends:

- **host desktop** — a Linux Flutter desktop app (`./simctl test`, `./simctl serve`/`up`), needs a display
  (real or Xvfb). No emulator.
- **android** — each test SELF-BOOTS its own emulator (`./simctl test --android`), needs the Android SDK
  and hardware KVM.

> Status: this port is **best-effort, validated on macOS + CI, not yet on a Linux box**. If something
> breaks, that's expected — capture the failure and it becomes a follow-up fix. The build toolchain here
> mirrors what CI already runs green on `ubuntu-latest` (`.github/actions/*`, `.github/workflows/test.yml`),
> so the build itself is well-trodden; the *runtime* (desktop-under-Xvfb, self-booted emulator) is the new
> part.

## 1. System packages (Ubuntu/Debian)

```sh
# Flutter linux-desktop toolchain (from .github/actions/build-linux)
sudo apt-get update
sudo apt-get install -y ninja-build libstdc++-12-dev libgtk-3-0 libgtk-3-dev cmake clang pkg-config
# Native codegen/build deps: libclang-dev for flutter_rust_bridge_codegen (bindgen), libudev-dev for the
# espflash cargo-bin (see .github/actions/install-cargo-bins)
sudo apt-get install -y libclang-dev libudev-dev
# Sim runtime extras: Xvfb for the headless host display, scrot for the host timeout-diagnostic screenshot
sudo apt-get install -y xvfb scrot
```

## 2. Rust, Flutter, just

- **Rust**: `rustup` stable. For `--android` also add the app's targets (from `build-android`):
  `rustup target add aarch64-linux-android armv7-linux-androideabi`.
- **Flutter**: pin to `frostsnapp/.fvmrc` (currently **3.38.5**), e.g. via `fvm`. Enable linux desktop:
  `flutter config --enable-linux-desktop`.
- **just**: `cargo install just` (or a package). Recipes live in `justfile`.

## 3. One-time codegen + firmware (the build needs both)

- **cargo binaries** — install `flutter_rust_bridge_codegen` (+ the other cargo bins the build uses); per
  `frostsnapp/README.md` this is the step that provides FRB codegen (needs `libclang-dev`, and `libudev-dev`
  for espflash — both in §1):
  ```sh
  just install-cargo-bins
  ```
- **flutter_rust_bridge bindings** — generate `frostsnapp/rust/src/frb_generated.rs`:
  ```sh
  just gen
  ```
  (`just build …` runs this via `maybe-gen`, but the sim build path calls `flutter build` directly, so run
  it once yourself. `simctl` auto-runs the dart `build_runner` step.)
- **Firmware at the conventional path** — the app embeds a device firmware binary at
  `target/riscv32imc-unknown-none-elf/release/<env>-frontier.bin` (see `justfile` `firmware_bin`). Either
  build it (`just build-firmware frontier` — needs the RISC-V GCC toolchain, see `build-device-firmware` in
  `test.yml`) or copy a released `*-frontier.bin` to that path. The sim uses VIRTUAL devices, but the build
  still links this binary in.

## 4. Android only (`--android`)

- **JDK 17** + the **Android SDK** command-line tools; set `ANDROID_HOME` (or `ANDROID_SDK_ROOT`, or
  `android/local.properties` `sdk.dir`, or the default `$HOME/Android/Sdk`). `simctl`'s `ensureSdkPackages`
  auto-installs the `emulator` package + `system-images;android-34;google_apis;x86_64` on first run.
- **NDK r25c** (matches `build-android`) for the APK build.
- **KVM** — the emulator needs hardware accel or it's unusably slow. Confirm `/dev/kvm` is present and
  writable by your user (`sudo apt-get install qemu-kvm`, add yourself to the `kvm` group, or `sudo chmod
  666 /dev/kvm`); `kvm-ok` reports status. On x86_64 Linux `ensureSdkPackages` picks the **x86_64** image,
  which runs on KVM.

bitcoind + electrs are NOT a manual dep — the Rust `sim_regtest` binary downloads pinned Linux builds on
first use.

## 5. Running

Host (under a virtual display):
```sh
xvfb-run -a ./simctl test regtest_receive      # one test
xvfb-run -a ./simctl test                        # whole suite (add --jobs N to cap parallelism)
xvfb-run -a ./simctl up                          # interactive: bring the sim up, then drive with ./simctl
```

Android (each test self-boots its own emulator; KVM required):
```sh
./simctl test --android regtest_receive
./simctl test --android regtest_dual_send        # two self-booted emulators, cross-wallet send
./simctl up --android                            # interactive on one emulator
```

Notes:
- Keep android `--jobs` LOW (start at 1). Each test boots 1–2 emulators; a small box can't take many at once.
- `./simctl clean` sweeps leftover test emulators + reaps the regtest backend if a run is interrupted.
- The whole-app `shot` + failure screenshots use the app channel (cross-platform); only the host
  timeout-diagnostic screenshot shells `scrot` (hence the dep above).
