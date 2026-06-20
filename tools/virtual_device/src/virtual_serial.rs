//! The coordinator-end transport: the in-memory analogue of a plugged USB device.
//!
//! `VirtualPort` implements `serialport::SerialPort` over a `HostEnd` byte pipe, so
//! the coordinator's `FramedSerialPort` (`BufReader<Box<dyn serialport::SerialPort>>`)
//! drives it byte-for-byte unchanged — the load-bearing methods (`bytes_to_read` and
//! a blocking `read`) are truthful; the line-config methods are inert stubs.
//! `VirtualSerial` implements `frostsnap_coordinator::Serial` (the injection seam):
//! it advertises one port per plugged device and hands back that device's
//! `VirtualPort`. This is the *only* coordinator-facing change — `UsbSerialManager`
//! and `FramedSerialPort` are untouched.

use crate::serial::HostEnd;
use frostsnap_coordinator::{PortDesc, PortOpenError, Serial};
use serialport::{ClearBuffer, DataBits, FlowControl, Parity, SerialPort, StopBits};
use std::io::{self, Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

/// The USB VID/PID the real `UsbSerialManager` filters connected ports on
/// (`frostsnap_coordinator::usb_serial_manager`). A virtual port must advertise
/// these or the manager ignores it.
pub const FROSTSNAP_VID: u16 = 12346;
pub const FROSTSNAP_PID: u16 = 4097;

const DEFAULT_TIMEOUT: Duration = Duration::from_secs(5);

/// One coordinator-side serial port backed by a device's `HostEnd` pipe.
pub struct VirtualPort {
    name: String,
    host: HostEnd,
    timeout: Duration,
}

impl VirtualPort {
    pub fn new(name: String, host: HostEnd) -> Self {
        Self {
            name,
            host,
            timeout: DEFAULT_TIMEOUT,
        }
    }
}

impl Read for VirtualPort {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        // Standard `Read` contract: a zero-length buffer reads zero bytes, never an
        // error. (ByteChannel::read also returns 0 for an empty buf, which we must
        // not conflate with a timeout.)
        if buf.is_empty() {
            return Ok(0);
        }
        match self.host.rx.read(buf, self.timeout) {
            0 => Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "virtual serial read timed out",
            )),
            n => Ok(n),
        }
    }
}

impl Write for VirtualPort {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.host.tx.push(buf);
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl SerialPort for VirtualPort {
    // --- load-bearing: readiness, blocking read, write all ride on Read/Write ---
    fn bytes_to_read(&self) -> serialport::Result<u32> {
        Ok(self.host.rx.len() as u32)
    }

    fn name(&self) -> Option<String> {
        Some(self.name.clone())
    }

    fn timeout(&self) -> Duration {
        self.timeout
    }

    fn set_timeout(&mut self, timeout: Duration) -> serialport::Result<()> {
        self.timeout = timeout;
        Ok(())
    }

    fn try_clone(&self) -> serialport::Result<Box<dyn SerialPort>> {
        Ok(Box::new(VirtualPort {
            name: self.name.clone(),
            host: self.host.clone(),
            timeout: self.timeout,
        }))
    }

    // --- inert stubs: a virtual UART has no real line configuration ---
    fn baud_rate(&self) -> serialport::Result<u32> {
        Ok(115_200)
    }
    fn data_bits(&self) -> serialport::Result<DataBits> {
        Ok(DataBits::Eight)
    }
    fn flow_control(&self) -> serialport::Result<FlowControl> {
        Ok(FlowControl::None)
    }
    fn parity(&self) -> serialport::Result<Parity> {
        Ok(Parity::None)
    }
    fn stop_bits(&self) -> serialport::Result<StopBits> {
        Ok(StopBits::One)
    }
    fn set_baud_rate(&mut self, _baud_rate: u32) -> serialport::Result<()> {
        Ok(())
    }
    fn set_data_bits(&mut self, _data_bits: DataBits) -> serialport::Result<()> {
        Ok(())
    }
    fn set_flow_control(&mut self, _flow_control: FlowControl) -> serialport::Result<()> {
        Ok(())
    }
    fn set_parity(&mut self, _parity: Parity) -> serialport::Result<()> {
        Ok(())
    }
    fn set_stop_bits(&mut self, _stop_bits: StopBits) -> serialport::Result<()> {
        Ok(())
    }
    fn write_request_to_send(&mut self, _level: bool) -> serialport::Result<()> {
        Ok(())
    }
    fn write_data_terminal_ready(&mut self, _level: bool) -> serialport::Result<()> {
        Ok(())
    }
    fn read_clear_to_send(&mut self) -> serialport::Result<bool> {
        Ok(false)
    }
    fn read_data_set_ready(&mut self) -> serialport::Result<bool> {
        Ok(false)
    }
    fn read_ring_indicator(&mut self) -> serialport::Result<bool> {
        Ok(false)
    }
    fn read_carrier_detect(&mut self) -> serialport::Result<bool> {
        Ok(false)
    }
    fn bytes_to_write(&self) -> serialport::Result<u32> {
        // Writes are delivered immediately into the pipe; nothing is pending.
        Ok(0)
    }
    fn clear(&self, _buffer_to_clear: ClearBuffer) -> serialport::Result<()> {
        Ok(())
    }
    fn set_break(&self) -> serialport::Result<()> {
        Ok(())
    }
    fn clear_break(&self) -> serialport::Result<()> {
        Ok(())
    }
}

/// A toggle for one virtual port's presence on the bus. Flipping it to disconnected
/// makes the port vanish from [`VirtualSerial::available_ports`], which the coordinator
/// observes exactly as a USB unplug; reconnecting it makes the port reappear and the
/// coordinator re-runs the magic-byte handshake (the device re-announces on its own).
/// Cheap to clone — clones share one flag — so the UI/FRB layer can hold a copy.
#[derive(Clone)]
pub struct PortConnection(Arc<AtomicBool>);

impl PortConnection {
    fn new() -> Self {
        Self(Arc::new(AtomicBool::new(true)))
    }

