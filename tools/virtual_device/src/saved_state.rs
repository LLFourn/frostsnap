//! A device's durable state as portable bytes — the NVS a physical device carries in a
//! drawer. What travels: the seed (device identity derives from seed + flash), the
//! announced firmware digest, and the flash content. Deliberately NOT here: chain
//! position, power state, RAM — none of that survives a real device leaving the bench
//! (see the fsim-app-restart plan's durable/volatile split).

use crate::flash::RamFlash;
use frostsnap_comms::Sha256Digest;

/// One byte of format versioning so a stored saved-state that outlives a layout change
/// fails loudly instead of booting garbage.
const VERSION: u8 = 1;

/// The durable half of one virtual device. Obtain via
/// [`ChainRouter::save_device_state`](crate::ChainRouter::save_device_state); restore via
/// [`ChainRouter::add_device_from_saved_state`](crate::ChainRouter::add_device_from_saved_state).
#[derive(Debug)]
pub struct DeviceSavedState {
    pub seed: u64,
    pub digest: Sha256Digest,
    pub flash: RamFlash,
}

impl DeviceSavedState {
    pub fn to_bytes(&self) -> Vec<u8> {
        let flash = self.flash.as_bytes();
        let mut bytes = Vec::with_capacity(1 + 8 + 32 + flash.len());
        bytes.push(VERSION);
        bytes.extend_from_slice(&self.seed.to_le_bytes());
        bytes.extend_from_slice(&self.digest.0);
        bytes.extend_from_slice(flash);
        bytes
    }

    pub fn from_bytes(bytes: &[u8]) -> Result<Self, String> {
        let (&version, rest) = bytes
            .split_first()
            .ok_or_else(|| "empty device saved-state".to_string())?;
        if version != VERSION {
            return Err(format!(
                "unsupported device saved-state version {version} (expected {VERSION})"
            ));
        }
        if rest.len() < 8 + 32 {
            return Err(format!(
                "device saved-state truncated at {} bytes",
                bytes.len()
            ));
        }
        let (seed, rest) = rest.split_at(8);
        let (digest, flash) = rest.split_at(32);
        Ok(Self {
            seed: u64::from_le_bytes(seed.try_into().expect("split at 8")),
            digest: Sha256Digest(digest.try_into().expect("split at 32")),
            flash: RamFlash::from_bytes(flash)?,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use embedded_storage::nor_flash::NorFlash;

    #[test]
    fn round_trips_and_rejects_malformed() {
        let mut flash = RamFlash::new();
        flash.erase(0, 4096).unwrap();
        flash.write(0, &[1, 2, 3, 4]).unwrap();
        let saved = DeviceSavedState {
            seed: 42,
            digest: Sha256Digest([7; 32]),
            flash,
        };
        let decoded = DeviceSavedState::from_bytes(&saved.to_bytes()).unwrap();
        assert_eq!(decoded.seed, 42);
        assert_eq!(decoded.digest, Sha256Digest([7; 32]));
        assert_eq!(decoded.flash.as_bytes(), saved.flash.as_bytes());

        assert!(DeviceSavedState::from_bytes(&[]).is_err());
        assert!(
            DeviceSavedState::from_bytes(&[9])
                .unwrap_err()
                .contains("version"),
            "unknown version fails loudly"
        );
        let mut truncated = saved.to_bytes();
        truncated.truncate(100);
        assert!(DeviceSavedState::from_bytes(&truncated).is_err());
    }
}
