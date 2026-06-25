//! The per-device thread runtime.
//!
//! `FrostyUi` is `!Send` (it holds `Rc`s), so a [`VirtualDevice`] cannot be moved into a
//! spawned thread. Instead a device is *built inside the thread* from a seed plus the
//! `Send` [`DeviceHandles`] it should run on, and only those `Arc`-backed handles cross the
//! thread boundary. Nothing `!Send` ever escapes — the device thread and the rest of the
//! app communicate solely through those handles.
//!
//! sim-13: a device thread is the device's POWER. [`spawn_device_thread`] wires a fresh
//! loop to the slot's STABLE handles (screen, touch, link channels) and a preserved flash
//! (NVS), so a re-boot resumes on the same surfaces and the same persisted data; only the
//! volatile loop/UI/RAM is rebuilt. Stopping the thread ([`DeviceThread::power_off`]) hands
//! the (mutated) flash back so the next power-on boots from it — a real power-cycle: RAM
//! lost, NVS kept.
//!
//! The thread runs `loop { poll_once(); on dirty → on_frame(rgba); short park }`.
//! `poll_once` is non-blocking and the park is short, so the loop checks the stop flag
//! every iteration; [`DeviceThread::power_off`] (and `Drop`) set the flag and join
//! promptly (no detached thread, no busy spin).

use crate::device::VirtualDevice;
use crate::display::SharedFramebuffer;
use crate::flash::RamFlash;
use crate::serial::{pipe, HostEnd, LinkGate, PipeByteIo};
use crate::touch::TouchQueue;
use frostsnap_comms::Sha256Digest;
use frostsnap_core::DeviceId;
use frostsnap_embedded::device_hal::{InitOutcome, Poll};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::Duration;

/// How long the device thread parks between polls when idle. Short enough that the
/// stop flag is observed (and join returns) promptly, long enough not to busy-spin.
const POLL_PARK: Duration = Duration::from_millis(3);

/// Where a device thread's rendered frames go: called with `(width, height, rgba8888)`
/// whenever the framebuffer changes. `Arc<dyn Fn + Send + Sync>` (not a moved-in `FnMut`)
/// so the slot can re-use the SAME sink across every power-on without rebuilding it.
pub type FrameSink = Arc<dyn Fn(u32, u32, Vec<u8>) + Send + Sync + 'static>;

/// The power-cycle-stable handles a device thread runs on: its link channels, screen,
/// touch surface, downstream-detect, and frame sink. The slot owns these and clones a set
/// into each freshly-spawned thread, so a re-boot resumes on the same surfaces and the
/// long-lived `SimDevice` handles keep driving whatever thread is currently powered.
#[derive(Clone)]
pub struct DeviceHandles {
    pub upstream_io: PipeByteIo,
    pub downstream_io: PipeByteIo,
    pub framebuffer: SharedFramebuffer,
    pub touch: TouchQueue,
    /// The link-to-the-child gate, read each tick to drive the firmware's downstream-detect
    /// (`None` for the tail / a standalone device).
    pub downstream_present: Option<LinkGate>,
    pub on_frame: FrameSink,
}

/// A running device thread — the device's power. Dropping it stops and joins the thread,
/// discarding the recovered flash; [`DeviceThread::power_off`] stops it and HANDS the
/// flash back instead (the power-off path, so the next power-on can boot from it).
pub struct DeviceThread {
    stop: Arc<AtomicBool>,
    join: Option<JoinHandle<RamFlash>>,
}

impl DeviceThread {
    /// Power the device off: signal stop, join the thread, and return its preserved flash
    /// (NVS). The volatile loop/UI/RAM is gone; the flash carries the device's persisted
    /// state (keypair, any finalized shares) to the next power-on.
    pub fn power_off(mut self) -> RamFlash {
        self.stop.store(true, Ordering::Relaxed);
        self.join
            .take()
            .and_then(|join| join.join().ok())
            .unwrap_or_default()
    }
}

impl Drop for DeviceThread {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
    }
}

