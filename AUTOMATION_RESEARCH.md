# AUTOMATION_RESEARCH.md

Research toward a full end-to-end test of the Frostsnap **app + real device
logic**, driven either by a deterministic script or by an AI agent that takes
screenshots, looks at the state of every device and the app, and decides what to
do next.

This is a research report and staged roadmap, not an implementation. Every axis
ends with a recommendation, rough effort/risk, the concrete files it touches,
and open questions. File references are repo-relative.

---

## TL;DR — the three cross-cutting decisions

1. **Windowing — render the devices *inside* the app, always visible.** The
   virtual device is **windowless by construction** (runs the real `DeviceLoop`,
   draws to an in-memory framebuffer, exposes the bytes), but those bytes are
   **always rendered for the developer** — never a black box. They stream over
   the FFI bridge into a **debug-only device tray** in the app:
   - **Desktop:** a docked, resizable tray down one side (app in an `Expanded`
     main area, devices in a fixed-width column). The agent taps the app region
     or a device region in the *same* window.
   - **Phone emulator:** a **collapsible overlay** — a draggable debug button
     toggles a bottom-sheet/drawer of device screens, in its own `Overlay` layer
     so the harness can hide it for clean app screenshots and it never intercepts
     taps meant for the app-under-test.
   - One window holds app + all devices ⇒ **one screenshot is the whole world.**
     Tapping a rendered device maps back to device touch (reuses `handle_touch`).
     Debug-build-only; never ships.
   - **"Headless" means only *offscreen*** (run the same rendered tray under
     Xvfb / an offscreen display for CI, captured or watched over VNC) — it is
     **not** a non-rendering mode. Separate per-device SDL windows (model A) are a
     throwaway convenience only.
