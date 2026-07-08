# sim-5-flutter-device-tray
# sim-5: Slice 2b — Flutter debug device tray + sim entrypoint swap

## Goal
Render the virtual device's screen **inside the app** and route taps back as device touches, so
the whole world (app + device) is one window. After this plan you can launch the app in sim mode
and see/poke the device live.

## Decision: no feature gate (per the user)
sim-4 put the sim surface behind a `sim` cargo feature. The user has decided **not to gate
anything at this stage** — just compile `load_sim` unconditionally; strategic conditioning (if any)
comes later via the env-var/build-flag path the app already threads to `build.rs`. So **Task 1 is
to remove the sim-4 gate**: `frostsnap_virtual_device` becomes an unconditional dependency again,
and `pub mod sim` + `Api::load_sim` drop their `#[cfg(feature = "sim")]`. Then `loadSim` always
exists in the FRB bindings, so `main.dart` can swap to it at runtime (a `--dart-define` flag) with
no separate entrypoint and no cargokit feature wiring.

## sim-4 API to bind (use the real names)
- `Api::load_sim(app_dir, seed) -> (Coordinator, AppCtx, DevicePool)`.
- `DevicePool::devices() -> List<SimDevice>`.
- `SimDevice`: `id() -> String`; `frames(StreamSink<SimFrame>)` (subscribe); `touch(x: int, y: int,
  liftUp: bool)`. `SimFrame { width, height, data }` is RGBA8888.

## Core model (read first)
**Windowing model B (Axis 8), debug-only by convention, production untouched.** The device is
windowless by construction (sim-1 framebuffer); its bytes are rendered in an in-app tray. One
window holds app + all devices ⇒ one screenshot is the whole world (what makes sim-7 driving
tractable). The tray maps over `pool.devices()`; each cell binds *its* `frames()` and routes taps
to *its* `touch()` — no central router. Production `main.dart` (the `load()` path) stays unchanged;
only the SIM-flagged branch calls `loadSim`.

## Tasks
1. **Un-gate** (above): `frostsnapp/rust/Cargo.toml` — `frostsnap_virtual_device` unconditional,
   drop the `sim` feature; `api/mod.rs` — `pub mod sim;` unconditional; `api/init.rs` — drop
   `#[cfg(feature = "sim")]` on `load_sim`. Run `just gen` (no `--rust-features`) so `loadSim` +
   `SimDevice`/`DevicePool`/`SimFrame` land in the default bindings.
2. `main.dart` (the `api.load()` site ~64-76): under a sim flag (`bool.fromEnvironment('SIM')` via
   `--dart-define=SIM=true`, falling back to `false`) call `api.loadSim(appDir:, seed:)` and keep the
   returned `DevicePool`; otherwise the existing `load()` path is byte-for-byte unchanged. Thread
   the `DevicePool` to the tray via the existing context/provider pattern.
3. Device-tray widget: a docked, resizable column on desktop (app content in `Expanded`, devices in
   a fixed-width column). For each `SimDevice`, subscribe `frames()` (→ `.toBehaviorSubject()` or a
   `StreamBuilder`) and render the latest `SimFrame` via `decodeImageFromPixels(bytes, 240, 280,
   PixelFormat.rgba8888, cb)` → `RawImage(filterQuality: none)` (mirror the camera frame pattern,
   `frostsnapp/lib/camera/camera_native.dart:168`).
4. Tap routing: wrap each device image in a `Listener`/`GestureDetector`; scale pointer coords from
   the widget size back to 240×280 and call `SimDevice.touch(x, y, liftUp)` — pointer-down →
   `liftUp:false`, pointer-up/cancel → `liftUp:true` (so a press-and-hold drives hold-to-confirm,
   reused by sim-7).

## Acceptance
- `flutter analyze` clean (with `just gen` bindings present); the sim app **compiles**
  (`flutter build <target>` or at minimum `cargo check -p rust_lib_frostsnapp` with `loadSim`
  present); the tray binds `SimDevice.frames()` → `RawImage` and taps → `SimDevice.touch()`.
- Production `main.dart` `load()` path unchanged; esp builds; no SDL.
- **Visual/interactive check is manual (the user):** "launch with `--dart-define=SIM=true` → the
  live device screen shows in the tray and tapping it drives the device." The reviewers finalize on
  the disk-observable + buildable artifacts above; the on-screen render is the user's verification
  (the clank reviewers run commands, not a GUI).

## Non-goals / deferred
No automated driving yet (sim-7). No phone overlay (desktop only). No multi-device tray scrolling.
No re-introduction of any feature/cfg gate (deferred to "when it's all done, if at all").

## Depends on
sim-4 (`load_sim` + `SimDevice`/`DevicePool`/`SimFrame` FRB types).
