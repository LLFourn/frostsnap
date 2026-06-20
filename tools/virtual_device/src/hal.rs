//! `SimHal`: the software `DeviceHal` the portable `DeviceLoop` runs on. Mirrors
//! the esp `EspHal` (`device/src/esp32_run.rs`) field-for-field — two `FramedSerial`
//! links, an RNG, the two keyed-hash secrets (fixed-entropy + share-encryption),
//! and firmware services — but every associated type is a software peripheral.

use crate::clock::SimClock;
use crate::firmware::SimFirmware;
use crate::flash::RamFlash;
use crate::secrets::SimKeyedHash;
use crate::serial::PipeByteIo;
use frostsnap_comms::{Downstream, Upstream};
use frostsnap_embedded::{
    device_hal::{DeviceHal, HalParts},
    framed_serial::FramedSerial,
    KeyedHash, ShareEncryptionSecrets,
};
use rand_chacha::ChaCha20Rng;

pub type SimUpstream = FramedSerial<PipeByteIo, SimClock, Upstream>;
pub type SimDownstream = FramedSerial<PipeByteIo, SimClock, Downstream>;

pub struct SimHal {
    pub(crate) upstream: SimUpstream,
    pub(crate) downstream: SimDownstream,
    pub(crate) rng: ChaCha20Rng,
    pub(crate) share_encryption: ShareEncryptionSecrets<SimKeyedHash>,
    pub(crate) fixed_entropy: SimKeyedHash,
    pub(crate) firmware: SimFirmware,
}

impl DeviceHal for SimHal {
    type Storage = RamFlash;
    type Upstream = SimUpstream;
    type Downstream = SimDownstream;
    type Rng = ChaCha20Rng;
    type Secrets = ShareEncryptionSecrets<SimKeyedHash>;
    type Firmware = SimFirmware;

    fn parts(&mut self) -> HalParts<'_, Self> {
        HalParts {
            upstream: &mut self.upstream,
            downstream: &mut self.downstream,
            rng: &mut self.rng,
            secrets: &mut self.share_encryption,
            firmware: &mut self.firmware,
        }
    }

    fn keypair_hasher(&mut self) -> &mut dyn KeyedHash {
        &mut self.fixed_entropy
    }
}
