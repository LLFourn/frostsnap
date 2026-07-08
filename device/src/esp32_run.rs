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
    flash_header::KeyedHash,
    framed_serial::FramedSerial,
};
use rand_chacha::ChaCha20Rng;

use crate::{
    efuse::{EfuseHmacKey, EfuseHmacKeys},
    esp_ui::EspClock,
    firmware::EspFirmware,
    io::SerialIo,
    resources::Resources,
};

type EspSerial<'a, D> = FramedSerial<SerialIo<'a>, EspClock, D>;

/// The esp peripheral bundle the portable loop runs on.
pub struct EspHal<'a> {
    upstream: EspSerial<'a, Upstream>,
    downstream: EspSerial<'a, Downstream>,
    rng: ChaCha20Rng,
    hmac_keys: EfuseHmacKeys<'a>,
    firmware: EspFirmware<'a>,
}

impl<'a> DeviceHal for EspHal<'a> {
    type Storage = FlashStorage<'static>;
    type Upstream = EspSerial<'a, Upstream>;
    type Downstream = EspSerial<'a, Downstream>;
    type Rng = ChaCha20Rng;
    type Secrets = frostsnap_embedded::ShareEncryptionSecrets<EfuseHmacKey<'a>>;
    type Firmware = EspFirmware<'a>;

    fn parts(&mut self) -> HalParts<'_, Self> {
        HalParts {
            upstream: &mut self.upstream,
            downstream: &mut self.downstream,
            rng: &mut self.rng,
            secrets: &mut self.hmac_keys.share_encryption,
            firmware: &mut self.firmware,
        }
    }

    fn keypair_hasher(&mut self) -> &mut dyn KeyedHash {
        &mut self.hmac_keys.fixed_entropy
    }
}

/// Main event loop for the device.
pub fn run<'a>(resources: Box<Resources<'a>>) -> ! {
    let Resources {
        rng,
        hmac_keys,
        ds,
        rsa,
        certificate,
        nvs,
        ota,
        ui,
        sha256,
        upstream_serial,
        downstream_serial,
        downstream_detect,
    } = *resources;

    let firmware = EspFirmware::new(ota, sha256, rsa, ds, certificate);
    let clock = EspClock;
    let mut hal = EspHal {
        upstream: upstream_serial,
        downstream: downstream_serial,
        rng,
        hmac_keys,
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
