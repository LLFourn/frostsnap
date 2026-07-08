//! esp-hal implementations of the UI HAL seam (`Clock`, `TouchSource`) and the
//! concrete display/`FrostyUi` types. The portable `FrostyUi<D, C, T>` lives in
//! `frostsnap_embedded`; this binds it to the ST7789 display, the esp system
//! timer, and CST816S touch.

use crate::touch_calibration::adjust_touch_point;
use embedded_graphics::prelude::Point;
use esp_hal::time::Instant;
use frostsnap_cst816s::{interrupt::TouchReceiver, TouchGesture as CstGesture};
use frostsnap_embedded::device_hal::{Clock, TouchEvent, TouchGesture, TouchSource};
use frostsnap_embedded::frosty_ui::FrostyUi;

/// The ST7789-over-SPI display (matches factory).
pub type EspDisplay<'a> = mipidsi::Display<
    mipidsi::interface::SpiInterface<
        'a,
        embedded_hal_bus::spi::ExclusiveDevice<
            esp_hal::spi::master::Spi<'a, esp_hal::Blocking>,
            crate::peripherals::NoCs,
            embedded_hal_bus::spi::NoDelay,
        >,
        esp_hal::gpio::Output<'a>,
    >,
    mipidsi::models::ST7789,
    esp_hal::gpio::Output<'a>,
>;

/// The concrete `FrostyUi` the device runs.
pub type EspFrostyUi<'a> = FrostyUi<EspDisplay<'a>, EspClock, EspTouch>;

/// `Clock` backed by the esp system timer.
#[derive(Clone, Copy, Default)]
pub struct EspClock;

impl Clock for EspClock {
    fn now_ms(&self) -> u64 {
        Instant::now().duration_since_epoch().as_millis()
    }
}

/// `TouchSource` backed by the CST816S interrupt receiver. Applies panel
/// calibration and maps the driver gesture into the portable `TouchGesture`.
pub struct EspTouch {
    receiver: TouchReceiver,
}

impl EspTouch {
    pub fn new(receiver: TouchReceiver) -> Self {
        Self { receiver }
    }
}

impl TouchSource for EspTouch {
    fn next_touch(&mut self) -> Option<TouchEvent> {
        self.receiver.dequeue().map(|e| TouchEvent {
            point: adjust_touch_point(Point::new(e.x, e.y)),
            lift_up: e.action == 1,
            gesture: match e.gesture {
                CstGesture::SlideUp => TouchGesture::SlideUp,
                CstGesture::SlideDown => TouchGesture::SlideDown,
                CstGesture::SlideLeft => TouchGesture::SlideLeft,
                CstGesture::SlideRight => TouchGesture::SlideRight,
                _ => TouchGesture::None,
            },
        })
    }
}
