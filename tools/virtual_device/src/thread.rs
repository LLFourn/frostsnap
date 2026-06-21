//! The per-device thread runtime.
//!
//! `FrostyUi` is `!Send` (it holds `Rc`s), so a [`VirtualDevice`] cannot be moved
//! into a spawned thread. Instead [`VirtualDevice::spawn`] *builds the device inside
//! the thread* from a seed and hands the caller only the `Send`, `Arc`-backed handles
//! (the framebuffer, the touch queue, the coordinator-side serial end) back over a
//! channel. Nothing `!Send` ever crosses the thread boundary — the device thread and
//! the rest of the app communicate solely through those `Arc`-backed pipes.
//!
//! The thread runs `loop { poll_once(false); on dirty → on_frame(rgba); short park }`.
//! `poll_once` is non-blocking and the park is short, so the loop checks the stop flag
//! every iteration; dropping the [`DeviceThread`] sets the flag and joins promptly (no
//! detached thread, no busy spin).

use crate::device::VirtualDevice;
use crate::display::SharedFramebuffer;
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

/// A running device thread. Dropping it stops and joins the thread.
pub struct DeviceThread {
    stop: Arc<AtomicBool>,
    join: Option<JoinHandle<()>>,
}

impl Drop for DeviceThread {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
    }
}

/// The `Send` handles a spawned device hands back: its id plus the `Arc`-backed
/// peripheral handles, and the thread itself (kept alive — drop it to stop the device).
/// `host` is set only for a device that owns its upstream pipe ([`VirtualDevice::spawn`]);
/// a chained device ([`VirtualDevice::spawn_chained`]) is wired to a peer link, so the
/// caller already holds the relevant ends and `host` is `None`.
pub struct SpawnedDevice {
    pub device_id: DeviceId,
    pub framebuffer: SharedFramebuffer,
    pub touch: TouchQueue,
    pub host: Option<HostEnd>,
    pub thread: DeviceThread,
}

impl VirtualDevice {
    /// Spawn a standalone device on its own thread (owns its upstream pipe, peerless
    /// downstream). The returned [`SpawnedDevice::host`] is the coordinator end.
    /// `on_frame` is called with `(width, height, rgba8888)` whenever the framebuffer
    /// changes. Returns once the device has booted and announced its id.
    pub fn spawn(
        seed: u64,
        firmware_digest: Sha256Digest,
        on_frame: impl FnMut(u32, u32, Vec<u8>) + Send + 'static,
    ) -> SpawnedDevice {
        let (upstream_io, host) = pipe();
        let downstream_io = PipeByteIo::disconnected();
        let mut spawned = Self::spawn_chained(
            seed,
            firmware_digest,
            upstream_io,
            downstream_io,
            None,
            on_frame,
        );
        spawned.host = Some(host);
        spawned
    }

    /// Spawn a device wired to externally-supplied upstream/downstream links (sim-10's
    /// chain). `downstream_present` is the gate of the link to the child below (read each
    /// tick to drive the firmware's real downstream-detect); `None` for the tail device.
    /// The device is built in-thread (so nothing `!Send` escapes) from the moved-in link
    /// ends. Returns with `host: None` — the caller owns the upstream peer end.
    pub fn spawn_chained(
        seed: u64,
        firmware_digest: Sha256Digest,
        upstream_io: PipeByteIo,
        downstream_io: PipeByteIo,
        downstream_present: Option<LinkGate>,
        mut on_frame: impl FnMut(u32, u32, Vec<u8>) + Send + 'static,
    ) -> SpawnedDevice {
        let stop = Arc::new(AtomicBool::new(false));
        let (tx, rx) = mpsc::channel::<(DeviceId, SharedFramebuffer, TouchQueue)>();

        let thread_stop = stop.clone();
        let join = thread::spawn(move || {
            // Built here so nothing `!Send` (FrostyUi/the session) ever escapes.
            let mut device =
                VirtualDevice::from_io(seed, firmware_digest, upstream_io, downstream_io);
            let framebuffer = device.framebuffer();
            let touch = device.touch();

            let mut session = match device.session() {
                InitOutcome::Ready(session) => session,
                InitOutcome::ResetRequested => return,
            };
            let device_id = session.device_id();

            // If the caller already dropped its end, there's nothing to drive.
            if tx.send((device_id, framebuffer.clone(), touch)).is_err() {
                return;
            }
            drop(tx);

            loop {
                if thread_stop.load(Ordering::Relaxed) {
                    return;
                }
                // The downstream-detect pin reads the link gate: a connected child below
                // makes the firmware establish + relay downstream; unplugging it tears
                // that down. None = no child (tail of the chain).
                let present = downstream_present
                    .as_ref()
                    .is_some_and(LinkGate::is_connected);
                if matches!(session.poll_once(present), Poll::ResetRequested) {
                    return;
                }
                if framebuffer.take_dirty() {
                    let (w, h, rgba) = framebuffer.export_rgba();
                    on_frame(w, h, rgba);
                }
                thread::sleep(POLL_PARK);
            }
        });

        let (device_id, framebuffer, touch) = rx
            .recv()
            .expect("device thread should boot and announce its id");

        SpawnedDevice {
            device_id,
            framebuffer,
            touch,
            host: None,
            thread: DeviceThread {
                stop,
                join: Some(join),
            },
        }
    }
}
