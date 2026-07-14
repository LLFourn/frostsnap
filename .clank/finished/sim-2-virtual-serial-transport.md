# sim-2-virtual-serial-transport
# sim-2: in-memory serial transport + Slice 0 handshake test

## Goal
Connect the virtual device (sim-1) to the **unchanged** coordinator over the in-memory pipe, and
prove it with a Rust integration test that drives one virtual device through magic-bytes →
Announce → naming → `DeviceChange::Registered`. This is AUTOMATION_RESEARCH Slice 0 — the two
hardest structural bets (device lift + transport) with zero Flutter.

## What sim-1 already built (don't redo)
sim-1 landed the device half of the transport in `tools/virtual_device`:
- `ByteChannel` (`Arc<Mutex<VecDeque<u8>>>`, `push`/`pop`/`len`/`drain`), `PipeByteIo`
  (device-side `ByteIo`), `HostEnd { rx, tx }` (coordinator-side, now `Clone`), and
  `pipe() -> (PipeByteIo, HostEnd)`.
- `VirtualDevice` owns the upstream pipe and exposes `host_serial() -> HostEnd` (owned clone),
  `framebuffer()`, `touch()`, and `session() -> InitOutcome<VirtualDeviceSession>` /
  `VirtualDeviceSession::poll_once`.
So the device-end `ByteIo` + the device's `FramedSerial` links already exist. sim-2 builds the
**coordinator** endpoint over `HostEnd`, runs the device, and proves the handshake.

## Core model (read first)
**Design invariant (Axis 4): zero coordinator changes except the injected `Serial`.** The only
coordinator-facing change anywhere in the sim stack is *which* `Serial` impl
`UsbSerialManager::new` (`frostsnap_coordinator/src/usb_serial_manager.rs`) is handed.
`FramedSerialPort` and `usb_serial_manager.rs` stay byte-for-byte unchanged. The proof this is
possible already exists: `FfiSerial` (`frostsnapp/rust/src/api/port.rs:25-107`) is a
non-serialport `Serial`.

The pipe carries the **real** framed protocol — magic bytes, `Announce`, conch — with **no
short-circuit**. Two load-bearing subtleties (Axis 3):
- `FramedSerialPort::anything_to_read` calls `serialport::SerialPort::bytes_to_read()` (a
  nonblocking readiness method **not** in `Read+Write`), so `VirtualPort` must report buffered
  length truthfully.
- The coordinator reads frames with `BufRead::fill_buf` / `read_exact` under a 5 s read timeout
  (`DesktopSerial`, `serial_port.rs:260`). `VirtualPort::read` therefore **blocks until bytes
  arrive or the timeout elapses** — returning 0 immediately would make `read_exact` fail with
  `UnexpectedEof` and break framing. sim-1's `ByteChannel::pop` is non-blocking (fine for the
  device, which polls); sim-2 adds a `Condvar`-backed blocking read for the coordinator side.
  This is correct serial semantics and is required once a device runs concurrently with the
  coordinator (sim-4); in sim-2's lockstep pump (below) the device writes whole frames before the
  coordinator reads, so reads always find complete data and never actually block.

This also closes the residual ruthless flagged on the lift: `FramedSerial`'s own
receive/decode/timeout path becomes runtime-exercised on host, not just compile-checked.

## Threading constraint (discovered during implementation)
The plan originally said "run the device on its own thread." That is **infeasible as written**:
`FrostyUi` is `!Send` — `SuperDrawTarget` holds `Rc<RefCell<D>>`
(`frostsnap_widgets/src/super_draw_target.rs:12`) and the backup widgets use `Rc` too, so a
`VirtualDevice` (which owns `FrostyUi`) cannot be moved into `thread::spawn`. Everything *else*
(`SimHal`, flash, the `Arc`-backed handles) is `Send`. The proper per-device thread therefore has
to **construct the `FrostyUi` inside its own thread** (build-in-place, never move it across), which
is exactly the shape sim-4's `DevicePool` needs (it spawns device threads to run concurrently with
the app's background coordinator). So the dedicated per-device thread is **deferred to sim-4**.
For sim-2's single device, a **single-threaded lockstep pump** (interleave the device session and
the manager on one thread) proves the Slice-0 handshake deterministically with no `Send`
requirement — strictly simpler and less flaky than threading one device.

## Tasks
1. Extend `ByteChannel` with blocking receive: add a `Condvar` (paired with the existing
   `Mutex<VecDeque<u8>>`); `push` notifies; add `read(buf, timeout) -> usize` that waits for ≥1
   byte (or timeout) then drains up to `buf.len()`. Keep `pop`/`len` non-blocking for the device.
