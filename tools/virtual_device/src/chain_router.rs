//! The sim's model of a daisy chain whose membership IS device power (sim-12 + sim-13).
//!
//! sim-10 wired a FIXED chain: device i's downstream was hard-crossed to device i+1's
//! upstream. sim-12 made the wiring a runtime CONFIG — an ordered list of device indices —
//! so the chain can be reordered and any device can connect independently. sim-13 adds the
//! load-bearing rule: **a device is powered iff it is in the chain.** The router therefore
//! OWNS one [`DeviceSlot`] per device — everything that must survive a power-cycle (the
//! stable screen/touch peripherals, the device-side link channels, and the preserved flash)
//! — and the order is literally the set of powered devices. There is no separate "is it
//! connected" vs "is it powered": they are the same fact, so they cannot disagree.
//!
//! A forwarding thread shuttles bytes along the CURRENT order each tick — coordinator <->
//! head.upstream, then each adjacent `prev.downstream <-> next.upstream`. Reconfiguring
//! ([`ChainRouter::set_chain`]) diffs membership: a device dropped from the order is POWERED
//! OFF (its thread stops, RAM gone, flash kept, screen darkened); a device added to the
//! order is POWERED ON (a fresh loop boots from the preserved flash, wired to the same
//! stable peripherals); a pure reorder leaves every thread running. The re-cable is
//! SURGICAL: only the links whose neighbor actually changed are reset, and the coordinator
//! USB port is re-enumerated only when the HEAD device changes — so disconnecting a tail or
//! middle device leaves the untouched devices (the head especially) running and registered,
//! exactly as real hardware hot-plug does (driven by each device's downstream-detect).
//! Nothing message-level changes — this is a byte-transport + power leaf; the
//! `frostsnap_embedded` relay is unchanged and simply runs over whatever topology the
//! router currently presents.

use crate::display::SharedFramebuffer;
use crate::firmware::FirmwareDigestCell;
use crate::flash::RamFlash;
use crate::observation::SimObservation;
use crate::serial::{pipe, ByteChannel, HostEnd, LinkGate};
use crate::thread::{spawn_device_thread, DeviceHandles, DeviceThread, FrameSink};
use crate::touch::TouchQueue;
use crate::virtual_serial::PortConnection;
use frostsnap_comms::Sha256Digest;
use frostsnap_core::DeviceId;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

/// How often the forwarding loop shuttles bytes. Tight, so the chain's hop-by-hop
/// magic-byte handshake (~100 ms cadence on the coordinator) is never starved by the
/// router adding latency between devices.
const TICK: Duration = Duration::from_millis(1);

/// How long the coordinator port is held down when the HEAD device changes. The USB port is
/// bound to the head's upstream, so swapping the head is modelled as unplugging the port and
/// plugging the new head in: the coordinator re-enumerates from that device. Long enough that
/// the coordinator's port poll observes the gap. (Non-head changes don't pulse — see
/// [`ChainRouter::set_chain`].)
const RECABLE_DOWN: Duration = Duration::from_millis(150);

/// The per-device build inputs that don't change across power-cycles. The router turns each
/// into a [`DeviceSlot`] (allocating that device's stable peripherals + links) and boots it.
pub struct SlotSpec {
    pub seed: u64,
    pub digest: Sha256Digest,
    pub on_frame: FrameSink,
}

/// The router-side endpoints for one device: the host ends of its upstream and downstream
/// links (the slot holds the matching device-side `PipeByteIo`s — clones of the same
/// `Arc`-backed channels), plus the downstream-detect flag the router drives (true iff the
/// device has a successor in the current order). The device thread reads the same flag.
struct DeviceLink {
    up: HostEnd,
    down: HostEnd,
    downstream_present: LinkGate,
}

/// One device's power state. ON owns the running thread; OFF holds the preserved flash
/// (NVS). Exactly one is present — chain membership and power are the same fact.
enum Power {
    On(DeviceThread),
    Off(RamFlash),
}

/// Everything for one device that SURVIVES a power-cycle. The [`DeviceHandles`] (screen,
/// touch surface, link channels, frame sink) are STABLE — handed unchanged to each
/// freshly-spawned thread, so the long-lived `SimDevice` handles keep driving
/// whatever thread is powered; the flash is PRESERVED across the cycle; only the loop/UI/RAM
/// is volatile (rebuilt each power-on). The device id is stable (seed + flash derived),
/// captured on the first boot.
struct DeviceSlot {
    seed: u64,
    /// The device's single firmware-identity record (see [`FirmwareDigestCell`]);
    /// shared with whatever thread is powered, and settable from outside at any
    /// time — the next announce reports it.
    digest: FirmwareDigestCell,
    handles: DeviceHandles,
    device_id: DeviceId,
    power: Power,
}

impl DeviceSlot {
    /// Power on: drain any touches queued while off, then spawn a fresh loop wired to the
    /// stable handles and booting from the preserved flash. No-op if already on.
    fn power_on(&mut self) {
        let flash = match std::mem::replace(&mut self.power, Power::Off(RamFlash::new())) {
            Power::Off(flash) => flash,
            already_on => {
                self.power = already_on;
                return;
            }
        };
        // A fresh boot must not replay touches that arrived while the device was off.
        self.handles.touch.clear();
        let (device_id, thread) =
            spawn_device_thread(self.seed, self.digest.clone(), self.handles.clone(), flash);
        // The id is stable across cycles (seed + flash derived); keep it in sync anyway.
        self.device_id = device_id;
        self.power = Power::On(thread);
    }

    /// Power off: stop the thread (RAM gone), keep its flash here (NVS preserved), and
    /// darken the screen — clear the framebuffer and push one blank frame so the tray and
    /// `screen` show a dark, powered-off device rather than the last live frame. No-op if
    /// already off.
    fn power_off(&mut self) {
        let thread = match std::mem::replace(&mut self.power, Power::Off(RamFlash::new())) {
            Power::On(thread) => thread,
            already_off => {
                self.power = already_off;
                return;
            }
        };
        let flash = thread.power_off();
        self.handles.framebuffer.clear();
        let (w, h, rgba) = self.handles.framebuffer.export_rgba();
        (self.handles.on_frame)(w, h, rgba);
        self.power = Power::Off(flash);
    }
}

/// What sits on one side of a device's link in a given chain order. Comparing a device's
/// old vs new neighbor tells us whether that link physically changed and must be re-cabled.
#[derive(PartialEq)]
enum Neighbor {
    /// The coordinator USB port (only an upstream — the head device).
    Coord,
    /// The end of the chain (only a downstream — the tail device).
    End,
    /// An adjacent device by index.
    Device(usize),
    /// The device is not in the chain (powered off).
    Off,
}

struct RouterState {
    /// The coordinator endpoint (a clone of what `VirtualSerial::single` drives): the
    /// coordinator writes `coord.tx` and reads `coord.rx`, so the router drains `coord.tx`
    /// (coordinator output) and pushes `coord.rx` (toward the coordinator).
    coord: HostEnd,
    /// The coordinator port's presence; pulsed down only when the HEAD device changes, to
    /// re-enumerate the device now on the USB port.
    port: PortConnection,
    /// When to bring the port back up after a re-cable (`None` = up / no pending pulse).
    reconnect_at: Option<Instant>,
    /// One entry per device ever added; a removed device leaves a tombstone (`None`) so
    /// indices — and therefore device numbers — never shift or get reused.
    links: Vec<Option<DeviceLink>>,
    /// Device indices in chain order; `order[0]` is the head on the coordinator port.
    order: Vec<usize>,
}

