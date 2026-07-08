# sim-9-multi-device
# sim-9: a fleet of N independent virtual devices in the sim

## Goal
Let the sim run more than one virtual device. The number of devices is chosen when the session
starts; each device can be plugged/unplugged on its own (plus a bulk "plug all in" action); the tray
identifies devices by a short number, renders them ~30% smaller, shows an unplugged device's screen as
off, and scrolls when there are many.

## Core model (read first)
The coordinator, the `DevicePool`, and the tray ALREADY model "a list of devices" —
`DevicePool.devices()` is a `Vec`, the tray is already a `ListView`, and the real `UsbSerialManager`
drives many ports. The sim is single-device only because the single-device assumption is concentrated
in three leaf spots:
1. `VirtualSerial::single()` + `connection()` — the serial seam hardcodes exactly one port (and
   `connection()` panics for >1).
2. `load_sim()` — spawns exactly one device: one seed, one `device-0.sock`, one `SimDevice`.
3. `SimDevice` has no stable ordinal — only the opaque `DeviceId`.

The change is to make the device set a first-class **fleet of N independent, self-contained units**.
Each unit owns: a 1-based **number**, its own virtual serial port + `PortConnection` toggle, its own
device-channel socket, its own framebuffer/touch, and its own device thread. Once a `SimDevice` is a
numbered, independently-pluggable unit, requirements 1/3/5 fall out of the model directly; 2/4/6 are
tray-rendering concerns over that fleet. No portable coordinator/device logic changes — this is purely
instantiating the EXISTING leaf N times (the sim-epic leaf-only invariant).

Single source of truth for connection state: the Rust `PortConnection` is authoritative. The tray
must READ it (`SimDevice.is_connected()`) and reflect it, NOT keep a parallel Dart `_connected`
mirror. The current cell-local mirror is a duplicated source of truth and is removed, so per-device
toggle, "plug all", and "screen off" all agree on one state.

## Rust: the fleet

### Multi-port virtual serial (leaf 1)
- Add `VirtualSerial::new(entries: Vec<(String, HostEnd)>) -> (VirtualSerial, Vec<PortConnection>)`:
  one `PortEntry` per device, each with its own fresh `PortConnection`, the connections returned in
  order so the caller hands each to its `SimDevice`. `available_ports()` already filters per-port on
  `is_connected()`, so independent plug/unplug works unchanged.
- Keep `single()` / `connection()` for the existing crate tests (one-port convenience). The
  panic-on-multi `connection()` is simply not used by the fleet path.

### load_sim builds N devices (leaf 2)
- `load_sim(app_dir, seed, device_count)`. Loop `i in 0..device_count`:
  - spawn `VirtualDevice` with seed `seed + i` (deterministic, distinct device IDs) announcing the
    same `firmware.digest()`;
  - its OWN `frames_sink` Arc + `on_frame` closure (no shared sink);
  - collect `(port_id, host)` for the serial; build ONE `VirtualSerial::new(entries)` -> N
    `PortConnection`s; one `UsbSerialManager` over it;
  - one `DeviceChannel` per device at `device-{number}.sock` (1-based);
  - one `SimDevice { number: i+1, connection: connections[i], .. }`.
- `DevicePool` keeps its `Vec`s (spawned / channels / devices) — already plural. Default
  `device_count` = 1, preserving single-device flows.

### SimDevice gains a number (leaf 3)
- `SimDevice.number() -> u32` (`#[frb(sync)]`), 1-based. `id()` stays (device-channel `device_id`,
  tooltip).

## Dart: entrypoint + tray
- Sim entrypoint reads `--dart-define=SIM_DEVICE_COUNT` (default 1) and passes it to
  `api.loadSim(seed, deviceCount)`.
