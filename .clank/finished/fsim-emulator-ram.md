# fsim-emulator-ram

Boot pool emulators with enough RAM that Android's lowmemorykiller stops force-stopping the app
mid-scenario. 2G (the AVD default) is not enough for this app.

## Why

Pool AVDs are created with the default `hw.ramSize=2G`. The app initializes super-wallets for four
networks plus Google services plus the sim device fleet; during the PR-505 recording effort Android's
`lowmemorykiller` breached its watermark and force-stopped `com.frostsnap` ~50s after launch —
surfacing as "Lost connection to device" ghosts (one of the three causes the label-diagnostics plan
disambiguates). Booting with `-memory 8192` removed the OOM entirely (validated in that effort).

## Scope — `frostsnapp/test_driver/emulator.dart`

- `bootEmulator` passes `-memory 8192` (the boot flag overrides the AVD's `hw.ramSize`, so EXISTING
  pool AVDs are covered without recreation — no config.ini surgery, no AVD churn). qemu commits guest
  RAM lazily, so concurrent 2-job runs don't reserve 16G up front; if host pressure ever shows up,
  tuning down is a one-line change.
- One comment stating why (LMK force-stops at 2G; the observed failure mode), per the evidence above.

## Acceptance
- `./fsim up --android`: `adb shell cat /proc/meminfo` reports MemTotal ≈ 8G.
- The app survives well past the old ~50s kill window: an android keygen run (`fsim test keygen
  --android`) green, and `logcat -d` on a live session shows no `am_kill`/lowmemorykiller entry for
  `com.frostsnap`.
- `dart analyze test_driver` clean; no other behavior changes.