impl RouterState {
    /// A device's upstream/downstream neighbors in `order` (`Off` if not in the chain).
    fn neighbors(order: &[usize], device: usize) -> (Neighbor, Neighbor) {
        match order.iter().position(|&d| d == device) {
            None => (Neighbor::Off, Neighbor::Off),
            Some(pos) => {
                let up = if pos == 0 {
                    Neighbor::Coord
                } else {
                    Neighbor::Device(order[pos - 1])
                };
                let down = if pos + 1 == order.len() {
                    Neighbor::End
                } else {
                    Neighbor::Device(order[pos + 1])
                };
                (up, down)
            }
        }
    }

    /// Re-cable from `previous` to the current `self.order`, disturbing ONLY what changed:
    /// refresh every device's downstream-detect, and clear a link's channels (dropping stale
    /// in-flight bytes so the firmware re-handshakes that hop) only when that device's
    /// neighbor on that side actually changed. A device whose upstream and downstream are
    /// unchanged is left completely alone — its session keeps running. The coordinator
    /// channels are cleared only when the head device changed (see [`ChainRouter::set_chain`]
    /// for the matching port pulse); an unchanged head keeps its coordinator session.
    fn recompute(&mut self, previous: &[usize]) {
        for (idx, link) in self.links.iter().enumerate() {
            let Some(link) = link else { continue };
            let (old_up, old_down) = Self::neighbors(previous, idx);
            let (new_up, new_down) = Self::neighbors(&self.order, idx);
            link.downstream_present
                .set_connected(matches!(new_down, Neighbor::Device(_)));
            if old_up != new_up {
                link.up.rx.clear();
                link.up.tx.clear();
            }
            if old_down != new_down {
                link.down.rx.clear();
                link.down.tx.clear();
            }
        }
        if previous.first() != self.order.first() {
            self.coord.rx.clear();
            self.coord.tx.clear();
        }
    }

    /// One forwarding tick over the current order. Each channel is handled exactly once
    /// (no double-drain that could discard a byte a device wrote between steps): spliced
    /// outputs are forwarded; un-spliced outputs (the tail's downstream, every off-chain
    /// device) are drained and discarded so they can't grow or leave stale bytes.
    fn forward_once(&self, buf: &mut Vec<u8>) {
        let drain_to = |from: &HostEnd, to_tx: &ByteChannel, buf: &mut Vec<u8>| {
            buf.clear();
            from.rx.drain(buf);
            if !buf.is_empty() {
                to_tx.push(buf);
            }
        };

        // coordinator <-> head
        match self.order.first() {
            Some(&head) => {
                buf.clear();
                self.coord.tx.drain(buf);
                if !buf.is_empty() {
                    self.link(head).up.tx.push(buf);
                }
                drain_to(&self.link(head).up, &self.coord.rx, buf);
            }
            None => {
                // No head: discard whatever the coordinator emits.
                buf.clear();
                self.coord.tx.drain(buf);
            }
        }

        // adjacent pairs: prev.downstream <-> next.upstream
        for pair in self.order.windows(2) {
            let (a, b) = (pair[0], pair[1]);
            // a's downstream output -> b's upstream input
            buf.clear();
            self.link(a).down.rx.drain(buf);
            if !buf.is_empty() {
                self.link(b).up.tx.push(buf);
            }
            // b's upstream output -> a's downstream input
            buf.clear();
            self.link(b).up.rx.drain(buf);
            if !buf.is_empty() {
                self.link(a).down.tx.push(buf);
            }
        }

        // the tail has no child: discard its downstream output
        if let Some(&tail) = self.order.last() {
            buf.clear();
            self.link(tail).down.rx.drain(buf);
        }

        // off-chain devices: discard both outputs (their inputs are never fed -> powered off)
        for (idx, link) in self.links.iter().enumerate() {
            let Some(link) = link else { continue };
            if !self.order.contains(&idx) {
                buf.clear();
                link.up.rx.drain(buf);
                buf.clear();
                link.down.rx.drain(buf);
            }
        }
    }

    /// The link of a device in the CURRENT order — live by invariant (`set_chain`
    /// rejects removed indices and removal tombstones only after leaving the order).
    fn link(&self, index: usize) -> &DeviceLink {
        self.links[index]
            .as_ref()
            .expect("order contains only live devices")
    }
}

/// A slot-addressed failure. The router speaks slot INDICES — it has no notion of the
/// app pool's logical device numbers — so number-aware callers translate variants into
/// number-labeled messages instead of parsing strings.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SlotError {
    OutOfRange { index: usize, count: usize },
    Removed { index: usize },
    ListedTwice { index: usize },
    Connected { index: usize },
    IdentityInPool { id: DeviceId },
}

impl core::fmt::Display for SlotError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            SlotError::OutOfRange { index, count } => {
                write!(f, "no device slot {index} (have {count})")
            }
            SlotError::Removed { index } => write!(f, "device slot {index} was removed"),
            SlotError::ListedTwice { index } => {
                write!(f, "device slot {index} listed more than once")
            }
            SlotError::Connected { index } => {
                write!(
                    f,
                    "device slot {index} is connected; unplug it before saving its state"
                )
            }
            SlotError::IdentityInPool { id } => {
                write!(f, "a device with identity {id} is already in the pool")
            }
        }
    }
}

impl std::error::Error for SlotError {}

/// Owns the device power slots and the byte-forwarding thread. Dropping it stops the
/// forwarding thread and then drops the slots, which powers off (stops + joins) every
/// running device thread.
pub struct ChainRouter {
    stop: Arc<AtomicBool>,
    join: Option<JoinHandle<()>>,
    state: Arc<Mutex<RouterState>>,
    /// One slot per device ever added (a removed device leaves a `None` tombstone, so
    /// indices never shift or get reused). Held by `set_chain` across the WHOLE mutation
    /// (so it serializes concurrent re-cables — see `set_chain`) and by the
    /// construction-time accessors. Never taken by the fast forwarding loop, so a slow
    /// thread join on power-off never stalls byte forwarding.
    slots: Mutex<Vec<Option<DeviceSlot>>>,
    /// Test-only seam: a hook `set_chain` invokes at its publish point (still holding
    /// `slots`), letting a test simulate a preemption there and prove a concurrent caller
    /// cannot interleave.
    #[cfg(test)]
    publish_hook: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
}

