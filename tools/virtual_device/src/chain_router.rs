//! The sim's model of re-cabling a daisy chain at runtime (sim-12).
//!
//! sim-10 wired a FIXED chain: device i's downstream was hard-crossed to device i+1's
//! upstream. To let the chain be reordered and to let any device connect independently,
//! the wiring becomes a runtime CONFIG instead: an ordered list of device indices. A
//! [`ChainRouter`] owns the single coordinator endpoint plus every device's upstream and
//! downstream endpoints, and a forwarding thread shuttles bytes along the CURRENT order
//! each tick — coordinator <-> head.upstream, then each adjacent `prev.downstream <->
//! next.upstream`. A device not in the order is unspliced: its upstream stays silent, so
//! the real firmware drops to Standby and the coordinator stops seeing it. Reconfiguring
//! ([`ChainRouter::set_chain`]) re-derives the splices and each device's downstream-detect
//! flag atomically. Nothing message-level changes — this is a byte-transport leaf; the
//! `frostsnap_embedded` relay is unchanged and simply runs over whatever topology the
//! router currently presents.

use crate::serial::{HostEnd, LinkGate};
use crate::virtual_serial::PortConnection;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

/// How often the forwarding loop shuttles bytes. Tight, so the chain's hop-by-hop
/// magic-byte handshake (~100 ms cadence on the coordinator) is never starved by the
/// router adding latency between devices.
const TICK: Duration = Duration::from_millis(1);

/// How long the coordinator port is held down across a re-cable. A topology change is
/// modelled as unplugging the whole bus from USB and plugging it back in, so the
/// coordinator drops every device and re-enumerates the new chain from scratch (this
/// sidesteps trying to surgically swap the head device underneath a live port). Long
/// enough that the coordinator's port poll observes the gap.
const RECABLE_DOWN: Duration = Duration::from_millis(150);

/// The router's endpoints for one device: the host ends of its upstream and downstream
/// links (the device holds the matching `PipeByteIo`s), plus the downstream-detect flag
/// the router drives (true iff the device has a successor in the current order). The
/// device thread reads the same flag via its `spawn_chained` downstream-present.
pub struct DeviceLink {
    pub up: HostEnd,
    pub down: HostEnd,
    pub downstream_present: LinkGate,
}

struct RouterState {
    /// The coordinator endpoint (a clone of what `VirtualSerial::single` drives): the
    /// coordinator writes `coord.tx` and reads `coord.rx`, so the router drains `coord.tx`
    /// (coordinator output) and pushes `coord.rx` (toward the coordinator).
    coord: HostEnd,
    /// The coordinator port's presence; pulsed down on a re-cable to force re-enumeration.
    port: PortConnection,
    /// When to bring the port back up after a re-cable (`None` = up / no pending pulse).
    reconnect_at: Option<Instant>,
    links: Vec<DeviceLink>,
    /// Device indices in chain order; `order[0]` is the head on the coordinator port.
    order: Vec<usize>,
}

impl RouterState {
    /// Atomically: set each device's downstream-detect from the order, and clear every
    /// link channel so a reconfigure is a clean re-cable (in-flight bytes are dropped;
    /// the firmware re-handshakes via magic bytes — no stale framing carries over).
    fn recompute(&mut self) {
        for (idx, link) in self.links.iter().enumerate() {
            let has_successor = self
                .order
                .iter()
                .position(|&d| d == idx)
                .is_some_and(|pos| pos + 1 < self.order.len());
            link.downstream_present.set_connected(has_successor);
        }
        self.coord.rx.clear();
        self.coord.tx.clear();
        for link in &self.links {
            link.up.rx.clear();
            link.up.tx.clear();
            link.down.rx.clear();
            link.down.tx.clear();
        }
    }

