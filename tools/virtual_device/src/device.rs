//! `VirtualDevice` — owns the device's parts; `VirtualDeviceSession` — a
//! caller-owned value that borrows them and holds **one** `DeviceLoop` alive for
//! its whole lifetime.
//!
//! `DeviceLoop` stores borrows (`HalParts`, `&mut UI`, `&dyn Clock`, a
//! `FlashPartition` over an external `RefCell`), so it can't be a field of the same
//! struct that owns those inputs. Instead `session()` builds it from disjoint field
//! borrows of `&mut self` and hands back a `VirtualDeviceSession` that keeps it
//! across `poll_once` calls — runtime state (connection state, outbox, nonce
//! batches, magic-byte counters, …) survives, unlike a per-tick rebuild. The
//! `Arc`-backed frame/touch/serial handles are cloned out at construction so a
//! reader can export frames / inject touch while a session runs.

use crate::backup_typist::EntryView;
use crate::clock::SimClock;
use crate::display::{FramebufferDisplay, SharedFramebuffer};
use crate::firmware::{FirmwareDigestCell, SimFirmware};
use crate::flash::{RamFlash, SECTORS};
use crate::hal::SimHal;
use crate::observation::{EntryOutcome, EntryProgress, SimObservation};
use crate::secrets::SimKeyedHash;
use crate::serial::{pipe, HostEnd, PipeByteIo};
use crate::thread::FrameSink;
use crate::touch::TouchQueue;
use core::cell::RefCell;
use frostsnap_comms::Sha256Digest;
use frostsnap_embedded::{
    device_hal::{InitOutcome, Poll},
    device_loop::DeviceLoop,
    framed_serial::FramedSerial,
    frosty_ui::FrostyUi,
    ui::{BusyTask, UiEvent, UserInteraction, Workflow},
    DownstreamConnectionState, FlashPartition, ShareEncryptionSecrets, UpstreamConnectionState,
};
use rand_chacha::ChaCha20Rng;
use rand_core::SeedableRng;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;

/// The real `FrostyUi` over the sim peripherals.
pub type SimUi = FrostyUi<FramebufferDisplay, SimClock, TouchQueue>;

/// The device's `UserInteraction`: [`SimUi`] plus the publish side of
/// [`SimObservation`]. Every call delegates; the calls that CHANGE the active
/// screen (`set_workflow`, `go_to_default`) also replace the observation in
/// the same step, and `poll` refreshes backup-entry progress from the widget
/// tree (read-only, same thread). `set_default_workflow` only stores a future
/// return destination — it does not change what's displayed, so it publishes
/// nothing.
///
/// `poll` also EXPORTS the frame when rendering dirtied it — here, not in the
/// device thread's loop, because the firmware-upgrade drain blocks that loop
/// for the whole transfer while still polling the UI per sector: export must
/// ride the poll or the tray freezes exactly when the screen is animating.
pub struct ObservedUi {
    inner: SimUi,
    observation: SimObservation,
    framebuffer: SharedFramebuffer,
    on_frame: FrameSink,
}

impl ObservedUi {
    fn sample_entry_progress(&self) -> Option<EntryProgress> {
        let (view_state, finished, invalid) = self.inner.backup_entry_state()?;
        Some(EntryProgress {
            view: EntryView::from_view_state(&view_state),
            finished,
            invalid,
            settled: self.inner.backup_entry_settled()?,
            keyboard_rect: self.inner.backup_entry_keyboard_rect()?,
            generation: self.observation.entry_generation(),
        })
    }
}

impl UserInteraction for ObservedUi {
    fn set_downstream_connection_state(&mut self, state: DownstreamConnectionState) {
        self.inner.set_downstream_connection_state(state)
    }

    fn set_upstream_connection_state(&mut self, state: UpstreamConnectionState) {
        self.inner.set_upstream_connection_state(state)
    }

    fn set_workflow(&mut self, workflow: Workflow) {
        let displayed = match &workflow {
            Workflow::DisplayBackup { backup, .. } => Some(backup.to_string()),
            _ => None,
        };
        let new_entry_run = matches!(workflow, Workflow::EnteringBackup(_));
        let ObservedUi {
            inner, observation, ..
        } = self;
        observation
            .replace_active_screen(displayed, new_entry_run, || inner.set_workflow(workflow));
    }

    fn set_default_workflow(&mut self, workflow: Workflow) {
        self.inner.set_default_workflow(workflow)
    }

    fn go_to_default(&mut self) {
        // The default workflow becomes the active screen; the sim only ever
        // observes screens it instruments (backup display/entry), and those
        // never sit in the default slot — so the new observation is empty.
        let ObservedUi {
            inner, observation, ..
        } = self;
        observation.replace_active_screen(None, false, || inner.go_to_default());
    }

    fn set_busy_task(&mut self, task: BusyTask) {
        self.inner.set_busy_task(task)
    }

    fn clear_busy_task(&mut self) {
        self.inner.clear_busy_task()
    }

