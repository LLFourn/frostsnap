//! The hardware-abstraction seam the lifted `DeviceLoop` runs on.
//!
//! `device/` implements `DeviceHal`/`FirmwareServices` over esp-hal; a host/sim
//! build implements them with in-memory peripherals. The portable run-loop only
//! ever sees these traits — never `esp_hal`.

use crate::framed_serial::SerialPort;
use crate::ui::UserInteraction;
use alloc::boxed::Box;
use embedded_graphics::geometry::Point;
use embedded_storage::nor_flash::{NorFlash, ReadNorFlash};
use frostsnap_comms::genuine_certificate::{Certificate, DsSignature};
use frostsnap_comms::{DeviceSendBody, Downstream, Sha256Digest, Upstream};
use frostsnap_core::device::DevicePrf;
use rand_core::{CryptoRng, RngCore};

/// A decoded touch sample in device-display space (calibration already applied).
/// The esp impl converts CST816S events/gestures into these; host/sim synthesizes
/// them. The portable touch handler keys off `lift_up` + `gesture`.
#[derive(Clone, Copy, Debug)]
pub struct TouchEvent {
    pub point: Point,
    /// true on release (CST816S `action == 1`).
    pub lift_up: bool,
    pub gesture: TouchGesture,
}

/// Portable mirror of the CST816S gesture set the UI cares about.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TouchGesture {
    None,
    SlideUp,
    SlideDown,
    SlideLeft,
    SlideRight,
}

/// A monotonic millisecond clock. `FrostyUi` owns one so `poll()`/`force_redraw()`
/// can stay signatureless and still advance during blocking loops (e.g. erase);
/// `DeviceLoop` takes a separate `&dyn Clock` for its own protocol timing (it
/// can't read the UI's private clock, and `parts()` borrows all of the HAL).
/// esp: the system timer; host: a fake/atomic counter.
pub trait Clock {
    fn now_ms(&self) -> u64;
}

/// A source of already-decoded touch samples. esp: wraps the CST816S
/// `TouchReceiver` + panel calibration; host/sim: a scriptable queue.
pub trait TouchSource {
    fn next_touch(&mut self) -> Option<TouchEvent>;
}

/// Outcome of one `DeviceLoop::poll`. `ResetRequested` means the loop already
/// sent the upstream reset signal; the device shell performs the actual reset.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Poll {
    Continue,
    ResetRequested,
}

/// Outcome of `DeviceLoop` construction: either a ready loop, or a reset request
/// (the init-time recovery erase ran). The shell resets instead of running.
pub enum InitOutcome<L> {
    Ready(L),
    ResetRequested,
}

/// Why a factory attestation produced no signature.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AttestError {
    NoFactoryKey,
    FactoryDataUnreadable,
    /// The signer refused the key or its own result.
    Rejected,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AttestPoll {
    Normal,
    InFlight,
    /// The outcome of the last [`DeviceCrypto::start_attestation`], returned once.
    Done(Result<Box<DsSignature>, AttestError>),
}

/// The device's secret-holding crypto. A factory attestation runs across many loop ticks, and
/// nothing else may use the crypto until it has finished, so the device secrets are only lent
/// through [`NormalCrypto`], which can't exist while an attestation is in flight.
pub trait DeviceCrypto {
    /// `None` from the start of an attestation until it has finished. Never waits.
    fn try_normal_mode(&mut self) -> Option<impl NormalCrypto + '_>;

    /// Abandons any attestation in flight, whose outcome is then never returned.
    fn force_normal_mode(&mut self) -> impl NormalCrypto + '_;

    /// Abandons any attestation in flight and starts signing `digest` with the factory key.
    fn start_attestation(&mut self, digest: &Sha256Digest) -> Result<(), AttestError>;

    /// Advances an attestation in flight by one step. Never waits.
    fn poll(&mut self) -> AttestPoll;

    /// `None` on a device without a factory certificate.
    fn certificate(&self) -> Option<Certificate>;
}

/// The device secrets, lent while no attestation is in flight.
pub trait NormalCrypto {
    fn share_encryption(&mut self) -> impl DevicePrf + '_;
    fn fixed_entropy(&mut self) -> impl DevicePrf + '_;
}

/// The image was downloaded but refused, so the active slot is untouched and the running firmware
/// is still good.
pub struct UpgradeRefused;

/// Device-only firmware services: OTA upgrades.
pub trait FirmwareServices {
    type Crypto: DeviceCrypto;

    /// Active firmware digest, for `DeviceSendBody::Announce`.
    fn firmware_digest(&self) -> Sha256Digest;

    /// Stages an upgrade to an image of `size` bytes with `firmware_digest`.
    fn prepare_upgrade(&mut self, size: u32, firmware_digest: Sha256Digest);

    /// Takes over the serial links for the image transfer of the staged upgrade. `Ok` means the
    /// device must now reset.
    fn enter_upgrade_mode<U, D>(
        &mut self,
        upstream: &mut U,
        downstream: Option<&mut D>,
        ui: &mut dyn UserInteraction,
        crypto: &mut Self::Crypto,
    ) -> Result<(), UpgradeRefused>
    where
        U: SerialPort<Upstream>,
        D: SerialPort<Downstream>;

    /// Drives a staged upgrade (erase progress, ack). Returns a message to forward.
    fn poll(&mut self, ui: &mut dyn UserInteraction) -> Option<DeviceSendBody>;

    /// The user confirmed the on-screen upgrade prompt (`UiEvent::UpgradeConfirm`).
    fn confirm_upgrade(&mut self);

    /// Drops any staged upgrade (coordinator `Cancel` or a soft reset).
    fn cancel(&mut self);
}

/// The device's peripheral bundle. `DeviceLoop` owns the split-borrow returned by
/// `parts()` plus a `&dyn Clock`, a `&mut UserInteraction`, and the NVS
/// `FlashPartition` (passed to `DeviceLoop::new` from an externally-owned
/// `RefCell<Storage>`, so the HAL never has to expose a self-referential borrow).
pub trait DeviceHal {
    // `Debug` because `FrostSigner`'s methods require it on the nonce-slot's
    // storage type (the nonce slot derives `Debug`).
    type Storage: NorFlash + ReadNorFlash + core::fmt::Debug;
    type Upstream: SerialPort<frostsnap_comms::Upstream>;
    type Downstream: SerialPort<frostsnap_comms::Downstream>;
    type Rng: RngCore + CryptoRng;
    type Crypto: DeviceCrypto;
    type Firmware: FirmwareServices<Crypto = Self::Crypto>;

    /// Split-borrow: one `&mut self` yields independent `&mut` sub-borrows so the
    /// loop can hold several at once.
    fn parts(&mut self) -> HalParts<'_, Self>;
}

pub struct HalParts<'a, H: DeviceHal + ?Sized> {
    pub upstream: &'a mut H::Upstream,
    pub downstream: &'a mut H::Downstream,
    pub rng: &'a mut H::Rng,
    pub crypto: &'a mut H::Crypto,
    pub firmware: &'a mut H::Firmware,
}