    /// One forwarding tick over the current order. Each channel is handled exactly once
    /// (no double-drain that could discard a byte a device wrote between steps): spliced
    /// outputs are forwarded; un-spliced outputs (the tail's downstream, every off-chain
    /// device) are drained and discarded so they can't grow or leave stale bytes.
    fn forward_once(&self, buf: &mut Vec<u8>) {
        let drain_to = |from: &HostEnd, to_tx: &crate::serial::ByteChannel, buf: &mut Vec<u8>| {
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

        // off-chain devices: discard both outputs (their inputs are never fed -> Standby)
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

/// Owns the forwarding thread; dropping it stops and joins the thread.
pub struct ChainRouter {
    stop: Arc<AtomicBool>,
    join: Option<JoinHandle<()>>,
    state: Arc<Mutex<RouterState>>,
}

impl ChainRouter {
    /// Start routing `links` (one per device, indexed) against `coord` on `port`, with the
    /// initial chain `order` (device indices; `order[0]` is the head). Pass a clone of the
    /// `HostEnd` and the `PortConnection` of the same `VirtualSerial::single`.
    pub fn new(
        coord: HostEnd,
        port: PortConnection,
        links: Vec<DeviceLink>,
        order: Vec<usize>,
    ) -> Self {
        let mut initial = RouterState {
            coord,
            port,
            reconnect_at: None,
            links,
            order,
        };
        initial.recompute();
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
        }
    }

    /// Re-cable the chain to `order` (device indices in chain order). Re-derives the
    /// splices + downstream-detect flags and pulses the coordinator port down so the bus
    /// fully re-enumerates over the new topology (in-flight bytes are dropped; devices
    /// re-handshake from scratch). The port comes back up after [`RECABLE_DOWN`].
    ///
    /// Validates at this shared boundary (all callers go through here): every index must
    /// be `< device_count` and appear at most once. An invalid `order` is rejected with
    /// `Err` and the current chain is left untouched — out-of-range would otherwise panic
    /// the forwarding loop's `links[i]`, and duplicates would be an invalid topology.
    pub fn set_chain(&self, order: Vec<usize>) -> Result<(), String> {
        let mut state = self.state.lock().unwrap();
        let count = state.links.len();
        let mut seen = vec![false; count];
        for &index in &order {
            if index >= count {
                return Err(format!("no device {} (have 1..={count})", index + 1));
            }
            if std::mem::replace(&mut seen[index], true) {
                return Err(format!("device {} listed more than once", index + 1));
            }
        }
        state.order = order;
        state.recompute();
        state.port.set_connected(false);
        state.reconnect_at = Some(Instant::now() + RECABLE_DOWN);
        Ok(())
    }

    /// The current chain order (device indices; `[0]` is the head).
    pub fn chain(&self) -> Vec<usize> {
        self.state.lock().unwrap().order.clone()
    }
}

impl Drop for ChainRouter {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::firmware::SimFirmware;
    use crate::serial::{pipe, ByteChannel};
    use crate::{VirtualDevice, VirtualSerial};
    use frostsnap_coordinator::{DeviceChange, UsbSerialManager};
    use frostsnap_core::DeviceId;
    use std::collections::HashSet;
    use std::time::{Duration, Instant};

    fn host() -> HostEnd {
        HostEnd {
            rx: ByteChannel::new(),
            tx: ByteChannel::new(),
        }
    }

    // The router presents a runtime-reconfigurable chain over ONE coordinator port:
    // [0,1,2] registers all three via relay; set_chain([1]) leaves ONLY device index 1
    // (proving a device connects independently of the others / becomes the head); and
    // restoring [0,1,2] re-registers all three over the new cabling.
    #[test]
    fn router_chain_registers_then_reconfigures_over_one_port() {
        let digest = SimFirmware::PLACEHOLDER_DIGEST;
        let coord = host();
        let serial = VirtualSerial::single("sim-device-0", coord.clone());
        let port = serial.connection();

        let mut links = Vec::new();
        let mut spawned = Vec::new();
        for i in 0..3u64 {
            let (up_io, up_host) = pipe();
            let (down_io, down_host) = pipe();
            let dp = LinkGate::new(false);
            let s = VirtualDevice::spawn_chained(
                10 + i,
                digest,
                up_io,
                down_io,
                Some(dp.clone()),
                |_, _, _| {},
            );
            links.push(DeviceLink {
                up: up_host,
                down: down_host,
                downstream_present: dp,
            });
            spawned.push(s);
        }
        let ids: Vec<DeviceId> = spawned.iter().map(|s| s.device_id).collect();
        assert_eq!(
            ids.iter().collect::<HashSet<_>>().len(),
            3,
            "distinct device ids"
        );

        let router = ChainRouter::new(coord, port, links, vec![0, 1, 2]);
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

        // Re-cable to just device index 1: only it stays (independent connect / head).
        router.set_chain(vec![1]).unwrap();
        assert!(
            pump(&mut manager, &mut live, &|s| s.len() == 1
                && s.contains(&ids[1])),
            "set_chain([1]) leaves only device index 1; saw {live:?}"
        );

        // Re-cable to a REORDERED two-device chain (head=2 -> 0): exercises an adjacency
        // that never existed in the original order, so a splice bug for reordered chains
        // would stop the downstream device (0) from registering through the head (2).
        router.set_chain(vec![2, 0]).unwrap();
        assert!(
            pump(&mut manager, &mut live, &|s| s.len() == 2
                && s.contains(&ids[2])
                && s.contains(&ids[0])),
            "set_chain([2,0]) registers exactly devices 2 and 0; saw {live:?}"
        );

        // Re-cable to a REORDERED full chain (2 -> 0 -> 1): all three re-register over the
        // new adjacencies (2->0 and 0->1, neither present in the original order).
        router.set_chain(vec![2, 0, 1]).unwrap();
        assert!(
            pump(&mut manager, &mut live, &|s| *s == all),
            "set_chain([2,0,1]) re-registers all three over the reordered chain; saw {live:?}"
        );

        drop(spawned);
    }

    // set_chain validates at the boundary: an out-of-range or duplicate order is rejected
    // and leaves the current chain untouched (so the forwarding loop never indexes a bad
    // device or builds a non-contiguous topology).
    #[test]
    fn set_chain_rejects_invalid_orders() {
        let serial = VirtualSerial::single("sim-device-0", host());
        let port = serial.connection();
        let links: Vec<DeviceLink> = (0..3)
            .map(|_| DeviceLink {
                up: host(),
                down: host(),
                downstream_present: LinkGate::new(false),
            })
            .collect();
        let router = ChainRouter::new(host(), port, links, vec![0, 1, 2]);

        assert!(router.set_chain(vec![0, 3]).is_err(), "index out of range");
        assert!(router.set_chain(vec![0, 0]).is_err(), "duplicate index");
        // Rejected attempts left the chain unchanged.
        assert_eq!(router.chain(), vec![0, 1, 2]);
        // A valid subset/reorder still applies.
        assert!(router.set_chain(vec![2, 0]).is_ok());
        assert_eq!(router.chain(), vec![2, 0]);
    }
}