2. **Flutter driving — two modalities, one app.** The agent needs both: (a) to
   **drive interactively from screenshots** (observe → act), and (b) to **author
   durable scripted tests by instrumenting the Flutter debug server** (the Dart
   VM Service).
   - **(a) Interactive / visual.** Screenshot + coordinate. On **macOS** (the
     team's dev OS) this is near-zero-setup via **Claude Code's built-in
     `computer-use` MCP** (handles Retina + window focus); the *same* modality
     spans Android (`adb screencap`/`input`) and Linux CI (`scrot`/`xdotool`), so
     it is **not** Linux-only — different per-OS drivers, identical contract.
     Vision *coordinate* grounding is weak on dense UI → add a **Set-of-Mark
     overlay** so the model picks labeled elements, not raw x/y.
   - **(b) Scripted / deterministic.** Instrument the **Dart VM Service**, which
     exposes the real **widget tree** out-of-process (`ext.flutter.inspector.
     getRootWidgetTree`) — *not* the accessibility tree, which is blind on
     Flutter's canvas. The agent reads it to target elements by **Key/Semantics**
     and emits replayable scripts (compiled to `integration_test`/`flutter_driver`
     Dart, or a VM-service-driven script). Off-the-shelf: the official
     `dart_mcp_server` (inspect/hot-reload), or a one-line in-app debug probe
     (`agent_wires_mcp`/`marionette_mcp`) adding tap/type/scroll + tree + marks.
   - **Frostsnap split:** the VM service introspects the **app's** widgets; the
     **device screens in the tray are framebuffers** (the VM service sees only an
     `Image`), so **device** actions/assertions go through the **Rust harness**
     (inject touch, assert on emitted messages/state) with the framebuffer PNG as
     the visual check. Patrol/Appium remain ruled out for the desktop half.
3. **First vertical slice.** Slice 0 below: lift just enough device logic to run
   on the host, talk to `UsbSerialManager` over an in-memory transport, and pass
   the magic-bytes → `Announce` → naming → `Registered` handshake **with no
   Flutter involved at all.** It de-risks the two hardest structural bets (device
   logic lift + transport) before any UI work.

---

## Current landscape (grounded)

| Subsystem | Where | State for our purposes |
|---|---|---|
| Device run loop | `device/src/esp32_run.rs` (`DeviceLoop`, `poll` ~244–790; `run` 794) | Loop is largely HW-agnostic but holds esp-hal `Resources` |
| Already trait-abstracted | display `DrawTarget`; flash `embedded-storage::NorFlash` (`frostsnap_embedded/src/partition.rs`); serial `SerialInterface` (`device/src/io.rs`); UI `UserInteraction` (`device/src/ui.rs:14`) | Reusable as-is |
| **Not** abstracted | SHA/RSA/DS crypto (`device/src/ds.rs`), eFuse HMAC (`device/src/efuse.rs`), RNG seeding (`device/src/peripherals.rs:155`) | The real blocker; intersects secure-boot #498 |
| Widget rendering | `frostsnap_widgets` (`Widget`/`DynWidget`, `SuperDrawTarget`); device UI in `device/src/frosty_ui.rs` | Same render path usable on host |
| Simulator | `tools/widget_simulator/src/main.rs` | Renders **static** demos, **not** `DeviceLoop`; has a stdin command grammar + PNG capture, but **always opens an SDL window** |
| Host transport | `frostsnap_coordinator/src/serial_port.rs` | `Serial` trait is the nominal seam; real coupling is `FramedSerialPort` over `BufReader<Box<dyn serialport::SerialPort>>`; uses `bytes_to_read()` for readiness |
| Coordinator wiring | `UsbSerialManager` (injected `Serial`), FFI in `frostsnapp/rust/src/api/{init,coordinator,port}.rs` | `load()` desktop / `load_host_handles_serial()` Android; `FfiSerial` already proves a non-serialport `Serial` impl |
| App test surface | `frostsnapp` | `integration_test` dep + **empty** `test_driver/integration_test.dart`; sparse `Key`/`Semantics`; no test mode |

---

## Sim app mode (what we run in both interactive and scripted)

There is **one debug/sim build of the app**, identical whether a human, Claude
driving interactively, or a script drives it. Only the *input source* differs —
not the app. It is the real app plus a debug layer, and it is **debug-build-only;
production is untouched**. Concretely it:

- **Drops hardware-only concerns.** Virtual devices are **dev / non-genuine**:
  genuine-check is off (the coordinator already gates the challenge on a flag) and
  firmware-upgrade/OTA flows are stubbed (no esp32 to flash). Protocol crypto
  (keygen/signing/hashing) still runs, in **software**. See Axis 9.
- **Runs virtual devices in a device pool, seeded into the coordinator.** A
  `DevicePool` owns the virtual devices (real device logic, Axis 1–2), **each on
  its own thread**, and hands the coordinator a single `VirtualSerial` (Axis 3–4);
  otherwise the **coordinator is unchanged**. Devices connect through the **same**
  `DeviceChange`/`StreamSink` path as real USB devices, so the app's *own* device
  list reacts genuinely — nothing is faked. **Start with one device, always
  connected;** the "＋ add device" / plug-unplug control and multi-device pools
  come later (Axis 4).
- **Renders the device screens in a side tray** (Axis 8, model B): each virtual
  device's 240×280 framebuffer shown in-app; tapping a device's screen injects a
  touch into that device. One window holds app + all devices.

So two UIs coexist: the **product's** real device UI (reacts to the virtual
connection) and the **debug tray** (the little device screens + add/remove
controls). Driving then comes in two modes over this one app — **interactive**
(screenshot + coordinate / computer-use) and **scripted** (VM-service widget tree
+ `Key`/`Semantics` targeting for the app; Rust harness for the devices) — see
Axis 5.

---

## Axis 1 — Lift device logic off esp32

**Findings.** `DeviceLoop` (`device/src/esp32_run.rs:58`) owns `Resources`
(esp-hal peripherals). The loop body and the UI/workflow state machine
(`device/src/frosty_ui.rs`, `device/src/ui.rs`, `device/src/widget_tree.rs`) are
already hardware-agnostic and ride on standard traits (`DrawTarget`, `NorFlash`,
`Reader`/`Writer`, `Timer`). The portability blockers are the **crypto
peripherals** with no trait: SHA (`esp_hal::sha`), RSA (`esp_hal::rsa`), the
Digital Signature peripheral (`device/src/ds.rs` `HardwareDs`), and eFuse HMAC
key access (`device/src/efuse.rs`, supplying the `share_encryption` and
`fixed_entropy` keys). RNG is `ChaCha20Rng` seeded from hardware
(`device/src/peripherals.rs:155`) — trivially swapped for a fixed seed on host.

**Recommendation.** Extract a host-compilable **`frostsnap_device` core crate**
holding `DeviceLoop` + UI + workflow, generic over a single `DeviceHal` trait
bundling: `Display: DrawTarget`, a touch/input source, `Flash: NorFlash`, a
serial `Reader`/`Writer`, `Rng: RngCore`, a monotonic `clock()`, and a **`Crypto`
sub-trait** (sha256, sign/verify, hmac, key-store). `device/` keeps the esp impl;
add a `host`/`sim` impl with software crypto (`sha2`, software `rsa`, `hmac`) and
a RAM key store. Keep the core `#![no_std]` + `alloc`, with a `std`/test feature
— the **HAL traits must compile on dev machines even though the esp impl does
not** (the workspace already excludes `device` from default members for exactly
this reason).

