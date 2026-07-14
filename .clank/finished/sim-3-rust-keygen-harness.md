# sim-3-rust-keygen-harness
# sim-3: Slice 1 — scripted 1-of-1 keygen at the Rust level (no Flutter)

## Goal
Drive a complete **1-of-1 keygen** end-to-end in pure Rust: the coordinator starts keygen, the
**real** `FrostyUi` shows the security-code check, a **scripted device touch** confirms it
(`UiEvent::KeyGenConfirm`), and the coordinator finalizes a key. This de-risks "send button
presses to the device" entirely before any Flutter, and produces device-screen PNG artifacts +
the hold-to-confirm calibration sim-7 reuses.

## What sim-1/sim-2 already built (don't redo)
- `VirtualDevice` (real `DeviceLoop` + `FrostyUi`), `session()`/`poll_once`, `framebuffer()`
  (PNG/RGBA export), `touch()` (inject `TouchEvent`s), `host_serial()`.
- `VirtualSerial`/`VirtualPort` transport; `lockstep_step(session, manager) -> LockstepOutcome
  { changes: Vec<DeviceChange>, device_reset: bool }`; the magic-bytes→Announce→`accept_device_name`
  →`Registered` handshake (Slice-0). **No device thread** — `FrostyUi` is `!Send`, so sim-3 drives
  the device with the same single-threaded lockstep pump.

## Core model (read first)
1. **The device confirm is a real touch through the real widget tree, not an injected `UiEvent`.**
   Keygen pauses on the `KeygenCheck` widget (`frostsnap_embedded/src/frosty_ui.rs` ~189-198,
   410-417); a hold-to-confirm gesture makes `is_confirmed()` true, emitting
   `UiEvent::KeyGenConfirm { phase }` (`ui.rs:145`) consumed by the loop (`device_loop.rs`
   ~681-687 → `signer.keygen_ack`). sim-3 must **calibrate** the synthetic touch — position over
   the confirm control, held long enough across `poll_once` ticks + `SimClock` advances (the
   widget times the hold via `HOLD_TO_CONFIRM_TIME_MS`). Device naming during keygen, if prompted,
   is the analogous `UiEvent::NameConfirm` (`ui.rs:151`).
2. **The coordinator side needs a bridge sim-2 didn't build.** `UsbSerialManager` is pure
   transport; the keygen *protocol* is `FrostCoordinator` (frostsnap_core) driven by the `KeyGen`
   `UiProtocol` (`frostsnap_coordinator/src/keygen.rs`). The loop that wires them —
   `poll_ports()` → feed `DeviceChange::AppMessage` to `FrostCoordinator::recv_device_message`
   (`frostsnap_core/src/coordinator.rs:595`) → drive the `UiProtocol::poll()` → send outputs via
   `UsbSender` (`UsbSerialManager::usb_sender()`, `.send(CoordinatorSendMessage)`) — lives only in
   the FFI-bound `FfiCoordinator` (`frostsnapp/rust/src/coordinator.rs:186-345`, which needs
   `frb_generated` + `StreamSink` + a db, none available here). sim-3 **replicates that bridge at
   the Rust level**, minus FFI/db/StreamSink, as reusable test/sim glue.

## Tasks
1. A minimal Rust-level coordinator runner (in `tools/virtual_device`, e.g. `sim_coordinator.rs`)
   owning a `FrostCoordinator` + `UsbSerialManager` (+ its `UsbSender`) + the active `UiProtocol`s.
   One `step()` (called alongside `lockstep_step`): drain `poll_ports()` changes, route
   `AppMessage`s into `FrostCoordinator::recv_device_message`, drive `UiProtocol::poll()` and the
   coordinator's outgoing messages out via `UsbSender::send`. Use a plain shared cell as the
   `Sink<KeyGenState>` (no `StreamSink`). Model it on `FfiCoordinator` (the reference).
2. Start keygen: build `BeginKeygen` (threshold 1, the one registered `DeviceId`) and
   `KeyGen::new(sink, &mut frost_coordinator, connected, begin_keygen, rng)`
   (`frostsnap_coordinator/src/keygen.rs`); register it as the active `UiProtocol`. Pump
   device+coordinator in lockstep until `KeyGenState` reaches `CheckKeyGen { session_hash }`.
3. On `CheckKeyGen`: dump the security-code PNG (`framebuffer().save_png`), then feed the
   calibrated hold-to-confirm `TouchEvent`s into `touch()`; pump until the device emits the
   ack and the coordinator records `KeyGenAck`.
4. Finalize (`FrostCoordinator::finalize_keygen` path) and assert an `AccessStructureRef` /
   key is produced. Handle a device `NameConfirm` prompt if the flow raises one.
5. Capture device-screen PNGs at each phase as Slice-1 debug artifacts (not the app tray).
6. Carry-forward (best-effort): exercise the `device_reset` path sim-2 surfaced — drive a
   touch-confirmed data-erase (or a coordinator wipe) and assert `lockstep_step` reports
   `device_reset`. If reaching the erase UI needs machinery beyond keygen scope, note it and keep
   it deferred (the surfacing API itself is already covered by the handshake's no-reset assert).

## Acceptance
- A Rust test runs a 1-of-1 keygen to completion (finalized key / `AccessStructureRef`), driven
  by **scripted device touches through the real `FrostyUi`** (no direct `UiEvent` injection) and
  the Rust-level coordinator bridge over the in-memory transport, green on host.
- The hold-to-confirm calibration is documented (touch position + hold duration in poll-ticks /
  ms) so sim-7 can reuse it for the FFI `touch()` path.
- No edits to `usb_serial_manager.rs`/`serial_port.rs`; esp still builds; no SDL.

## Non-goals / deferred
No Flutter / FFI (sim-4+). No signing (keygen only). No multi-party (1-of-1 — the user's target;
multi-device keygen is a later epic step).

## Depends on
sim-2 (lockstep pump + `LockstepOutcome.device_reset` + `Registered` handshake + `framebuffer()`/
`touch()` handles).