impl ChainRouter {
    /// Build the router from one [`SlotSpec`] per device and the initial chain `order`
    /// (device indices; `order[0]` is the head). Allocates each device's stable handles,
    /// boots every device once to learn its stable id, then powers off any device not in
    /// `order`. Pass a clone of the `HostEnd` and the `PortConnection` of the same
    /// `VirtualSerial::single` as `coord`/`port`.
    pub fn new(
        coord: HostEnd,
        port: PortConnection,
        specs: Vec<SlotSpec>,
        order: Vec<usize>,
    ) -> Self {
        let mut slots: Vec<Option<DeviceSlot>> = Vec::with_capacity(specs.len());
        let mut links: Vec<Option<DeviceLink>> = Vec::with_capacity(specs.len());
        for spec in specs {
            // Boot once to learn the (stable) device id; `order` below powers off any
            // device that shouldn't start connected.
            let (slot, link) = Self::build_slot(spec);
            slots.push(Some(slot));
            links.push(Some(link));
        }

        // Devices not in the initial order start powered off (their flash is preserved).
        for (idx, slot) in slots.iter_mut().enumerate() {
            if !order.contains(&idx) {
                slot.as_mut().expect("just built").power_off();
            }
        }

        let mut initial = RouterState {
            coord,
            port,
            reconnect_at: None,
            links,
            order,
        };
        if initial.order.is_empty() {
            initial.port.set_connected(false);
        }
        // No previous chain at construction: every in-chain device is a fresh cable-up.
        initial.recompute(&[]);
        let state = Arc::new(Mutex::new(initial));

        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = stop.clone();
        let loop_state = state.clone();
        let join = thread::spawn(move || {
            let mut buf = Vec::new();
            while !thread_stop.load(Ordering::Relaxed) {
                {
                    let mut state = loop_state.lock().unwrap();
                    // Bring the port back up once the re-cable down-time has elapsed.
                    if let Some(at) = state.reconnect_at {
                        if Instant::now() >= at {
                            state.port.set_connected(true);
                            state.reconnect_at = None;
                        }
                    }
                    state.forward_once(&mut buf);
                }
                thread::sleep(TICK);
            }
        });

        Self {
            stop,
            join: Some(join),
            state,
            slots: Mutex::new(slots),
            #[cfg(test)]
            publish_hook: Mutex::new(None),
        }
    }

    /// Build one device's power slot + its router-side link from a [`SlotSpec`]: allocate
    /// the stable peripherals (screen/touch) and the upstream/downstream pipe pair, then
    /// boot once to learn the (stable) device id. The device starts powered ON; the caller
    /// decides final power (the constructor powers off any device not in the initial order;
    /// [`add_device`](Self::add_device) powers a newly-added device off until it's connected).
    fn build_slot(spec: SlotSpec) -> (DeviceSlot, DeviceLink) {
        Self::build_slot_from(spec, RamFlash::new())
    }

    /// [`build_slot`](Self::build_slot), booting from the given flash instead of a fresh
    /// one — the restore-from-saved-state construction (same seed + same flash ⇒ the same
    /// device identity, shares intact).
    fn build_slot_from(spec: SlotSpec, flash: RamFlash) -> (DeviceSlot, DeviceLink) {
        let (up_io, up_host) = pipe();
        let (down_io, down_host) = pipe();
        let downstream_present = LinkGate::new(false);
        let handles = DeviceHandles {
            upstream_io: up_io,
            downstream_io: down_io,
            framebuffer: SharedFramebuffer::new(),
            touch: TouchQueue::new(),
            observation: SimObservation::new(),
            downstream_present: Some(downstream_present.clone()),
            on_frame: spec.on_frame,
        };
        let digest = FirmwareDigestCell::new(spec.digest);
        let (device_id, thread) =
            spawn_device_thread(spec.seed, digest.clone(), handles.clone(), flash);
        let slot = DeviceSlot {
            seed: spec.seed,
            digest,
            handles,
            device_id,
            power: Power::On(thread),
        };
        let link = DeviceLink {
            up: up_host,
            down: down_host,
            downstream_present,
        };
        (slot, link)
    }

    /// Append a new device to the fleet at runtime and return its index (the new highest
    /// index — the fleet only ever grows, so indices stay contiguous). The device starts
    /// DISCONNECTED (powered off, not in the chain); plug it in with
    /// [`connect`](Self::connect). The slot+link are built OUTSIDE the locks (the boot-for-id
    /// is slow), then pushed while holding `slots` THEN `state` — the same lock order as
    /// [`set_chain`](Self::set_chain), so a concurrent re-cable serializes here and the
    /// `slots.len() == links.len()` invariant the forwarding loop relies on stays atomic. The
    /// forwarding loop drains the new (off-chain) device's channels until it is connected.
    pub fn add_device(&self, spec: SlotSpec) -> Result<usize, SlotError> {
        let (slot, link) = Self::build_slot(spec);
        self.insert_slot(slot, link)
    }

    /// The ONE insertion boundary, shared by fresh adds and saved-state restores: power
    /// the built slot off, then — under the locks — enforce one-device-per-identity and
    /// publish at a fresh index. The identity check lives HERE because a fresh add can
    /// collide too: restoring another session's blank device occupies a seed a later
    /// fresh allocation would reuse (same seed + same blank flash ⇒ the same DeviceId).
    /// A collision is a clear error, never a silent duplicate.
    fn insert_slot(&self, mut slot: DeviceSlot, link: DeviceLink) -> Result<usize, SlotError> {
        slot.power_off();
        let new_id = slot.device_id;
        let mut slots = self.slots.lock().unwrap();
        if slots
            .iter()
            .flatten()
            .any(|existing| existing.device_id == new_id)
        {
            return Err(SlotError::IdentityInPool { id: new_id });
        }
        let mut state = self.state.lock().unwrap();
        let index = slots.len();
        slots.push(Some(slot));
        state.links.push(Some(link));
        Ok(index)
    }

    /// Re-cable the chain to `order` (device indices in chain order). Diffs membership
    /// against the current chain and applies POWER accordingly: a device removed from the
    /// order is powered off (thread stopped, flash kept, screen darkened); a device added
    /// is powered on (a fresh loop boots from the preserved flash); a device that stays
    /// (pure reorder) keeps its thread running. Then re-derives the splices +
    /// downstream-detect flags and pulses the coordinator port down so the bus fully
    /// re-enumerates over the new topology. The port comes back up after [`RECABLE_DOWN`].
    ///
    /// Validates at this shared boundary (all callers go through here): every index must
    /// be `< device_count` and appear at most once. An invalid `order` is rejected with
    /// `Err` and the chain — and all device power — is left untouched.
    pub fn set_chain(&self, order: Vec<usize>) -> Result<(), SlotError> {
        let mut slots = self.slots.lock().unwrap();
        self.apply_order_locked(&mut slots, order)
    }

    /// The ONE locked chain mutation, shared by every mutator (`set_chain`, `connect`,
    /// `disconnect`, `remove_device`): validate, diff power, publish. The caller passes
    /// its `slots` guard — held across the WHOLE mutation, so the diff baseline and the
    /// published order are one atomic step AND a caller can compose further steps
    /// (removal's tombstone) into the same transaction. Two concurrent mutators
    /// serialize on `slots`; the fast forwarding loop never takes it (it reads
    /// `state`), so holding it across the thread joins below does not stall byte
    /// forwarding.
    fn apply_order_locked(
        &self,
        slots: &mut [Option<DeviceSlot>],
        order: Vec<usize>,
    ) -> Result<(), SlotError> {
        let count = slots.len();
        let mut seen = vec![false; count];
        for &index in &order {
            if index >= count {
                return Err(SlotError::OutOfRange { index, count });
            }
            if slots[index].is_none() {
                return Err(SlotError::Removed { index });
            }
            if std::mem::replace(&mut seen[index], true) {
                return Err(SlotError::ListedTwice { index });
            }
        }

        // Diff membership: removed -> power off, added -> power on. (A device present in
        // both orders is a pure reorder — leave its thread running.)
        let current = self.state.lock().unwrap().order.clone();
        for &index in &current {
            if !order.contains(&index) {
                slots[index].as_mut().expect("was in the order").power_off();
            }
        }
        for &index in &order {
            if !current.contains(&index) {
                slots[index].as_mut().expect("validated live").power_on();
            }
        }

        // Test seam: simulate a preemption at the publish point — still holding `slots` —
        // so a test can assert a concurrent caller cannot interleave here.
        #[cfg(test)]
        {
            let hook = self.publish_hook.lock().unwrap().clone();
            if let Some(hook) = hook {
                hook();
            }
        }

        // Pulse the coordinator port ONLY if the head changed: the USB port is bound to the
        // head's upstream, so a head swap must re-enumerate, but an unchanged head keeps its
        // coordinator session. Downstream add/remove is handled by the firmware's
        // downstream-detect (recompute refreshes it), so untouched devices never restart.
        // The port models the head's CABLE, so with no head there is no port: an emptied
        // chain stays down (no reconnect scheduled — also cancelling any pending pulse)
        // until a head returns. Bringing it back up on a timer with nothing behind it would
        // hand the coordinator a live-looking port whose reads can only ever time out.
        let head_changed = order.first() != current.first();
        let mut state = self.state.lock().unwrap();
        state.order = order;
        state.recompute(&current);
        if head_changed {
            state.port.set_connected(false);
            state.reconnect_at = state.order.first().map(|_| Instant::now() + RECABLE_DOWN);
        }
        Ok(())
    }

