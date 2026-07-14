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
use crate::flash::RamFlash;
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
    digest: Sha256Digest,
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
            spawn_device_thread(self.seed, self.digest, self.handles.clone(), flash);
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
    links: Vec<DeviceLink>,
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
                    self.links[head].up.tx.push(buf);
                }
                drain_to(&self.links[head].up, &self.coord.rx, buf);
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
            self.links[a].down.rx.drain(buf);
            if !buf.is_empty() {
                self.links[b].up.tx.push(buf);
            }
            // b's upstream output -> a's downstream input
            buf.clear();
            self.links[b].up.rx.drain(buf);
            if !buf.is_empty() {
                self.links[a].down.tx.push(buf);
            }
        }

        // the tail has no child: discard its downstream output
        if let Some(&tail) = self.order.last() {
            buf.clear();
            self.links[tail].down.rx.drain(buf);
        }

        // off-chain devices: discard both outputs (their inputs are never fed -> powered off)
        for (idx, link) in self.links.iter().enumerate() {
            if !self.order.contains(&idx) {
                buf.clear();
                link.up.rx.drain(buf);
                buf.clear();
                link.down.rx.drain(buf);
            }
        }
    }
}

/// Owns the device power slots and the byte-forwarding thread. Dropping it stops the
/// forwarding thread and then drops the slots, which powers off (stops + joins) every
/// running device thread.
pub struct ChainRouter {
    stop: Arc<AtomicBool>,
    join: Option<JoinHandle<()>>,
    state: Arc<Mutex<RouterState>>,
    /// One slot per device. Held by `set_chain` across the WHOLE mutation (so it serializes
    /// concurrent re-cables — see `set_chain`) and by the construction-time accessors. Never
    /// taken by the fast forwarding loop, so a slow thread join on power-off never stalls
    /// byte forwarding.
    slots: Mutex<Vec<DeviceSlot>>,
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
        let mut slots = Vec::with_capacity(specs.len());
        let mut links = Vec::with_capacity(specs.len());
        for spec in specs {
            // Boot once to learn the (stable) device id; `order` below powers off any
            // device that shouldn't start connected.
            let (slot, link) = Self::build_slot(spec);
            slots.push(slot);
            links.push(link);
        }

        // Devices not in the initial order start powered off (their flash is preserved).
        for (idx, slot) in slots.iter_mut().enumerate() {
            if !order.contains(&idx) {
                slot.power_off();
            }
        }

