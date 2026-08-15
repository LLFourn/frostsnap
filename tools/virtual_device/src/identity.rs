//! Where a sim device's identity lives: a cell each BOOT publishes into.
//!
//! A device id is derived from the 32 random bytes the flash header stores
//! (`FlashHeader::init` draws them from the RNG) plus the efuse-analog
//! fixed-entropy key. So identity is a property of the FLASH, not of the slot:
//! it survives a power-cycle and a saved-state restore (both carry the header),
//! and it DIES with an erase — the next boot re-inits the header and mints a new
//! one, exactly as hardware does.
//!
//! That makes a slot-cached id wrong: an erase reboots the device in place, so
//! anything holding the id from spawn would keep labelling the wiped device as
//! its old self. Every boot publishes here instead, and the router and its
//! handles read through it.

use frostsnap_core::DeviceId;
use std::sync::{Arc, Mutex};

/// A device's live identity. Cheap to clone; clones share the record, which is
/// how a slot keeps reading the identity of whatever boot is current.
#[derive(Clone, Default)]
pub struct DeviceIdentityCell(Arc<Mutex<Option<DeviceId>>>);

impl DeviceIdentityCell {
    pub fn new() -> Self {
        Self::default()
    }

    /// The current identity. `None` only before the device's first boot has
    /// completed — unobservable through a spawned slot, which blocks on that
    /// boot (see `spawn_device_thread`).
    pub fn get(&self) -> Option<DeviceId> {
        *self.0.lock().unwrap()
    }

    pub fn publish(&self, id: DeviceId) {
        *self.0.lock().unwrap() = Some(id);
    }
}
