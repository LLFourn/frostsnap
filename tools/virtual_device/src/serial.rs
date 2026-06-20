//! The device end of the serial link: a `ByteIo` over an in-memory byte buffer.
//!
//! A `Pipe` is one duplex connection — two directions, each a shared byte queue.
//! The device side is a `PipeByteIo` (wrapped by `FramedSerial` in the HAL); the
//! host side is a `HostEnd` whose raw byte queues the coordinator's `VirtualPort`
//! drives (sim-2). sim-1 only needs the device end (a `disconnected()` link is a
//! device with no peer — it renders Standby and never establishes upstream).

use frostsnap_embedded::framed_serial::ByteIo;
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

/// One direction of buffered bytes, shared between the two ends of a pipe.
#[derive(Clone, Default)]
pub struct ByteChannel(Arc<Mutex<VecDeque<u8>>>);

impl ByteChannel {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn push(&self, bytes: &[u8]) {
        self.0.lock().unwrap().extend(bytes.iter().copied());
    }

    pub fn pop(&self) -> Option<u8> {
        self.0.lock().unwrap().pop_front()
    }

    pub fn len(&self) -> usize {
        self.0.lock().unwrap().len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Drain everything currently buffered (used by the coordinator-side port).
    pub fn drain(&self, out: &mut Vec<u8>) {
        let mut q = self.0.lock().unwrap();
        out.extend(q.drain(..));
    }
}

/// The device-side byte transport.
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
