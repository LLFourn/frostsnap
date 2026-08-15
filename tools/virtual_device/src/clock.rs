//! A monotonic millisecond `Clock` for the sim. Backed by `Instant` so all the
//! clones (the two `FramedSerial` links, the `FrostyUi`, and the loop's own
//! `&dyn Clock`) agree on a single advancing timeline — the framing read-timeout
//! and the UI redraw gate then behave as on hardware.

use frostsnap_embedded::device_hal::Clock;
use std::time::Instant;

#[derive(Clone, Copy)]
pub struct SimClock {
    start: Instant,
}

impl SimClock {
    pub fn new() -> Self {
        Self {
            start: Instant::now(),
        }
    }
}

impl Default for SimClock {
    fn default() -> Self {
        Self::new()
    }
}

impl Clock for SimClock {
    fn now_ms(&self) -> u64 {
        self.start.elapsed().as_millis() as u64
    }
}