- Tray (`sim_device_tray.dart`):
  - **Number, not id (5):** cell title is `'Device ${device.number()}'`; the full id moves to a
    tooltip.
  - **30% smaller (2):** render the device image at ~70% of today's size (a render-width constant
    ~170 instead of filling the full tray width). Touch mapping already uses the LIVE rendered box
    size, so it stays correct at any render size.
  - **Screen off when off (4):** when `!device.isConnected()` paint an "off" placeholder (dark
    rectangle + usb-off glyph) instead of the live `RawImage`. The device thread keeps running
    (existing sim semantics; unplug is a port-presence/presentation change, NOT a power-cycle/reset —
    see Out of scope).
  - **Independent + plug-all (1):** keep the per-cell connect/disconnect toggle (each cell now owns
    its own `PortConnection`, so one toggle is independent). Add a PINNED tray header with a "Plug all
    in / Unplug all" action that flips every device. Drop the cell-local `_connected` mirror; read
    `isConnected()` as the source of truth and `setState` after toggling.
  - **Scrollable (6):** header pinned; the device list in an `Expanded(ListView(...))` so it scrolls
    with many devices.

## Harness + simctl (preserve the no-drift contract)
The tests and the live CLI MUST keep driving through the SAME `SimHarness` calls (sim-8). Extend, do
not fork:
- `SimHarness.launch({deviceCount = 1})` / `runScenario(..., {deviceCount})`: pass `SIM_DEVICE_COUNT`,
  wait for `device-1.sock`..`device-N.sock`, connect N `SimDeviceChannel`s. Expose
  `List<SimDeviceChannel> devices` and `SimDeviceChannel device([int number = 1])` (1-based).
  `unplug([n])` / `plug([n])` target one (default 1). `_captureFailure` dumps every device framebuffer
  (`device-1.png`..`device-N.png`).
- `keygen_drive.dart`: `h.device` -> `h.device(1)` (1-device keygen otherwise unchanged).
- `simctl`: `serve --count N`; device commands (`hold`/`swipe`/`touch`/`screen`/`set-connected`) take
  `--device N` (default 1); app commands (`tap`/`enter`/`wait`/`exists`/`tap-until`/`shot`) stay
  single (one app). Add a `devices` command (prints count + each number/id/connected) for
  introspection. simctl stays a thin forwarder to `SimHarness` methods — nothing to drift.
- Socket numbering becomes 1-based (`device-1.sock`), aligned with the display number and simctl
  `--device`; changed consistently across `load_sim`, the harness, and simctl (was `device-0.sock`).

## Out of scope (future)
- A full N-of-M keygen driven across multiple devices (each device's naming + per-device security-check
  hold). This plan delivers the fleet plumbing + tray UX; the existing 1-device keygen stays the
  end-to-end flow.
- Power-cycle/reset on unplug (the device thread currently keeps running while unplugged; "screen off"
  is presentation only).

## Tasks
1. Multi-port `VirtualSerial::new(entries) -> (serial, Vec<PortConnection>)`; keep `single`/
   `connection`. Unit test: two ports, unplug one -> only that port leaves `available_ports()`.
2. `load_sim(app_dir, seed, device_count)` builds the fleet (per-device seed / sink / socket /
   connection); `SimDevice.number()`; sim entrypoint `SIM_DEVICE_COUNT` define + `loadSim` arg.
3. Tray: numbered title, ~30%-smaller render, screen-off when unplugged, pinned "plug all / unplug
   all" header, scrollable list, single-source connection state (remove the `_connected` mirror).
4. Harness + simctl multi-device: N sockets/channels, `device(n)`, per-device `--device` selector,
   `serve --count`, `devices` introspection; `keygen_drive` -> `device(1)`.

## Acceptance
- `cargo test -p frostsnap_virtual_device` green incl. the multi-port serial test.
- `cargo check -p rust_lib_frostsnapp` builds; `flutter analyze` clean; `dart format` clean; esp
  unaffected; production `load()` / `main.dart` unchanged.
- A driver scenario launches with `deviceCount: 3` and asserts (disk-observable): 3 device sockets
  appear; the 3 `SimDeviceChannel`s report numbers 1/2/3 and three DISTINCT device ids; unplugging
  device 2 only leaves devices 1 and 3 connected (`is_connected` per device); teardown leaves no
  residue.
- The existing 1-device `keygen_drive` stays green.
- A self-verified tray screenshot with >=3 devices: numbered titles, ~30%-smaller renders, one
  unplugged device showing screen-off, the list scrolling, and "plug all in" reconnecting it.

## Depends on
sim-8 (the dual-channel harness + simctl + tray). Reuses sim-2's `PortConnection` plug model per port
and the existing `DevicePool` / tray `Vec` shape.
