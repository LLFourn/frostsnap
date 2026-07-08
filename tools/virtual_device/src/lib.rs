//! A host-runnable virtual Frostsnap device: the **real** lifted `DeviceLoop` +
//! `FrostyUi` over software peripherals. Only the leaf `DeviceHal` peripherals are
//! sim-specific — crypto primitive, flash, RNG, clock, display, touch, serial — so
//! the device runs the identical protocol/UI the esp firmware does.
//!
//! See [`VirtualDevice`] for the ownership model (owned parts +
//! caller-owned [`VirtualDeviceSession`] holding one persistent loop).

mod chain_router;
mod clock;
mod device;
mod display;
mod firmware;
mod flash;
mod hal;
mod input;
mod secrets;
mod serial;
mod sim_coordinator;
mod thread;
mod touch;
mod virtual_serial;

pub use chain_router::{ChainRouter, SlotSpec};
pub use clock::SimClock;
pub use device::{SimUi, VirtualDevice, VirtualDeviceSession};
pub use display::{FramebufferDisplay, SharedFramebuffer, HEIGHT, WIDTH};
pub use firmware::SimFirmware;
pub use flash::{RamFlash, SECTORS};
pub use hal::{SimDownstream, SimHal, SimUpstream};
pub use input::DeviceInput;
pub use secrets::SimKeyedHash;
pub use serial::{pipe, ByteChannel, HostEnd, LinkGate, PipeByteIo};
pub use sim_coordinator::{SimCoordinator, StateCell, StepOutcome};
pub use thread::{DeviceThread, FrameSink, SpawnedDevice};
pub use touch::TouchQueue;

/// The touch-injection types, re-exported so callers (the FRB `SimDevice`) can push
/// touches without depending on `frostsnap_embedded`/`embedded-graphics` directly.
pub use embedded_graphics::geometry::Point;
pub use frostsnap_embedded::device_hal::{TouchEvent, TouchGesture};
pub use virtual_serial::{
    PortConnection, VirtualPort, VirtualSerial, FROSTSNAP_PID, FROSTSNAP_VID,
};

use frostsnap_coordinator::{DeviceChange, UsbSerialManager};
use frostsnap_embedded::device_hal::Poll;

/// The result of one [`lockstep_step`]: the coordinator's `DeviceChange`s this tick,
/// plus whether the device asked the shell to reset (`Poll::ResetRequested`, e.g. a
/// confirmed data-erase). Once `device_reset` is set the session's loop has torn
/// itself down, so the caller must stop polling it.
pub struct LockstepOutcome {
    pub changes: Vec<DeviceChange>,
    pub device_reset: bool,
}

/// One lockstep step: advance the device one tick, then poll the coordinator. The
/// caller owns the loop, the deadline, and any `accept_device_name` calls between
/// steps, and must stop on `device_reset`. Give the deadline generous margin — the
/// coordinator's ~100 ms magic-byte cadence is real-time and lives in the unchanged
/// manager. (sim-2 drives one device this way because `FrostyUi` is `!Send`; the
/// per-device thread is sim-4 — see [`VirtualDevice`].)
pub fn lockstep_step(
    session: &mut VirtualDeviceSession<'_>,
    manager: &mut UsbSerialManager,
) -> LockstepOutcome {
    let poll = session.poll_once(false);
    LockstepOutcome {
        changes: manager.poll_ports(),
        device_reset: matches!(poll, Poll::ResetRequested),
    }
}