- **Effort:** L (largest piece). **Risk:** med-high — crypto + secure-boot.
- **Files:** `device/src/{esp32_run,resources,peripherals,ui,frosty_ui,ds,efuse,ota,partitions}.rs`; new `frostsnap_device` crate; `Cargo.toml` workspace members.
- **Open questions:** exactly where to cut the crypto line; whether sim implements DS at all (see Axis 9); how much of `Resources` lifetime gymnastics survives the move.

## Axis 2 — Virtual device runtime

**Findings.** `tools/widget_simulator` already renders `frostsnap_widgets` to a
`SimulatorDisplay<Rgb565>` at 240×280 and writes PNGs
(`main.rs:236`), but it instantiates **static demo widgets** and never runs
`DeviceLoop`. The device's real render path is `FrostyUi`
(`device/src/frosty_ui.rs`) driving the widget tree to a `DrawTarget`, with touch
arriving via `TouchReceiver` and dispatched through
`handle_touch`/`handle_vertical_drag` (`device/src/touch_handler.rs`).

**Recommendation.** A `tools/virtual_device` lib/bin that constructs the lifted
`DeviceLoop` (Axis 1) with: a framebuffer `DrawTarget` (`SimulatorDisplay` or
`VecFramebuffer`), a programmatic touch injector feeding the **same**
`handle_touch` path, RAM-backed `NorFlash`, software crypto, a seeded RNG, a
monotonic clock, and an in-memory serial endpoint (Axis 3). It reuses the
widget_simulator render + screenshot machinery but drives the **real** UI. **Each
device runs on its own thread** (`loop { poll() }` + drain its touch queue + push
its framebuffer on dirty) — the faithful analogue of an independent MCU, keeping
each device's state single-threaded and isolated. **Start with a single device;**
add more (and daisy-chaining, by linking upstream/downstream serial endpoints)
later.

- **Effort:** M (gated on Axis 1). **Risk:** med.
- **Files:** new `tools/virtual_device`; reuse `tools/widget_simulator` render path, `device/src/{frosty_ui,widget_tree,touch_handler}.rs`.
- **Open questions:** whether touch calibration (`touch_handler.rs`) is bypassed in sim; star topology (each device → coordinator) first, daisy-chain deferred.

## Axis 3 — Coordinator ↔ virtual-device transport

**Findings (incorporating review).** The `Serial` trait
(`serial_port.rs:15`) is the *nominal* seam and its own comment says it is "not
really necessary anymore." The **real** coupling is `FramedSerialPort`
(`serial_port.rs:48`) wrapping `BufReader<Box<dyn serialport::SerialPort>>`
(`SerialPort` alias, line 10). Critically, `anything_to_read()`
(`serial_port.rs:69`) calls **`bytes_to_read()`** — a *nonblocking readiness*
method that is **not** part of `Read + Write`. The manager polls this to avoid
blocking. So an in-memory transport that only offers `Read + Write` is
insufficient: it must answer "how many bytes are buffered right now?" The layer
also uses `fill_buf`/`consume`/`read_exact` (`BufRead`) and `write_all`/`flush`,
and `DesktopSerial` sets a 5 s read timeout (`serial_port.rs:260`).

**Recommendation — option A (committed).** The "zero coordinator changes except
the seeded `Serial`" invariant (Axis 4) *selects* this: implement
`serialport::SerialPort` for an in-memory `VirtualPort` backed by a duplex byte
pipe (a `Mutex<VecDeque<u8>>` + `Condvar` per direction, so `read` blocks with
timeout and `bytes_to_read` reports buffered length). Implement `bytes_to_read()`
**truthfully**; stub the ~15 irrelevant methods (baud/parity/flow control) as
no-ops. `FramedSerialPort` and `UsbSerialManager` are then **byte-for-byte
unchanged**. `VirtualSerial: Serial` enumerates one port per *plugged* device and
returns the coordinator-end of that device's pipe.
- **Option B (explicitly deferred):** generalizing `FramedSerialPort` over a
  `trait ByteTransport: Read + Write { fn bytes_to_read() -> io::Result<u32>; }`
  is cleaner but **is itself a coordinator change**, so the invariant rules it out
  for now — revisit only if we later want to drop the `serialport` dependency.

Either way the **readiness method is load-bearing** and must be part of the
abstraction. The bincode framing, magic-bytes handshake, and conch flow control
(`serial_port.rs:99–202`) are transport-agnostic and should round-trip over an
in-memory pipe once readiness is correct.

