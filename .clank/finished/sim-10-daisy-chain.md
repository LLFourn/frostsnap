# sim-10-daisy-chain
# sim-10: wire the virtual devices as a real daisy chain

## Goal
Make the sim's multiple devices form the SAME daisy chain real hardware uses instead of sim-9's
star: one device plugs into the coordinator (USB), each further device hangs off the previous
device's DOWNSTREAM port, and messages are relayed along the chain. The coordinator then sees ONE
port and discovers N devices through the chain — exercising the firmware's real downstream
forwarding, and giving correct unplug semantics (pulling a node drops everything below it).

## Why (what sim-9 got wrong)
sim-9 gives each virtual device its own coordinator-side serial port (`load_sim` pushes one
`(port_id, host)` per device into `VirtualSerial::new`), and every device's downstream link is dead
(`device.rs` `PipeByteIo::disconnected()`, the thread always polls `poll_once(false)`). That is a
STAR: the coordinator enumerates N ports, and the entire downstream forward/relay path in
`frostsnap_embedded/src/device_loop.rs` (`downstream_connection_state`, downstream magic-bytes,
`message.target_destinations.should_forward()`) is never run. Real devices daisy-chain, so:
- the sim isn't testing how messages actually route on a chain (leaf-only invariant: the sim should
  drive the same portable firmware paths as hardware — this one is bypassed), and
- unplug is wrong: sim-9 unplugs each device independently; on a real chain pulling node *i* powers
  off and disconnects node *i* AND everything downstream of it.

## Core model (read first)
The chain is the physical topology; ALL routing/disconnect behavior must EMERGE from the unchanged
firmware + coordinator, not from sim bookkeeping.
- **Wiring.** device 1: upstream → the one coordinator port; downstream → device 2's upstream.
  device *i* (1<i<N): upstream → device (i-1)'s downstream; downstream → device (i+1)'s upstream.
  device N: downstream → none. So there is exactly ONE coordinator-facing port (device 1);
  `available_ports()` returns 1, and the coordinator learns devices 2..N from Announce messages the
  chain relays upstream.
- **A link is the only sim control.** Each link carries a `connected` flag that gates BOTH byte
  flow across the link AND the parent's downstream-detect. Unplugging a link = flip the flag:
  bytes stop crossing and the parent's detect reads absent, so the real `DeviceLoop` tears down its
  downstream connection, the orphaned devices' `UpstreamConnection` drops, and the coordinator marks
  the whole subtree disconnected — through the genuine protocol, with NO "mark disconnected"
  bookkeeping in the sim. Re-plug restores flow + detect; the firmware re-handshakes and re-announces.
- **Power flows down the chain.** A device is powered (screen on, on the bus) iff it is reachable
  from the coordinator through all-connected links. Pull a mid-chain link and that node + its subtree
  go dark — same dark-screen state sim-9 already renders, generalized from "this device" to
  "unreachable subtree".
