//! The esp `FirmwareServices` implementation: OTA upgrades. This is the
//! device-only half the sim drops — the portable `DeviceLoop` only sees the
//! `FirmwareServices` trait.

use frostsnap_comms::{DeviceSendBody, Downstream, Sha256Digest, Upstream};
use frostsnap_embedded::{
    device_hal::{FirmwareServices, UpgradeRefused},
    framed_serial::SerialPort,
    ui::UserInteraction,
};

use crate::crypto::EspCrypto;
use crate::ota::{FirmwareUpgradeMode, OtaPartitions, UpgradeOutcome};
use crate::partitions::PartitionExt;

pub struct EspFirmware<'a> {
    ota: OtaPartitions<'a>,
    active_firmware_digest: Sha256Digest,
    upgrade: Option<FirmwareUpgradeMode<'a>>,
}

impl<'a> EspFirmware<'a> {
    pub fn new(ota: OtaPartitions<'a>, crypto: &mut EspCrypto<'a>) -> Self {
        let active_partition = ota.active_partition();
        let (firmware_size, _firmware_and_signature_block_size) =
            active_partition.firmware_size().unwrap();
        let active_firmware_digest = crypto
            .force_normal_mode()
            .digest(&active_partition, Some(firmware_size));

        Self {
            ota,
            active_firmware_digest,
            upgrade: None,
        }
    }
}

impl<'a> FirmwareServices for EspFirmware<'a> {
    type Crypto = EspCrypto<'a>;

    fn firmware_digest(&self) -> Sha256Digest {
        self.active_firmware_digest
    }

    fn prepare_upgrade(&mut self, size: u32, firmware_digest: Sha256Digest) {
        self.upgrade = Some(self.ota.start_upgrade(
            size,
            firmware_digest,
            self.active_firmware_digest,
        ));
    }

    fn enter_upgrade_mode<U, D>(
        &mut self,
        upstream: &mut U,
        downstream: Option<&mut D>,
        ui: &mut dyn UserInteraction,
        crypto: &mut EspCrypto<'a>,
    ) -> Result<(), UpgradeRefused>
    where
        U: SerialPort<Upstream>,
        D: SerialPort<Downstream>,
    {
        let mut upgrade = self
            .upgrade
            .take()
            .expect("upgrade cannot start because we were not warned about it");
        let outcome = upgrade.enter_upgrade_mode(
            upstream.raw(),
            downstream.map(|d| d.raw()),
            ui,
            &mut crypto.force_normal_mode(),
        );
        match outcome {
            UpgradeOutcome::Committed => Ok(()),
            UpgradeOutcome::Rejected => Err(UpgradeRefused),
        }
    }

    fn poll(&mut self, ui: &mut dyn UserInteraction) -> Option<DeviceSendBody> {
        self.upgrade.as_mut().and_then(|upgrade| upgrade.poll(ui))
    }

    fn confirm_upgrade(&mut self) {
        if let Some(upgrade) = self.upgrade.as_mut() {
            upgrade.upgrade_confirm();
        }
    }

    fn cancel(&mut self) {
        self.upgrade = None;
    }
}
