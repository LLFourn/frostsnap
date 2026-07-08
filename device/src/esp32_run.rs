//! The esp shell around the portable `DeviceLoop`: aggregates the esp
//! peripherals into a `DeviceHal`, then loops `poll` and performs the hardware
//! reset when the loop asks for one. All device logic lives in
//! `frostsnap_embedded::device_loop`.

use alloc::boxed::Box;
use esp_storage::FlashStorage;
use frostsnap_comms::{Downstream, Upstream};
use frostsnap_embedded::{
    device_hal::{DeviceHal, HalParts, InitOutcome, Poll},
    device_loop::DeviceLoop,
    framed_serial::FramedSerial,
};
use rand_chacha::ChaCha20Rng;

use crate::{
    crypto::EspCrypto, esp_ui::EspClock, firmware::EspFirmware, io::SerialIo, resources::Resources,
};

type EspSerial<'a, D> = FramedSerial<SerialIo<'a>, EspClock, D>;

/// The esp peripheral bundle the portable loop runs on.
pub struct EspHal<'a> {
    upstream: EspSerial<'a, Upstream>,
    downstream: EspSerial<'a, Downstream>,
    rng: ChaCha20Rng,
    crypto: EspCrypto<'a>,
    firmware: EspFirmware<'a>,
}

impl<'a> DeviceHal for EspHal<'a> {
    type Storage = FlashStorage<'static>;
    type Upstream = EspSerial<'a, Upstream>;
    type Downstream = EspSerial<'a, Downstream>;
    type Rng = ChaCha20Rng;
    type Crypto = EspCrypto<'a>;
    type Firmware = EspFirmware<'a>;

    fn parts(&mut self) -> HalParts<'_, Self> {
        HalParts {
            upstream: &mut self.upstream,
            downstream: &mut self.downstream,
            rng: &mut self.rng,
            crypto: &mut self.crypto,
            firmware: &mut self.firmware,
        }
    }
}

/// Main event loop for the device.
pub fn run<'a>(resources: Box<Resources<'a>>) -> ! {
    let Resources {
        rng,
        mut crypto,
        nvs,
        ota,
        ui,
        upstream_serial,
        downstream_serial,
        downstream_detect,
    } = *resources;

    let firmware = EspFirmware::new(ota, &mut crypto);
    let clock = EspClock;
    let mut hal = EspHal {
        upstream: upstream_serial,
        downstream: downstream_serial,
        rng,
        crypto,
        firmware,
    };
    let mut ui = ui;

    let mut device_loop = match DeviceLoop::new(&mut hal, &mut *ui, &clock, nvs) {
        InitOutcome::Ready(device_loop) => device_loop,
        InitOutcome::ResetRequested => esp_hal::system::software_reset(),
    };

    loop {
        let downstream_present = !downstream_detect.is_high();
        match device_loop.poll(downstream_present) {
            Poll::Continue => {}
            Poll::ResetRequested => esp_hal::system::software_reset(),
        }
    }
}