    /// The current chain order (device indices; `[0]` is the head). These are exactly the
    /// powered-on devices, in chain order.
    pub fn chain(&self) -> Vec<usize> {
        self.state.lock().unwrap().order.clone()
    }

    /// Ensure `index` names a live slot, or return the tombstone/range error.
    fn ensure_live(slots: &[Option<DeviceSlot>], index: usize) -> Result<(), SlotError> {
        match slots.get(index) {
            Some(Some(_)) => Ok(()),
            Some(None) => Err(SlotError::Removed { index }),
            None => Err(SlotError::OutOfRange {
                index,
                count: slots.len(),
            }),
        }
    }

    /// Connect `device` by plugging it into the TAIL of the daisy chain (a new device joins
    /// at the end). Idempotent when already connected; errs on a removed/unknown device.
    /// The single source of truth for "connect a device", used by every surface (FRB
    /// `SimDevice`, the device socket, the tray). Reads the current order under the same
    /// `slots` hold as the mutation, so two concurrent connects cannot both append.
    pub fn connect(&self, device: usize) -> Result<(), SlotError> {
        let mut slots = self.slots.lock().unwrap();
        Self::ensure_live(&slots, device)?;
        let mut order = self.state.lock().unwrap().order.clone();
        if order.contains(&device) {
            return Ok(());
        }
        order.push(device);
        self.apply_order_locked(&mut slots, order)
    }

    /// Disconnect `device` AND everything downstream of it — pulling a device out of a daisy
    /// chain cuts power and comms to every device below it (they were reached, and powered,
    /// through it). Idempotent when not connected; errs on a removed/unknown device. The
    /// single source of truth for "disconnect a device", used by every surface.
    pub fn disconnect(&self, device: usize) -> Result<(), SlotError> {
        let mut slots = self.slots.lock().unwrap();
        Self::ensure_live(&slots, device)?;
        let order = self.state.lock().unwrap().order.clone();
        match order.iter().position(|&d| d == device) {
            None => Ok(()),
            Some(pos) => self.apply_order_locked(&mut slots, order[..pos].to_vec()),
        }
    }

    /// Remove device `index` from the fleet: disconnect it (daisy-chain semantics —
    /// everything downstream falls off with it) and free its slot. The index becomes a
    /// TOMBSTONE — never reused, so surviving devices keep their numbers — and every
    /// later operation on it errors. The freed slot's thread is joined (power-off) and
    /// its flash dropped: removal is the device leaving the bench, not going in a
    /// drawer — save its state first if it matters.
    ///
    /// One `slots`-held transaction end to end: the un-cable and the tombstone cannot
    /// interleave with a concurrent connect/re-cable, which would otherwise republish
    /// the device between them and leave the forwarding loop dereferencing a dead link.
    pub fn remove_device(&self, index: usize) -> Result<(), SlotError> {
        let mut slots = self.slots.lock().unwrap();
        Self::ensure_live(&slots, index)?;
        let order = self.state.lock().unwrap().order.clone();
        if let Some(pos) = order.iter().position(|&d| d == index) {
            self.apply_order_locked(&mut slots, order[..pos].to_vec())?;
        }
        slots[index] = None;
        self.state.lock().unwrap().links[index] = None;
        Ok(())
    }

    /// The durable state of device `index` — seed, announced digest, flash. Requires the
    /// device DISCONNECTED: a running slot's flash lives in its thread ("unplug it, then
    /// pocket it" is the physical action anyway), and membership IS power, so a
    /// disconnected device's flash is parked in the slot. Atomic: liveness, membership,
    /// and the flash clone happen under one slots-then-state hold.
    pub fn save_device_state(&self, index: usize) -> Result<crate::DeviceSavedState, SlotError> {
        let slots = self.slots.lock().unwrap();
        Self::ensure_live(&slots, index)?;
        if self.state.lock().unwrap().order.contains(&index) {
            return Err(SlotError::Connected { index });
        }
        let slot = slots[index].as_ref().expect("just checked");
        let Power::Off(flash) = &slot.power else {
            unreachable!("a disconnected device is powered off (membership IS power)");
        };
        Ok(crate::DeviceSavedState {
            seed: slot.seed,
            digest: slot.digest.get(),
            flash: flash.clone(),
        })
    }

    /// Restore a device from a [`DeviceSavedState`](crate::DeviceSavedState) as a NEW fleet
    /// member (fresh index — numbers are never reused) and return its index. Same seed +
    /// same flash ⇒ the SAME device identity, so this REJECTS a saved state whose identity
    /// is already live in the pool: the physical model has one device per identity, and a
    /// duplicate would collide in every coordinator map keyed by it. The boot-for-id runs
    /// outside the locks (it is slow), like [`add_device`](Self::add_device); the
    /// duplicate check and the push are one locked step, and a losing racer is rejected.
    pub fn add_device_from_saved_state(
        &self,
        saved: crate::DeviceSavedState,
        on_frame: FrameSink,
    ) -> Result<usize, SlotError> {
        let spec = SlotSpec {
            seed: saved.seed,
            digest: saved.digest,
            on_frame,
        };
        let (slot, link) = Self::build_slot_from(spec, saved.flash);
        self.insert_slot(slot, link)
    }

    /// Whether device `index` is a live (non-removed) member of the fleet.
    pub fn is_live(&self, index: usize) -> bool {
        matches!(self.slots.lock().unwrap().get(index), Some(Some(_)))
    }

    /// Whether device `index` is currently in the chain — a STATE read, so a removed
    /// device is the tombstone error, not `false` (which would claim "exists,
    /// disconnected"). Liveness and membership are read under the same slots-then-state
    /// hold every mutation uses, so the answer can't straddle a concurrent removal.
    pub fn is_connected(&self, index: usize) -> Result<bool, SlotError> {
        let slots = self.slots.lock().unwrap();
        Self::ensure_live(&slots, index)?;
        Ok(self.state.lock().unwrap().order.contains(&index))
    }

    /// The stable id of device `index` (same across power-cycles). Used to build the
    /// long-lived `SimDevice` handles at construction.
    pub fn device_id(&self, index: usize) -> DeviceId {
        self.with_slot(index, "device_id", |slot| slot.device_id)
    }

    /// Set device `index`'s firmware digest — powered or not; the next announce
    /// (a replug's re-handshake, or the next boot) reports it. See
    /// [`FirmwareDigestCell`] for the writer semantics.
    pub fn set_firmware_digest(&self, index: usize, digest: Sha256Digest) -> Result<(), SlotError> {
        let slots = self.slots.lock().unwrap();
        Self::ensure_live(&slots, index)?;
        slots[index]
            .as_ref()
            .expect("just checked")
            .digest
            .set(digest);
        Ok(())
    }