/// Drive the device's hold-to-confirm control by pushing **one** touch-down at
/// `point` (never a release) into `touch`.
///
/// # Calibration (reused verbatim by sim-7)
/// The confirm control is the `HoldToConfirm` widget's `CircleButton`. Its
/// `handle_touch` latches `CircleButtonState::Pressed` on a touch-down inside the
/// button and only returns to `Idle` on a **release** (`lift_up = true`)
/// (`frostsnap_widgets/src/circle_button.rs`). The Pressed model is therefore
/// **latching**: one `lift_up = false` event keeps the button `Pressed` across every
/// subsequent `FrostyUi::poll` — a release is never re-sent, so the button never
/// un-presses on its own.
///
/// Confirmation is a **time-integral**, not a poll-tick count and not a sleep value:
/// while the button is `Pressed`, `HoldToConfirm::draw` accumulates the wall-clock
/// delta between successive draws into its progress
/// (`frostsnap_widgets/src/hold_to_confirm.rs`), and `FrostyUi::poll` redraws at most
/// once per `DISPLAY_REFRESH_MS` (25 ms). Once ≥ `HOLD_TO_CONFIRM_TIME_MS` (2000 ms)
/// of clock-advance has elapsed *while Pressed*, the button shows its checkmark and
/// `KeygenCheck::is_confirmed()` becomes true, firing `UiEvent::KeyGenConfirm`.
///
/// So the caller must keep polling the device with ≥ 2000 ms of real clock-advance
/// accruing between draws (the sim clock is `Instant`-backed). One touch-down
/// suffices once the button is shown and latched; re-asserting the press each poll
/// (as the keygen test does) only adds robustness to the startup race where the
/// coordinator's CheckKeyGen lands a few ticks before the device renders the button.
/// This helper only injects the press; the caller owns the pump.
pub fn hold_to_confirm(touch: &TouchQueue, point: embedded_graphics::geometry::Point) {
    touch.push(TouchEvent {
        point,
        lift_up: false,
        gesture: TouchGesture::None,
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use frostsnap_core::{device::DeviceSecretDerivation, nonce_stream::NonceStreamId};
    use frostsnap_embedded::{
        device_hal::InitOutcome, FlashHeader, FlashPartition, KeyedHash, ShareEncryptionSecrets,
    };
    use rand_chacha::ChaCha20Rng;
    use rand_core::SeedableRng;
    use std::collections::HashSet;

    // (a) The device keypair is real crypto: deterministic for a given seed
    // (same boot → same key) and key-dependent (a different fixed-entropy key gives
    // a different public key). A constant keyed-hash would make all of these equal.
    #[test]
    fn device_keypair_is_deterministic_and_key_dependent() {
        let derive = |rng_seed: u64, key_label: &str| {
            let flash = std::cell::RefCell::new(RamFlash::new());
            let mut nvs = FlashPartition::new(&flash, 0, SECTORS as u32, "nvs");
            let header_sectors = nvs.split_off_front(2);
            let header_flash = FlashHeader::new(header_sectors);
            let mut rng = ChaCha20Rng::seed_from_u64(rng_seed);
            let header = header_flash.init(&mut rng);
            let mut hasher = SimKeyedHash::from_seed(rng_seed, key_label);
            header.device_keypair(&mut hasher).public_key()
        };

        assert_eq!(
            derive(7, "fixed-entropy-key"),
            derive(7, "fixed-entropy-key"),
            "same seed + key must reproduce the device keypair"
        );
        assert_ne!(
            derive(7, "fixed-entropy-key"),
            derive(7, "other-key"),
            "the keypair must depend on the fixed-entropy key (real keyed hash)"
        );
    }

    // (b) The shared portable derivation over a real KeyedHash is non-constant and
    // varies with its inputs/keys. Exercises ShareEncryptionSecrets<SimKeyedHash>
    // (the one source of truth), not a sim re-implementation. derive_nonce_seed is
    // the safety-critical path: a constant or index-independent output is fatal.
    #[test]
    fn shared_nonce_derivation_is_real_and_input_dependent() {
        let mut secrets =
            ShareEncryptionSecrets(SimKeyedHash::from_seed(1, "share-encryption-key"));
        let stream = NonceStreamId([9u8; 16]);
        let seed = [4u8; 32];

        let n0 = secrets.derive_nonce_seed(stream, 0, &seed);
        let n1 = secrets.derive_nonce_seed(stream, 1, &seed);

        assert_ne!(
            n0, [0u8; 32],
            "nonce seed must not be the constant stub value"
        );
        assert_ne!(
            n0, n1,
            "nonce seed must depend on the index (guards to_be_bytes packing)"
        );

        // key-dependent: a different keyed-hash key gives a different seed.
        let mut other = ShareEncryptionSecrets(SimKeyedHash::from_seed(2, "share-encryption-key"));
        assert_ne!(
            n0,
            other.derive_nonce_seed(stream, 0, &seed),
            "nonce seed must depend on the device key"
        );
    }

    // The keyed-hash primitive itself is a real keyed PRF: domain-, input-, and
    // key-separated (the leaf that ShareEncryptionSecrets composes).
    #[test]
    fn keyed_hash_primitive_is_separated() {
        let mut k = SimKeyedHash::from_seed(1, "fixed-entropy-key");
        let base = k.keyed_hash("domain-a", b"input-x");
        assert_ne!(base, [0u8; 32]);
        assert_ne!(
            base,
            k.keyed_hash("domain-b", b"input-x"),
            "domain separated"
        );
        assert_ne!(
            base,
            k.keyed_hash("domain-a", b"input-y"),
            "input separated"
        );
        let mut k2 = SimKeyedHash::from_seed(2, "fixed-entropy-key");
        assert_ne!(base, k2.keyed_hash("domain-a", b"input-x"), "key separated");
    }

    // (c) A booted device runs a *persistent session* (one loop across ticks) and
    // renders a real frame we can export to a non-blank PNG. The Instant-backed
    // clock means we must let wall-clock pass the 25ms redraw gate.
    #[test]
    fn booted_device_renders_a_frame() {
        let mut device = VirtualDevice::new(42);
        let fb = device.framebuffer();

        let mut session = match device.session() {
            InitOutcome::Ready(session) => session,
            InitOutcome::ResetRequested => panic!("a fresh device should boot, not reset"),
        };

        for _ in 0..8 {
            session.poll_once(false);
            std::thread::sleep(std::time::Duration::from_millis(10));
        }

        let (w, h, rgba) = fb.export_rgba();
        assert_eq!((w, h), (WIDTH, HEIGHT));
        assert_eq!(rgba.len(), (WIDTH * HEIGHT * 4) as usize);
        let distinct: HashSet<&[u8]> = rgba.chunks(4).collect();
        assert!(
            distinct.len() > 1,
            "the real FrostyUi should have rendered content, not a blank frame"
        );

        let path = std::env::temp_dir().join("frostsnap_virtual_device_frame.png");
        fb.save_png(&path).expect("save png");
        assert!(std::fs::metadata(&path).expect("png exists").len() > 0);
    }

    // (b, cont.) The other half of the shared derivation: get_share_encryption_key
    // through ShareEncryptionSecrets<SimKeyedHash> is non-constant and varies with a
    // packed input (the access-structure ref) and with the keyed-hash key.
    #[test]
    fn shared_share_encryption_key_is_real_and_input_dependent() {
        use frostsnap_core::schnorr_fun::fun::prelude::*;
        use frostsnap_core::{
            AccessStructureId, AccessStructureRef, CoordShareDecryptionContrib, KeyId,
        };

        let party = s!(1).public();
        let coord = || CoordShareDecryptionContrib::from_bytes([12u8; 32]);
        let asr = AccessStructureRef {
            key_id: KeyId([10u8; 32]),
            access_structure_id: AccessStructureId([11u8; 32]),
        };

        let mut secrets =
            ShareEncryptionSecrets(SimKeyedHash::from_seed(1, "share-encryption-key"));
        let k0 = secrets.get_share_encryption_key(asr, party, coord()).0;
        assert_ne!(
            k0, [0u8; 32],
            "share encryption key must not be the constant stub value"
        );

        // varies with a packed input (a different key_id in the access-structure ref).
        let asr2 = AccessStructureRef {
            key_id: KeyId([99u8; 32]),
            access_structure_id: AccessStructureId([11u8; 32]),
        };
        assert_ne!(
            k0,
            secrets.get_share_encryption_key(asr2, party, coord()).0,
            "share encryption key must depend on the access structure ref"
        );

        // varies with the keyed-hash key.
        let mut other = ShareEncryptionSecrets(SimKeyedHash::from_seed(2, "share-encryption-key"));
        assert_ne!(
            k0,
            other.get_share_encryption_key(asr, party, coord()).0,
            "share encryption key must depend on the device key"
        );
    }

    // The coordinator-side serial handle is an owned, cloneable handle (like the
    // framebuffer/touch handles): captured before a session and used to drive bytes
    // into the device while the borrowed loop polls. The device drains its upstream
    // input every poll (PowerOn magic-byte scan), so pushed bytes are consumed.
    #[test]
    fn host_serial_handle_is_cloneable_and_drives_bytes_during_a_session() {
        let mut device = VirtualDevice::new(5);
        let host = device.host_serial(); // owned: still usable after session() borrows &mut device
        let host_clone = host.clone();

        let mut session = match device.session() {
            InitOutcome::Ready(session) => session,
            InitOutcome::ResetRequested => panic!("a fresh device should boot, not reset"),
        };

        host.tx.push(&[1, 2, 3, 4]);
        assert_eq!(
            host_clone.tx.len(),
            4,
            "clones share the same Arc-backed wire"
        );

        session.poll_once(false);
        assert_eq!(
            host.tx.len(),
            0,
            "the device drained its upstream input while the session polled"
        );
    }

    // Slice 0: one virtual device handshakes through the *real, unchanged*
    // UsbSerialManager over the in-memory pipe — magic-bytes → Announce → NeedName →
    // coordinator-side accept_device_name → Registered — driven by the lockstep pump.
    #[test]
    fn one_virtual_device_registers_through_the_coordinator() {
        use frostsnap_coordinator::{DeviceChange, UsbSerialManager};
        use std::time::{Duration, Instant};

        let mut device = VirtualDevice::new(1);
        let host = device.host_serial();
        let mut manager =
            UsbSerialManager::new(Box::new(VirtualSerial::single("sim-device-0", host)));

        let mut session = match device.session() {
            InitOutcome::Ready(session) => session,
            InitOutcome::ResetRequested => panic!("a fresh device should boot, not reset"),
        };

        // Generous deadline: the coordinator's ~100ms magic-byte cadence is real-time
        // and lives in the unchanged manager, so this must not be wall-clock tight.
        let deadline = Instant::now() + Duration::from_secs(30);
        let mut connected_id = None;
        let mut registered = None;
        while Instant::now() < deadline && registered.is_none() {
            let outcome = lockstep_step(&mut session, &mut manager);
            assert!(
                !outcome.device_reset,
                "device unexpectedly reset during the handshake"
            );
            for change in outcome.changes {
                match change {
                    DeviceChange::Connected { id, .. } => connected_id = Some(id),
                    DeviceChange::NeedsName { id } => {
                        connected_id = Some(id);
                        manager.accept_device_name(id, "Sim Device".to_string());
                    }
                    DeviceChange::Registered { id, name } => registered = Some((id, name)),
                    _ => {}
                }
            }
            std::thread::sleep(Duration::from_millis(5));
        }

        let (id, name) = registered.expect("device should register within the deadline");
        assert_eq!(
            Some(id),
            connected_id,
            "the registered id matches the announced one"
        );
        assert_eq!(name, "Sim Device");

        // Release the &mut device borrow held by the session, then check the guard:
        // the sim must never have been offered a firmware upgrade.
        drop(session);
        assert_eq!(
            device.upgrades_offered(),
            0,
            "a genuine-off sim device must never be offered a firmware upgrade"
        );
    }

    // sim-4: the per-device thread runtime registers through a *real* UsbSerialManager
    // across two real threads (not lockstep) — this exercises sim-2's Condvar blocking
    // read at runtime: the manager's read thread blocks on the pipe while the device
    // thread renders and replies concurrently. Also asserts a frame is observable.
    #[test]
    fn spawned_device_registers_through_the_coordinator_across_threads() {
        use frostsnap_coordinator::{DeviceChange, UsbSerialManager};
        use std::sync::atomic::{AtomicUsize, Ordering};
        use std::sync::Arc;
        use std::time::{Duration, Instant};

        let frames = Arc::new(AtomicUsize::new(0));
        let frame_counter = frames.clone();
        let spawned = VirtualDevice::spawn(
            7,
            crate::firmware::SimFirmware::PLACEHOLDER_DIGEST,
            move |_, _, _| {
                frame_counter.fetch_add(1, Ordering::Relaxed);
            },
        );

        let mut manager = UsbSerialManager::new(Box::new(VirtualSerial::single(
            "sim-0",
            spawned.host.clone().unwrap(),
        )));

        // Generous wall-clock deadline: the coordinator's ~100ms magic-byte cadence is
        // real-time and the device runs on its own thread, so this must not be tight.
        let deadline = Instant::now() + Duration::from_secs(30);
        let mut registered = None;
        while Instant::now() < deadline && registered.is_none() {
            for change in manager.poll_ports() {
                match change {
                    DeviceChange::NeedsName { id } => {
                        manager.accept_device_name(id, "Sim".to_string());
                    }
                    DeviceChange::Registered { id, .. } => registered = Some(id),
                    _ => {}
                }
            }
            std::thread::sleep(Duration::from_millis(5));
        }

        let id = registered.expect("device should register within the deadline");
        assert_eq!(
            id, spawned.device_id,
            "the registered id matches the device thread's announced id"
        );

        // The device renders on its own thread and `FrostyUi` only redraws once
        // `DISPLAY_REFRESH_MS` of its wall-clock has elapsed, so the first frame
        // lands shortly *after* registration. Wait for it rather than racing the
        // assert (the in-memory handshake can complete in under a refresh period).
        while Instant::now() < deadline && frames.load(Ordering::Relaxed) == 0 {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(
            frames.load(Ordering::Relaxed) > 0,
            "the device thread should have rendered and pushed at least one frame"
        );

        // Dropping the handle stops + joins the device thread; this must not hang.
        drop(spawned);
    }

    // Connect/disconnect (sim-7): unplugging flips the coordinator-side port
    // presence only — the device thread keeps running — and the coordinator
    // observes a real disconnect. Replugging makes the port reappear and the
    // portable `DeviceLoop` re-announces (magic-bytes-while-established ->
    // soft_reset), so the device registers again with no embedded change.
    #[test]
    fn unplug_and_replug_round_trips_through_the_coordinator() {
        use frostsnap_coordinator::{DeviceChange, UsbSerialManager};
        use std::time::{Duration, Instant};

        let spawned = VirtualDevice::spawn(
            9,
            crate::firmware::SimFirmware::PLACEHOLDER_DIGEST,
            |_, _, _| {},
        );

        let serial = VirtualSerial::single("sim-0", spawned.host.clone().unwrap());
        let connection = serial.connection();
        let mut manager = UsbSerialManager::new(Box::new(serial));

        // Pump the manager (real wall-clock; magic cadence is ~100ms) until `f`
        // observes the change it wants in a poll round, or the deadline passes.
        type ChangePred = Box<dyn FnMut(&mut UsbSerialManager, DeviceChange) -> bool>;
        let pump_until = |manager: &mut UsbSerialManager, mut f: ChangePred| -> bool {
            let deadline = Instant::now() + Duration::from_secs(30);
            while Instant::now() < deadline {
                for change in manager.poll_ports() {
                    if f(manager, change) {
                        return true;
                    }
                }
                std::thread::sleep(Duration::from_millis(5));
            }
            false
        };

        // 1. Initial registration.
        let registered = pump_until(
            &mut manager,
            Box::new(|m, change| match change {
                DeviceChange::NeedsName { id } => {
                    m.accept_device_name(id, "Sim".to_string());
                    false
                }
                DeviceChange::Registered { .. } => true,
                _ => false,
            }),
        );
        assert!(registered, "device registers initially");
        let id = spawned.device_id;

        // 2. Unplug -> the port vanishes -> the coordinator sees a disconnect.
        connection.set_connected(false);
        let saw_disconnect = pump_until(
            &mut manager,
            Box::new(
                move |_, change| matches!(change, DeviceChange::Disconnected { id: gone } if gone == id),
            ),
        );
        assert!(saw_disconnect, "coordinator sees the device unplug");

        // 3. Replug -> the port reappears -> the device re-handshakes and re-registers.
        connection.set_connected(true);
        let reregistered = pump_until(
            &mut manager,
            Box::new(|m, change| match change {
                DeviceChange::NeedsName { id } => {
                    m.accept_device_name(id, "Sim".to_string());
                    false
                }
                DeviceChange::Registered { .. } => true,
                _ => false,
            }),
        );
        assert!(reregistered, "device re-registers after replug");

        drop(spawned);
    }

    // Slice 1: a complete 1-of-1 keygen, driven by a *scripted device touch through
    // the real FrostyUi* (no injected UiEvent) plus the Rust-level coordinator bridge.
    // The device confirms the security code via a held hold-to-confirm; the
    // coordinator advances to all-acks and finalizes an AccessStructureRef. Returns the
    // booted device (session dropped) + the finalized ref so callers can also inspect the
    // post-keygen device (the power-cycle test recovers its flash).
    fn run_one_device_keygen(seed: u64) -> (VirtualDevice, frostsnap_core::AccessStructureRef) {
        use embedded_graphics::geometry::Point;
        use frostsnap_core::coordinator::BeginKeygen;
        use frostsnap_core::device::KeyPurpose;
        use frostsnap_core::SymmetricKey;
        use std::collections::BTreeSet;
        use std::time::{Duration, Instant};

        // The hold-to-confirm CircleButton sits at a different spot on each screen:
        // the bare NewNamePrompt (HoldToConfirm<Text>) centers it (~120,150); the
        // KeygenCheck lays it low-center (~120,215) below the security code. Both
        // verified against the rendered framebuffer.
        const NAME_CONFIRM_POINT: Point = Point::new(120, 150);
        const KEYGEN_CONFIRM_POINT: Point = Point::new(120, 215);
        // Generous wall-clock margin: the coordinator's ~100ms magic-byte cadence and
        // the 2000ms hold are both real-time (the sim clock is Instant-backed).
        let deadline = || Instant::now() + Duration::from_secs(40);

        let mut device = VirtualDevice::new(seed);
        let fb = device.framebuffer();
        let touch = device.touch();
        let host = device.host_serial();
        let manager = UsbSerialManager::new(Box::new(VirtualSerial::single("sim-device-0", host)));
        let mut coordinator = SimCoordinator::new(manager, "Sim Device");

        let mut session = match device.session() {
            InitOutcome::Ready(session) => session,
            InitOutcome::ResetRequested => panic!("a fresh device should boot, not reset"),
        };

        // Phase 1: handshake + REAL device naming. The bridge prompts the device to
        // name itself (finish_naming); the device shows the NewName screen and we
        // hold-to-confirm it. This sets the device's pending name — which keygen
        // finalize requires (an unnamed device panics on FinalizeKeyGen) — and the
        // resulting SetName drives the device to Registered.
        let registered_id = {
            let until = deadline();
            let mut registered = None;
            while Instant::now() < until && registered.is_none() {
                hold_to_confirm(&touch, NAME_CONFIRM_POINT);
                assert!(
                    !lockstep_step_device(&mut session),
                    "device unexpectedly reset during the handshake"
                );
                if let Some(id) = coordinator.step().registered.first().copied() {
                    registered = Some(id);
                }
                // Let wall-clock advance so the name hold-to-confirm integral grows.
                std::thread::sleep(Duration::from_millis(15));
            }
            registered.expect("device should register (and self-name) within the deadline")
        };

        // Phase 2: begin a 1-of-1 keygen for the registered device.
        let state = StateCell::new();
        let mut rng = ChaCha20Rng::seed_from_u64(99);
        // Bitcoin purpose so the device-side `holds_key` (wallet_network) can confirm
        // the finalized key actually persisted on the device.
        let begin_keygen = BeginKeygen::new(
            vec![registered_id],
            1,
            "sim wallet".to_string(),
            KeyPurpose::Bitcoin(bitcoin::Network::Bitcoin),
            &mut rng,
        );
        let keygen = frostsnap_coordinator::keygen::KeyGen::new(
            state.clone(),
            coordinator.coordinator_mut(),
            BTreeSet::from([registered_id]),
            begin_keygen,
            &mut rng,
        );
        coordinator.set_keygen(keygen);

        // Phase 3: pump until the device shows the security-code check (CheckKeyGen).
        {
            let until = deadline();
            while Instant::now() < until && state.get().and_then(|s| s.session_hash).is_none() {
                assert!(
                    !lockstep_step_device(&mut session),
                    "device reset during keygen"
                );
                coordinator.step();
                std::thread::sleep(Duration::from_millis(5));
            }
        }
        let security_state = state.get().expect("keygen state emitted");
        assert!(
            security_state.session_hash.is_some(),
            "device should reach the security-code check"
        );
        assert!(
            security_state.aborted.is_none(),
            "keygen must not abort: {:?}",
            security_state.aborted
        );

        // The coordinator's session_hash can land a few ticks before the *device*
        // renders the KeygenCheck widget, so pump a little more (no touch yet) to let
        // the security-code screen draw before capturing it as a debug artifact.
        {
            let until = Instant::now() + Duration::from_secs(2);
            while Instant::now() < until {
                lockstep_step_device(&mut session);
                coordinator.step();
                std::thread::sleep(Duration::from_millis(15));
            }
        }
        save_phase_png(&fb, "frostsnap_keygen_security_code.png");

        // Phase 4: confirm via a held touch on the confirm control. The button latches
        // Pressed on a touch-down and HoldToConfirm integrates the clock delta on each
        // redraw. We re-assert the touch-down each poll because the coordinator's
        // CheckKeyGen (session_hash) can land a few ticks before the *device* renders
        // the KeygenCheck widget — re-asserting guarantees a press is queued once the
        // button actually exists. (A single touch-down also suffices once the button is
        // latched; re-asserting is just robust to that startup race.)
        {
            let until = deadline();
            while Instant::now() < until && !state.get().map(|s| s.all_acks).unwrap_or(false) {
                hold_to_confirm(&touch, KEYGEN_CONFIRM_POINT);
                assert!(
                    !lockstep_step_device(&mut session),
                    "device reset during confirm"
                );
                coordinator.step();
                // Let real wall-clock advance between draws so the hold integral grows.
                std::thread::sleep(Duration::from_millis(15));
            }
        }
        let acked = state.get().expect("state");
        assert!(
            acked.all_acks,
            "the held touch should have confirmed keygen (all acks). state: {acked:?}"
        );
        save_phase_png(&fb, "frostsnap_keygen_confirmed.png");

        // Phase 5: finalize. `finalize_keygen` sets the coordinator-side
        // KeyGenState.finished synchronously AND queues `FinishKeygen` for the device,
        // so we must pump a phase that is NOT gated on `finished` (it is already set)
        // to actually flush `FinishKeygen` to the device and let it persist its share.
        let asr = coordinator.finalize_keygen(SymmetricKey([7u8; 32]), &mut rng);
        assert!(
            !session.holds_key(asr.key_id),
            "device must not hold the key until finalize is delivered"
        );
        {
            let until = deadline();
            while Instant::now() < until && !session.holds_key(asr.key_id) {
                assert!(
                    !lockstep_step_device(&mut session),
                    "device reset after finalize"
                );
                coordinator.step();
                std::thread::sleep(Duration::from_millis(5));
            }
        }
        assert!(
            session.holds_key(asr.key_id),
            "device should persist the finalized key (FinishKeygen delivered + processed)"
        );
        assert_eq!(
            state.get().and_then(|s| s.finished),
            Some(asr),
            "coordinator-side keygen state should also reflect the finalized key"
        );
        save_phase_png(&fb, "frostsnap_keygen_finished.png");

        drop(session);
        (device, asr)
    }

    // The keygen completes and the sim was never offered a firmware upgrade.
    #[test]
    fn one_device_keygen_completes() {
        let (device, _asr) = run_one_device_keygen(1);
        assert_eq!(
            device.upgrades_offered(),
            0,
            "a genuine-off sim device must never be offered a firmware upgrade"
        );
    }

    // sim-13: a power-cycle preserves NVS. Drive a real keygen so the device persists a
    // finalized share, recover its flash (power off), then boot a FRESH device from that
    // flash (power on): it STILL holds the key. The negative control — booting from an
    // empty flash — does NOT, proving the check is about a runtime-written value surviving,
    // not the seed-derivable device id (which is stable regardless of flash).
    #[test]
    fn power_cycle_preserves_persisted_share() {
        let seed = 1;
        let (device, asr) = run_one_device_keygen(seed);
        let preserved = device.into_flash();

        let mut rebooted = VirtualDevice::from_saved(
            seed,
            SimFirmware::PLACEHOLDER_DIGEST,
            PipeByteIo::disconnected(),
            PipeByteIo::disconnected(),
            SharedFramebuffer::new(),
            TouchQueue::new(),
            preserved,
        );
        let session = match rebooted.session() {
            InitOutcome::Ready(session) => session,
            InitOutcome::ResetRequested => panic!("boot from preserved flash should be Ready"),
        };
        assert!(
            session.holds_key(asr.key_id),
            "the finalized share must survive a power-cycle (flash preserved)"
        );
        drop(session);

        let mut fresh = VirtualDevice::from_saved(
            seed,
            SimFirmware::PLACEHOLDER_DIGEST,
            PipeByteIo::disconnected(),
            PipeByteIo::disconnected(),
            SharedFramebuffer::new(),
            TouchQueue::new(),
            RamFlash::new(),
        );
        let session = match fresh.session() {
            InitOutcome::Ready(session) => session,
            InitOutcome::ResetRequested => panic!("fresh boot should be Ready"),
        };
        assert!(
            !session.holds_key(asr.key_id),
            "an empty flash must NOT hold the key — proves persistence, not seed-derivation"
        );
    }

    /// Advance the device one tick; returns whether it asked to reset. Keeps the
    /// keygen test's pump loops terse (the SimCoordinator owns the manager, so the
    /// crate-level `lockstep_step` — which borrows both — isn't usable here).
    fn lockstep_step_device(session: &mut VirtualDeviceSession<'_>) -> bool {
        matches!(
            session.poll_once(false),
            frostsnap_embedded::device_hal::Poll::ResetRequested
        )
    }

    fn save_phase_png(fb: &SharedFramebuffer, name: &str) {
        let path = std::env::temp_dir().join(name);
        fb.save_png(&path).expect("save png");
    }
}