    fn poll(&mut self) -> Option<UiEvent> {
        let event = self.inner.poll();
        // Completion is the EVENT, not screen state: record it before the
        // loop processes it and tears the screen down.
        if matches!(event, Some(UiEvent::EnteredShareBackup { .. })) {
            self.observation
                .record_entry_outcome(EntryOutcome::Accepted);
        }
        if matches!(event, Some(UiEvent::BackupRecorded)) {
            self.observation.record_display_confirmed();
        }
        let progress = self.sample_entry_progress();
        if progress.as_ref().is_some_and(|p| p.invalid) {
            self.observation.record_entry_outcome(EntryOutcome::Invalid);
        }
        self.observation.set_entry_progress(progress);
        if self.framebuffer.take_dirty() {
            let (w, h, rgba) = self.framebuffer.export_rgba();
            (self.on_frame)(w, h, rgba);
        }
        event
    }

    fn force_redraw(&mut self) {
        self.inner.force_redraw()
    }
}

/// The power-cycle-stable, `Arc`-backed surfaces a device presents to the sim:
/// its screen, touch queue, and screen observation. A power slot owns one set
/// and hands the SAME set to every boot, so long-lived handles keep working
/// across reboots.
pub struct DeviceSurfaces {
    pub framebuffer: SharedFramebuffer,
    pub touch: TouchQueue,
    pub observation: SimObservation,
    /// Where rendered frames go (see [`ObservedUi::poll`]); a no-op for
    /// devices nobody watches live (tests read the framebuffer directly).
    pub on_frame: FrameSink,
}

impl DeviceSurfaces {
    pub fn new() -> Self {
        Self {
            framebuffer: SharedFramebuffer::new(),
            touch: TouchQueue::new(),
            observation: SimObservation::new(),
            on_frame: Arc::new(|_, _, _| {}),
        }
    }
}

impl Default for DeviceSurfaces {
    fn default() -> Self {
        Self::new()
    }
}

pub struct VirtualDevice {
    flash: RefCell<RamFlash>,
    hal: SimHal,
    ui: ObservedUi,
    clock: SimClock,
    framebuffer: SharedFramebuffer,
    touch: TouchQueue,
    // Only set when the device owns its upstream pipe ([`with_firmware_digest`]); a
    // chained device built with [`from_io`] is wired to a peer's link, so it has no
    // host of its own (the caller holds the coordinator end).
    host: Option<HostEnd>,
    upgrades_offered: Arc<AtomicU32>,
}

impl VirtualDevice {
    /// Build a device. `seed` fixes both the RNG and the dev keys, so a given seed
    /// is a reproducible device. The upstream link is a connected pipe (its
    /// coordinator end is [`VirtualDevice::host_serial`], driven in sim-2); the
    /// downstream link has no peer.
    pub fn new(seed: u64) -> Self {
        Self::with_firmware_digest(seed, SimFirmware::PLACEHOLDER_DIGEST)
    }

    /// Like [`VirtualDevice::new`], but the device announces `firmware_digest`. The
    /// app path passes the digest of the firmware bin it also seeds into the
    /// coordinator so the device is seen as having up-to-date (compatible) firmware.
    /// Owns its upstream pipe (`host_serial` hands out the coordinator end) and has a
    /// peerless downstream.
    pub fn with_firmware_digest(seed: u64, firmware_digest: Sha256Digest) -> Self {
        let (upstream_io, host) = pipe();
        let downstream_io = PipeByteIo::disconnected();
        let mut device = Self::from_io(seed, firmware_digest, upstream_io, downstream_io);
        device.host = Some(host);
        device
    }

    /// Build a device wired to externally-supplied upstream and downstream byte links,
    /// with its own fresh peripherals and empty flash — the chained construction
    /// (sim-10): the caller owns the link ends, so neighbours can be connected
    /// device-to-device. Has no `host` of its own.
    pub fn from_io(
        seed: u64,
        firmware_digest: Sha256Digest,
        upstream_io: PipeByteIo,
        downstream_io: PipeByteIo,
    ) -> Self {
        Self::from_saved(
            seed,
            FirmwareDigestCell::new(firmware_digest),
            upstream_io,
            downstream_io,
            DeviceSurfaces::new(),
            RamFlash::new(),
            Arc::new(AtomicBool::new(false)),
        )
    }