2. Coordinator-end `VirtualPort: serialport::SerialPort` (serialport 4.9.0) over a `HostEnd`.
   Implement **truthfully**: `bytes_to_read` (= `rx.len()`), `Read::read` (blocking via the new
   `ByteChannel::read` with the port's timeout), `Write::{write,flush}` (= `tx.push`),
   `try_clone` (clone the `HostEnd`), `name`, `timeout` (stored, settable via `set_timeout`).
   Stub as no-ops: baud/parity/flow-control/stop-bits getters+setters, RTS/DTR/CTS/DSR/RI/CD,
   `bytes_to_write`, `clear`, `set_break`/`clear_break`.
3. `VirtualSerial: frostsnap_coordinator::Serial` (`serial_port.rs:15`): owns the plugged
   device(s) (one for now); `available_ports()` returns one `PortDesc { id, vid, pid }` with the
   VID/PID `UsbSerialManager` filters on (verify the exact constants in
   `usb_serial_manager.rs` — research said vid 12346 / pid 4097); `open_device_port(id, baud)`
   returns that device's coordinator-end `VirtualPort` boxed. (This pulls `frostsnap_coordinator`
   + `serialport` into `tools/virtual_device`'s deps.)
4. Single-threaded lockstep pump (see Threading constraint): a helper that, given a
   `VirtualDeviceSession` and `&mut UsbSerialManager`, loops interleaving `session.poll_once(false)`
   with `manager.poll_ports()` (with a small real-time sleep so the coordinator's ~100 ms
   magic-byte cadence fires), collecting `DeviceChange`s, until a caller predicate or a deadline.
   No `thread::spawn`; framebuffer/touch handles update in place via their `Arc`s (no explicit
   export step). Handle `Poll::ResetRequested` (stop) and `InitOutcome::ResetRequested`. (The
   dedicated per-device thread that builds `FrostyUi` in-place is sim-4.)
5. Slice 0 test: build one `VirtualDevice`, `VirtualSerial::single` over its `host_serial()`,
   `UsbSerialManager::new(Box::new(VirtualSerial))`; run the lockstep pump; on `NeedsName` call
   `manager.accept_device_name(id, …)` (`usb_serial_manager.rs:634`, which populates the
   coordinator's `device_names` map that the registration gate at `:463-474` reads); assert the
   `DeviceChange` sequence reaches `Registered { id, name }`. (Device-side touch-confirm naming is
   sim-3; Slice-0 names coordinator-side.)
6. Upgrade guard (carry-forward from sim-1 review, below): ensure the coordinator never offers an
   upgrade to a sim digest, and/or soften `SimFirmware::handle`'s `Upgrade(_)` arm from
   `unreachable!` to an ignored, logged no-op so a future coordinator can't panic the device.
   Assert in the Slice-0 test that no upgrade message is sent.

## Acceptance
- Integration test: one virtual device handshakes to `DeviceChange::Registered` through a real
  `UsbSerialManager` (magic-bytes → Announce → AnnounceAck → NeedName → coordinator-side
  `accept_device_name` → Registered), green on host, driven by the single-threaded lockstep pump.
- Unit tests for `ByteChannel::read`: blocks then unblocks on a late push, and times out cleanly
  with no producer (the Condvar liveness ruthless flagged).
- **No edits** to `usb_serial_manager.rs` / `serial_port.rs` (enforce the invariant — the diff
  outside `tools/virtual_device` is limited to its new `frostsnap_coordinator`/`serialport`
  dependency, not the coordinator's source).
- esp still builds (`just check-device`); no SDL pulled into `tools/virtual_device`.

## Non-goals / deferred
No keygen yet (sim-3). No app/FFI (sim-4+). No multi-device / daisy-chain. No plug-unplug churn
(device present at launch; dynamic `add_device`/`unplug` is sim-4+).

## Depends on
sim-1 (the virtual device + its `ByteIo`/`HostEnd` pipe + `session()` runtime).

## Carry-forward from sim-1 review (ruthless)
`SimFirmware::handle` answers `Upgrade(_) => unreachable!` (correct in sim-1, where no
transport drives it). Once this plan wires a real coordinator to the device, that becomes a
**latent panic** if the coordinator ever offers an upgrade to a virtual device. sim-1's
contract (`SimFirmware` digest never matches a "latest" firmware) means the coordinator should
never offer one — but make that explicit here (Task 6).
