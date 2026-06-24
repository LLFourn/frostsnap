//! FRB types backing the **debug-only** virtual-device simulator (see
//! [`super::init::Api::load_sim`]). A [`DevicePool`] owns the host-side virtual
//! device thread(s) and hands Dart [`SimDevice`] handles: each streams the device
//! framebuffer ([`SimFrame`]) and accepts injected touches. Production paths never reach
//! these.

use crate::frb_generated::StreamSink;
use flutter_rust_bridge::frb;
use frostsnap_coordinator::{FirmwareBin, ValidatedFirmwareBin};
use frostsnap_core::DeviceId;
use frostsnap_virtual_device::{
    ChainRouter, DeviceChannel, DeviceInput, FrameSink, Point, SharedFramebuffer, SlotSpec,
    TouchEvent, TouchGesture, TouchQueue,
};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// A minimal but structurally-valid ESP firmware image, used only so the simulator is
/// self-contained: real builds embed firmware via `BUNDLE_FIRMWARE`, but the sim has no
/// real firmware. The coordinator treats this as the latest firmware and the virtual
/// device announces its digest, so the app sees up-to-date (compatible) firmware without
/// a hardware build. Layout: a 24-byte ESP image header (`0xE9` magic, one segment, no
/// appended digest), an 8-byte segment header declaring a 16-byte segment, then zero
/// padding to the 64-byte (16-aligned, +1 checksum) total `firmware_size` expects.
const SIM_FIRMWARE_IMAGE: [u8; 64] = {
    let mut img = [0u8; 64];
    img[0] = 0xE9; // ESP_MAGIC
    img[1] = 1; // segment_count
    img[28] = 16; // segment 0 length (u32 LE), header at offset 24 (addr) + 28 (len)
    img
};

/// The simulator's self-contained firmware bin. Validation succeeds because the image is
/// a structurally-valid *unsigned* ESP image (`firmware_size == total_size`), which skips
/// the known-versions check. `load_sim` seeds this as the coordinator's latest firmware
/// and announces [`ValidatedFirmwareBin::digest`] from the virtual device.
pub(crate) fn sim_firmware_bin() -> ValidatedFirmwareBin {
    FirmwareBin::new(&SIM_FIRMWARE_IMAGE)
        .validate()
        .expect("sim firmware image is a valid unsigned ESP image")
}

/// One rendered device frame, RGBA8888, for streaming to the Flutter tray.
pub struct SimFrame {
    pub width: u32,
    pub height: u32,
    pub data: Vec<u8>,
}

/// A handle to one host virtual device. Cheaply cloneable (its state is `Arc`-backed),
/// so the pool can hand out copies that all drive the same underlying device thread.
#[derive(Clone)]
#[frb(opaque)]
pub struct SimDevice {
    number: u32,
    device_id: DeviceId,
    touch: TouchQueue,
    framebuffer: SharedFramebuffer,
    frames_sink: Arc<Mutex<Option<StreamSink<SimFrame>>>>,
    // The shared chain config (single source of truth): "connected" == this device's
    // number is in the chain. Per-device connect/disconnect are thin edits to that one
    // ordered list via [`ChainRouter::set_chain`] — no separate per-device state.
    router: Arc<ChainRouter>,
}

impl SimDevice {
    /// This device's 1-based position in the pool — a short, stable label for the tray
    /// and the device-channel selector, in place of the opaque [`SimDevice::id`].
    #[frb(sync)]
    pub fn number(&self) -> u32 {
        self.number
    }

    #[frb(sync)]
    pub fn id(&self) -> String {
        self.device_id.to_string()
    }

    /// Register the sink the device thread pushes [`SimFrame`]s into (its `on_frame`
    /// closure, set up in `load_sim`, writes into this same `Arc`). Immediately replays
    /// the *current* framebuffer so the tray paints at once — the device may have
    /// cleared its initial dirty flag before Dart subscribed, so waiting for the next
    /// redraw would otherwise leave the cell blank.
    pub fn frames(&self, sink: StreamSink<SimFrame>) {
        let (width, height, data) = self.framebuffer.export_rgba();
        let _ = sink.add(SimFrame {
            width,
            height,
            data,
        });
        *self.frames_sink.lock().unwrap() = Some(sink);
    }