/// The `Send` handles a standalone spawned device hands back (test helper): its id plus
/// the `Arc`-backed peripheral handles, and the running thread (drop it to stop the
/// device). `host` is the coordinator end of the device's own upstream pipe.
pub struct SpawnedDevice {
    pub device_id: DeviceId,
    pub framebuffer: SharedFramebuffer,
    pub touch: TouchQueue,
    pub host: Option<HostEnd>,
    pub thread: DeviceThread,
}

/// Spawn a device thread (power it on): build a fresh loop in-thread wired to the given
/// STABLE `handles` and booting from `flash`, and run it until stopped. The thread returns
/// its (mutated) flash on exit so [`DeviceThread::power_off`] can preserve it. Blocks until
/// the device has booted and announced its id, which it returns.
pub(crate) fn spawn_device_thread(
    seed: u64,
    firmware_digest: Sha256Digest,
    handles: DeviceHandles,
    flash: RamFlash,
) -> (DeviceId, DeviceThread) {
    let DeviceHandles {
        upstream_io,
        downstream_io,
        framebuffer,
        touch,
        downstream_present,
        on_frame,
    } = handles;

    let stop = Arc::new(AtomicBool::new(false));
    let (tx, rx) = mpsc::channel::<DeviceId>();

    let thread_stop = stop.clone();
    let join = thread::spawn(move || -> RamFlash {
        // Built here so nothing `!Send` (FrostyUi/the session) ever escapes the thread.
        let mut device = VirtualDevice::from_saved(
            seed,
            firmware_digest,
            upstream_io,
            downstream_io,
            framebuffer.clone(),
            touch,
            flash,
        );

        {
            let mut session = match device.session() {
                InitOutcome::Ready(session) => session,
                // Recovery erase ran on boot: hand the (erased) flash back and stop.
                InitOutcome::ResetRequested => return device.into_flash(),
            };
            let device_id = session.device_id();

            // If the caller already dropped its end, there's nothing to drive.
            if tx.send(device_id).is_err() {
                drop(session);
                return device.into_flash();
            }
            drop(tx);

            loop {
                if thread_stop.load(Ordering::Relaxed) {
                    break;
                }
                // The downstream-detect pin reads the link gate: a connected child below
                // makes the firmware establish + relay downstream; unplugging it tears
                // that down. None = no child (tail of the chain / standalone).
                let present = downstream_present
                    .as_ref()
                    .is_some_and(LinkGate::is_connected);
                if matches!(session.poll_once(present), Poll::ResetRequested) {
                    break;
                }
                if framebuffer.take_dirty() {
                    let (w, h, rgba) = framebuffer.export_rgba();
                    on_frame(w, h, rgba);
                }
                thread::sleep(POLL_PARK);
            }
        }

        // Session dropped (loop/UI/HAL torn down); preserve the flash for the next boot.
        device.into_flash()
    });

    let device_id = rx
        .recv()
        .expect("device thread should boot and announce its id");

    (
        device_id,
        DeviceThread {
            stop,
            join: Some(join),
        },
    )
}

impl VirtualDevice {
    /// Spawn a standalone device on its own thread with fresh peripherals + empty flash
    /// (owns its upstream pipe, peerless downstream) — a test helper. The returned
    /// [`SpawnedDevice::host`] is the coordinator end. `on_frame` is called with
    /// `(width, height, rgba8888)` whenever the framebuffer changes. Returns once the
    /// device has booted and announced its id.
    pub fn spawn(
        seed: u64,
        firmware_digest: Sha256Digest,
        on_frame: impl Fn(u32, u32, Vec<u8>) + Send + Sync + 'static,
    ) -> SpawnedDevice {
        let (upstream_io, host) = pipe();
        let framebuffer = SharedFramebuffer::new();
        let touch = TouchQueue::new();
        let handles = DeviceHandles {
            upstream_io,
            downstream_io: PipeByteIo::disconnected(),
            framebuffer: framebuffer.clone(),
            touch: touch.clone(),
            downstream_present: None,
            on_frame: Arc::new(on_frame),
        };
        let (device_id, thread) =
            spawn_device_thread(seed, firmware_digest, handles, RamFlash::new());
        SpawnedDevice {
            device_id,
            framebuffer,
            touch,
            host: Some(host),
            thread,
        }
    }
}
