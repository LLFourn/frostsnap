//! The sim's `FirmwareServices`: a RAM-only mirror of the real upgrade flow.
//!
//! FAKED, knowingly (user-accepted trade, see the fsim-firmware-upgrade plan):
//! nothing is stored and nothing is verified — the image bytes are drained and
//! DISCARDED, and the device simply trusts the coordinator's claimed digest,
//! announcing it after the reboot. Sim green is protocol/UI coverage, never
//! storage-path coverage.
//!
//! REAL, and the point: every comms message (`PrepareUpgrade*`,
//! `AckUpgradeMode`, `EnterUpgradeMode`, the raw byte stream with its
//! chunk-ready flow control, passive forwarding down the chain) and every
//! device screen — the consent prompt and erase/download progress are the
//! real widgets driven through the real `Workflow` values, in the same order
//! the esp half (`device/src/ota.rs`) drives
//! them. The genuine-check half is also dropped: a `Challenge` is answered
//! with `None` (dev/non-genuine device, no certificate).

use frostsnap_comms::{
    CommsMisc, CoordinatorSendBody, CoordinatorUpgradeMessage, DeviceSendBody, Downstream,
    Sha256Digest, Upstream, FIRMWARE_NEXT_CHUNK_READY_SIGNAL,
};
use frostsnap_embedded::{
    device_hal::{FirmwareAction, FirmwareServices},
    framed_serial::{ByteIo, SerialPort},
    ui::{self, UserInteraction},
};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};

/// The chunk granularity of the real pump (one flash sector): progress and
/// chunk-ready signalling advance per this many bytes.
const SECTOR_SIZE: u32 = 4096;

/// Per-sector pacing of the drain. In-memory pipes would finish a whole image
/// in microseconds — no visible progress, and nothing for an interruption
/// test to interrupt — where the real link (921600 baud + flash writes) takes
/// seconds. 200 ms/sector puts the sim app's 32-chunk image at ~6 s of
/// observable transfer — comfortably longer than one harness hold-and-check
/// cycle, so an interruption e2e can reliably unplug mid-transfer.
const SECTOR_PACING: std::time::Duration = std::time::Duration::from_millis(200);

/// A device's single firmware-identity record — "what the flash claims". Read
/// LIVE at every use (the announce, the Passive-vs-Upgrading decision on
/// `PrepareUpgrade*`), so the next announce reports whatever was last written.
/// Writers: a COMPLETED transfer, and the harness's set-digest surface (any
/// time, powered or not). Last write wins — with one record there is nothing
/// for it to desync from. Cheap to clone; clones share the record, which is
/// how it survives a power-cycle (the slot keeps a clone and hands it to each
/// spawned thread). An interrupted transfer writes nothing, so power loss
/// keeps the old digest.
#[derive(Clone)]
pub struct FirmwareDigestCell(Arc<Mutex<Sha256Digest>>);

impl FirmwareDigestCell {
    pub fn new(digest: Sha256Digest) -> Self {
        Self(Arc::new(Mutex::new(digest)))
    }

    pub fn get(&self) -> Sha256Digest {
        *self.0.lock().unwrap()
    }

    pub fn set(&self, digest: Sha256Digest) {
        *self.0.lock().unwrap() = digest;
    }
}

pub struct SimFirmware {
    digest: FirmwareDigestCell,
    upgrade: Option<Staged>,
    /// The device thread's stop flag. The drain pump blocks the device loop
    /// (the real takeover semantics) but is sim-owned code, so it exits
    /// cooperatively when the slot powers off mid-transfer.
    stop: Arc<AtomicBool>,
    upgrades_offered: Arc<AtomicU32>,
}

/// Mirror of `device/src/ota.rs`'s `FirmwareUpgradeMode` shape, minus the
/// partitions.
enum Staged {
    Upgrading {
        size: u32,
        digest: Sha256Digest,
        state: State,
    },
    Passive {
        size: u32,
        sent_ack: bool,
    },
}

enum State {
    WaitingForConfirm { sent_prompt: bool },
    Erase { seq: u32 },
    WaitingToEnterUpgradeMode,
}

impl SimFirmware {
    /// A placeholder digest for harnesses that don't care about app-side firmware
    /// compatibility (the pure-Rust sims). The app path (`load_sim`) instead passes
    /// the digest of the firmware bin it also seeds into the coordinator, so the
    /// device announces a digest the coordinator considers up-to-date — otherwise
    /// the app gates the device as "incompatible firmware".
    pub const PLACEHOLDER_DIGEST: Sha256Digest = Sha256Digest([0x5a; 32]);