    /// Inject a touch into the running device — drives the real `FrostyUi` widget tree
    /// exactly as the hardware touch controller does.
    #[frb(sync)]
    pub fn touch(&self, x: u16, y: u16, lift_up: bool) {
        self.touch.push(TouchEvent {
            point: Point::new(x as i32, y as i32),
            lift_up,
            gesture: TouchGesture::None,
        });
    }

    /// Inject a SWIPE from `(x1,y1)` to `(x2,y2)` over `ms`. Runs through the SAME gesture-
    /// inferring path the device channel/CLI use ([`DeviceInput::swipe`]), so the synthesized
    /// `SlideUp`/`SlideDown` is exactly what the CST816S would report and the widget tree's
    /// vertical-drag handling fires. NOT `#[frb(sync)]`: it emits intermediate move events across
    /// `ms` of wall-clock, so it runs off the UI isolate.
    pub fn swipe(&self, x1: u16, y1: u16, x2: u16, y2: u16, ms: u32) {
        DeviceInput::new(self.touch.clone()).swipe(
            x1 as i32,
            y1 as i32,
            x2 as i32,
            y2 as i32,
            Duration::from_millis(ms as u64),
        );
    }
}

/// The per-device frame plumbing: an `Arc` the device thread's `on_frame` pushes [`SimFrame`]s
/// into, and the `on_frame` closure itself. [`SimDevice::frames`] later registers the Dart
/// `StreamSink` into the same `Arc`. Shared by `load_sim` and [`DevicePool::add_device`].
pub(crate) fn make_frame_sink() -> (Arc<Mutex<Option<StreamSink<SimFrame>>>>, FrameSink) {
    let frames_sink: Arc<Mutex<Option<StreamSink<SimFrame>>>> = Arc::new(Mutex::new(None));
    let on_frame_sink = frames_sink.clone();
    let on_frame: FrameSink = Arc::new(move |width, height, data| {
        if let Some(sink) = &*on_frame_sink.lock().unwrap() {
            let _ = sink.add(SimFrame {
                width,
                height,
                data,
            });
        }
    });
    (frames_sink, on_frame)
}

/// Build the device-input socket channel + Dart [`SimDevice`] handle for the router slot at
/// `index` (1-based device number = `index + 1`), wired to that slot's STABLE handles + the
/// shared router. Shared by `load_sim` (initial fleet) and [`DevicePool::add_device`].
pub(crate) fn build_device(
    router: &Arc<ChainRouter>,
    app_dir: &Path,
    index: usize,
    frames_sink: Arc<Mutex<Option<StreamSink<SimFrame>>>>,
) -> anyhow::Result<(DeviceChannel, SimDevice)> {
    let number = (index + 1) as u32;
    let device_id = router.device_id(index);
    let socket = app_dir.join(format!("device-{number}.sock"));
    let channel = DeviceChannel::serve(
        socket,
        router.touch(index),
        router.framebuffer(index),
        router.clone(),
        index,
        device_id,
    )?;
    let device = SimDevice::new(
        number,
        device_id,
        router.touch(index),
        router.framebuffer(index),
        frames_sink,
        router.clone(),
    );
    Ok((channel, device))
}

/// Owns the host virtual device fleet (via the [`ChainRouter`], which holds each device's
/// power slot) and the Dart-facing [`SimDevice`] handles. The fleet is growable at runtime
/// ([`add_device`](Self::add_device)). Dropping the pool drops the last router reference,
/// which stops the forwarding thread and powers off every device.
#[frb(opaque)]
pub struct DevicePool {
    // The base seed + app dir needed to mint the NEXT device: its seed is `seed + index` and
    // its socket is `app_dir/device-<n>.sock`, so add_device builds one exactly as load_sim does.
    seed: u64,
    app_dir: PathBuf,
    // The single source of truth: owns each device's power slot (flash + peripherals) and the
    // chain order, where chain membership IS power. The fleet grows via ChainRouter::add_device.
    router: Arc<ChainRouter>,
    // The kept-alive input sockets + the Dart handles, interior-mutable so add_device grows
    // them in lockstep with the router. Dropping the pool stops the accept loops (no residue).
    state: Mutex<PoolDevices>,
}

/// The pool's growable per-device resources, in 1-based device order: the served sockets
/// (kept alive) and the Dart [`SimDevice`] handles.
struct PoolDevices {
    channels: Vec<DeviceChannel>,
    handles: Vec<SimDevice>,
}

