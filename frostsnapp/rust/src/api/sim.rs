//! FRB types backing the **debug-only** virtual-device simulator (see
//! [`super::init::Api::load_sim`]). A [`DevicePool`] owns the host-side virtual
//! device thread(s) and hands Dart [`SimDevice`] handles: each streams the device
//! framebuffer ([`SimFrame`]) and accepts injected touches. Production paths never reach
//! these.

use crate::frb_generated::StreamSink;
use flutter_rust_bridge::frb;
use frostsnap_coordinator::{FirmwareBin, ValidatedFirmwareBin};
use frostsnap_virtual_device::{
    record_on_device, type_on_device, BackupTarget, ChainRouter, DeviceInput, FrameSink, Point,
    SharedFramebuffer, SlotError, SlotSpec, TouchEvent, TouchGesture, TouchQueue,
};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// A structurally-valid ESP firmware image, used only so the simulator is
/// self-contained: real builds embed firmware via `BUNDLE_FIRMWARE`, but the sim has no
/// real firmware. The coordinator treats this as the latest firmware; up-to-date virtual
/// devices announce its digest, and stale ones get offered it as THE upgrade — the bytes
/// really stream to (and through) the devices, so it spans 32 transfer chunks (128 KiB)
/// to make the upgrade progress UI visibly animate instead of completing in one frame.
/// Layout: the 24+8-byte ESP image/segment headers (`0xE9` magic, one segment filling
/// the rest, no appended digest) plus the 16-byte checksum tail `firmware_size` expects.
const SIM_FIRMWARE_IMAGE_LEN: usize = 32 * 4096;