    /// Read a LIVE slot, atomically: liveness check and resource read happen under one
    /// `slots` hold, so a concurrent removal can only land before (clear error) or after
    /// (the cloned `Arc`-backed resource stays safely inert) — never between as a panic.
    fn with_live_slot<T>(
        &self,
        index: usize,
        read: impl FnOnce(&DeviceSlot) -> T,
    ) -> Result<T, SlotError> {
        let slots = self.slots.lock().unwrap();
        Self::ensure_live(&slots, index)?;
        Ok(read(slots[index].as_ref().expect("just checked")))
    }

    /// Read a LIVE slot. Callers must gate on [`is_live`](Self::is_live) — driving a
    /// removed device is a caller bug, named by `what` in the panic.
    fn with_slot<T>(&self, index: usize, what: &str, read: impl FnOnce(&DeviceSlot) -> T) -> T {
        read(
            self.slots.lock().unwrap()[index]
                .as_ref()
                .unwrap_or_else(|| panic!("{what}: device slot {index} was removed")),
        )
    }

    /// A clone of device `index`'s STABLE framebuffer handle — the same screen surface
    /// every power-on draws into, so a handle captured once keeps showing the live (or
    /// darkened-off) device across reboots.
    pub fn framebuffer(&self, index: usize) -> Result<SharedFramebuffer, SlotError> {
        self.with_live_slot(index, |slot| slot.handles.framebuffer.clone())
    }

    /// A clone of device `index`'s STABLE touch queue — every power-on reads from it, so a
    /// handle captured once keeps driving whatever thread is currently powered.
    pub fn touch(&self, index: usize) -> Result<TouchQueue, SlotError> {
        self.with_live_slot(index, |slot| slot.handles.touch.clone())
    }

    /// A clone of device `index`'s STABLE screen observation — every power-on publishes
    /// into it (and clears it on power-off), so a handle captured once keeps observing
    /// whatever thread is currently powered.
    pub fn observation(&self, index: usize) -> Result<SimObservation, SlotError> {
        self.with_live_slot(index, |slot| slot.handles.observation.clone())
    }

    /// Whether device `index` currently has a running thread (powered on). The sim-13
    /// invariant is that this equals `chain().contains(&index)`.
    #[cfg(test)]
    fn is_powered(&self, index: usize) -> bool {
        matches!(
            self.slots.lock().unwrap()[index],
            Some(DeviceSlot {
                power: Power::On(_),
                ..
            })
        )
    }

    /// Install the publish-point hook (see [`ChainRouter::publish_hook`]).
    #[cfg(test)]
    fn set_publish_hook(&self, hook: Arc<dyn Fn() + Send + Sync>) {
        *self.publish_hook.lock().unwrap() = Some(hook);
    }
}

impl Drop for ChainRouter {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
        // `slots` drops next: each powered-on slot joins its device thread.
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::firmware::SimFirmware;
    use crate::{Point, TouchEvent, TouchGesture, VirtualSerial};
    use frostsnap_coordinator::{DeviceChange, UsbSerialManager};
    use frostsnap_core::DeviceId;
    use std::collections::HashSet;
    use std::sync::atomic::AtomicUsize;
    use std::time::{Duration, Instant};

    fn host() -> HostEnd {
        HostEnd {
            rx: ByteChannel::new(),
            tx: ByteChannel::new(),
        }
    }

    /// Whether the framebuffer is entirely black — the powered-off look. A booted device
    /// renders non-black UI content, so this distinguishes off (dark) from on (rendered).
    fn is_dark(fb: &SharedFramebuffer) -> bool {
        let (_, _, rgba) = fb.export_rgba();
        rgba.chunks(4)
            .all(|px| px[0] == 0 && px[1] == 0 && px[2] == 0)
    }