impl DevicePool {
    pub(crate) fn new(
        seed: u64,
        app_dir: PathBuf,
        router: Arc<ChainRouter>,
        channels: Vec<DeviceChannel>,
        handles: Vec<SimDevice>,
    ) -> Self {
        Self {
            seed,
            app_dir,
            router,
            state: Mutex::new(PoolDevices { channels, handles }),
        }
    }

    pub fn devices(&self) -> Vec<SimDevice> {
        self.state.lock().unwrap().handles.clone()
    }

    /// Add a virtual device to the fleet at runtime and return its handle. Grows the router (a
    /// new powered-off slot), serves its `device-<n>.sock`, then plugs it into the chain TAIL
    /// via [`ChainRouter::connect`] so it enumerates to the coordinator like a real hot-plug.
    /// The device number is the next contiguous value (the fleet only ever grows).
    pub fn add_device(&self) -> anyhow::Result<SimDevice> {
        let mut state = self.state.lock().unwrap();
        let index = state.handles.len();
        let (frames_sink, on_frame) = make_frame_sink();
        let spec = SlotSpec {
            seed: self.seed.wrapping_add(index as u64),
            digest: sim_firmware_bin().digest(),
            on_frame,
        };
        let router_index = self.router.add_device(spec);
        debug_assert_eq!(router_index, index, "pool and router device counts agree");
        let (channel, device) = build_device(&self.router, &self.app_dir, index, frames_sink)?;
        state.channels.push(channel);
        state.handles.push(device.clone());
        // Plug the new device into the tail so it powers on and enumerates to the coordinator.
        self.router.connect(index);
        Ok(device)
    }

    /// The connected chain as 1-based device numbers, in order (first = the device on the
    /// coordinator USB port). Devices not listed are disconnected.
    #[frb(sync)]
    pub fn chain(&self) -> Vec<u32> {
        self.router
            .chain()
            .iter()
            .map(|&index| (index + 1) as u32)
            .collect()
    }

    /// Re-cable the chain to exactly these 1-based device numbers, in order. This is the
    /// single mutation behind connect, disconnect, and reorder. Invalid input (a `0`, an
    /// out-of-range number, or a duplicate) is rejected, leaving the chain unchanged.
    #[frb(sync)]
    pub fn set_chain(&self, order: Vec<u32>) {
        // 1-based -> 0-based with checked_sub so a `0` can't underflow; if any number is
        // out of the valid 1-based range, don't apply a partial chain. The router then
        // re-validates range + duplicates and no-ops anything still invalid.
        let indices: Vec<usize> = order
            .iter()
            .filter_map(|&n| n.checked_sub(1).map(|i| i as usize))
            .collect();
        if indices.len() != order.len() {
            return;
        }
        let _ = self.router.set_chain(indices);
    }
}

impl SimDevice {
    pub(crate) fn new(
        number: u32,
        device_id: DeviceId,
        touch: TouchQueue,
        framebuffer: SharedFramebuffer,
        frames_sink: Arc<Mutex<Option<StreamSink<SimFrame>>>>,
        router: Arc<ChainRouter>,
    ) -> Self {
        Self {
            number,
            device_id,
            touch,
            framebuffer,
            frames_sink,
            router,
        }
    }

    /// Connect this device (plug it into the tail of the chain) or disconnect it. Because
    /// the chain is a daisy chain, disconnecting a device also disconnects everything
    /// downstream of it (they were reached through it) — see [`ChainRouter::disconnect`].
    /// Use [`DevicePool::set_chain`] to reorder. Drives the sim tray's per-device toggle.
    #[frb(sync)]
    pub fn set_connected(&self, connected: bool) {
        let index = (self.number - 1) as usize;
        if connected {
            self.router.connect(index);
        } else {
            self.router.disconnect(index);
        }
    }

    /// Whether this device is currently in the chain.
    #[frb(sync)]
    pub fn is_connected(&self) -> bool {
        self.router.chain().contains(&((self.number - 1) as usize))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sim_firmware_validates_and_is_unsigned() {
        let fw = sim_firmware_bin();
        // Unsigned (firmware_size == total_size) so validation skips the
        // KNOWN_FIRMWARE_VERSIONS check regardless of build env.
        assert_eq!(fw.firmware_size(), fw.total_size());
        // The digest the device announces must be deterministic so it always matches
        // the coordinator's latest.
        assert_eq!(fw.digest(), sim_firmware_bin().digest());
    }
}