        let mut initial = RouterState {
            coord,
            port,
            reconnect_at: None,
            links,
            order,
        };
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
        let (up_io, up_host) = pipe();
        let (down_io, down_host) = pipe();
        let downstream_present = LinkGate::new(false);
        let handles = DeviceHandles {
            upstream_io: up_io,
            downstream_io: down_io,
            framebuffer: SharedFramebuffer::new(),
            touch: TouchQueue::new(),
            downstream_present: Some(downstream_present.clone()),
            on_frame: spec.on_frame,
        };
        let (device_id, thread) =
            spawn_device_thread(spec.seed, spec.digest, handles.clone(), RamFlash::new());
        let slot = DeviceSlot {
            seed: spec.seed,
            digest: spec.digest,
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
    pub fn add_device(&self, spec: SlotSpec) -> usize {
        let (mut slot, link) = Self::build_slot(spec);
        slot.power_off();
        let mut slots = self.slots.lock().unwrap();
        let mut state = self.state.lock().unwrap();
        let index = slots.len();
        slots.push(slot);
        state.links.push(link);
        index
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
    pub fn set_chain(&self, order: Vec<usize>) -> Result<(), String> {
        // Hold `slots` across the WHOLE mutation — validate, read the previous order, power
        // slots, and publish the new order — so the diff baseline and the published order
        // are one atomic step. Two concurrent callers (FRB and a device socket run on
        // different threads) therefore serialize here, so the published order can never
        // disagree with which slots are powered. `slots` is never taken by the fast
        // forwarding loop (it uses `state`), so holding it across the thread joins below
        // does not stall byte forwarding.
        let mut slots = self.slots.lock().unwrap();
        let count = slots.len();
        let mut seen = vec![false; count];
        for &index in &order {
            if index >= count {
                return Err(format!("no device {} (have 1..={count})", index + 1));
            }
            if std::mem::replace(&mut seen[index], true) {
                return Err(format!("device {} listed more than once", index + 1));
            }
        }

        // Diff membership: removed -> power off, added -> power on. (A device present in
        // both orders is a pure reorder — leave its thread running.)
        let current = self.state.lock().unwrap().order.clone();
        for &index in &current {
            if !order.contains(&index) {
                slots[index].power_off();
            }
        }
        for &index in &order {
            if !current.contains(&index) {
                slots[index].power_on();
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
        let head_changed = order.first() != current.first();
        let mut state = self.state.lock().unwrap();
        state.order = order;
        state.recompute(&current);
        if head_changed {
            state.port.set_connected(false);
            state.reconnect_at = Some(Instant::now() + RECABLE_DOWN);
        }
        Ok(())
    }

    /// The current chain order (device indices; `[0]` is the head). These are exactly the
    /// powered-on devices, in chain order.
    pub fn chain(&self) -> Vec<usize> {
        self.state.lock().unwrap().order.clone()
    }

    /// Connect `device` by plugging it into the TAIL of the daisy chain (a new device joins
    /// at the end). No-op if already connected. The single source of truth for "connect a
    /// device", used by every surface (FRB `SimDevice`, the device socket, the tray).
    pub fn connect(&self, device: usize) {
        let mut order = self.chain();
        if !order.contains(&device) {
            order.push(device);
            let _ = self.set_chain(order);
        }
    }

    /// Disconnect `device` AND everything downstream of it — pulling a device out of a daisy
    /// chain cuts power and comms to every device below it (they were reached, and powered,
    /// through it). No-op if not connected. The single source of truth for "disconnect a
    /// device", used by every surface.
    pub fn disconnect(&self, device: usize) {
        let order = self.chain();
        if let Some(pos) = order.iter().position(|&d| d == device) {
            let _ = self.set_chain(order[..pos].to_vec());
        }
    }

    /// The stable id of device `index` (same across power-cycles). Used to build the
    /// long-lived `SimDevice` handles at construction.
    pub fn device_id(&self, index: usize) -> DeviceId {
        self.slots.lock().unwrap()[index].device_id
    }

    /// A clone of device `index`'s STABLE framebuffer handle — the same screen surface
    /// every power-on draws into, so a handle captured once keeps showing the live (or
    /// darkened-off) device across reboots.
    pub fn framebuffer(&self, index: usize) -> SharedFramebuffer {
        self.slots.lock().unwrap()[index]
            .handles
            .framebuffer
            .clone()
    }

    /// A clone of device `index`'s STABLE touch queue — every power-on reads from it, so a
    /// handle captured once keeps driving whatever thread is currently powered.
    pub fn touch(&self, index: usize) -> TouchQueue {
        self.slots.lock().unwrap()[index].handles.touch.clone()
    }

    /// Whether device `index` currently has a running thread (powered on). The sim-13
    /// invariant is that this equals `chain().contains(&index)`.
    #[cfg(test)]
    fn is_powered(&self, index: usize) -> bool {
        matches!(self.slots.lock().unwrap()[index].power, Power::On(_))
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
        let new_index = router.add_device(SlotSpec {
            seed: 99,
            digest: SimFirmware::PLACEHOLDER_DIGEST,
            on_frame: Arc::new(|_, _, _| {}),
        });
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
        router.connect(new_index);
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
        let framebuffer = router.framebuffer(0);
        let touch = router.touch(0);
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

    // The canonical chain operations: connect plugs into the tail; disconnect cuts the
    // daisy chain at the device, dropping it AND everything downstream (a pulled device
    // takes its subtree with it) — never a gap-close.
    #[test]
    fn connect_appends_and_disconnect_cuts_downstream() {
        let coord = host();
        let serial = VirtualSerial::single("sim-device-0", coord.clone());
        let port = serial.connection();
        let router = ChainRouter::new(coord, port, specs(4, 80), vec![0, 1, 2, 3]);

        // Disconnect the middle device: it and everything downstream (2, 3) fall off.
        router.disconnect(1);
        assert_eq!(router.chain(), vec![0]);

        // Disconnecting a device that isn't connected is a no-op.
        router.disconnect(2);
        assert_eq!(router.chain(), vec![0]);

        // Connect appends to the tail (no-op if already connected).
        router.connect(2);
        router.connect(0);
        router.connect(3);
        assert_eq!(router.chain(), vec![0, 2, 3]);

        // Disconnecting the head cuts the whole chain.
        router.disconnect(0);
        assert_eq!(router.chain(), Vec::<usize>::new());
    }
}
