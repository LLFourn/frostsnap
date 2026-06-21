//! The device end of the serial link: a `ByteIo` over an in-memory byte buffer.
//!
//! A `Pipe` is one duplex connection — two directions, each a shared byte queue.
//! The device side is a `PipeByteIo` (wrapped by `FramedSerial` in the HAL); the
//! host side is a `HostEnd` whose raw byte queues the coordinator's `VirtualPort`
//! drives (sim-2). sim-1 only needs the device end (a `disconnected()` link is a
//! device with no peer — it renders Standby and never establishes upstream).

use frostsnap_embedded::framed_serial::ByteIo;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

/// One direction of buffered bytes, shared between the two ends of a pipe. The
/// `Condvar` lets the *coordinator* side block in `read` until bytes arrive (its
/// `read_exact`/timeout path can't tolerate an immediate empty read); the *device*
/// side uses the non-blocking `pop` because it polls.
#[derive(Clone, Default)]
pub struct ByteChannel(Arc<(Mutex<VecDeque<u8>>, Condvar)>);

impl ByteChannel {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn push(&self, bytes: &[u8]) {
        let (lock, cvar) = &*self.0;
        let mut q = lock.lock().unwrap();
        q.extend(bytes.iter().copied());
        // Notify while holding the lock so a waiting reader can't miss the wakeup.
        cvar.notify_all();
    }

    pub fn pop(&self) -> Option<u8> {
        self.0 .0.lock().unwrap().pop_front()
    }

    pub fn len(&self) -> usize {
        self.0 .0.lock().unwrap().len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Drain everything currently buffered (used by the coordinator-side port).
    pub fn drain(&self, out: &mut Vec<u8>) {
        let mut q = self.0 .0.lock().unwrap();
        out.extend(q.drain(..));
    }

    /// Discard everything currently buffered — a cut link loses its bytes in transit.
    pub fn clear(&self) {
        self.0 .0.lock().unwrap().clear();
    }

    /// Blocking read for the coordinator side: wait up to `timeout` for ≥1 byte,
    /// then move as many buffered bytes as fit into `buf`. Returns the count moved
    /// (0 only on timeout with no data). Uses a `wait_timeout` loop on the
    /// emptiness predicate so it honors the deadline despite spurious wakeups.
    pub fn read(&self, buf: &mut [u8], timeout: Duration) -> usize {
        if buf.is_empty() {
            return 0;
        }
        let (lock, cvar) = &*self.0;
        let mut q = lock.lock().unwrap();
        let deadline = Instant::now() + timeout;
        while q.is_empty() {
            let remaining = match deadline.checked_duration_since(Instant::now()) {
                Some(r) => r,
                None => return 0,
            };
            let (next, wait) = cvar.wait_timeout(q, remaining).unwrap();
            q = next;
            if wait.timed_out() && q.is_empty() {
                return 0;
            }
        }
        let n = buf.len().min(q.len());
        for slot in buf.iter_mut().take(n) {
            *slot = q.pop_front().unwrap();
        }
        n
    }
}

/// A shared boolean flag. Used as a device's downstream-detect: the [`ChainRouter`]
/// drives it (true iff the device has a successor in the current chain) and the device
/// thread reads it each tick. Cheap to clone — clones share one flag.
///
/// [`ChainRouter`]: crate::ChainRouter
#[derive(Clone)]
pub struct LinkGate(Arc<AtomicBool>);

impl LinkGate {
    pub fn new(connected: bool) -> Self {
        Self(Arc::new(AtomicBool::new(connected)))
    }

    pub fn set_connected(&self, connected: bool) {
        self.0.store(connected, Ordering::Relaxed);
    }

    pub fn is_connected(&self) -> bool {
        self.0.load(Ordering::Relaxed)
    }
}

/// The device-side byte transport. Byte flow is governed externally (by the
/// [`ChainRouter`](crate::ChainRouter), which drains/feeds the host ends), so the device
/// end itself just reads its `rx` and writes its `tx`.
pub struct PipeByteIo {
    rx: ByteChannel,
    tx: ByteChannel,
}

impl PipeByteIo {
    /// A device end with no peer attached — reads never yield, writes are buffered
    /// but unread. Enough to boot and render a standalone device.
    pub fn disconnected() -> Self {
        Self {
            rx: ByteChannel::new(),
            tx: ByteChannel::new(),
        }
    }
}

impl ByteIo for PipeByteIo {
    fn read_byte(&mut self) -> Option<u8> {
        self.rx.pop()
    }

    fn has_data(&mut self) -> bool {
        !self.rx.is_empty()
    }

    fn fill(&mut self) {}

    fn write_bytes(&mut self, bytes: &[u8]) -> Result<(), ()> {
        self.tx.push(bytes);
        Ok(())
    }

    fn nb_flush(&mut self) {}

    fn flush(&mut self) {}

    fn set_baud(&mut self, _baud: u32) {}
}

/// The host (coordinator) side of a pipe: `rx` carries device→host bytes, `tx`
/// carries host→device bytes. sim-2 builds the coordinator `serialport::SerialPort`
/// over these. Cloneable like the other handles — the `ByteChannel`s are `Arc`-backed,
/// so a clone captured before a session drives the same wire while the loop runs.
#[derive(Clone)]
pub struct HostEnd {
    pub rx: ByteChannel,
    pub tx: ByteChannel,
}

/// Create a connected duplex pair: the device's `PipeByteIo` and the host end.
pub fn pipe() -> (PipeByteIo, HostEnd) {
    let dev_to_host = ByteChannel::new();
    let host_to_dev = ByteChannel::new();
    (
        PipeByteIo {
            rx: host_to_dev.clone(),
            tx: dev_to_host.clone(),
        },
        HostEnd {
            rx: dev_to_host,
            tx: host_to_dev,
        },
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn read_times_out_cleanly_with_no_producer() {
        let ch = ByteChannel::new();
        let mut buf = [0u8; 4];
        let start = Instant::now();
        let n = ch.read(&mut buf, Duration::from_millis(50));
        assert_eq!(n, 0, "no producer ⇒ read returns 0 (timed out)");
        assert!(
            start.elapsed() >= Duration::from_millis(50),
            "honored the timeout"
        );
    }

    #[test]
    fn read_blocks_then_unblocks_on_a_late_push() {
        let ch = ByteChannel::new();
        let writer = ch.clone();
        let producer = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(30));
            writer.push(&[7, 8, 9]);
        });

        let mut buf = [0u8; 8];
        let start = Instant::now();
        let n = ch.read(&mut buf, Duration::from_secs(5));
        producer.join().unwrap();

        assert_eq!(n, 3, "the late push wakes the blocked reader");
        assert_eq!(&buf[..3], &[7, 8, 9]);
        assert!(
            start.elapsed() >= Duration::from_millis(25),
            "it actually blocked"
        );
    }

    #[test]
    fn read_returns_immediately_when_data_is_already_buffered() {
        let ch = ByteChannel::new();
        ch.push(&[1, 2]);
        let mut buf = [0u8; 8];
        assert_eq!(ch.read(&mut buf, Duration::from_secs(5)), 2);
        assert_eq!(&buf[..2], &[1, 2]);
    }
}
