//! A host-runnable virtual Frostsnap device: the **real** lifted `DeviceLoop` +
//! `FrostyUi` over software peripherals. Only the leaf `DeviceHal` peripherals are
//! sim-specific — crypto primitive, flash, RNG, clock, display, touch, serial — so
//! the device runs the identical protocol/UI the esp firmware does.
//!
//! See [`VirtualDevice`] for the ownership model (owned parts +
//! caller-owned [`VirtualDeviceSession`] holding one persistent loop).

mod clock;
mod device;
mod display;
mod firmware;
mod flash;
mod hal;
mod secrets;
mod serial;
mod touch;
mod virtual_serial;

pub use clock::SimClock;
pub use device::{SimUi, VirtualDevice, VirtualDeviceSession};
pub use display::{FramebufferDisplay, SharedFramebuffer, HEIGHT, WIDTH};
pub use firmware::SimFirmware;
pub use flash::{RamFlash, SECTORS};
pub use hal::{SimDownstream, SimHal, SimUpstream};
pub use secrets::SimKeyedHash;
pub use serial::{pipe, ByteChannel, HostEnd, PipeByteIo};
pub use touch::TouchQueue;
pub use virtual_serial::{VirtualPort, VirtualSerial, FROSTSNAP_PID, FROSTSNAP_VID};

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
}