static SIM_FIRMWARE_IMAGE: [u8; SIM_FIRMWARE_IMAGE_LEN] = {
    let mut img = [0u8; SIM_FIRMWARE_IMAGE_LEN];
    img[0] = 0xE9; // ESP_MAGIC
    img[1] = 1; // segment_count
                // Segment 0 length (u32 LE at offset 28; addr at 24): everything after
                // the 32 header bytes, minus the 16-byte checksum tail the size parser
                // accounts for.
    let seg_len = (SIM_FIRMWARE_IMAGE_LEN - 32 - 16) as u32;
    img[28] = seg_len as u8;
    img[29] = (seg_len >> 8) as u8;
    img[30] = (seg_len >> 16) as u8;
    img[31] = (seg_len >> 24) as u8;
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
    /// The router slot index. Numbers are session-scoped labels that survive app
    /// generations (a restarted generation seeds a number base), so index and
    /// number-1 diverge — the index is carried, never derived.
    index: usize,
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

    /// This device's router index. Liveness is NOT checked here — each behavioral
    /// method fetches its resource through the router's atomic live-slot accessors,
    /// so the check and the acquisition are one step (a check-then-use split would
    /// let a concurrent removal turn the promised clear error into a panic).
    fn index(&self) -> usize {
        self.index
    }

    /// Translate a router [`SlotError`] about THIS device into number-speak.
    fn slot_err(&self, e: SlotError) -> anyhow::Error {
        describe_slot_error(e, |index| (index == self.index).then_some(self.number))
    }

    /// The live touch queue, or the tombstone error.
    fn live_touch(&self) -> anyhow::Result<TouchQueue> {
        self.router
            .touch(self.index())
            .map_err(|e| self.slot_err(e))
    }

    /// The live framebuffer, or the tombstone error.
    fn live_framebuffer(&self) -> anyhow::Result<SharedFramebuffer> {
        self.router
            .framebuffer(self.index())
            .map_err(|e| self.slot_err(e))
    }

    /// The live observation, or the tombstone error.
    fn live_observation(&self) -> anyhow::Result<frostsnap_virtual_device::SimObservation> {
        self.router
            .observation(self.index())
            .map_err(|e| self.slot_err(e))
    }

    /// This device's CURRENT id, read live from the router: an erase re-inits the
    /// flash header the id derives from, so the device that comes back after one is a
    /// different device — a cached id would keep naming the erased one.
    #[frb(sync)]
    pub fn id(&self) -> anyhow::Result<String> {
        Ok(self
            .router
            .device_id(self.index())
            .map_err(|e| self.slot_err(e))?
            .to_string())
    }

    /// Register the sink the device thread pushes [`SimFrame`]s into (its `on_frame`
    /// closure, set up in `load_sim`, writes into this same `Arc`). Immediately replays
    /// the *current* framebuffer so the tray paints at once — the device may have
    /// cleared its initial dirty flag before Dart subscribed, so waiting for the next
    /// redraw would otherwise leave the cell blank.
    pub fn frames(&self, sink: StreamSink<SimFrame>) -> anyhow::Result<()> {
        // A REMOVED device produces no frames rather than an error: the pool can remove one at any
        // moment, so a subscriber cannot avoid that race, and erroring reaches the app as an
        // UNCAUGHT async error — a crash report for an ordinary lifecycle event. Dropping the sink
        // closes the stream, which is what "there is nothing to show" should look like.
        //
        // ONLY removal. Every other slot error means the router is in a state nobody intended, and
        // turning those into an empty stream would give a frozen device screen and a green test —
        // the hidden-failure class this harness exists to end.
        let framebuffer = match self.router.framebuffer(self.index()) {
            Ok(framebuffer) => framebuffer,
            Err(SlotError::Removed { .. }) => return Ok(()),
            Err(e) => return Err(self.slot_err(e)),
        };
        let (width, height, data) = framebuffer.export_rgba();
        let _ = sink.add(SimFrame {
            width,
            height,
            data,
        });
        *self.frames_sink.lock().unwrap() = Some(sink);
        Ok(())
    }

    /// Snapshot the CURRENT framebuffer WITHOUT touching the frame stream — backs the app-channel
    /// `device-screen` endpoint. Unlike [`frames`], which installs its sink into the single
    /// `frames_sink` slot (so a one-shot read there would hijack the live tray subscriber), this
    /// reads the shared framebuffer directly, exactly like the host socket's `save_png`.
    #[frb(sync)]
    pub fn snapshot(&self) -> anyhow::Result<SimFrame> {
        let (width, height, data) = self.live_framebuffer()?.export_rgba();
        Ok(SimFrame {
            width,
            height,
            data,
        })
    }

    /// Inject a touch into the running device — drives the real `FrostyUi` widget tree
    /// exactly as the hardware touch controller does.
    #[frb(sync)]
    pub fn touch(&self, x: u16, y: u16, lift_up: bool) -> anyhow::Result<()> {
        self.live_touch()?.push(TouchEvent {
            point: Point::new(x as i32, y as i32),
            lift_up,
            gesture: TouchGesture::None,
        });
        Ok(())
    }

    /// Inject a SWIPE from `(x1,y1)` to `(x2,y2)` over `ms`. Runs through the SAME gesture-
    /// inferring path the device channel/CLI use ([`DeviceInput::swipe`]), so the synthesized
    /// `SlideUp`/`SlideDown` is exactly what the CST816S would report and the widget tree's
    /// vertical-drag handling fires. NOT `#[frb(sync)]`: it emits intermediate move events across
    /// `ms` of wall-clock, so it runs off the UI isolate.
    pub fn swipe(&self, x1: u16, y1: u16, x2: u16, y2: u16, ms: u32) -> anyhow::Result<()> {
        DeviceInput::new(self.live_touch()?).swipe(
            x1 as i32,
            y1 as i32,
            x2 as i32,
            y2 as i32,
            Duration::from_millis(ms as u64),
        );
        Ok(())
    }

    /// The WHOLE "write it down" half in one call: wait for this device's display-backup
    /// screen, capture its full text, then drive the real paged display (page swipes +
    /// the final hold-to-confirm, widget-owned geometry) until the device's own
    /// `BackupRecorded` fires for this display run. Returns the text — feed it to
    /// [`type_backup`](Self::type_backup) for the entry half. Blocking (~40 s); NOT
    /// `#[frb(sync)]`.
    pub fn record_backup(&self) -> anyhow::Result<String> {
        Ok(record_on_device(
            &DeviceInput::new(self.live_touch()?),
            &self.live_observation()?,
            Duration::from_secs(120),
        )?)
    }

    /// Advance the paged backup display one page. The swipe span comes from the display
    /// widget's own geometry contract — callers never supply device pixels. NOT
    /// `#[frb(sync)]` (emits a real swipe over wall-clock).
    pub fn backup_display_next(&self) -> anyhow::Result<()> {
        DeviceInput::new(self.live_touch()?).backup_display_next();
        Ok(())
    }

    /// Hold the backup display's confirmation control long enough to confirm (fires the
    /// device's `BackupRecorded`); the point is probed from the confirmation page's own
    /// hit-testing. Blocks for the hold duration (~2.6 s); NOT `#[frb(sync)]`.
    pub fn backup_display_confirm(&self) -> anyhow::Result<()> {
        DeviceInput::new(self.live_touch()?).backup_display_confirm();
        Ok(())
    }

    /// The full text (`#N WORD1 … WORD25`) of the backup this device is currently
    /// DISPLAYING — privileged read-only sim observation of the display-backup screen,
    /// independent of which page is visible (the pen-and-paper analog). Errors when the
    /// device isn't showing a backup.
    #[frb(sync)]
    pub fn displayed_backup(&self) -> anyhow::Result<String> {
        self.live_observation()?
            .displayed_backup()
            .ok_or_else(|| anyhow::anyhow!("device {} is not displaying a backup", self.number))
    }

    /// Type a full backup (`#N WORD1 … WORD25`, case-insensitive) on this device's
    /// backup-entry screen as REAL touches: share index on the numeric keyboard, letters
    /// on the BIP39-constrained alphabetic keyboard (scrolling as needed), a word-selector
    /// tap per word. The words must exist on the BIP39 list (nothing else is typeable);
    /// checksum validity is judged by the device itself — a checksum-invalid set types
    /// through and errors. Blocking for the duration of the typing (~a minute); NOT
    /// `#[frb(sync)]`, so it runs off the UI isolate.
    pub fn type_backup(&self, text: String) -> anyhow::Result<()> {
        let target = BackupTarget::parse(&text)?;
        type_on_device(
            &DeviceInput::new(self.live_touch()?),
            &self.live_observation()?,
            &target,
            Duration::from_secs(300),
        )?;
        Ok(())
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

/// Build the Dart [`SimDevice`] handle for the router slot at `index` (1-based device number =
/// `index + 1`), wired to that slot's STABLE handles + the shared router. Shared by `load_sim`
/// (initial fleet) and [`DevicePool::add_device`]. Devices are driven over the app channel (the
/// harness drives this handle via FRB); there is no host socket.
pub(crate) fn build_device(
    router: &Arc<ChainRouter>,
    number: u32,
    index: usize,
    frames_sink: Arc<Mutex<Option<StreamSink<SimFrame>>>>,
) -> SimDevice {
    SimDevice::new(number, index, frames_sink, router.clone())
}

/// The pool's explicit number allocation state (see the `numbering` field).
struct Numbering {
    /// The number the NEXT added device receives — monotonic, never reused.
    next: u32,
    /// Router index -> logical number. Tombstoned slots KEEP their entry: their label
    /// outlives them, so errors about a removed slot still name the right device.
    by_index: Vec<u32>,
}

/// Render a router [`SlotError`] with logical device-number labels. `number_of_index`
/// returns the label for a slot the caller knows, `None` for one it doesn't (which
/// would mean pool/router numbering disagree — labeled honestly as a slot).
fn describe_slot_error(
    e: SlotError,
    number_of_index: impl Fn(usize) -> Option<u32>,
) -> anyhow::Error {
    let label = |index: usize| match number_of_index(index) {
        Some(number) => format!("device {number}"),
        None => format!("device slot {index}"),
    };
    match e {
        SlotError::Removed { index } => anyhow::anyhow!("{} was removed", label(index)),
        SlotError::OutOfRange { index, count } => {
            anyhow::anyhow!("no {} (the router has {count} slots)", label(index))
        }
        SlotError::ListedTwice { index } => {
            anyhow::anyhow!("{} listed more than once", label(index))
        }
        SlotError::Connected { index } => anyhow::anyhow!(
            "{} is connected; unplug it before saving its state",
            label(index)
        ),
        SlotError::IdentityInPool { id } => {
            anyhow::anyhow!("a device with identity {id} is already in the pool")
        }
    }
}

/// Owns the host virtual device fleet (via the [`ChainRouter`], which holds each device's
/// power slot) and the Dart-facing [`SimDevice`] handles. The fleet is growable at runtime
/// ([`add_device`](Self::add_device)). Dropping the pool drops the last router reference,
/// which stops the forwarding thread and powers off every device.
#[frb(opaque)]
pub struct DevicePool {
    // The base seed needed to mint the NEXT device: its seed is `seed + index`, so add_device
    // builds one exactly as load_sim does.
    seed: u64,
    // The single source of truth: owns each device's power slot (flash + peripherals) and the
    // chain order, where chain membership IS power. The fleet grows via ChainRouter::add_device.
    router: Arc<ChainRouter>,
    // The Dart [`SimDevice`] handles (1-based device order), interior-mutable so add_device grows
    // them in lockstep with the router. Every FLEET mutation (add, restore, remove) holds this
    // lock for its whole transaction — a removal interleaving between a concurrent add's
    // router-publish and its handle-build/connect would tombstone the in-flight slot.
    handles: Mutex<Vec<SimDevice>>,
    // The pool OWNS the number-to-slot allocation: numbers are SESSION-scoped labels
    // that survive app generations (a restarted generation is seeded with the previous
    // generation's next number via [`seed_next_number`](Self::seed_next_number)), so
    // they are allocated explicitly — never derived from router position, which drifts
    // from the labels as soon as a generation holds tombstones plus a seeded counter.
    numbering: Mutex<Numbering>,
    /// Test-only seam: invoked between the router publish and the handle build inside the
    /// add paths (still holding `handles`), so a test can prove a concurrent remove cannot
    /// interleave there.
    #[cfg(test)]
    insertion_hook: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
}

impl DevicePool {
    pub(crate) fn new(seed: u64, router: Arc<ChainRouter>, handles: Vec<SimDevice>) -> Self {
        let count = handles.len() as u32;
        Self {
            seed,
            router,
            handles: Mutex::new(handles),
            numbering: Mutex::new(Numbering {
                next: count + 1,
                by_index: (1..=count).collect(),
            }),
            #[cfg(test)]
            insertion_hook: Mutex::new(None),
        }
    }

    /// Allocate the number for a slot the router just published at `index`. Locks
    /// `numbering` under the caller's `handles` hold (the one fleet-mutation lock
    /// order), keeping `by_index` in lockstep with the router's slot count.
    fn allocate_number(&self, index: usize) -> u32 {
        let mut numbering = self.numbering.lock().unwrap();
        debug_assert_eq!(
            numbering.by_index.len(),
            index,
            "pool numbering and router slots agree"
        );
        let number = numbering.next;
        numbering.next += 1;
        numbering.by_index.push(number);
        number
    }

    fn number_of(&self, index: usize) -> u32 {
        self.numbering.lock().unwrap().by_index[index]
    }

    fn index_of(&self, number: u32) -> anyhow::Result<usize> {
        self.numbering
            .lock()
            .unwrap()
            .by_index
            .iter()
            .position(|&n| n == number)
            .ok_or_else(|| anyhow::anyhow!("no device {number} in this app generation"))
    }

    /// Translate a router [`SlotError`] into the pool's language: logical device
    /// numbers, not slot indices.
    fn slot_err(&self, e: SlotError) -> anyhow::Error {
        let numbering = self.numbering.lock().unwrap();
        describe_slot_error(e, |index| numbering.by_index.get(index).copied())
    }

    /// The number the NEXT added device will get — read by `restartApp` before killing a
    /// generation, so the next one can be seeded and numbers stay session-unique.
    /// Takes `handles` first (the pool's fleet-transaction lock): a `numbering`-only
    /// read could observe an in-flight add after its router publish but before its
    /// number commits, handing the restart a stale next the add is about to consume.
    #[frb(sync)]
    pub fn next_device_number(&self) -> u32 {
        let _handles = self.handles.lock().unwrap();
        self.numbering.lock().unwrap().next
    }

    /// Seed the counter so the next added device gets EXACTLY [`next`] — called by
    /// `restartApp` on the new generation before any devices are re-added, continuing
    /// the previous generation's numbering. LIVE devices block seeding; tombstones
    /// don't (the android relaunch boots the APK's baked-in device, which restartApp
    /// removes before seeding) — but they keep their labels, so `next` must clear
    /// every number this generation has already allocated.
    pub fn seed_next_number(&self, next: u32) -> anyhow::Result<()> {
        let handles = self.handles.lock().unwrap();
        let live = handles
            .iter()
            .filter(|device| self.router.is_live(device.index))
            .count();
        if live != 0 {
            anyhow::bail!(
                "the number counter can only be seeded with no live devices ({live} exist)"
            );
        }
        if next == 0 {
            anyhow::bail!("device numbers are 1-based, got 0");
        }
        let mut numbering = self.numbering.lock().unwrap();
        if let Some(&max) = numbering.by_index.iter().max() {
            if next <= max {
                anyhow::bail!(
                    "seeding next number {next} would reuse a number this generation already allocated (max {max})"
                );
            }
        }
        numbering.next = next;
        Ok(())
    }

    #[cfg(test)]
    fn fire_insertion_hook(&self) {
        let hook = self.insertion_hook.lock().unwrap().clone();
        if let Some(hook) = hook {
            hook();
        }
    }

    #[cfg(not(test))]
    fn fire_insertion_hook(&self) {}

    pub fn devices(&self) -> Vec<SimDevice> {
        let handles = self.handles.lock().unwrap();
        handles
            .iter()
            .filter(|device| self.router.is_live(device.index))
            .cloned()
            .collect()
    }

    /// Remove device `number` from the fleet: disconnect (its daisy-chain downstream
    /// falls off) and free the slot. The number is TOMBSTONED — never reused, so the
    /// surviving devices keep theirs — and every later operation on it errors. Removal
    /// drops the device's flash: save its state first if it matters.
    pub fn remove_device(&self, number: u32) -> anyhow::Result<()> {
        // Fleet mutations serialize on `handles` (see the field doc): without this, a
        // removal could tombstone a slot a concurrent add has published but not yet
        // built its handle for.
        let _handles = self.handles.lock().unwrap();
        let index = self.index_of(number)?;
        self.router
            .remove_device(index)
            .map_err(|e| self.slot_err(e))
    }

    /// Add a virtual device to the fleet at runtime and return its handle. Grows the router (a
    /// new powered-off slot), then plugs it into the chain TAIL via [`ChainRouter::connect`] so it
    /// enumerates to the coordinator like a real hot-plug. The device number is the next contiguous
    /// value (the fleet only ever grows). Always factory-fresh (the bundled digest);
    /// make it stale afterwards with [`SimDevice::set_firmware_digest`]. Factory-fresh
    /// means a NEW identity — minted from the boot's own entropy, so it cannot collide
    /// with a device already in the pool.
    pub fn add_device(&self) -> anyhow::Result<SimDevice> {
        let mut handles = self.handles.lock().unwrap();
        let index = handles.len();
        let (frames_sink, on_frame) = make_frame_sink();
        let spec = SlotSpec {
            seed: self.seed.wrapping_add(index as u64),
            digest: sim_firmware_bin().digest(),
            on_frame,
        };
        let router_index = self.router.add_device(spec).map_err(|e| self.slot_err(e))?;
        debug_assert_eq!(router_index, index, "pool and router device counts agree");
        self.fire_insertion_hook();
        let device = build_device(
            &self.router,
            self.allocate_number(index),
            index,
            frames_sink,
        );
        handles.push(device.clone());
        // Plug the new device into the tail so it powers on and enumerates to the
        // coordinator. Live because fleet mutations serialize on `handles` — but a
        // Result, not an expect: this state is externally observable, so a future
        // discipline slip should surface as an error, not a panic.
        self.router.connect(index).map_err(|e| self.slot_err(e))?;
        Ok(device)
    }

    /// The durable state of device `number` — seed, announced firmware digest, flash —
    /// as opaque saved-state bytes for [`add_device_from_saved_state`]. Requires the device
    /// DISCONNECTED (unplug it, then pocket it); errors on a connected or removed
    /// device. The device REMAINS in the fleet — pair with `remove_device` to model
    /// putting it in a drawer.
    pub fn save_device_state(&self, number: u32) -> anyhow::Result<Vec<u8>> {
        let index = self.index_of(number)?;
        Ok(self
            .router
            .save_device_state(index)
            .map_err(|e| self.slot_err(e))?
            .to_bytes())
    }

    /// Restore a device from [`save_device_state`] bytes as a NEW fleet member (fresh
    /// number — numbers are never reused) and plug it into the chain tail. Same seed +
    /// same flash means the SAME device identity, key shares intact; a saved state whose
    /// identity is already live in the pool is rejected (one device per identity).
    pub fn add_device_from_saved_state(&self, saved_state: Vec<u8>) -> anyhow::Result<SimDevice> {
        let decoded = frostsnap_virtual_device::DeviceSavedState::from_bytes(&saved_state)
            .map_err(|e| anyhow::anyhow!(e))?;
        let mut handles = self.handles.lock().unwrap();
        let index = handles.len();
        let (frames_sink, on_frame) = make_frame_sink();
        let router_index = self
            .router
            .add_device_from_saved_state(decoded, on_frame)
            .map_err(|e| self.slot_err(e))?;
        debug_assert_eq!(router_index, index, "pool and router device counts agree");
        self.fire_insertion_hook();
        let device = build_device(
            &self.router,
            self.allocate_number(router_index),
            router_index,
            frames_sink,
        );
        handles.push(device.clone());
        self.router
            .connect(router_index)
            .map_err(|e| self.slot_err(e))?;
        Ok(device)
    }

    /// The connected chain as 1-based device numbers, in order (first = the device on the
    /// coordinator USB port). Devices not listed are disconnected.
    #[frb(sync)]
    pub fn chain(&self) -> Vec<u32> {
        self.router
            .chain()
            .iter()
            .map(|&index| self.number_of(index))
            .collect()
    }

    /// Re-cable the chain to exactly these 1-based device numbers, in order. This is the
    /// single mutation behind connect, disconnect, and reorder. Invalid input (a `0`, an
    /// out-of-range number, a REMOVED number, or a duplicate) is rejected with an error,
    /// leaving the chain unchanged.
    #[frb(sync)]
    pub fn set_chain(&self, order: Vec<u32>) -> anyhow::Result<()> {
        let indices: Vec<usize> = order
            .iter()
            .map(|&n| self.index_of(n))
            .collect::<anyhow::Result<_>>()?;
        self.router.set_chain(indices).map_err(|e| self.slot_err(e))
    }
}

impl SimDevice {
    pub(crate) fn new(
        number: u32,
        index: usize,
        frames_sink: Arc<Mutex<Option<StreamSink<SimFrame>>>>,
        router: Arc<ChainRouter>,
    ) -> Self {
        Self {
            number,
            index,
            frames_sink,
            router,
        }
    }

    /// Connect this device (plug it into the tail of the chain) or disconnect it. Because
    /// the chain is a daisy chain, disconnecting a device also disconnects everything
    /// downstream of it (they were reached through it) — see [`ChainRouter::disconnect`].
    /// Use [`DevicePool::set_chain`] to reorder. Drives the sim tray's per-device toggle.
    #[frb(sync)]
    pub fn set_connected(&self, connected: bool) -> anyhow::Result<()> {
        let index = self.index;
        if connected {
            self.router.connect(index)
        } else {
            self.router.disconnect(index)
        }
        .map_err(|e| self.slot_err(e))
    }

    /// Set the firmware digest this device claims (64 hex chars) — any time,
    /// connected or not; the next announce (a replug's re-handshake, or the next
    /// boot) reports it. Any digest the coordinator doesn't recognize makes the
    /// app offer the bundled sim-image upgrade, so this is how a test invalidates
    /// an EXISTING device's firmware and forces the upgrade flow on it.
    #[frb(sync)]
    pub fn set_firmware_digest(&self, digest_hex: String) -> anyhow::Result<()> {
        let digest: frostsnap_coordinator::frostsnap_comms::Sha256Digest = digest_hex
            .parse()
            .map_err(|_| anyhow::anyhow!("firmware digest must be 64 hex chars"))?;
        self.router
            .set_firmware_digest(self.index, digest)
            .map_err(|e| self.slot_err(e))
    }

    /// Whether this device is currently in the chain — a state read, so a removed
    /// device is the tombstone error, never a stale `false`.
    #[frb(sync)]
    pub fn is_connected(&self) -> anyhow::Result<bool> {
        self.router
            .is_connected(self.index())
            .map_err(|e| self.slot_err(e))
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

    use frostsnap_virtual_device::{ByteChannel, HostEnd, VirtualSerial};
    use std::sync::mpsc;
    use std::time::Duration;

    // The pool's fleet mutations are ONE transaction: a remove released into an add's
    // insertion window (router slot published, Dart handle not yet built) must BLOCK on
    // `handles` until the add completes — not tombstone the in-flight slot, which would
    // panic the handle build or hand back a dead device.
    #[test]
    fn remove_cannot_interleave_with_an_add_in_flight() {
        let coord = HostEnd {
            rx: ByteChannel::new(),
            tx: ByteChannel::new(),
        };
        let serial = VirtualSerial::single("sim-0", coord.clone());
        let port = serial.connection();
        let router = Arc::new(ChainRouter::new(coord, port, vec![], vec![]));
        let pool = Arc::new(DevicePool::new(7, router, vec![]));

        let (tx, rx) = mpsc::channel::<()>();
        let tx = Mutex::new(tx);
        *pool.insertion_hook.lock().unwrap() = Some(Arc::new(move || {
            if std::thread::current().name() == Some("adder") {
                let _ = tx.lock().unwrap().send(());
                std::thread::sleep(Duration::from_millis(80));
            }
        }));

        let adder = std::thread::Builder::new()
            .name("adder".into())
            .spawn({
                let pool = pool.clone();
                move || pool.add_device()
            })
            .unwrap();

        rx.recv().unwrap();
        let remover = std::thread::Builder::new()
            .name("remover".into())
            .spawn({
                let pool = pool.clone();
                move || pool.remove_device(1)
            })
            .unwrap();

        let device = adder
            .join()
            .unwrap()
            .expect("the add must complete with a live handle");
        assert_eq!(device.number(), 1);
        // The remove then lands on the COMPLETED device — an ordered removal, not a race.
        remover
            .join()
            .unwrap()
            .expect("removal after the add must succeed");
        assert!(pool.devices().is_empty());
    }

    // The counter snapshot must linearize with fleet transactions: an add parked
    // between its router publish and its number allocation holds `handles`, so a
    // concurrent next-number read blocks until the add commits and reports the number
    // AFTER it — never the stale pre-add value a restart seed would then collide with.
    #[test]
    fn next_number_read_linearizes_with_an_add_in_flight() {
        let (pool, _serial) = empty_pool("sim-next-0");

        let (tx, rx) = mpsc::channel::<()>();
        let tx = Mutex::new(tx);
        *pool.insertion_hook.lock().unwrap() = Some(Arc::new(move || {
            if std::thread::current().name() == Some("adder") {
                let _ = tx.lock().unwrap().send(());
                std::thread::sleep(Duration::from_millis(80));
            }
        }));

        let adder = std::thread::Builder::new()
            .name("adder".into())
            .spawn({
                let pool = pool.clone();
                move || pool.add_device()
            })
            .unwrap();

        rx.recv().unwrap();
        let next = pool.next_device_number();
        assert_eq!(
            next, 2,
            "the read must observe the committed add, not its window"
        );
        assert_eq!(adder.join().unwrap().unwrap().number(), 1);
    }

    fn empty_pool(name: &str) -> (Arc<DevicePool>, VirtualSerial) {
        let coord = HostEnd {
            rx: ByteChannel::new(),
            tx: ByteChannel::new(),
        };
        let serial = VirtualSerial::single(name, coord.clone());
        let port = serial.connection();
        let router = Arc::new(ChainRouter::new(coord, port, vec![], vec![]));
        (Arc::new(DevicePool::new(7, router, vec![])), serial)
    }

    // The android restart shape: the relaunched APK boots its baked-in device (number 1),
    // restartApp removes it, then seeds the counter with the PREVIOUS generation's next.
    // The pool owns the number-to-slot allocation, so the seed's promise is exact — the
    // first add after seeding gets EXACTLY `next`, tombstones keep their own labels, and
    // no number ever names an unrelated slot (the old base+index+1 arithmetic handed the
    // seeded number back to the baked tombstone and shifted every later allocation).
    #[test]
    fn android_shaped_seed_allocates_exactly_next_and_labels_tombstones() {
        let (pool, _serial) = empty_pool("sim-seed-0");

        let baked = pool.add_device().expect("baked device");
        assert_eq!(baked.number(), 1);
        pool.remove_device(1).expect("converge to empty");
        pool.seed_next_number(3).expect("no live devices");

        let restored = pool.add_device().expect("first post-seed add");
        assert_eq!(restored.number(), 3, "the seed's promise is exact");
        assert_eq!(pool.next_device_number(), 4);
        assert_eq!(pool.chain(), vec![3]);

        // Tombstone and never-allocated numbers stay correctly labeled after seeding.
        assert_eq!(
            pool.remove_device(1).unwrap_err().to_string(),
            "device 1 was removed"
        );
        assert_eq!(
            baked.set_connected(true).unwrap_err().to_string(),
            "device 1 was removed"
        );
        assert_eq!(
            pool.remove_device(2).unwrap_err().to_string(),
            "no device 2 in this app generation"
        );
    }

    #[test]
    fn seed_rejects_live_devices_zero_and_number_reuse() {
        let (pool, _serial) = empty_pool("sim-seed-1");

        let device = pool.add_device().expect("live device");
        assert!(
            pool.seed_next_number(5)
                .unwrap_err()
                .to_string()
                .contains("no live devices"),
            "a live device blocks seeding"
        );

        pool.remove_device(device.number()).unwrap();
        assert!(
            pool.seed_next_number(0)
                .unwrap_err()
                .to_string()
                .contains("1-based"),
            "numbers are 1-based"
        );
        assert!(
            pool.seed_next_number(1)
                .unwrap_err()
                .to_string()
                .contains("would reuse"),
            "a tombstone keeps its label, so the seed must clear it"
        );
        pool.seed_next_number(2)
            .expect("above every allocated number");
        assert_eq!(pool.add_device().unwrap().number(), 2);
    }
}
