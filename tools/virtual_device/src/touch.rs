//! A `TouchSource` fed from outside the device thread. The tray (sim-5) and the
//! scripted driver (sim-3/7) push `TouchEvent`s; the device's `FrostyUi` pulls them
//! through the real widget tree — touches drive the UI exactly as the CST816S does
//! on hardware, never via injected `UiEvent`s.

use frostsnap_embedded::device_hal::{TouchEvent, TouchSource};
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

/// A cloneable handle to a device's pending-touch queue.
#[derive(Clone, Default)]
pub struct TouchQueue(Arc<Mutex<VecDeque<TouchEvent>>>);

impl TouchQueue {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn push(&self, event: TouchEvent) {
        self.0.lock().unwrap().push_back(event);
    }
}

impl TouchSource for TouchQueue {
    fn next_touch(&mut self) -> Option<TouchEvent> {
        self.0.lock().unwrap().pop_front()
    }
}
