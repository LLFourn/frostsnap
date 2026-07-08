#![no_std]
#[cfg(feature = "std")]
#[macro_use]
extern crate std;

#[macro_use]
extern crate alloc;

mod ab_write;
#[cfg(test)]
pub mod test;
pub use ab_write::*;
mod nor_flash_log;
pub use nor_flash_log::*;
mod partition;
pub use partition::*;
mod nonce_slots;
pub use nonce_slots::*;
pub mod flash_header;
pub use flash_header::*;
mod secrets;
pub use secrets::*;
pub mod flash_log;
pub use flash_log::*;

// The lifted device run-loop + UI (esp-free). Gated behind `ui` because it pulls
// the widget stack; storage consumers can still use the crate without it.
#[cfg(feature = "ui")]
mod connection;
#[cfg(feature = "ui")]
pub use connection::*;
/// Display refresh frequency in milliseconds (25ms = 40 FPS).
/// The version of the firmware built from this tree.
///
/// A literal because an image can never contain its own digest, so running firmware cannot look
/// itself up in the released-version table. It is accurate because exactly one binary is ever
/// signed as a given release. From v0.5.0 the version is embedded at build time and this goes away.
///
/// Included from `device/` rather than defined there because the lift moved this const's consumers
/// — `frosty_ui` and `widget_tree` — into this crate, and a `no_std` crate the device depends on
/// cannot depend back on it. Same inclusion `frostsnap_widgets::demo_widget` uses, for the same reason.
pub const FIRMWARE_VERSION: frostsnap_comms::firmware_version::VersionNumber = {
    let (major, minor, patch) = include!("../../device/firmware_version.rs");
    frostsnap_comms::firmware_version::VersionNumber::new(major, minor, patch)
};

const _: () = {
    const fn ordered(v: frostsnap_comms::firmware_version::VersionNumber) -> u32 {
        (v.major as u32) << 16 | (v.minor as u32) << 8 | v.patch as u32
    }
    assert!(
        ordered(frostsnap_comms::firmware_version::EARLIEST_ACCEPTABLE)
            <= ordered(FIRMWARE_VERSION),
        "a release bump moved the downgrade floor past the version this tree builds"
    );
};

pub const DISPLAY_REFRESH_MS: u64 = 25;

#[cfg(feature = "ui")]
pub mod device_hal;
#[cfg(feature = "ui")]
pub mod device_loop;
#[cfg(feature = "ui")]
pub mod erase;
#[cfg(feature = "ui")]
pub use device_hal::*;
#[cfg(feature = "ui")]
pub use device_loop::*;
#[cfg(feature = "ui")]
pub mod framed_serial;
#[cfg(feature = "ui")]
pub mod frosty_ui;
#[cfg(feature = "ui")]
pub mod root_widget;
#[cfg(feature = "ui")]
pub mod touch_handler;
#[cfg(feature = "ui")]
pub mod ui;
#[cfg(feature = "ui")]
pub mod widget_tree;