- **Effort:** S–M. **Risk:** low-med (handshake/conch must round-trip).
- **Files:** new `virtual_serial.rs` (the `VirtualPort: serialport::SerialPort` + `VirtualSerial: Serial`); **no edits** to `usb_serial_manager.rs` or `FramedSerialPort` (that's the invariant).
- **Open questions:** the virtual device must emit the **normal** magic bytes + `DeviceSupportedFeatures` over the pipe — **no short-circuit** (the invariant forbids faking coordinator state or altering the manager/framing path). What's actually open: how the host device loop schedules the initial magic-bytes / conch negotiation, and how `VirtualSerial` assigns port IDs and advertised features.

## Axis 4 — Bind the real app to virtual devices

**Findings.** FFI entrypoints are `load()` (desktop) and
`load_host_handles_serial()` (Android) in `frostsnapp/rust/src/api/init.rs`;
`FfiCoordinator` runs the `UsbSerialManager` poll loop on a background thread
(`coordinator.rs:138`). `UsbSerialManager::new` takes the injected `Serial`.
`FfiSerial` (`api/port.rs`) already demonstrates a non-serialport `Serial` impl
fed from outside the coordinator — the same shape we need.

**Design invariant — zero coordinator changes except the seeded `Serial`.** The
only coordinator-facing change is *which* `Serial` impl `UsbSerialManager` is
given. The seam already exists and is proven (`FfiSerial` is a non-`serialport`
`Serial`). Everything else about the coordinator stays untouched.

**Recommendation.** A debug-only entrypoint hands Dart **two independent
objects**: the normal `Coordinator` (unchanged) and a **`DevicePool`**. The pool
owns the per-thread virtual devices and exposes `.serial()` — the `VirtualSerial`
seeded into the coordinator. Each device is its **own FRB opaque handle**:

```
VirtualDevice { id() -> DeviceId; frames() -> StreamSink<Frame>;
                touch(x, y, phase); plug(); unplug() }
```

so the tray maps over a `List<VirtualDevice>` (each cell binds to *its* device's
`frames` stream and routes taps to *its* `touch`) — **no central frame router**.
The two surfaces never talk directly; they reconcile by `DeviceId` (the handle
generates the device keypair; the coordinator learns the same id via `Announce`).
**Plug/unplug is just the `available_ports()` set:** `add_device` makes a port
appear → the coordinator's existing `poll_ports` handshakes it → the app's real
device list lights up; `unplug()` removes it → `Disconnected`. No coordinator
code, no faked events.

**Start with one device, always connected** (pool of size 1, present at launch).
The `add_device`/`unplug` controls and multi-device pools come later.

- **Effort:** S–M. **Risk:** low (additive; the invariant keeps blast radius near zero).
- **Files:** `frostsnapp/rust/src/api/` — new `DevicePool` + `VirtualDevice` opaque types and a debug entrypoint that seeds `pool.serial()`; reuses `virtual_serial.rs` (Axis 3). No edits to `usb_serial_manager.rs`/`serial_port.rs`.
- **Open questions:** lifetime/ownership of the pool vs the coordinator poll thread; how per-device config (blank vs pre-keyed, name) is passed to `add_device`.

## Axis 5 — Driving the Flutter app (tool matrix)

Flutter paints widgets onto a canvas and creates **no native UI elements**, so
OS accessibility sees one `FlutterView` unless semantics are annotated, and the
only widget-aware driving is via in-app instrumentation over the Dart VM service.
There is **no first-party way for an external process to inject a widget-keyed
tap into a live desktop Flutter app** — that gap shapes everything.

| Approach | Desktop | Android emu | External live drive? | Screenshot (desktop?) | Introspection | Tap/type | 2025–26 status |
|---|---|---|---|---|---|---|---|
| integration_test + WidgetTester | runs tests ✓ | ✓ | No (in-proc, batch) | **No on desktop** (#51890) | full finders/semantics | by Key/finder | **active, recommended** |
| flutter_driver + flutter drive | possible, **unconfirmed**, CI friction | ✓ | **Yes** (`FlutterDriver.connect`) | `driver.screenshot()` (Impeller caveats) | finders | by finder | legacy / under-maintained |
| Patrol | macOS **alpha**, **Linux ✗** | ✓ | batch + `develop` loop; MCP | via integration_test (desktop gap) | finders + native tree | native by selector/coord | very active; mixed CI rep |
| Appium (flutter-integration-driver) | macOS build cmd only, **Linux ✗** | ✓ | **Yes** (W3C server) | W3C getScreenshot | by key/text/semantics | finder-based | active |
| Raw Dart VM Service (`vm_service`) | ✓ | ✓ (adb forward) | **Yes** (JSON-RPC) | **`_flutter.screenshot` works on desktop** | `getRootWidgetTree` | **none without in-app ext** | first-party, active |
| OS-level (adb / screencapture+cliclick) | ✓ | ✓ | **Yes**, zero instrumentation | ✓ both | none (coords only) | coordinate-only | stable primitives |

**Recommendation matrix.**

| Scenario | Primary | Fallback |
|---|---|---|
| Desktop — script | integration_test + WidgetTester | flutter_driver `connect` (verify desktop) |
| Desktop — AI agent | OS `screencapture` + `cliclick`/CGEvent | long-lived `vm_service` (`_flutter.screenshot` + tree) |
| Android emu — script | integration_test | flutter_driver / Appium integration-driver |
| Android emu — AI agent | `adb screencap` + `adb shell input` | `vm_service` (tree + key taps via in-app ext) |

Desktop `integration_test` screenshots are **unsupported** (#51890) — use
VM-service `_flutter.screenshot` or OS `screencapture`. On `Key`/`Semantics`
coverage: `Key`/`ValueKey`/`GlobalKey` usages already exist across ~22 files —
`lib/wallet.dart`, `lib/electrum_server_settings.dart`, `lib/nonce_replenish.dart`,
`lib/wallet_{receive,create,device_list}.dart`, and most `lib/restoration/*.dart`
views — but they are mostly **route/list/animation-state keys**, not stable
handles on the core workflow controls (keygen/signing/send buttons). There are
**no `Semantics()` wrappers** at all (only `SemanticsService` announcements +
`ExcludeSemantics` in `lib/copy_feedback.dart`). So driving app flows by key
still requires adding stable `Key`s/`Semantics` to the interactive controls of
each flow, even though incidental keys are already present.

**Two modalities (what the agent actually needs).** The agent must both *drive
interactively from screenshots* and *author durable scripted tests by
instrumenting the Flutter debug server* (the Dart VM Service). Two backends, one
contract (the screenshot+coordinate row and the `vm_service` row above):

- **Interactive / visual — macOS-native via Claude Code computer-use.** On the
  team's Macs, **Claude Code ships a built-in `computer-use` MCP** (screenshot +
  click/type, auto Retina downscaling, window focus) — zero setup, zero app
  instrumentation. The *same* observe→act contract is implemented per OS:
  `screencapture` + `cliclick`/CGEvent on macOS, `adb screencap`/`input` on
  Android, `scrot`/`xdotool` (under Xvfb) on Linux CI. So this is **not Linux-only**
  — macOS leads; Linux is just the CI form. Weak VLM *coordinate* grounding on
  dense UI is mitigated with a **Set-of-Mark overlay** (the structured tree below
  supplies element bounds for the marks).
- **Scripted / deterministic — instrument the Dart VM Service.** `_flutter.*` +
  `ext.flutter.inspector.getRootWidgetTree` expose the **widget** tree
  out-of-process (*not* the canvas-blind a11y tree). The agent targets elements by
  **Key/Semantics** and emits replayable scripts → `integration_test`/
  `flutter_driver` Dart, or a VM-service-driven script. Ready-made: the official
  **`dart_mcp_server`** (inspect + hot-reload, no taps), or a one-line in-app debug
  probe — **`agent_wires_mcp`** / **`marionette_mcp`** (denoised tree +
  tap/type/scroll + Set-of-Mark screenshots; macOS/Linux desktop). **This is the
  "instrument the debug server" path.**
- **Device side stays in Rust.** The VM service sees the tray's device
  framebuffers only as `Image`s, so device actions/assertions run through the Rust
  harness (Axes 6–7); the framebuffer PNG is the device visual check.

**Recommendation.** Primary dev/debug surface = **macOS + Claude Code
computer-use** (interactive) **paired with a VM-Service instrumentation**
(`dart_mcp_server` or a debug-only probe) so the agent perceives the real widget
tree and authors **Key-based, replayable** scripts instead of brittle pixel
coordinates. Keep the contract identical on Android-emulator (`adb` + VM service
over `adb forward`) and Linux CI (Xvfb + VM service). Patrol (no Linux, macOS
alpha) and Appium-desktop remain out.

- **Effort to enable:** M (Keys/Semantics on workflow controls + the two-backend harness). **Risk:** med (VM-service reachability under flutter_rust_bridge + vision grounding — both spike-gated).
- **Files:** `frostsnapp/lib/main.dart` (debug VM-service/probe init + test-mode hook) and workflow widgets needing stable `Key`s/`Semantics`; `frostsnapp/integration_test/` + `test_driver/integration_test.dart` as the script target; a `tools/sim_harness` exposing the observe→act contract with per-OS drivers (`screencapture`/`cliclick` on macOS, `adb` on Android, `Xvfb`+`scrot`/`xdotool` for Linux CI) plus a VM-Service client (or `dart_mcp_server`/probe) for structured reads.
- **Open questions:** does the widget tree stay fully reachable over the VM service under flutter_rust_bridge's isolate (spike `getRootWidgetTree` on a debug build); Claude Code computer-use eligibility (Pro/Max + claude.ai auth, **not** Bedrock/Vertex/Foundry); vision tap accuracy on the real UI → whether Set-of-Mark is required; mobile-mcp text-entry reliability on the Flutter canvas.

## Axis 6 — Agent-driven observation & control

**Recommendation.** The agent perceives via **two channels** and acts via a thin
**harness daemon**:
- **Visual:** one composite screenshot — with windowing model **B** (Axis 8) a
  single app screenshot already contains the app **and** every device framebuffer,
  collapsing observation to one image.
- **Structured (app only):** the **Dart VM Service widget tree** (Axis 5) for
  cheap, reliable state reads and Key/Semantics targeting — the antidote to vision
  "state hallucination."
The daemon exposes a small verb set — `list-devices`, `screenshot {app|device i}`,
`widget-tree {app}`, `tap {app|device i} x y | app-key <k>`, `type text`, `wait`,
`quiesce` — over a socket. **App** taps resolve by Key (via VM service) or by
coordinate; **device** actions reuse the widget_simulator grammar
(`touch`/`release`/`drag`) into the Rust touch injector, and device state is read
from the Rust harness (emitted messages), since the VM service sees a device only
as an `Image`.

- **Effort:** M. **Risk:** med.
- **Files:** new `tools/sim_harness` (daemon exposing the verb set + a VM-Service client / `dart_mcp_server` link); `tools/virtual_device` (framebuffer export + touch injector); `frostsnapp/lib/main.dart` (debug VM-service/probe init); OS-capture backend needs no extra app files.
- **Open questions:** UI quiescence signal (when is it safe to screenshot?); device framebuffer delivery (files vs socket vs in-app panel); whether app reads go through raw `vm_service`, `dart_mcp_server`, or an in-app probe.

## Axis 7 — Scriptable harness

**Recommendation.** The AI-authored script spans two sides with two targeting
schemes: **app** steps target widgets by **Key/Semantics over the VM service**
(deterministic, replayable — the durable half the user wants), and **device**
steps go through the **Rust harness** (inject touch, assert on emitted
`DeviceToCoordinator` messages / device state). Two homes fit:
- **Rust orchestrator** — virtual devices and the coordinator are Rust, so it
  spawns devices, injects device touches, asserts on emitted messages, and drives
  the app via a VM-Service client (Key-based) with screenshots for visual
  checkpoints. The agent emits these scripts.
- **Dart `integration_test`** owns the app side (native `Key`/finder targeting,
  most deterministic) and FFIs into a "sim control" API for the device side —
  single process, but inherits the desktop screenshot gap, so visual device checks
  fall back to the framebuffer PNG.
The agent can author in either; the VM-service/Key targeting is what makes the
output stable rather than pixel-brittle.

- **Effort:** M. **Risk:** med.
- **Files:** new `tools/sim_harness` (Rust orchestrator) reusing the `frostsnap_coordinator` test surface, `tools/virtual_device`, and a VM-Service client; or, for the Dart-owns-app variant, `frostsnapp/integration_test/` + a bridged "sim control" API in `frostsnapp/rust/src/api/`.
- **Open questions:** Rust-orchestrator vs Dart-owns-app as the canonical script form; shared assertion vocabulary across the FFI boundary; how device-side and app-side steps interleave/synchronize in one script.

## Axis 8 — Windowing / presentation (rendered in-app tray; offscreen for CI)

**Findings (incorporating review).** `widget_simulator/src/main.rs:122` **always**
creates an SDL `Window` and calls `window.update()` (line 327) and
`window.events()` (line 252) every frame — so today's PNG capture **rides on an
on-screen SDL window and is not true headless.** The `SimulatorDisplay`
framebuffer and `to_rgb_output_image().save_png()` (line 236) are **independent
of the window**. A windowless device render (draw to the framebuffer, `save_png`,
drive purely from commands — via a `Window`-skipping loop or
`SDL_VIDEODRIVER=dummy`) is therefore feasible and useful as a **Rust-side debug
artifact**, but it is **not** the CI surface: CI renders the full app + tray
**offscreen under Xvfb** (model C below).

**Three models.**
- **A — app window + separate device SDL windows.** Best for hands-on device-UI
  work. Needs a display server; not CI-friendly.
- **B — device screens embedded inside the app (debug panel).** Each
  `VirtualDevice` handle (Axis 4) exposes its **own** framebuffer stream
  (240×280, converted to RGBA in Rust, pushed on dirty) → `decodeImageFromPixels`
  → `RawImage` (`FilterQuality.none`); taps route back through that handle's
  `touch`. **Single window; one screenshot captures app + all devices** — ideal
  for the agent. More wiring.
- **C — offscreen (the CI form of B).** The *same* in-app tray, rendered under an
  offscreen display (Xvfb) and screenshotted; nothing is left undrawn. For pure
  Rust-side checks, devices can also be dumped via `save_png`. Best for CI.

**Recommendation.** Build the device runtime **windowless** (framebuffer +
exposed bytes) and make **model B the primary surface** — the devices are
**always rendered for the developer** inside the app, never hidden. Concretely:
- **Desktop:** a docked, resizable **device tray** down one side (app content in
  an `Expanded` main area, devices in a fixed-width column that scrolls when there
  are many). The agent taps the app region or a device region in the same window.
- **Phone emulator:** the app-under-test owns the screen, so the tray is a
  **collapsible overlay** — a draggable debug button toggles a bottom-sheet/drawer
  of device screens. It lives in a top `Overlay` layer (`IgnorePointer` when
  collapsed), the harness can **hide it entirely** for clean app screenshots, and
  it never sits over the controls under test. Dev pulls it out to watch; agent
  hides it to act, shows it to observe.
- **Debug-build-only** (a `cfg`/dart-define gate); never ships.
- **"Headless" = offscreen, still rendered.** CI runs the same B surface under
  Xvfb and screenshots it; there is **no mode where devices aren't drawn**. Model
  A (separate SDL windows) is a throwaway convenience only.

- **Effort:** B is M–L. **Risk:** med.
- **Files:** `tools/virtual_device` framebuffer export; new `frostsnapp` debug device-tray + bridged framebuffer-stream/touch-inject API (behind a debug gate); `tools/widget_simulator` offscreen-render refactor.
- **Open questions:** framebuffer transport format/bandwidth over the bridge (raw RGB565 vs RGBA vs per-frame PNG) for N devices; how tray tap coordinates map back to device touch (scaling/calibration); whether the tray blits raw bytes or re-renders `frostsnap_widgets` in Dart; phone-overlay isolation so the tray never intercepts app-under-test taps or leaks into app-only screenshots; redraw cadence vs the quiescence signal (Axis 6).

## Axis 9 — Secure-boot / genuine-check / provisioning in sim

**Findings.** Genuine verification is a DS/RSA challenge-response
(`device/src/esp32_run.rs:562`, `device/src/ds.rs`); eFuse supplies
`share_encryption` + `fixed_entropy` keys (`device/src/efuse.rs`); `Announce`
carries `firmware_digest`; the coordinator sends `Challenge` and expects
`SignedChallenge`, **gated** on a genuine-check flag
(`usb_serial_manager.rs:606`). This intersects secure-boot work #498.

**Recommendation.** In sim, default genuine-check **off** so virtual devices are
treated as dev/non-genuine (the coordinator gate already allows this). Provide
software eFuse (RAM key store) + software SHA so keygen/signing crypto still
works end-to-end. A "genuine sim" with a software DS is a later, optional step.
Sim provisioning writes fixed **dev** keys into the RAM store, behind a feature
so it can never be confused with prod.

- **Effort:** S (disable path) / L (software-genuine). **Risk:** med — must not weaken prod; keep sim crypto feature-gated.
- **Files:** `device/src/{ds,efuse}.rs` (esp impls the sim must mirror); new software crypto + RAM key-store in the `frostsnap_device` core crate (Axis 1); `frostsnap_coordinator/src/usb_serial_manager.rs:606` (genuine-check gate); coordinate with #498 (`frostsnap_secure_boot`, `frostsnapp/rust/build.rs`).
- **Open questions:** coordinate with #498; guarantee sim keys are never mistakable for prod artifacts.

## Axis 10 — Staged roadmap

- **Slice 0 — proof, no app.** Lift just enough of `DeviceLoop` to compile on
  host with software peripherals; in-memory `VirtualPort` implementing
  `serialport::SerialPort` incl. `bytes_to_read`; a Rust test that runs
  `UsbSerialManager` against **one** virtual device through magic-bytes →
  `Announce` → naming, asserting `DeviceChange::Registered`. Zero Flutter. Proves
  Axes 1 + 3 — the two hardest structural bets.
- **Slice 1 — device UI + scripted touch.** Drive the lifted `DeviceLoop`/
  `FrostyUi` with scripted touch through a keygen prompt and dump the device
  framebuffer to a PNG as a **Rust-side/debug artifact** (no app yet); assert on
  emitted `DeviceToCoordinator` messages. Proves Axis 2 (real device UI from the
  lifted logic + scripted input). NB: this device-only PNG is a debug artifact,
  **not** the Axis 8C surface — 8C (rendered app + tray) is validated in Slices 3–4.
- **Slice 2 — app bound to ONE virtual device.** Debug entrypoint → `Coordinator`
  + a `DevicePool` of size 1 (one always-connected `VirtualDevice` handle); drive
  the app on **macOS** via the VM service (Key-targeted) + computer-use
  screenshots; confirm the device connects, names, and renders in the tray. Proves
  Axes 4 + 5 and stands up the **scripted-test path** (VM-service Key targeting →
  replayable script). Multi-device pools (needed for a full multi-party keygen)
  follow once the single-device path works.
- **Slice 3 — embedded tray + agent loop.** Windowing model B: the in-app device
  tray; harness daemon; agent loops screenshot → reason → act on the **macOS
  computer-use** surface (with VM-service reads). Proves Axes 6 + 8B, and **8C by
  running the same app + tray under Xvfb** (offscreen, still rendered) and
  screenshotting it.
- **Slice 4 — Android + CI.** adb backend for the emulator; CI runs the app + tray
  **offscreen under Xvfb** (not a non-rendering "headless" mode), watchable via
  `x11vnc`.

**Recommendation.** Sequence strictly by the critical path — land Slice 0 before
any UI work, since it validates the two structural bets (device-logic lift +
in-memory transport) cheaply; treat each slice's acceptance as a gate before
starting the next.

**Critical path:** Axis 1 (device-logic lift) blocks everything; Axis 3
(transport readiness) blocks Slice 0; Axis 5 (driver choice + keys/semantics)
blocks app driving.

- **Effort:** L overall (sum of Axes 1–9); risk is front-loaded into Slice 0.
- **Risk:** med — mostly inherited from Axis 1 (crypto/secure-boot) and Axis 5 (desktop driver gaps); sequencing exists to surface those early.
- **Files:** spans every axis above — see each axis's Files line; this section adds no new files of its own.
- **Open questions:** concrete acceptance criteria per slice; whether Slice 2 drives via `integration_test` or OS-capture first; how much Android (Slice 4) timing/DPI work can be shared with desktop.

---

## Spike checklist (de-risk before committing to a slice)

1. **Offscreen rendered surface** — the rendered app + device tray runs under
   **Xvfb** (offscreen but still drawn; `x11vnc` to watch) and can be
   screenshotted. Separately, confirm the windowless device runtime can dump its
   framebuffer to a PNG (`save_png`) as a Rust-side artifact — a debug aid, not
   the CI surface.
2. **In-memory transport** — `VirtualPort` satisfies `FramedSerialPort` including
   `bytes_to_read`; magic-bytes + conch round-trip end to end.
3. **VM-service scripting path (the scripted-test backbone), two parts.**
   (a) Connect to a **debug `frostsnapp` build** and fetch
   `ext.flutter.inspector.getRootWidgetTree`; recover stable **Key/Semantics**
   targets + bounds for the core flows; confirm this works with **flutter_rust_bridge
   initialized** (the FRB isolate doesn't hide the widget tree). (b) Prove the chosen
   action path can **replay a Key-targeted tap/type/scroll** — via
   `integration_test`/`flutter_driver` output *or* a debug in-app probe
   (`agent_wires`/`marionette`). Note: raw `vm_service` alone **cannot** inject
   input (per the Axis 5 table), so one of these action paths is required. (The
   visual/computer-use screenshot + coordinate-tap spike is item 5.)
4. **Android emulator** — `adb exec-out screencap` + `adb shell input tap`;
   calibrate DPI/resolution → tap coordinate mapping.
5. **Desktop OS driving** — `screencapture` + `cliclick`/CGEvent; calibrate
   Retina point↔pixel (2×) scaling.
6. **FRB under instrumented build** — app boots cleanly in a debug/profile build
   with flutter_rust_bridge initialized and the virtual-device entrypoint.
