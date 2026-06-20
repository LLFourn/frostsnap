//! FRB types backing the **debug-only** virtual-device simulator (see
//! [`super::init::Api::load_sim`]). A [`DevicePool`] owns the host-side virtual
//! device thread(s) and hands Dart [`SimDevice`] handles: each streams the device
//! framebuffer ([`SimFrame`]) and accepts injected touches. Production paths never reach
//! these.

use crate::frb_generated::StreamSink;
use flutter_rust_bridge::frb;
use frostsnap_core::DeviceId;
use frostsnap_virtual_device::{
    Point, SharedFramebuffer, SpawnedDevice, TouchEvent, TouchGesture, TouchQueue,
};
use std::sync::{Arc, Mutex};

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
    device_id: DeviceId,
    touch: TouchQueue,
    framebuffer: SharedFramebuffer,
    frames_sink: Arc<Mutex<Option<StreamSink<SimFrame>>>>,
}

impl SimDevice {
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
}

/// Owns the host virtual device thread(s) and the Dart-facing [`SimDevice`] handles.
/// Dropping the pool drops the [`SpawnedDevice`]s, which stops + joins their threads.
#[frb(opaque)]
pub struct DevicePool {
    // Kept alive so the device threads keep running; never read directly.
    _spawned: Vec<SpawnedDevice>,
    devices: Vec<SimDevice>,
}

impl DevicePool {
    pub(crate) fn new(spawned: Vec<SpawnedDevice>, devices: Vec<SimDevice>) -> Self {
        Self {
            _spawned: spawned,
            devices,
        }
    }

    pub fn devices(&self) -> Vec<SimDevice> {
        self.devices.clone()
    }
}

impl SimDevice {
    pub(crate) fn new(
        device_id: DeviceId,
        touch: TouchQueue,
        framebuffer: SharedFramebuffer,
        frames_sink: Arc<Mutex<Option<StreamSink<SimFrame>>>>,
    ) -> Self {
        Self {
            device_id,
            touch,
            framebuffer,
            frames_sink,
        }
    }
}
