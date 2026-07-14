//! RAM-backed `NorFlash` — the host stand-in for the esp NVS partition. Promoted
//! from the smoke-test `FakeFlash`; the const sizes match the esp flash geometry
//! the loop assumes (1-byte reads, 4-byte writes, 4 KiB erase sectors).

use embedded_storage::nor_flash::{self, NorFlash, ReadNorFlash};

/// 256 KiB of NVS — the same sector count the lifted loop's NVS sizing was
/// validated against on host.
pub const SECTORS: usize = 64;
const SECTOR_SIZE: usize = 4096;
const CAPACITY: usize = SECTOR_SIZE * SECTORS;

pub struct RamFlash(Box<[u8; CAPACITY]>);

impl RamFlash {
    pub fn new() -> Self {
        Self(Box::new([0xff; CAPACITY]))
    }
}

impl Default for RamFlash {
    fn default() -> Self {
        Self::new()
    }
}

impl core::fmt::Debug for RamFlash {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("RamFlash")
            .field("capacity", &CAPACITY)
            .finish()
    }
}

impl nor_flash::ErrorType for RamFlash {
    type Error = core::convert::Infallible;
}

impl ReadNorFlash for RamFlash {
    const READ_SIZE: usize = 1;

    fn read(&mut self, offset: u32, bytes: &mut [u8]) -> Result<(), Self::Error> {
        let start = offset as usize;
        bytes.copy_from_slice(&self.0[start..start + bytes.len()]);
        Ok(())
    }

    fn capacity(&self) -> usize {
        CAPACITY
    }
}

impl NorFlash for RamFlash {
    const WRITE_SIZE: usize = 4;
    const ERASE_SIZE: usize = SECTOR_SIZE;

    fn erase(&mut self, from: u32, to: u32) -> Result<(), Self::Error> {
        self.0[from as usize..to as usize].fill(0xff);
        Ok(())
    }

    fn write(&mut self, offset: u32, bytes: &[u8]) -> Result<(), Self::Error> {
        let start = offset as usize;
        self.0[start..start + bytes.len()].copy_from_slice(bytes);
        Ok(())
    }
}
