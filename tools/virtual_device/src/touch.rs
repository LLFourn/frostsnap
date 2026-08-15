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

    /// Drop every pending touch. Called on power-on (sim-13) so touches that arrived
    /// while the device was powered off don't replay into the freshly-booted thread.
    pub fn clear(&self) {
        self.0.lock().unwrap().clear();
    }

    /// How many touches are queued but not yet pulled by the device. Lets a test observe
    /// that a running thread drains the queue (proving touch reaches the device) versus a
    /// powered-off slot where it does not.
    #[cfg(test)]
    pub(crate) fn pending(&self) -> usize {
        self.0.lock().unwrap().len()
    }
}

impl TouchSource for TouchQueue {
    fn next_touch(&mut self) -> Option<TouchEvent> {
        self.0.lock().unwrap().pop_front()
    }
}
