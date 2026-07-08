//! High-level device gestures composed from raw touch events.
//!
//! [`DeviceInput`] turns taps / holds / swipes into the `TouchEvent` sequences the
//! device's `FrostyUi` already understands: press/release latching for holds, and the
//! `TouchGesture` slide flags for vertical scrolls and the log/main toggle (see
//! `frostsnap_embedded::touch_handler`). Timed ops block the calling thread for real
//! wall-clock — the device's `Instant`-backed clock reads that elapsed time while the
//! device runs concurrently — so drive these from the device channel's own threads,
//! never from a non-blocking / FRB-sync context.

use crate::touch::TouchQueue;
use embedded_graphics::geometry::Point;
use frostsnap_embedded::device_hal::{TouchEvent, TouchGesture};
use std::time::Duration;

/// Number of intermediate points a [`DeviceInput::swipe`] emits between endpoints.
const SWIPE_STEPS: i32 = 8;

/// Composes high-level gestures onto a device's [`TouchQueue`].
pub struct DeviceInput {
    touch: TouchQueue,
}

impl DeviceInput {
    pub fn new(touch: TouchQueue) -> Self {
        Self { touch }
    }

    fn event(&self, x: i32, y: i32, lift_up: bool, gesture: TouchGesture) {
        self.touch.push(TouchEvent {
            point: Point::new(x, y),
            lift_up,
            gesture,
        });
    }

    /// Inject one raw touch event: a press/move when `lift_up` is false, a release
    /// when true. Repeated presses at moving points form a drag; the caller owns the
    /// timing. (The composed `tap`/`hold`/`swipe` are usually what you want.)
    pub fn raw(&self, x: i32, y: i32, lift_up: bool) {
        self.event(x, y, lift_up, TouchGesture::None);
    }

    /// A press immediately followed by a release at the same point.
    pub fn tap(&self, x: i32, y: i32) {
        self.event(x, y, false, TouchGesture::None);
        self.event(x, y, true, TouchGesture::None);
    }

    /// Press at `(x, y)`, hold for `duration` of real wall-clock, then release. A
    /// hold-to-confirm control confirms once `duration` exceeds its threshold
    /// (`HOLD_TO_CONFIRM_TIME_MS`): the concurrently-running device integrates the
    /// elapsed clock while the press is latched.
    pub fn hold(&self, x: i32, y: i32, duration: Duration) {
        self.event(x, y, false, TouchGesture::None);
        std::thread::sleep(duration);
        self.event(x, y, true, TouchGesture::None);
    }

    /// Swipe from `(x1, y1)` to `(x2, y2)` over `duration`, emitting intermediate move
    /// events tagged with the inferred slide gesture so vertical scrolls and the
    /// horizontal log/main toggle register exactly as a CST816S slide would.
    pub fn swipe(&self, x1: i32, y1: i32, x2: i32, y2: i32, duration: Duration) {
        let gesture = infer_gesture(x1, y1, x2, y2);
        let step = duration / SWIPE_STEPS as u32;
        self.event(x1, y1, false, gesture);
        for i in 1..=SWIPE_STEPS {
            std::thread::sleep(step);
            let x = x1 + (x2 - x1) * i / SWIPE_STEPS;
            let y = y1 + (y2 - y1) * i / SWIPE_STEPS;
            self.event(x, y, i == SWIPE_STEPS, gesture);
        }
    }
}

/// The CST816S slide gesture matching the dominant swipe direction.
fn infer_gesture(x1: i32, y1: i32, x2: i32, y2: i32) -> TouchGesture {
    let (dx, dy) = (x2 - x1, y2 - y1);
    if dx.abs() >= dy.abs() {
        match dx.signum() {
            -1 => TouchGesture::SlideLeft,
            1 => TouchGesture::SlideRight,
            _ => TouchGesture::None,
        }
    } else {
        match dy.signum() {
            -1 => TouchGesture::SlideUp,
            1 => TouchGesture::SlideDown,
            _ => TouchGesture::None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use frostsnap_embedded::device_hal::TouchSource;
    use std::time::Instant;

    fn drain(mut q: TouchQueue) -> Vec<TouchEvent> {
        let mut out = Vec::new();
        while let Some(e) = q.next_touch() {
            out.push(e);
        }
        out
    }

    #[test]
    fn tap_is_press_then_release_at_point() {
        let q = TouchQueue::new();
        DeviceInput::new(q.clone()).tap(10, 20);
        let evs = drain(q);
        assert_eq!(evs.len(), 2);
        assert_eq!(evs[0].point, Point::new(10, 20));
        assert!(!evs[0].lift_up, "first event is a press");
        assert!(evs[1].lift_up, "second event is a release");
    }

    #[test]
    fn hold_presses_then_releases_after_the_duration() {
        let q = TouchQueue::new();
        let start = Instant::now();
        DeviceInput::new(q.clone()).hold(5, 6, Duration::from_millis(40));
        assert!(
            start.elapsed() >= Duration::from_millis(40),
            "hold blocks for the duration"
        );
        let evs = drain(q);
        assert_eq!(evs.len(), 2);
        assert!(!evs[0].lift_up && evs[1].lift_up);
    }

    #[test]
    fn swipe_up_tags_slide_up_and_releases_at_the_end() {
        let q = TouchQueue::new();
        DeviceInput::new(q.clone()).swipe(120, 200, 120, 50, Duration::from_millis(8));
        let evs = drain(q);
        assert!(evs.len() >= 2);
        assert!(
            evs.iter()
                .all(|e| matches!(e.gesture, TouchGesture::SlideUp)),
            "a y-decreasing swipe is tagged SlideUp"
        );
        assert!(!evs.first().unwrap().lift_up, "starts with a press");
        assert!(evs.last().unwrap().lift_up, "ends with a release");
        assert_eq!(
            evs.last().unwrap().point,
            Point::new(120, 50),
            "ends at the target"
        );
    }
}
