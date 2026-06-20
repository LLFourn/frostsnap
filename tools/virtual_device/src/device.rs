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

use crate::clock::SimClock;
use crate::display::{FramebufferDisplay, SharedFramebuffer};
use crate::firmware::SimFirmware;
use crate::flash::{RamFlash, SECTORS};
use crate::hal::SimHal;
use crate::secrets::SimKeyedHash;
use crate::serial::{pipe, HostEnd, PipeByteIo};
use crate::touch::TouchQueue;
use core::cell::RefCell;
use frostsnap_embedded::{
    device_hal::{InitOutcome, Poll},
    device_loop::DeviceLoop,
    framed_serial::FramedSerial,
    frosty_ui::FrostyUi,
    FlashPartition, ShareEncryptionSecrets,
};
use rand_chacha::ChaCha20Rng;
use rand_core::SeedableRng;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;

/// The device's `UserInteraction` — the real `FrostyUi` over the sim peripherals.
pub type SimUi = FrostyUi<FramebufferDisplay, SimClock, TouchQueue>;

pub struct VirtualDevice {
    flash: RefCell<RamFlash>,
    hal: SimHal,
    ui: SimUi,
    clock: SimClock,
    framebuffer: SharedFramebuffer,
    touch: TouchQueue,
    host: HostEnd,
    upgrades_offered: Arc<AtomicU32>,
}

impl VirtualDevice {
    /// Build a device. `seed` fixes both the RNG and the dev keys, so a given seed
    /// is a reproducible device. The upstream link is a connected pipe (its
    /// coordinator end is [`VirtualDevice::host_serial`], driven in sim-2); the
    /// downstream link has no peer (single-device star topology).
    pub fn new(seed: u64) -> Self {
        let clock = SimClock::new();
        let framebuffer = SharedFramebuffer::new();
        let touch = TouchQueue::new();

        let (upstream_io, host) = pipe();
        let downstream_io = PipeByteIo::disconnected();

        let firmware = SimFirmware::new();
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

        let ui = FrostyUi::new(
            FramebufferDisplay::new(framebuffer.clone()),
            clock,
            touch.clone(),
        );

        Self {
            flash: RefCell::new(RamFlash::new()),
            hal,
            ui,
            clock,
            framebuffer,
            touch,
            host,
            upgrades_offered,
        }
    }

    /// How many firmware-upgrade messages the coordinator has offered this device —
    /// should always be 0 (the sim never advertises an upgradeable digest).
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

    /// The coordinator-side byte endpoint of the upstream link, as an owned
    /// cloneable handle (wired to a `VirtualPort` in sim-2). Capture it *before*
    /// starting a session — like [`framebuffer`](Self::framebuffer) and
    /// [`touch`](Self::touch), the clone shares the same `Arc`-backed wire and stays
    /// usable while the borrowed session runs.
    pub fn host_serial(&self) -> HostEnd {
        self.host.clone()
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
    loop_: Box<DeviceLoop<'a, SimHal, SimUi>>,
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
}
