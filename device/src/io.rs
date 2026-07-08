//! esp byte transport for the serial links. The portable bincode framing now
//! lives in `frostsnap_embedded::framed_serial::FramedSerial`; this provides the
//! `SerialIo` transport it rides on (`ByteIo`).

use core::convert::Infallible;
use esp_hal::uart::{self, Uart};
use esp_hal::usb::usb_serial_jtag::UsbSerialJtag;
use esp_hal::Blocking;
use frostsnap_embedded::framed_serial::{ByteIo, WriteError};

use crate::uart_interrupt::{UartHandle, UartNum, UartReceiver};

pub enum SerialIo<'a> {
    Uart {
        handle: UartHandle,
        uart_num: UartNum,
        consumer: UartReceiver,
    },
    Jtag {
        jtag: UsbSerialJtag<'a, Blocking>,
        peek_byte: Option<u8>,
    },
}

impl<'a> SerialIo<'a> {
    pub fn new_uart(uart: Uart<'static, Blocking>, uart_num: UartNum) -> Self {
        let (handle, consumer) = crate::uart_interrupt::register_uart(uart, uart_num);
        SerialIo::Uart {
            handle,
            uart_num,
            consumer,
        }
    }

    pub fn new_jtag(jtag: UsbSerialJtag<'a, Blocking>) -> Self {
        SerialIo::Jtag {
            jtag,
            peek_byte: None,
        }
    }

    /// Check if data is available without consuming it
    pub fn has_data(&self) -> bool {
        match self {
            SerialIo::Uart { consumer, .. } => consumer.peek().is_some(),
            SerialIo::Jtag { peek_byte, .. } => peek_byte.is_some(),
        }
    }

    /// Internal method to read a byte from the appropriate source
    pub fn read_byte(&mut self) -> Option<u8> {
        match self {
            SerialIo::Uart {
                consumer, handle, ..
            } => match consumer.dequeue() {
                Some(byte) => Some(byte),
                None => {
                    handle.fill_buffer();
                    consumer.dequeue()
                }
            },
            SerialIo::Jtag { jtag, peek_byte } => {
                if let Some(byte) = peek_byte.take() {
                    Some(byte)
                } else {
                    jtag.read_byte().ok()
                }
            }
        }
    }

    pub fn change_baud(&mut self, baudrate: u32) {
        self.flush();
        match self {
            SerialIo::Uart { handle, .. } => {
                handle.change_baud(baudrate);
            }
            SerialIo::Jtag { .. } => { /* no baud rate for USB jtag */ }
        }
    }

    pub fn fill_queue(&mut self) {
        match self {
            SerialIo::Uart { handle, .. } => {
                handle.fill_buffer();
            }
            SerialIo::Jtag { jtag, peek_byte } => {
                if peek_byte.is_none() {
                    *peek_byte = jtag.read_byte().ok();
                }
            }
        }
    }

    pub fn write_byte_nb(&mut self, byte: u8) -> nb::Result<(), Infallible> {
        match self {
            SerialIo::Jtag { jtag, .. } => jtag.write_byte_nb(byte),
            SerialIo::Uart { handle, .. } => match handle.write_bytes(&[byte]) {
                Ok(_) => Ok(()),
                Err(_) => Err(nb::Error::WouldBlock),
            },
        }
    }

    pub fn write_bytes(&mut self, bytes: &[u8]) -> Result<(), SerialInterfaceError> {
        match self {
            SerialIo::Uart { handle, .. } => handle
                .write_bytes(bytes)
                .map_err(SerialInterfaceError::UartWriteError)?,
            SerialIo::Jtag { jtag, .. } => {
                let _infallible = jtag.write(bytes);
            }
        }
        Ok(())
    }

    pub fn nb_flush(&mut self) {
        match self {
            SerialIo::Uart { .. } => { /* uart write already blocks until written */ }
            SerialIo::Jtag { jtag, .. } => {
                let _ = jtag.flush_tx_nb();
            }
        }
    }

    /// Blocking flush — ensure everything is written (e.g. before reset).
    pub fn flush(&mut self) {
        match self {
            SerialIo::Uart { handle, .. } => handle.flush_tx(),
            SerialIo::Jtag { jtag, .. } => {
                let _ = jtag.flush_tx();
            }
        }
    }
}

impl ByteIo for SerialIo<'_> {
    fn read_byte(&mut self) -> Option<u8> {
        SerialIo::read_byte(self)
    }
    fn has_data(&mut self) -> bool {
        SerialIo::has_data(self)
    }
    fn fill(&mut self) {
        self.fill_queue();
    }
    fn write_bytes(&mut self, bytes: &[u8]) -> Result<(), WriteError> {
        SerialIo::write_bytes(self, bytes).map_err(|_| WriteError)
    }
    fn nb_flush(&mut self) {
        SerialIo::nb_flush(self);
    }
    fn flush(&mut self) {
        SerialIo::flush(self);
    }
    fn set_baud(&mut self, baud: u32) {
        self.change_baud(baud);
    }
}

#[derive(Debug)]
pub enum SerialInterfaceError {
    UartReadError,
    UartWriteError(uart::TxError),
    JtagError,
}