- **The firmware is NOT touched.** `frostsnap_embedded` forwarding/relay already implements the
  chain; sim-10 only wires the physical links so that code finally runs. `UsbSerialManager` is
  unchanged (it already handles many devices over one forwarded port — that's real hardware).

## Rust: chain wiring (leaf only)
- **Serial leaf** (`tools/virtual_device/src/serial.rs`): add a device-to-device link — two crossed
  `ByteChannel`s yielding two `PipeByteIo` ends (A.downstream ↔ B.upstream), the analogue of the
  existing host `pipe()`. Add a `connected: Arc<AtomicBool>` gate so a disconnected link drops writes
  and yields no reads (a "link present" query backs the detect pin). One gate per link.
- **VirtualDevice/spawn** (`device.rs`, `thread.rs`): take the upstream and downstream byte-IO ends as
  inputs (instead of always building its own upstream `pipe()` + a dead downstream), plus a
  downstream-present source the poll loop reads each tick to pass real `downstream_present` into
  `poll_once`. The `!Send` device is still built in-thread; the `Arc`-backed link ends are created
  outside and moved in.
- **load_sim** (`api/init.rs`): build the chain — device 1 gets a `pipe()` whose `HostEnd` is the
  single coordinator port (`VirtualSerial::single`); for each adjacent pair create a gated link and
  wire device *i*'s downstream to device (i+1)'s upstream; spawn each device with its ends + a
  per-link present/connected gate. Expose, per device, the control that plugs/unplugs the link to its
  PARENT (device 1's parent link is the coordinator `PortConnection` from sim-2; inner devices' is the
  gated device-link). `SimDevice.number()` stays the chain position.

## Dart: tray reflects the chain
- Cells are listed in chain order (device 1 = the one on USB).
- A cell's connect/disconnect toggles the link to its PARENT (uniform "unplug this device"); pulling
  it drops the device AND its descendants. "Plug all in / unplug all" flips every link.
- Screen-off is REACHABILITY-based: a device renders its live frame iff reachable from the coordinator
  through all-connected links; otherwise dark (an unplugged node and everything below it go dark).
  Still presentation-only and independent of frame activity; computed from the chain + link flags
  (the single source of truth), so plug-all and per-node toggles agree.

## Harness + simctl
- `device(n)` still selects the nth device in the chain (1-based). `unplug([n])`/`plug([n])` toggle the
  link to device *n*'s parent (so `unplug(2)` drops 2..N), `set-connected --device N` likewise. The
  driving surface is otherwise unchanged (no drift — sim-8 contract preserved).
- Rewrite `multi_device_drive` to CHAIN semantics: bring up a 3-device chain and assert the coordinator
  exposes exactly ONE port yet registers 3 DISTINCT devices (proves forwarding ran); unplug device 2 →
  devices 2 AND 3 disconnect, device 1 stays; replug → all 3 return; no residue. (sim-9's version
  asserted star semantics — "unplug 2 leaves 1+3" — which is now wrong.)

## Out of scope / stretch
- Stretch (nice if cheap): a 2-of-2 keygen across a 2-device chain, proving keygen routes over a real
  forwarded link end-to-end. Required acceptance stays the chain-registration + subtree-unplug
  scenario; the 1-device `keygen_drive` stays the baseline e2e.

## Tasks
1. Serial leaf: device-to-device gated link primitive (crossed `ByteChannel`s + a `connected` gate
   backing byte flow + detect). Unit test: bytes cross a connected link both ways; a disconnected link
   passes nothing and reads as absent.
2. VirtualDevice/spawn take injected upstream/downstream IO + a downstream-present source; `load_sim`
   builds the chain (device 1 on the single coordinator port; inner gated links; per-device parent-link
   control).
3. Tray: chain-ordered cells, per-node toggle = parent link, reachability-based subtree screen-off,
   plug-all over links.
4. Harness + simctl: parent-link `unplug(n)`/`plug(n)`/`--device N`; rewrite `multi_device_drive` to
   chain semantics (1 port, N registered, subtree unplug, no residue).

## Acceptance
- `cargo test -p frostsnap_virtual_device` green incl. the gated-link unit test and a coordinator
  test: a 3-device CHAIN registers all 3 over ONE `VirtualSerial` port (exercises the device_loop
  downstream forward/relay path).
- `cargo check -p rust_lib_frostsnapp`; `flutter analyze`; `dart-format-check-app`; esp unaffected;
  `frostsnap_embedded` forwarding code UNCHANGED; production `load()`/`main.dart` unchanged.
- Driver scenario (`just sim-multi-drive`): 3-device chain → coordinator shows exactly 1 port and 3
  distinct registered ids; unplug device 2 → devices 2+3 drop, device 1 stays; replug → all 3 return;
  teardown leaves no residue.
- 1-device `keygen_drive` stays green.
- Self-verified tray screenshot: a chain with a mid-chain device unplugged, showing that node and its
  descendants dark while the upstream devices stay live; plug-all restores.

## Depends on
sim-9 (the fleet plumbing, tray, `SimHarness`/`simctl` multi-device, `SimDevice.number`). Replaces
sim-9's star wiring in `load_sim` and its `multi_device_drive` star assertions with the chain. Reuses
sim-2's `PortConnection` for device 1's USB link and the firmware's existing downstream forwarding.