    /// Build a device wired to externally-owned peripherals and flash — the power-slot
    /// construction (sim-13). The `framebuffer`, `touch`, and `flash` outlive any single
    /// power-cycle: the slot owns them and hands the same handles to each freshly-spawned
    /// device thread, so a re-boot resumes on the same screen/touch surface and the same
    /// NVS (only the volatile loop/UI/RAM is rebuilt). [`Self::into_flash`] hands the
    /// (mutated) flash back to the slot when the thread stops. Has no `host` of its own.
    /// `stop` is the owning thread's stop flag: the upgrade drain pump blocks
    /// the loop (real takeover semantics) but exits on it, so power-off can't
    /// deadlock behind a mid-transfer device.
    pub fn from_saved(
        seed: u64,
        firmware_digest: FirmwareDigestCell,
        upstream_io: PipeByteIo,
        downstream_io: PipeByteIo,
        surfaces: DeviceSurfaces,
        flash: RamFlash,
        stop: Arc<AtomicBool>,
    ) -> Self {
        let DeviceSurfaces {
            framebuffer,
            touch,
            observation,
            on_frame,
        } = surfaces;
        let clock = SimClock::new();

        let firmware = SimFirmware::new(firmware_digest, stop);
        let upgrades_offered = firmware.upgrades_offered();
        let hal = SimHal {
            upstream: FramedSerial::new(upstream_io, clock),
            downstream: FramedSerial::new(downstream_io, clock),
            rng: ChaCha20Rng::seed_from_u64(seed),
            share_encryption: ShareEncryptionSecrets(SimKeyedHash::from_seed(
                seed,
                "share-encryption-key",
            )),
            fixed_entropy: SimKeyedHash::from_seed(seed, "fixed-entropy-key"),
            firmware,
        };

        let ui = ObservedUi {
            inner: FrostyUi::new(
                FramebufferDisplay::new(framebuffer.clone()),
                clock,
                touch.clone(),
            ),
            observation,
            framebuffer: framebuffer.clone(),
            on_frame,
        };

        Self {
            flash: RefCell::new(flash),
            hal,
            ui,
            clock,
            framebuffer,
            touch,
            host: None,
            upgrades_offered,
        }
    }

    /// Recover the device's flash (NVS) after its session has ended — the power-off path
    /// (sim-13). Consumes the device (its volatile loop/UI/HAL are dropped) and returns
    /// the flash store so the slot can preserve it and feed it to the next power-on.
    pub fn into_flash(self) -> RamFlash {
        self.flash.into_inner()
    }

    /// How many firmware-upgrade offers (`PrepareUpgrade*`) the coordinator has
    /// made to this device — pinned 0 for a device announcing an up-to-date digest.
    pub fn upgrades_offered(&self) -> u32 {
        self.upgrades_offered.load(Ordering::Relaxed)
    }

    /// A handle to the device screen, for frame export / PNG dumps.
    pub fn framebuffer(&self) -> SharedFramebuffer {
        self.framebuffer.clone()
    }

    /// A handle to inject touch events into the running device.
    pub fn touch(&self) -> TouchQueue {
        self.touch.clone()
    }

    /// The read side of this device's screen observation.
    pub fn observation(&self) -> SimObservation {
        self.ui.observation.clone()
    }

    /// The coordinator-side byte endpoint of the upstream link, as an owned
    /// cloneable handle (wired to a `VirtualPort` in sim-2). Capture it *before*
    /// starting a session — like [`framebuffer`](Self::framebuffer) and
    /// [`touch`](Self::touch), the clone shares the same `Arc`-backed wire and stays
    /// usable while the borrowed session runs.
    pub fn host_serial(&self) -> HostEnd {
        self.host
            .clone()
            .expect("host_serial is only valid on a device that owns its upstream pipe")
    }

    /// Start a session: construct the one persistent `DeviceLoop` over the owned
    /// parts. `ResetRequested` means the init-time recovery erase ran.
    pub fn session(&mut self) -> InitOutcome<VirtualDeviceSession<'_>> {
        let nvs = FlashPartition::new(&self.flash, 0, SECTORS as u32, "nvs");
        match DeviceLoop::new(&mut self.hal, &mut self.ui, &self.clock, nvs) {
            InitOutcome::Ready(loop_) => InitOutcome::Ready(VirtualDeviceSession { loop_ }),
            InitOutcome::ResetRequested => InitOutcome::ResetRequested,
        }
    }
}

/// A live device session: one borrowed `DeviceLoop`, advanced by `poll_once`.
pub struct VirtualDeviceSession<'a> {
    loop_: Box<DeviceLoop<'a, SimHal, ObservedUi>>,
}

impl VirtualDeviceSession<'_> {
    /// Advance the same loop one tick. `downstream_present` mirrors the esp
    /// downstream-detect pin (false for a single device with no child).
    pub fn poll_once(&mut self, downstream_present: bool) -> Poll {
        self.loop_.poll(downstream_present)
    }

    /// Whether the device has persisted a finalized key for `key_id` — the
    /// device-side proof that a keygen's `FinishKeygen` was delivered and processed.
    pub fn holds_key(&self, key_id: frostsnap_core::KeyId) -> bool {
        self.loop_.holds_key(key_id)
    }

    /// This device's id, used to reconcile it with the coordinator-side
    /// `DeviceChange`s (the two surfaces never talk directly; they share an id).
    pub fn device_id(&self) -> frostsnap_core::DeviceId {
        self.loop_.device_id()
    }
}