    pub fn set_connected(&self, connected: bool) {
        self.0.store(connected, Ordering::Relaxed);
    }

    pub fn is_connected(&self) -> bool {
        self.0.load(Ordering::Relaxed)
    }
}

/// The `Serial` impl seeded into `UsbSerialManager`: one in-memory port per plugged
/// device. The coordinator is otherwise unchanged.
pub struct VirtualSerial {
    ports: Vec<PortEntry>,
}

struct PortEntry {
    id: String,
    host: HostEnd,
    connection: PortConnection,
}

impl VirtualSerial {
    /// A single device, connected by default (sim-2 scope). Pass the device's
    /// `host_serial()` handle.
    pub fn single(id: impl Into<String>, host: HostEnd) -> Self {
        Self {
            ports: vec![PortEntry {
                id: id.into(),
                host,
                connection: PortConnection::new(),
            }],
        }
    }

    /// The [`PortConnection`] toggle for the single port — flip it to simulate
    /// plug/unplug. Panics if there isn't exactly one port.
    pub fn connection(&self) -> PortConnection {
        let [entry] = &self.ports[..] else {
            panic!("connection() is only valid for a single-port VirtualSerial");
        };
        entry.connection.clone()
    }
}

impl Serial for VirtualSerial {
    fn available_ports(&self) -> Vec<PortDesc> {
        self.ports
            .iter()
            .filter(|entry| entry.connection.is_connected())
            .map(|entry| PortDesc {
                id: entry.id.clone(),
                vid: FROSTSNAP_VID,
                pid: FROSTSNAP_PID,
            })
            .collect()
    }

    fn open_device_port(
        &self,
        unique_id: &str,
        _baud_rate: u32,
    ) -> Result<Box<dyn SerialPort>, PortOpenError> {
        let entry = self
            .ports
            .iter()
            .find(|entry| entry.id == unique_id)
            .ok_or_else(|| PortOpenError::Other("unknown virtual port".into()))?;
        Ok(Box::new(VirtualPort::new(
            entry.id.clone(),
            entry.host.clone(),
        )))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::serial::pipe;

    #[test]
    fn read_into_empty_buffer_is_ok_zero_not_timeout() {
        let (_device, host) = pipe();
        let mut port = VirtualPort::new("p".to_string(), host);
        let mut empty: [u8; 0] = [];
        // Must be Ok(0) per the Read contract, even though no bytes are buffered.
        assert_eq!(port.read(&mut empty).unwrap(), 0);
    }
}