    /// The device announces `digest.get()` in its `Announce`. To be seen as
    /// compatible by the app, that must equal the coordinator's latest firmware
    /// digest.
    pub fn new(digest: FirmwareDigestCell, stop: Arc<AtomicBool>) -> Self {
        Self {
            digest,
            upgrade: None,
            stop,
            upgrades_offered: Arc::new(AtomicU32::new(0)),
        }
    }

    /// Counts coordinator upgrade offers seen (`PrepareUpgrade*`), so tests can
    /// assert an up-to-date device is never offered one.
    pub fn upgrades_offered(&self) -> Arc<AtomicU32> {
        self.upgrades_offered.clone()
    }

    /// Drain the takeover byte stream: read exactly `size` bytes upstream with
    /// the real chunk-ready flow control, forwarding to a downstream child so a
    /// chain upgrades in the same pass — then throw the bytes away. Shape
    /// mirrors `FirmwareUpgradeMode::enter_upgrade_mode` (minus flash, baud,
    /// and verification); `writing` is false on the passive path, matching the
    /// real pump's forward-only behavior there.
    ///
    /// Returns false if the slot powered off mid-transfer.
    fn drain_image(
        &self,
        size: u32,
        writing: bool,
        upstream_io: &mut dyn ByteIo,
        mut downstream_io: Option<&mut dyn ByteIo>,
        ui: &mut dyn UserInteraction,
    ) -> bool {
        let mut i: u32 = 0;
        let mut byte_count: u32 = 0;

        let mut finished = false;
        let mut downstream_ready = downstream_io.is_none();
        let mut told_upstream_im_ready = false;

        while !finished {
            if self.stop.load(Ordering::Relaxed) {
                return false;
            }
            if downstream_ready {
                if let Some(byte) = upstream_io.read_byte() {
                    i += 1;
                    byte_count += 1;
                    finished = byte_count == size;
                    if let Some(downstream_io) = &mut downstream_io {
                        downstream_io.write_bytes(&[byte]).unwrap();
                    }

                    if i == SECTOR_SIZE || finished {
                        downstream_ready = downstream_io.is_none();
                        told_upstream_im_ready = false;
                        i = 0;
                        if writing {
                            ui.set_workflow(ui::Workflow::FirmwareUpgrade(
                                ui::FirmwareUpgradeStatus::Download {
                                    progress: byte_count as f32 / size as f32,
                                },
                            ));
                            ui.poll();
                            std::thread::sleep(SECTOR_PACING);
                        }
                    }
                }
            }

            if !finished {
                if let Some(downstream_io) = &mut downstream_io {
                    while let Some(byte) = downstream_io.read_byte() {
                        assert!(
                            byte == FIRMWARE_NEXT_CHUNK_READY_SIGNAL,
                            "invalid control byte sent by downstream"
                        );
                        downstream_ready = true;
                    }
                }

                if downstream_ready && !told_upstream_im_ready {
                    upstream_io
                        .write_bytes(&[FIRMWARE_NEXT_CHUNK_READY_SIGNAL])
                        .unwrap();
                    upstream_io.nb_flush();
                    told_upstream_im_ready = true;
                }
            }
        }

        ui.poll();
        if let Some(downstream_io) = &mut downstream_io {
            downstream_io.flush();
        }
        true
    }
}

impl FirmwareServices for SimFirmware {
    fn firmware_digest(&self) -> Sha256Digest {
        self.digest.get()
    }

