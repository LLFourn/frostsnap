# e2e-sim-harness-research
# Research: full end-to-end app + virtual-device simulation harness

Goal: get to where `claude` can run a full e2e test — the real app driving
real device *logic* (not just rendered widgets), observed and driven by a
script or by an AI agent that takes screenshots. This plan's deliverable is a
research document, **`AUTOMATION_RESEARCH.md`** (repo root), that explores all
the work involved and ends with a staged build roadmap. No production code is
changed by the research itself; spikes are throwaway or feature-gated.

## Problem

The pieces exist but nothing connects them into a runnable e2e loop:

- **Device logic is welded to esp32.** The run loop (`device/src/esp32_run.rs`
  `DeviceLoop::poll`, ~244–790) is largely hardware-agnostic and already sits on
  traits — display via embedded-graphics `DrawTarget`, flash via
  `embedded-storage` `NorFlash`, serial via `SerialInterface`, UI via the
  `UserInteraction` trait (`device/src/ui.rs`). But `DeviceLoop` holds esp-hal
  `Resources`, and the crypto peripherals (SHA/RSA/DS, eFuse HMAC in
  `device/src/{ds,efuse}.rs`) have **no trait abstraction** — they are the real
  blocker and they intersect secure-boot / genuine-check (#498).
- **The simulator renders widgets, not logic.** `tools/widget_simulator`
  (SDL2, `SimulatorDisplay<Rgb565>`, 240x280) instantiates *static* demo widgets;
  it never runs the firmware loop. It already has a useful stdin command
  protocol (`touch x,y` / `release` / `drag y1,y2` / `screenshot <file>` /
  `wait ms` / `quit`) and headless PNG capture (`to_rgb_output_image().save_png`).
- **The coordinator has the right seam but a concrete transport.** The `Serial`
  trait (`frostsnap_coordinator/src/serial_port.rs`) is the injection point and
  `UsbSerialManager` takes it by injection — but the byte transport it returns is
  hardcoded `Box<dyn serialport::SerialPort>`, and no mock/in-memory transport
  exists. Wire protocol + framing + conch flow control live in
  `frostsnap_comms` and `FramedSerialPort`.
- **The app has scaffolding but no harness.** `frostsnapp` is wired through
  flutter_rust_bridge (`load()` desktop / `load_host_handles_serial()` Android),
  has the `integration_test` dep and an empty `test_driver/integration_test.dart`,
  but **no flutter_driver/Patrol/Appium**, sparse `Key`/`Semantics`, and no
  test/mock mode hook in `lib/main.dart`.

## Design

`AUTOMATION_RESEARCH.md` is organized as the axes below. **Every axis ends with:
a recommendation, rough effort/risk, concrete files-to-touch (cited), and open
questions.** The doc is a research report + roadmap, not an implementation.

1. **Lift device logic off esp32.** Define the HAL trait boundary (display,
   touch, flash, serial, RNG/time, and the hard one: crypto — SHA/RSA/DS/eFuse).
   Propose a host-compilable crate holding `DeviceLoop` generic over a `Hal`
   trait; `device/` becomes the esp impl. Resolve the crypto gap: software impls
   (sha2/rsa) vs feature-gating vs disabling genuine-check in sim. Determinism:
   seedable RNG + injectable time. Note that hal *traits* must compile on dev
   machines even if esp impls don't.
2. **Virtual device runtime.** Host build of the lifted logic with software
   peripherals: framebuffer display (reuse the widget_simulator render path),
   scriptable/synthetic touch, RAM-backed flash, in-memory serial. Multiple
   devices + daisy-chaining.
3. **Coordinator ↔ virtual-device transport.** Abstract the hardcoded
   `serialport::SerialPort` behind a `Read+Write` (or narrower) trait; implement
   a `VirtualSerial: Serial` that bridges `FramedSerialPort` to in-process device
   serial loops via channels, preserving magic-bytes handshake + conch token.
4. **Bind the real app to virtual devices.** A test-only FFI entrypoint /
   feature flag that injects `VirtualSerial` into `UsbSerialManager` (new
   `load_*` variant or env flag), leaving the prod path untouched. Where the
   virtual devices live relative to the app process.
5. **Driving the Flutter app (tool research — the explicit ask).** Evaluate
   integration_test + flutter_driver, Patrol, Appium, the VM-service /
   flutter_driver extension, accessibility-tree automation, and
   screenshot+coordinate tapping. Score each on: desktop (macOS/Linux) support,
   **android emulator** support, whether an *external* agent (not in-process
   Dart) can drive it, screenshot capture, widget-tree/semantics introspection,
   tap/type injection, stability/CI-fitness. Recommend a primary + fallback and
   list the `Key`/`Semantics` we'd need to add.
6. **Agent-driven observation & control loop.** How the agent sees the whole
   world (app screenshot + each device framebuffer PNG) and issues actions; the
   action vocabulary; how observations are unified; how the agent emits scripts.
7. **Scriptable test harness.** The deterministic harness the agent produces:
   spawn N virtual devices, drive app + device actions, assert on state.
   Orchestration language (Rust driver vs Dart integration_test vs hybrid),
   reusing the widget_simulator command protocol.
8. **Windowing / presentation (explicit question).** Compare (A) app window +
   separate device windows (SDL), (B) device screens embedded *inside* the app as
   a debug panel — single window, framebuffers piped over the bridge, (C) fully
   headless (PNG only, best for CI/agent). Trade-offs for human dev vs agent vs
   CI; recommend.
9. **Secure-boot / genuine-check / provisioning in sim.** How attestation
   (DS/RSA), eFuse keys, and the genuine challenge behave with virtual devices;
   the sim provisioning path. Reconcile with #498.
10. **Staging & sequencing.** A phased roadmap: the smallest first vertical
    slice that yields value (e.g. one virtual device + scripted touch +
    coordinator handshake over in-memory transport, *no app yet*), then app
    binding, then the agent loop. Name the critical-path refactors and their
    blast radius.

## Steps

1. Re-walk each subsystem at the cited entry points and record the exact seams
   in the doc (don't re-survey from scratch — extend the map above).
2. Cheap spikes to de-risk the key claims, kept throwaway/feature-gated:
   - widget_simulator renders headless to PNG with no on-screen window;
   - the `Serial` trait can be satisfied by an in-memory pipe carrying framed
     bytes through `FramedSerialPort`;
   - `flutter test integration_test` (or the chosen driver) can launch
     `frostsnapp` on desktop in this repo, screenshot it, and tap a widget;
   - the same driver path works against an android emulator.
3. Build the flutter-driving evaluation matrix; where feasible, a throwaway
   proof that the chosen tool can screenshot + tap on both desktop and emulator.
4. Write `AUTOMATION_RESEARCH.md` with one section per axis, each closing with
   recommendation / effort / files-to-touch / open questions.
5. Make the cross-cutting calls explicitly: windowing model, primary+fallback
   flutter driver, and the first vertical slice.

## Verification

- `AUTOMATION_RESEARCH.md` exists at repo root and covers all 10 axes, each with
  a recommendation, rough effort/risk, cited files-to-touch, and open questions.
- A justified decision on the windowing model.
- A recommended flutter-driving tool (primary + fallback) backed by the
  desktop/android matrix, with any spike results noted.
- A staged roadmap with a concretely defined first vertical slice.
- No production code paths changed by the research; any spike code is throwaway
  or feature-gated and called out as such.
