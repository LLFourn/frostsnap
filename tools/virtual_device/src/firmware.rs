//! The sim's `FirmwareServices` — an honest no-op, not a security hole. Virtual
//! devices are dev/non-genuine (Axis 9): the genuine-check is off, so a `Challenge`
//! is answered with `None` (no certificate to sign with), and the seeded digest
//! means the coordinator never offers an upgrade. The esp half (OTA + DS/RSA
//! signing, `device/src/firmware.rs`) is exactly what the sim drops.

use frostsnap_comms::{CoordinatorSendBody, Downstream, Sha256Digest, Upstream};
use frostsnap_embedded::{
    device_hal::{FirmwareAction, FirmwareServices},
    framed_serial::SerialPort,
    ui::UserInteraction,
};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;

pub struct SimFirmware {
    digest: Sha256Digest,
    upgrades_offered: Arc<AtomicU32>,
}

impl SimFirmware {
    /// A placeholder digest for harnesses that don't care about app-side firmware
    /// compatibility (the pure-Rust sims). The app path (`load_sim`) instead passes
    /// the digest of the firmware bin it also seeds into the coordinator, so the
    /// device announces a digest the coordinator considers up-to-date — otherwise
    /// the app gates the device as "incompatible firmware".
    pub const PLACEHOLDER_DIGEST: Sha256Digest = Sha256Digest([0x5a; 32]);

    /// The device announces `digest` in its `Announce`. To be seen as compatible by
    /// the app, this must equal the coordinator's latest firmware digest.
    pub fn new(digest: Sha256Digest) -> Self {
        Self {
            digest,
            upgrades_offered: Arc::new(AtomicU32::new(0)),
        }
    }

    /// Counts coordinator upgrade messages seen — should stay 0 (the device
    /// announces the coordinator's latest digest, so no upgrade is ever offered).
    pub fn upgrades_offered(&self) -> Arc<AtomicU32> {
        self.upgrades_offered.clone()
    }
}

impl Default for SimFirmware {
    fn default() -> Self {
        Self::new(Self::PLACEHOLDER_DIGEST)
    }
}

impl FirmwareServices for SimFirmware {
    fn firmware_digest(&self) -> Sha256Digest {
        self.digest
    }

    fn handle<U, D>(
        &mut self,
        msg: &CoordinatorSendBody,
        _upstream: &mut U,
        _downstream: Option<&mut D>,
        _ui: &mut dyn UserInteraction,
    ) -> FirmwareAction
    where
        U: SerialPort<Upstream>,
        D: SerialPort<Downstream>,
    {
        match msg {
            // Genuine-check is off for dev devices: no certificate, so nothing to
            // sign. The coordinator gates the challenge on its own flag.
            CoordinatorSendBody::Challenge(_) => FirmwareAction::None,
            // The sim never advertises an upgradeable digest, so a coordinator should
            // never offer one. If a (mis)driven coordinator does, ignore it rather
            // than panic — a real coordinator must not be able to crash the device.
            // Counted so the Slice-0 test can assert it never happens.
            CoordinatorSendBody::Upgrade(_) => {
                self.upgrades_offered.fetch_add(1, Ordering::Relaxed);
                FirmwareAction::None
            }
            _ => FirmwareAction::None,
        }
    }

    fn poll(&mut self, _ui: &mut dyn UserInteraction) -> FirmwareAction {
        FirmwareAction::None
    }

    fn confirm_upgrade(&mut self) {}

    fn cancel(&mut self) {}
}