    fn handle<U, D>(
        &mut self,
        msg: &CoordinatorSendBody,
        upstream: &mut U,
        downstream: Option<&mut D>,
        ui: &mut dyn UserInteraction,
    ) -> FirmwareAction
    where
        U: SerialPort<Upstream>,
        D: SerialPort<Downstream>,
    {
        match msg {
            CoordinatorSendBody::Upgrade(
                CoordinatorUpgradeMessage::PrepareUpgrade {
                    size,
                    firmware_digest,
                }
                | CoordinatorUpgradeMessage::PrepareUpgrade2 {
                    size,
                    firmware_digest,
                },
            ) => {
                self.upgrades_offered.fetch_add(1, Ordering::Relaxed);
                self.upgrade = Some(if *firmware_digest == self.digest.get() {
                    Staged::Passive {
                        size: *size,
                        sent_ack: false,
                    }
                } else {
                    Staged::Upgrading {
                        size: *size,
                        digest: *firmware_digest,
                        state: State::WaitingForConfirm { sent_prompt: false },
                    }
                });
                FirmwareAction::None
            }
            CoordinatorSendBody::Upgrade(CoordinatorUpgradeMessage::EnterUpgradeMode) => {
                let staged = self
                    .upgrade
                    .take()
                    .expect("upgrade cannot start because we were not warned about it");
                let (size, writing, new_digest) = match staged {
                    Staged::Upgrading {
                        size,
                        digest,
                        state,
                    } => {
                        assert!(
                            matches!(state, State::WaitingToEnterUpgradeMode),
                            "can't start upgrade while still preparing"
                        );
                        (size, true, Some(digest))
                    }
                    Staged::Passive { size, .. } => (size, false, None),
                };
                let downstream_raw = downstream.map(|d| d.raw());
                let completed = self.drain_image(size, writing, upstream.raw(), downstream_raw, ui);
                if completed {
                    if let Some(new_digest) = new_digest {
                        self.digest.set(new_digest);
                    }
                }
                FirmwareAction::ResetRequested
            }
            // Genuine-check is off for dev devices: no certificate, so nothing to
            // sign. The coordinator gates the challenge on its own flag.
            CoordinatorSendBody::Challenge(_) => FirmwareAction::None,
            _ => FirmwareAction::None,
        }
    }

    fn poll(&mut self, ui: &mut dyn UserInteraction) -> FirmwareAction {
        match &mut self.upgrade {
            Some(Staged::Upgrading {
                size,
                digest,
                state,
            }) => match state {
                State::WaitingForConfirm { sent_prompt } if !*sent_prompt => {
                    *sent_prompt = true;
                    ui.set_workflow(ui::Workflow::prompt(ui::Prompt::ConfirmFirmwareUpgrade {
                        firmware_digest: *digest,
                        size: *size,
                    }));
                    FirmwareAction::None
                }
                State::Erase { seq } => {
                    // No flash to erase; the image's own sector count paces the
                    // real Erase progress widget proportionally to the transfer.
                    let last = size.div_ceil(SECTOR_SIZE).max(1);
                    *seq += 1;
                    ui.set_workflow(ui::Workflow::FirmwareUpgrade(
                        ui::FirmwareUpgradeStatus::Erase {
                            progress: *seq as f32 / last as f32,
                        },
                    ));
                    if *seq >= last {
                        *state = State::WaitingToEnterUpgradeMode;
                        FirmwareAction::Send(Box::new(DeviceSendBody::Misc(
                            CommsMisc::AckUpgradeMode,
                        )))
                    } else {
                        FirmwareAction::None
                    }
                }
                _ => FirmwareAction::None,
            },
            Some(Staged::Passive { sent_ack, .. }) => {
                if !*sent_ack {
                    *sent_ack = true;
                    ui.set_workflow(ui::Workflow::FirmwareUpgrade(
                        ui::FirmwareUpgradeStatus::Passive,
                    ));
                    FirmwareAction::Send(Box::new(DeviceSendBody::Misc(CommsMisc::AckUpgradeMode)))
                } else {
                    FirmwareAction::None
                }
            }
            None => FirmwareAction::None,
        }
    }

    fn confirm_upgrade(&mut self) {
        if let Some(Staged::Upgrading {
            state: state @ State::WaitingForConfirm { sent_prompt: true },
            ..
        }) = &mut self.upgrade
        {
            *state = State::Erase { seq: 0 };
        }
    }

