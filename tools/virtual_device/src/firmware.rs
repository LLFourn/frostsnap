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
    pub fn new() -> Self {
        // A fixed, arbitrary-but-stable digest. The coordinator compares it against
        // the latest known firmware to decide whether to offer an upgrade; a fixed
        // value with no matching "latest" means no upgrade is ever staged.
        Self {
            digest: Sha256Digest([0x5a; 32]),
            upgrades_offered: Arc::new(AtomicU32::new(0)),
        }
    }

    /// Counts coordinator upgrade messages seen — should stay 0 (the sim never
    /// advertises an upgradeable digest). The Slice-0 test asserts on this.
    pub fn upgrades_offered(&self) -> Arc<AtomicU32> {
        self.upgrades_offered.clone()
    }
}

impl Default for SimFirmware {
    fn default() -> Self {
        Self::new()
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