    /// Block until `cond` holds or the deadline passes; returns whether it held.
    fn wait_until(cond: impl Fn() -> bool) -> bool {
        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline {
            if cond() {
                return true;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        cond()
    }

    fn specs(count: u64, base_seed: u64) -> Vec<SlotSpec> {
        (0..count)
            .map(|i| SlotSpec {
                seed: base_seed + i,
                digest: SimFirmware::PLACEHOLDER_DIGEST,
                on_frame: Arc::new(|_, _, _| {}),
            })
            .collect()
    }

    // The router presents a runtime-reconfigurable chain over ONE coordinator port, and
    // chain membership IS power: [0,1,2] registers all three via relay; set_chain([1])
    // POWERS OFF 0 and 2 (their threads stop) leaving ONLY device index 1 (proving a device
    // connects independently / becomes the head); and restoring the chain POWERS THEM BACK
    // ON (a fresh boot from preserved flash) so they re-register with their STABLE ids.
    #[test]
    fn router_chain_registers_then_reconfigures_over_one_port() {
        let coord = host();
        let serial = VirtualSerial::single("sim-device-0", coord.clone());
        let port = serial.connection();

        let router = ChainRouter::new(coord, port, specs(3, 10), vec![0, 1, 2]);
        let ids: Vec<DeviceId> = (0..3).map(|i| router.device_id(i)).collect();
        assert_eq!(
            ids.iter().collect::<HashSet<_>>().len(),
            3,
            "distinct device ids"
        );

        let mut manager = UsbSerialManager::new(Box::new(serial));

        // Pump the manager (naming devices as asked) into `live` until `pred` holds.
        let mut live: HashSet<DeviceId> = HashSet::new();
        let pump = |manager: &mut UsbSerialManager,
                    live: &mut HashSet<DeviceId>,
                    pred: &dyn Fn(&HashSet<DeviceId>) -> bool|
         -> bool {
            let deadline = Instant::now() + Duration::from_secs(90);
            while Instant::now() < deadline {
                for change in manager.poll_ports() {
                    match change {
                        DeviceChange::NeedsName { id } => {
                            manager.accept_device_name(id, "Sim".to_string());
                        }
                        DeviceChange::Registered { id, .. } => {
                            live.insert(id);
                        }
                        DeviceChange::Disconnected { id } => {
                            live.remove(&id);
                        }
                        _ => {}
                    }
                }
                if pred(live) {
                    return true;
                }
                std::thread::sleep(Duration::from_millis(5));
            }
            false
        };

        let all: HashSet<DeviceId> = ids.iter().copied().collect();
        assert!(
            pump(&mut manager, &mut live, &|s| *s == all),
            "all three chained devices register over one port; saw {live:?}"
        );

        // Re-cable to just device index 1: 0 and 2 power off; only 1 stays (independent
        // connect / head).
        router.set_chain(vec![1]).unwrap();
        assert!(
            pump(&mut manager, &mut live, &|s| s.len() == 1
                && s.contains(&ids[1])),
            "set_chain([1]) leaves only device index 1; saw {live:?}"
        );

        // Re-cable to a REORDERED two-device chain (head=2 -> 0): 2 and 0 power back on
        // from preserved flash and register with their STABLE ids over an adjacency that
        // never existed in the original order.
        router.set_chain(vec![2, 0]).unwrap();
        assert!(
            pump(&mut manager, &mut live, &|s| s.len() == 2
                && s.contains(&ids[2])
                && s.contains(&ids[0])),
            "set_chain([2,0]) registers exactly devices 2 and 0; saw {live:?}"
        );

        // Re-cable to a REORDERED full chain (2 -> 0 -> 1): device 1 powers back on and
        // all three re-register over the reordered adjacencies (2->0 and 0->1).
        router.set_chain(vec![2, 0, 1]).unwrap();
        assert!(
            pump(&mut manager, &mut live, &|s| *s == all),
            "set_chain([2,0,1]) re-registers all three over the reordered chain; saw {live:?}"
        );
    }

    // Runtime growth (runtime-add-devices): add_device appends a device to a LIVE fleet
    // without disturbing the running chain. The new device starts off-chain (powered off,
    // not enumerated) with a fresh distinct id; connecting it plugs it into the TAIL, where
    // it boots and registers over the existing chain while the head and the other devices
    // keep their sessions — exactly the hot-plug a real daisy chain does.
    #[test]
    fn add_device_grows_fleet_and_connects_at_tail() {
        let coord = host();
        let serial = VirtualSerial::single("sim-device-0", coord.clone());
        let port = serial.connection();

        let router = ChainRouter::new(coord, port, specs(2, 60), vec![0, 1]);
        let mut ids: Vec<DeviceId> = (0..2).map(|i| router.device_id(i)).collect();

        let mut manager = UsbSerialManager::new(Box::new(serial));
        let mut live: HashSet<DeviceId> = HashSet::new();
        let pump = |manager: &mut UsbSerialManager,
                    live: &mut HashSet<DeviceId>,
                    pred: &dyn Fn(&HashSet<DeviceId>) -> bool|
         -> bool {
            let deadline = Instant::now() + Duration::from_secs(90);
            while Instant::now() < deadline {
                for change in manager.poll_ports() {
                    match change {
                        DeviceChange::NeedsName { id } => {
                            manager.accept_device_name(id, "Sim".to_string());
                        }
                        DeviceChange::Registered { id, .. } => {
                            live.insert(id);
                        }
                        DeviceChange::Disconnected { id } => {
                            live.remove(&id);
                        }
                        _ => {}
                    }
                }
                if pred(live) {
                    return true;
                }
                std::thread::sleep(Duration::from_millis(5));
            }
            false
        };

        // The initial two-device chain registers.
        let first_two: HashSet<DeviceId> = ids.iter().copied().collect();
        assert!(
            pump(&mut manager, &mut live, &|s| *s == first_two),
            "initial chain registers; saw {live:?}"
        );

        // Grow the fleet: a third device appears off-chain (powered off, not enumerated)
        // with a fresh distinct id, at the next contiguous index. The chain is untouched.
        let new_index = router
            .add_device(SlotSpec {
                seed: 99,
                digest: SimFirmware::PLACEHOLDER_DIGEST,
                on_frame: Arc::new(|_, _, _| {}),
            })
            .unwrap();
        assert_eq!(new_index, 2, "appended at the next contiguous index");
        let new_id = router.device_id(new_index);
        assert!(!ids.contains(&new_id), "added device has a distinct id");
        assert_eq!(
            router.chain(),
            vec![0, 1],
            "add does not connect the device"
        );
        assert!(
            !router.is_powered(new_index),
            "added device starts powered off"
        );

        // Plug it into the tail: it powers on and registers over the existing chain while
        // devices 0 and 1 keep their sessions (head unchanged -> no port re-enumeration).
        router.connect(new_index).unwrap();
        ids.push(new_id);
        let all: HashSet<DeviceId> = ids.iter().copied().collect();
        assert_eq!(router.chain(), vec![0, 1, 2], "connected at the tail");
        assert!(
            router.is_powered(new_index),
            "connected device is powered on"
        );
        assert!(
            pump(&mut manager, &mut live, &|s| *s == all),
            "the added device registers at the tail without dropping the others; saw {live:?}"
        );
    }

    // set_chain validates at the boundary: an out-of-range or duplicate order is rejected
    // and leaves the current chain (and all device power) untouched.
    #[test]
    fn set_chain_rejects_invalid_orders() {
        let coord = host();
        let serial = VirtualSerial::single("sim-device-0", coord.clone());
        let port = serial.connection();
        let router = ChainRouter::new(coord, port, specs(3, 20), vec![0, 1, 2]);

        assert!(router.set_chain(vec![0, 3]).is_err(), "index out of range");
        assert!(router.set_chain(vec![0, 0]).is_err(), "duplicate index");
        // Rejected attempts left the chain unchanged.
        assert_eq!(router.chain(), vec![0, 1, 2]);
        // A valid subset/reorder still applies.
        assert!(router.set_chain(vec![2, 0]).is_ok());
        assert_eq!(router.chain(), vec![2, 0]);
    }

    // Concurrent set_chain callers (FRB and device sockets run on different threads) must
    // never leave the published chain order disagreeing with which slots are powered — chain
    // membership IS power. The natural race window (between releasing the slots lock and
    // publishing the order, in a non-atomic implementation) is sub-microsecond, so we force
    // the dangerous interleaving deterministically: when the connect-all caller reaches the
    // publish point it signals, then pauses; the test releases the conflicting disconnect-all
    // caller into that pause. With set_chain atomic (slots held across the publish),
    // disconnect-all is blocked until connect-all finishes, so order and power agree. Without
    // it, disconnect-all powers everything off while connect-all is paused, then connect-all
    // publishes [0,1,2] last — leaving order=[0,1,2] with every slot off.
    #[test]
    fn concurrent_set_chain_keeps_membership_and_power_consistent() {
        let coord = host();
        let serial = VirtualSerial::single("sim-device-0", coord.clone());
        let port = serial.connection();
        let router = Arc::new(ChainRouter::new(coord, port, specs(3, 40), vec![0, 1, 2]));

        // Only the connect-all caller parks at the publish point (the baseline above and the
        // disconnect-all caller run on differently-named threads, so the hook ignores them).
        let (tx, rx) = std::sync::mpsc::channel::<()>();
        let tx = Mutex::new(tx);
        router.set_publish_hook(Arc::new(move || {
            if std::thread::current().name() == Some("connect-all") {
                let _ = tx.lock().unwrap().send(());
                std::thread::sleep(Duration::from_millis(80));
            }
        }));

        let connect = std::thread::Builder::new()
            .name("connect-all".into())
            .spawn({
                let router = router.clone();
                move || router.set_chain(vec![0, 1, 2]).unwrap()
            })
            .unwrap();

        // Wait until connect-all is parked at its publish point, then race disconnect-all in.
        rx.recv().unwrap();
        let disconnect = std::thread::Builder::new()
            .name("disconnect-all".into())
            .spawn({
                let router = router.clone();
                move || router.set_chain(vec![]).unwrap()
            })
            .unwrap();

        connect.join().unwrap();
        disconnect.join().unwrap();

        // Whichever order won the race, power must match it exactly.
        let chain = router.chain();
        for index in 0..3 {
            assert_eq!(
                chain.contains(&index),
                router.is_powered(index),
                "device {index}: chain membership must equal power (chain={chain:?})"
            );
        }
    }

    // sim-13 acceptance: a disconnect powers the device off (screen dark, no new frames) and
    // a reconnect powers it back on, driven entirely through the handles captured ONCE up
    // front — the same `framebuffer`/`touch` clones `load_sim` hands to `SimDevice`. This proves
    // those long-lived handles keep driving the device across a
    // power-cycle (no orphaning onto a dead thread): frames return on reconnect and a touch
    // pushed through the pre-existing queue reaches the freshly-booted thread.
    #[test]
    fn disconnect_powers_off_and_reconnect_drives_through_the_same_handle() {
        let coord = host();
        let serial = VirtualSerial::single("sim-device-0", coord.clone());
        let port = serial.connection();

        // A frame sink that counts frames, like the tray's StreamSink.
        let frames = Arc::new(AtomicUsize::new(0));
        let on_frame: FrameSink = {
            let frames = frames.clone();
            Arc::new(move |_, _, _| {
                frames.fetch_add(1, Ordering::SeqCst);
            })
        };
        let spec = SlotSpec {
            seed: 50,
            digest: SimFirmware::PLACEHOLDER_DIGEST,
            on_frame,
        };
        let router = ChainRouter::new(coord, port, vec![spec], vec![0]);

        // Capture the handles ONCE — exactly what SimDevice holds for the
        // device's whole life. Everything below drives the device through these, never
        // re-fetching after a power-cycle.
        let framebuffer = router.framebuffer(0).unwrap();
        let touch = router.touch(0).unwrap();
        let device_id = router.device_id(0);

        // Boots and renders into the captured framebuffer.
        assert!(
            wait_until(|| !is_dark(&framebuffer)),
            "the device should render a boot frame"
        );

        // Disconnect = power off: the captured screen goes dark and no new frames arrive.
        router.set_chain(vec![]).unwrap();
        assert!(
            is_dark(&framebuffer),
            "a powered-off device's screen is dark through the same handle"
        );
        let frames_when_off = frames.load(Ordering::SeqCst);
        std::thread::sleep(Duration::from_millis(200));
        assert_eq!(
            frames.load(Ordering::SeqCst),
            frames_when_off,
            "a powered-off device pushes no new frames"
        );

        // Reconnect = power on (boot from preserved flash): the SAME handle sees a fresh
        // boot frame.
        router.set_chain(vec![0]).unwrap();
        assert!(
            wait_until(|| !is_dark(&framebuffer)),
            "reconnect re-boots the device — the screen returns through the same handle"
        );
        assert!(
            frames.load(Ordering::SeqCst) > frames_when_off,
            "new frames flow after reconnect"
        );

        // Touch through the PRE-EXISTING queue reaches the rebooted thread, which drains it.
        touch.push(TouchEvent {
            point: Point::new(120, 150),
            lift_up: false,
            gesture: TouchGesture::None,
        });
        assert!(
            wait_until(|| touch.pending() == 0),
            "the rebooted thread consumes touch pushed through the same handle"
        );

        // The id is stable across the whole power-cycle.
        assert_eq!(
            router.device_id(0),
            device_id,
            "the device id is stable across the power-cycle"
        );
    }

    // Regression: disconnecting the tail device must power off ONLY the tail — the head and
    // middle keep running and stay registered with the coordinator. (Before the surgical
    // re-cable, every set_chain pulsed the whole USB port, so disconnecting the back device
    // dropped the front device too — the coordinator re-enumerated everything.)
    #[test]
    fn disconnecting_the_tail_leaves_the_rest_connected() {
        let coord = host();
        let serial = VirtualSerial::single("sim-device-0", coord.clone());
        let port = serial.connection();
        let router = ChainRouter::new(coord, port, specs(3, 60), vec![0, 1, 2]);
        let ids: Vec<DeviceId> = (0..3).map(|i| router.device_id(i)).collect();
        let mut manager = UsbSerialManager::new(Box::new(serial));

        // Bring all three up.
        let mut live: HashSet<DeviceId> = HashSet::new();
        let deadline = Instant::now() + Duration::from_secs(60);
        while Instant::now() < deadline && live.len() < 3 {
            for change in manager.poll_ports() {
                match change {
                    DeviceChange::NeedsName { id } => {
                        manager.accept_device_name(id, "Sim".to_string());
                    }
                    DeviceChange::Registered { id, .. } => {
                        live.insert(id);
                    }
                    DeviceChange::Disconnected { id } => {
                        live.remove(&id);
                    }
                    _ => {}
                }
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(live.len(), 3, "all three register first; saw {live:?}");

        // Disconnect the tail. The head and middle must NEVER be seen disconnecting; only
        // the tail leaves.
        router.set_chain(vec![0, 1]).unwrap();
        let deadline = Instant::now() + Duration::from_secs(30);
        let mut tail_gone = false;
        while Instant::now() < deadline && !tail_gone {
            for change in manager.poll_ports() {
                match change {
                    DeviceChange::NeedsName { id } => {
                        manager.accept_device_name(id, "Sim".to_string());
                    }
                    DeviceChange::Disconnected { id } => {
                        assert_ne!(
                            id, ids[0],
                            "the head must not drop when the tail is removed"
                        );
                        assert_ne!(
                            id, ids[1],
                            "the middle must not drop when the tail is removed"
                        );
                        if id == ids[2] {
                            tail_gone = true;
                        }
                    }
                    _ => {}
                }
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(
            tail_gone,
            "the coordinator should see the tail device disconnect"
        );
    }

    // Removal tombstones: removing a device frees its slot but never its INDEX, so the
    // surviving devices keep their numbers, a later add gets a fresh index, and every
    // operation on the removed index is a clean error — the chain staying coherent
    // throughout (the removed device's downstream falls off with it, daisy-chain style).
    #[test]
    fn remove_device_tombstones_the_index_and_keeps_numbering_stable() {
        let coord = host();
        let serial = VirtualSerial::single("sim-device-0", coord.clone());
        let port = serial.connection();
        let router = ChainRouter::new(coord, port, specs(3, 200), vec![0, 1, 2]);
        let ids: Vec<DeviceId> = (0..3).map(|i| router.device_id(i)).collect();

        // Remove the MIDDLE device: it and its downstream leave the chain; the head keeps
        // its index and id; the tail (cut off by daisy-chain semantics) is re-connectable.
        router.remove_device(1).unwrap();
        assert_eq!(router.chain(), vec![0]);
        assert!(!router.is_live(1));
        router.connect(2).unwrap();
        assert_eq!(router.chain(), vec![0, 2]);
        assert_eq!(router.device_id(0), ids[0], "survivors keep their identity");
        assert_eq!(router.device_id(2), ids[2]);

        // The tombstone is permanent: re-removal, reconnection, and re-cabling through it
        // all error; a runtime add gets a FRESH index, never the freed one.
        assert_eq!(
            router.remove_device(1).unwrap_err(),
            SlotError::Removed { index: 1 }
        );
        assert_eq!(
            router.set_chain(vec![0, 1, 2]).unwrap_err(),
            SlotError::Removed { index: 1 }
        );
        let new_index = router
            .add_device(SlotSpec {
                seed: 300,
                digest: SimFirmware::PLACEHOLDER_DIGEST,
                on_frame: Arc::new(|_, _, _| {}),
            })
            .unwrap();
        assert_eq!(new_index, 3, "a freed index is never reused");
        router.connect(new_index).unwrap();
        assert_eq!(router.chain(), vec![0, 2, 3]);
        assert!(
            !ids.contains(&router.device_id(new_index)),
            "the new device is a new identity, not the removed one's"
        );

        // Out-of-range removal errors too (validation at the shared boundary).
        assert_eq!(
            router.remove_device(9).unwrap_err(),
            SlotError::OutOfRange { index: 9, count: 4 }
        );

        // Every mutator AND state read names the tombstone rather than acting on it,
        // returning a stale answer, or panicking.
        assert!(router.is_connected(0).unwrap());
        let tombstone = SlotError::Removed { index: 1 };
        assert_eq!(router.is_connected(1).unwrap_err(), tombstone);
        assert_eq!(router.connect(1).unwrap_err(), tombstone);
        assert_eq!(router.disconnect(1).unwrap_err(), tombstone);
        assert_eq!(
            router
                .set_firmware_digest(1, SimFirmware::PLACEHOLDER_DIGEST)
                .unwrap_err(),
            tombstone
        );
    }

    // Save/restore semantics: saving a device's state requires it DISCONNECTED (a
    // running slot's flash lives in its thread); restore is a NEW index carrying the
    // SAME identity (seed + flash derived) and the set digest; and a saved state whose
    // identity is still live in the pool is rejected — one device per identity.
    #[test]
    fn save_and_restore_preserve_identity_and_reject_duplicates() {
        let coord = host();
        let serial = VirtualSerial::single("sim-device-0", coord.clone());
        let port = serial.connection();
        let router = ChainRouter::new(coord, port, specs(2, 240), vec![0, 1]);
        let id1 = router.device_id(1);
        let junk = Sha256Digest([0x42; 32]);

        assert_eq!(
            router.save_device_state(1).unwrap_err(),
            SlotError::Connected { index: 1 },
            "a connected device cannot have its state saved"
        );
        router.disconnect(1).unwrap();
        router.set_firmware_digest(1, junk).unwrap();
        let saved = router.save_device_state(1).unwrap();
        let bytes = saved.to_bytes();

        // The identity is still live: restore must be rejected.
        let noop: FrameSink = Arc::new(|_, _, _| {});
        let dup = crate::DeviceSavedState::from_bytes(&bytes).unwrap();
        assert_eq!(
            router
                .add_device_from_saved_state(dup, noop.clone())
                .unwrap_err(),
            SlotError::IdentityInPool { id: id1 },
            "one device per identity"
        );

        router.remove_device(1).unwrap();
        let decoded = crate::DeviceSavedState::from_bytes(&bytes).unwrap();
        let restored = router.add_device_from_saved_state(decoded, noop).unwrap();
        assert_eq!(
            restored, 2,
            "restore gets a FRESH index, never the freed one"
        );
        assert_eq!(
            router.device_id(restored),
            id1,
            "same seed + same flash is the same device identity"
        );
        // The set digest travelled: re-saving the (still-disconnected) restored
        // device reads it back without needing a digest getter.
        assert_eq!(router.save_device_state(restored).unwrap().digest, junk);
        router.connect(restored).unwrap();
        assert_eq!(router.chain(), vec![0, 2]);
    }

    // One device per identity holds for FRESH adds too, not just restores: restoring
    // another session's blank device occupies a seed that a later fresh allocation
    // would reuse (same seed + same blank flash ⇒ the same DeviceId), so the shared
    // insertion boundary must reject the fresh duplicate as well.
    #[test]
    fn fresh_add_cannot_duplicate_a_restored_identity() {
        let coord = host();
        let serial = VirtualSerial::single("sim-device-0", coord.clone());
        let port = serial.connection();
        let router = ChainRouter::new(coord, port, specs(1, 260), vec![0]);

        // "Another session's" blank device with the seed a future fresh add would get.
        let imported = crate::DeviceSavedState {
            seed: 261,
            digest: SimFirmware::PLACEHOLDER_DIGEST,
            flash: RamFlash::new(),
        };
        let noop: FrameSink = Arc::new(|_, _, _| {});
        let restored = router
            .add_device_from_saved_state(imported, noop.clone())
            .unwrap();
        assert_eq!(restored, 1);

        // The fresh add that would mint the same identity must be rejected.
        assert!(
            matches!(
                router
                    .add_device(SlotSpec {
                        seed: 261,
                        digest: SimFirmware::PLACEHOLDER_DIGEST,
                        on_frame: noop,
                    })
                    .unwrap_err(),
                SlotError::IdentityInPool { .. }
            ),
            "the shared insertion boundary enforces identity uniqueness for fresh adds"
        );
    }

    // Removal is ONE slots-held transaction: a concurrent connect racing into the gap
    // between "un-cable" and "tombstone" would republish the device and leave the
    // forwarding loop dereferencing a dead link. The remover parks at the publish point
    // (still holding `slots`); the reconnector is released into that pause and must
    // BLOCK until removal completes, then observe the tombstone — never a half-removed
    // device in the chain.
    #[test]
    fn remove_racing_reconnect_cannot_republish_the_device() {
        let coord = host();
        let serial = VirtualSerial::single("sim-device-0", coord.clone());
        let port = serial.connection();
        let router = Arc::new(ChainRouter::new(coord, port, specs(2, 220), vec![0, 1]));

        let (tx, rx) = std::sync::mpsc::channel::<()>();
        let tx = Mutex::new(tx);
        router.set_publish_hook(Arc::new(move || {
            if std::thread::current().name() == Some("remover") {
                let _ = tx.lock().unwrap().send(());
                std::thread::sleep(Duration::from_millis(80));
            }
        }));

        let remover = std::thread::Builder::new()
            .name("remover".into())
            .spawn({
                let router = router.clone();
                move || router.remove_device(1)
            })
            .unwrap();

        rx.recv().unwrap();
        let reconnector = std::thread::Builder::new()
            .name("reconnector".into())
            .spawn({
                let router = router.clone();
                move || router.connect(1)
            })
            .unwrap();

        remover.join().unwrap().unwrap();
        assert_eq!(
            reconnector.join().unwrap().unwrap_err(),
            SlotError::Removed { index: 1 },
            "the racing connect must observe the completed removal"
        );
        assert!(!router.is_live(1));
        assert_eq!(router.chain(), vec![0]);
        // The forwarding loop survived (a dead-link dereference would have poisoned it):
        // the chain still re-cables and the surviving device still answers.
        router.set_chain(vec![]).unwrap();
        router.set_chain(vec![0]).unwrap();
        let _ = router.device_id(0);
    }

    // The canonical chain operations: connect plugs into the tail; disconnect cuts the
    // daisy chain at the device, dropping it AND everything downstream (a pulled device
    // takes its subtree with it) — never a gap-close.
    #[test]
    fn connect_appends_and_disconnect_cuts_downstream() {
        let coord = host();
        let serial = VirtualSerial::single("sim-device-0", coord.clone());
        let port = serial.connection();
        let router = ChainRouter::new(coord, port.clone(), specs(4, 80), vec![0, 1, 2, 3]);

        // Disconnect the middle device: it and everything downstream (2, 3) fall off.
        router.disconnect(1).unwrap();
        assert_eq!(router.chain(), vec![0]);

        // Disconnecting a device that isn't connected is a no-op.
        router.disconnect(2).unwrap();
        assert_eq!(router.chain(), vec![0]);

        // Connect appends to the tail (no-op if already connected).
        router.connect(2).unwrap();
        router.connect(0).unwrap();
        router.connect(3).unwrap();
        assert_eq!(router.chain(), vec![0, 2, 3]);

        // Disconnecting the head cuts the whole chain — and the port, which models the
        // head's cable, must STAY down (the head-swap reconnect pulse must not revive a
        // port with nothing behind it) until a head returns.
        router.disconnect(0).unwrap();
        assert_eq!(router.chain(), Vec::<usize>::new());
        assert!(!port.is_connected(), "no head, no port");
        std::thread::sleep(RECABLE_DOWN * 2);
        assert!(
            !port.is_connected(),
            "an empty chain never reconnects the port"
        );
        router.connect(3).unwrap();
        assert!(
            wait_until(|| port.is_connected()),
            "a new head brings the port back up"
        );
    }
}