    fn cancel(&mut self) {
        self.upgrade = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::input::DeviceInput;
    use crate::serial::pipe;
    use crate::thread::{spawn_device_thread, DeviceHandles};
    use crate::{RamFlash, VirtualSerial};
    use frostsnap_comms::CoordinatorSendMessage;
    use frostsnap_coordinator::{
        AppMessageBody, DeviceChange, FirmwareBin, UsbSerialManager, ValidatedFirmwareBin,
    };
    use std::time::{Duration, Instant as WallInstant};

    /// Three chunks, so the chunk-ready flow control actually cycles.
    const TEST_IMAGE_LEN: usize = 3 * 4096;

    /// Structurally-valid unsigned ESP image spanning [`TEST_IMAGE_LEN`]
    /// (magic + one segment filling the rest), same construction as the app's
    /// `SIM_FIRMWARE_IMAGE`.
    static TEST_IMAGE: [u8; TEST_IMAGE_LEN] = {
        let mut img = [0u8; TEST_IMAGE_LEN];
        img[0] = 0xE9; // ESP_MAGIC
        img[1] = 1; // segment_count
                    // firmware_size = 32 (headers) + segment + 16 (checksum tail).
        let seg_len = (TEST_IMAGE_LEN - 32 - 16) as u32;
        img[28] = seg_len as u8;
        img[29] = (seg_len >> 8) as u8;
        img[30] = (seg_len >> 16) as u8;
        img[31] = (seg_len >> 24) as u8;
        img
    };

    fn test_bin() -> ValidatedFirmwareBin {
        FirmwareBin::new(&TEST_IMAGE)
            .validate()
            .expect("test image is a valid unsigned ESP image")
    }

    /// One stale device on its own thread plus a coordinator bundling
    /// [`TEST_IMAGE`], registered and named — with the shared handles a test
    /// needs to power-cycle, unplug, or re-digest it.
    struct Rig {
        device_id: frostsnap_core::DeviceId,
        thread: crate::thread::DeviceThread,
        handles: DeviceHandles,
        manager: UsbSerialManager,
        connection: crate::PortConnection,
        digest: FirmwareDigestCell,
        /// Frames delivered to the device's sink — the tray's feed. Counted so a
        /// test can prove the screen keeps STREAMING while the blocking transfer
        /// drain owns the device loop.
        frames: std::sync::Arc<std::sync::atomic::AtomicUsize>,
    }

    /// Spawn a stale device (placeholder digest) on its own thread and a
    /// coordinator that bundles [`TEST_IMAGE`], registered and named.
    fn stale_device_and_coordinator(seed: u64) -> Rig {
        let (upstream_io, host) = pipe();
        let frames = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let handles = DeviceHandles {
            upstream_io,
            downstream_io: crate::serial::PipeByteIo::disconnected(),
            framebuffer: crate::SharedFramebuffer::new(),
            touch: crate::TouchQueue::new(),
            observation: crate::SimObservation::new(),
            downstream_present: None,
            on_frame: {
                let frames = frames.clone();
                std::sync::Arc::new(move |_, _, _| {
                    frames.fetch_add(1, Ordering::SeqCst);
                })
            },
        };
        let digest = FirmwareDigestCell::new(SimFirmware::PLACEHOLDER_DIGEST);
        let identity = crate::identity::DeviceIdentityCell::new();
        let thread = spawn_device_thread(
            seed,
            digest.clone(),
            identity.clone(),
            handles.clone(),
            RamFlash::new(),
        );
        let device_id = identity.get().expect("booted");

        let serial = VirtualSerial::single("sim-0", host);
        let connection = serial.connection();
        let mut manager = UsbSerialManager::new(Box::new(serial)).with_firmware_bin(test_bin());
        let deadline = WallInstant::now() + Duration::from_secs(30);
        let mut registered = false;
        while WallInstant::now() < deadline && !registered {
            for change in manager.poll_ports() {
                match change {
                    DeviceChange::NeedsName { id } => {
                        manager.accept_device_name(id, "Sim".to_string())
                    }
                    DeviceChange::Registered { .. } => registered = true,
                    _ => {}
                }
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(registered, "device should register");
        assert_eq!(
            manager.firmware_digest_for_device(device_id),
            Some(SimFirmware::PLACEHOLDER_DIGEST),
            "initial registration announces the stale digest"
        );
        Rig {
            device_id,
            thread,
            handles,
            manager,
            connection,
            digest,
            frames,
        }
    }

    /// Wait for the device to (re-)register and pin the digest it ANNOUNCED —
    /// the coordinator-visible contract the app consumes, so a regression
    /// that reboots with a stale digest while handing over the new one
    /// internally cannot pass.
    fn await_registration_announcing(
        manager: &mut UsbSerialManager,
        device_id: frostsnap_core::DeviceId,
        expected_digest: Sha256Digest,
        what: &str,
    ) {
        let deadline = WallInstant::now() + Duration::from_secs(30);
        let mut registered = false;
        while WallInstant::now() < deadline && !registered {
            for change in manager.poll_ports() {
                if let DeviceChange::Registered { .. } = change {
                    registered = true;
                }
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(registered, "{what}: device should register");
        assert_eq!(
            manager.firmware_digest_for_device(device_id),
            Some(expected_digest),
            "{what}: announced digest"
        );
    }

    /// Offer the upgrade, hold-confirm it on the device's real prompt, and
    /// wait for its `AckUpgradeMode`.
    fn offer_and_confirm(
        manager: &mut UsbSerialManager,
        device_id: frostsnap_core::DeviceId,
        touch: &crate::TouchQueue,
    ) {
        manager.usb_sender().send(CoordinatorSendMessage::to(
            device_id,
            CoordinatorSendBody::Upgrade(CoordinatorUpgradeMessage::PrepareUpgrade2 {
                size: TEST_IMAGE_LEN as u32,
                firmware_digest: test_bin().digest(),
            }),
        ));

        let input = DeviceInput::new(touch.clone());
        let deadline = WallInstant::now() + Duration::from_secs(60);
        let mut acked = false;
        while WallInstant::now() < deadline && !acked {
            input.hold(120, 215, Duration::from_millis(3200));
            for change in manager.poll_ports() {
                if let DeviceChange::AppMessage(msg) = change {
                    if matches!(msg.body, AppMessageBody::Misc(CommsMisc::AckUpgradeMode)) {
                        acked = true;
                    }
                }
            }
        }
        assert!(acked, "device should confirm and ack upgrade mode");
    }

    // The complete lifecycle: offer → on-device consent → erase ack → the real
    // coordinator streams the real bytes with the real flow control → the
    // device resets, REBOOTS IN ITS THREAD, and the completed transfer has
    // written the new digest to the shared cell.
    #[test]
    fn upgrade_completes_reboots_and_writes_the_new_digest() {
        let mut rig = stale_device_and_coordinator(77);
        offer_and_confirm(&mut rig.manager, rig.device_id, &rig.handles.touch);

        // The drain owns the device loop for the whole transfer, so mid-transfer
        // frames exist only because export rides the UI's own per-sector poll — a
        // frozen tray regresses this window to exactly 0. The bound is derived
        // from the fixture and the flow control's own ordering: the device sends
        // an INITIAL chunk-ready before sector 1, so the coordinator's item k is
        // satisfied by sector k-1's ready — which the device writes only AFTER
        // sector k-1's poll (and export). Consuming the whole iterator therefore
        // guarantees sectors-1 exports, and the window is still strictly inside
        // the transfer: when the last item returns, the final sector is still
        // draining, so no reboot frame can inflate the count.
        let sectors = TEST_IMAGE_LEN.div_ceil(SECTOR_SIZE as usize);
        let frames_before = rig.frames.load(Ordering::SeqCst);
        for progress in rig.manager.run_firmware_upgrade().unwrap() {
            progress.unwrap();
        }
        let mid_transfer_frames = rig.frames.load(Ordering::SeqCst) - frames_before;
        assert!(
            mid_transfer_frames >= sectors - 1,
            "the device screen must keep streaming during the transfer \
             (saw {mid_transfer_frames} frames, expected at least {})",
            sectors - 1,
        );

        // The reboot re-announces over the same pipe; the announce must carry
        // the NEW digest — the coordinator-visible fact the app consumes.
        await_registration_announcing(
            &mut rig.manager,
            rig.device_id,
            test_bin().digest(),
            "post-upgrade reboot",
        );

        assert_eq!(
            rig.digest.get(),
            test_bin().digest(),
            "the completed transfer must write the cell"
        );
    }

    // Interruption: power the device off mid-transfer. The sim-owned drain
    // loop observes the stop flag, so power_off returns promptly (no
    // deadlock), the staged upgrade dies with the thread's RAM (the cell is
    // only written on COMPLETION, so the old digest survives), and the retry
    // — a fresh boot from the SAME flash and cell — completes.
    #[test]
    fn power_off_mid_transfer_keeps_the_old_digest_and_retry_succeeds() {
        let mut rig = stale_device_and_coordinator(78);
        offer_and_confirm(&mut rig.manager, rig.device_id, &rig.handles.touch);

        let mut progress = rig.manager.run_firmware_upgrade().unwrap();
        progress.next().unwrap().unwrap();
        drop(progress);

        let off_started = WallInstant::now();
        let flash = rig.thread.power_off();
        assert!(
            off_started.elapsed() < Duration::from_secs(5),
            "power_off must not deadlock behind the blocked transfer"
        );
        assert_eq!(
            rig.digest.get(),
            SimFirmware::PLACEHOLDER_DIGEST,
            "an interrupted upgrade must leave the old digest"
        );

        let identity = crate::identity::DeviceIdentityCell::new();
        let thread = spawn_device_thread(
            78,
            rig.digest.clone(),
            identity.clone(),
            rig.handles.clone(),
            flash,
        );
        let device_id = identity.get().expect("booted");
        // The reboot after interruption must ANNOUNCE the old digest.
        await_registration_announcing(
            &mut rig.manager,
            device_id,
            SimFirmware::PLACEHOLDER_DIGEST,
            "post-interruption reboot",
        );

        offer_and_confirm(&mut rig.manager, device_id, &rig.handles.touch);
        for progress in rig.manager.run_firmware_upgrade().unwrap() {
            progress.unwrap();
        }
        await_registration_announcing(
            &mut rig.manager,
            device_id,
            test_bin().digest(),
            "post-retry reboot",
        );

        drop(thread);
        assert_eq!(
            rig.digest.get(),
            test_bin().digest(),
            "the retried upgrade must complete"
        );
    }

    // Port death mid-transfer: the coordinator's raw loop holds no poll loop, so
    // an open port erroring its I/O (BrokenPipe once the connection goes down) is
    // the loop's ONLY exit — the seam the app-level mid-transfer interruption
    // rides. Pin that the error arrives promptly instead of the loop wedging on a
    // silent line, and that the interrupted device keeps its old digest.
    #[test]
    fn port_death_mid_transfer_errors_the_raw_loop_instead_of_wedging() {
        let mut rig = stale_device_and_coordinator(79);
        offer_and_confirm(&mut rig.manager, rig.device_id, &rig.handles.touch);

        let mut progress = rig.manager.run_firmware_upgrade().unwrap();
        progress.next().unwrap().unwrap();

        rig.connection.set_connected(false);
        let died_at = WallInstant::now();
        assert!(
            progress.any(|p| p.is_err()),
            "the raw loop must surface the dead port as an error, not stream to completion"
        );
        assert!(
            died_at.elapsed() < Duration::from_secs(10),
            "the error must arrive promptly, not wedge"
        );
        drop(progress);

        rig.thread.power_off();
        assert_eq!(
            rig.digest.get(),
            SimFirmware::PLACEHOLDER_DIGEST,
            "an interrupted transfer must leave the old digest"
        );
    }

    /// Poll until the manager observes the port's device(s) disconnect.
    fn await_disconnected(manager: &mut UsbSerialManager, what: &str) {
        let deadline = WallInstant::now() + Duration::from_secs(30);
        let mut disconnected = false;
        while WallInstant::now() < deadline && !disconnected {
            for change in manager.poll_ports() {
                if let DeviceChange::Disconnected { .. } = change {
                    disconnected = true;
                }
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(disconnected, "{what}: device should disconnect");
    }

    // The digest is a settable property whose value the NEXT ANNOUNCE reports:
    // set it while the device is RUNNING (the harder half — no reboot is
    // involved; the replug's re-handshake re-reads it live), and set it again
    // to restore up-to-date — both directions, same running thread.
    #[test]
    fn set_digest_takes_effect_on_the_next_announce() {
        let mut rig = stale_device_and_coordinator(80);

        let junk = Sha256Digest([0x42; 32]);
        rig.digest.set(junk);
        assert_eq!(
            rig.manager.firmware_digest_for_device(rig.device_id),
            Some(SimFirmware::PLACEHOLDER_DIGEST),
            "no announce yet — the coordinator must still hold the old digest"
        );

        rig.connection.set_connected(false);
        await_disconnected(&mut rig.manager, "unplug after set");
        rig.connection.set_connected(true);
        await_registration_announcing(&mut rig.manager, rig.device_id, junk, "replug after set");

        rig.digest.set(test_bin().digest());
        rig.connection.set_connected(false);
        await_disconnected(&mut rig.manager, "unplug after restore");
        rig.connection.set_connected(true);
        await_registration_announcing(
            &mut rig.manager,
            rig.device_id,
            test_bin().digest(),
            "replug after restore",
        );
    }
}
