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
    Point, PortConnection, SharedFramebuffer, SpawnedDevice, TouchEvent, TouchGesture, TouchQueue,
};
use std::sync::{Arc, Mutex};

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
    device_id: DeviceId,
    touch: TouchQueue,
    framebuffer: SharedFramebuffer,
    frames_sink: Arc<Mutex<Option<StreamSink<SimFrame>>>>,
    connection: PortConnection,
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
        connection: PortConnection,
    ) -> Self {
        Self {
            device_id,
            touch,
            framebuffer,
            frames_sink,
            connection,
        }
    }

    /// Simulate plugging/unplugging the device's USB. When disconnected the port
    /// vanishes from the coordinator's view (it sees an unplug); reconnecting makes
    /// it reappear and re-announce. Drives the sim tray's connect/disconnect toggle.
    #[frb(sync)]
    pub fn set_connected(&self, connected: bool) {
        self.connection.set_connected(connected);
    }

    #[frb(sync)]
    pub fn is_connected(&self) -> bool {
        self.connection.is_connected()
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
