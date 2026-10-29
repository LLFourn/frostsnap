//! The sim's factory: what provisioning makes of a real device, in software. Each device gets its
//! eFuse keys, derived from a seed, and usually its factory data: an RSA-3072 attestation key
//! standing in for its DS key, and a certificate for it. A genuine device's certificate is signed by
//! the dev factory key — the same key `FROSTSNAP_ENV=dev` apps accept, so the app's own verifier is
//! what decides a sim device is genuine.
//!
//! A DS key belongs to one piece of hardware: two devices sharing one look to the coordinator like
//! one device under two ids, and the later one to prove itself supersedes the other. So every
//! device provisioned gets a fresh key, and keeps its hardware for life, across reboots and
//! saved-state restores.

use frostsnap_comms::genuine_certificate::{
    self, CaseColor, Certificate, CertificateBody, DsSignature,
};
use frostsnap_core::schnorr_fun::fun::{marker::EvenY, KeyPair, Scalar};
use frostsnap_core::{hex, schnorr_fun};
use rsa::pkcs1::{DecodeRsaPrivateKey, EncodeRsaPrivateKey, EncodeRsaPublicKey};
use rsa::{Pkcs1v15Sign, RsaPrivateKey};
use sha2::{Digest, Sha256};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

const DEV_FACTORY_SECRET: &str =
    include_str!("../../../frostsnap_factory/genuine/dev/secret_key.hex");

const CASE_COLORS: [CaseColor; 5] = [
    CaseColor::Orange,
    CaseColor::Blue,
    CaseColor::Silver,
    CaseColor::Red,
    CaseColor::Black,
];

/// Which factory a device came from, which decides what the app's genuine check makes of it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SimFactory {
    /// Certified by the dev factory key `FROSTSNAP_ENV=dev` apps trust.
    Genuine,
    /// Certified by a factory key no app trusts, as a counterfeit would be.
    Untrusted,
    /// Never provisioned: with no certificate it can't answer the check at all.
    Blank,
}

/// What a device is made of at the factory, which nothing it does can change.
#[derive(Clone, Debug)]
pub struct SimHardware {
    seed: u64,
    factory: Option<Arc<SimFactoryData>>,
}

impl SimHardware {
    /// New hardware whose eFuse keys derive from `seed`, made by `factory`. Any DS key it gets is
    /// one no other device holds. Consecutive `nth` get distinct case colours, so devices side by
    /// side can be told apart.
    pub fn provision(seed: u64, nth: usize, factory: SimFactory) -> Self {
        let factory = match factory {
            SimFactory::Genuine => Some(SimFactoryData::provision(nth, dev_factory_keypair())),
            SimFactory::Untrusted => Some(SimFactoryData::provision(
                nth,
                KeyPair::new_xonly(Scalar::random(&mut rand_core::OsRng)),
            )),
            SimFactory::Blank => None,
        };
        Self {
            seed,
            factory: factory.map(Arc::new),
        }
    }

    pub(crate) fn seed(&self) -> u64 {
        self.seed
    }

    pub(crate) fn factory(&self) -> Option<&Arc<SimFactoryData>> {
        self.factory.as_ref()
    }

    #[cfg(test)]
    pub(crate) fn certificate(&self) -> Option<&Certificate> {
        Some(self.factory.as_ref()?.certificate())
    }

    /// Whether `self` and `other` would be one piece of hardware to the coordinator.
    pub fn same_ds_key(&self, other: &Self) -> bool {
        match (&self.factory, &other.factory) {
            (Some(a), Some(b)) => a.ds_key.to_public_key() == b.ds_key.to_public_key(),
            _ => false,
        }
    }

    pub(crate) fn encode(&self, bytes: &mut Vec<u8>) {
        // A blank device's record is empty, which factory data never is.
        let factory = self
            .factory
            .as_ref()
            .map(|factory| factory.to_bytes())
            .unwrap_or_default();
        bytes.extend_from_slice(&self.seed.to_le_bytes());
        bytes.extend_from_slice(&(factory.len() as u32).to_le_bytes());
        bytes.extend_from_slice(&factory);
    }

    /// Decodes what [`Self::encode`] wrote, returning the bytes after it.
    pub(crate) fn decode(bytes: &[u8]) -> Result<(Self, &[u8]), String> {
        let truncated = || "hardware truncated".to_string();
        let (seed, rest) = bytes.split_first_chunk::<8>().ok_or_else(truncated)?;
        let (factory_len, rest) = rest.split_first_chunk::<4>().ok_or_else(truncated)?;
        let (factory, rest) = rest
            .split_at_checked(u32::from_le_bytes(*factory_len) as usize)
            .ok_or_else(truncated)?;
        let hardware = Self {
            seed: u64::from_le_bytes(*seed),
            factory: match factory {
                [] => None,
                factory => Some(Arc::new(SimFactoryData::from_bytes(factory)?)),
            },
        };
        Ok((hardware, rest))
    }
}

/// A provisioned device's factory data.
pub(crate) struct SimFactoryData {
    ds_key: RsaPrivateKey,
    certificate: Certificate,
}

impl core::fmt::Debug for SimFactoryData {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("SimFactoryData")
            .field("certificate", &self.certificate)
            .finish_non_exhaustive()
    }
}

impl SimFactoryData {
    fn provision(nth: usize, factory_key: KeyPair<EvenY>) -> Self {
        let ds_key = RsaPrivateKey::new(
            &mut rand_core::OsRng,
            frostsnap_comms::factory::DS_KEY_SIZE_BITS,
        )
        .expect("RSA key generation");
        let fingerprint = Sha256::digest(
            ds_key
                .to_public_key()
                .to_pkcs1_der()
                .expect("an RSA public key always has a DER encoding"),
        );
        let certificate = genuine_certificate::sign_certificate(
            schnorr_fun::new_with_deterministic_nonces::<Sha256>(),
            CertificateBody::Frontier {
                ds_public_key: (&ds_key.to_public_key()).into(),
                case_color: CASE_COLORS[nth % CASE_COLORS.len()],
                revision: "sim".into(),
                serial: format!("SIM{}", hex::encode(&fingerprint[..4])),
                timestamp: SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .expect("the clock is after 1970")
                    .as_secs(),
            },
            factory_key,
        );
        Self {
            ds_key,
            certificate,
        }
    }

    pub fn certificate(&self) -> &Certificate {
        &self.certificate
    }

    /// What the DS computes over a digest: a PKCS#1 v1.5 SHA-256 signature.
    pub fn sign(&self, digest: &[u8; 32]) -> DsSignature {
        let signature = self
            .ds_key
            .sign(Pkcs1v15Sign::new::<Sha256>(), digest)
            .expect("an RSA-3072 key signs a SHA-256 digest");
        DsSignature(
            signature
                .try_into()
                .expect("an RSA-3072 signature is 384 bytes"),
        )
    }

    fn to_bytes(&self) -> Vec<u8> {
        let ds_key = self
            .ds_key
            .to_pkcs1_der()
            .expect("an RSA private key always has a DER encoding");
        let ds_key = ds_key.as_bytes();
        let mut bytes = (ds_key.len() as u32).to_le_bytes().to_vec();
        bytes.extend_from_slice(ds_key);
        bytes.extend(
            bincode::encode_to_vec(&self.certificate, frostsnap_comms::BINCODE_CONFIG)
                .expect("a certificate always encodes"),
        );
        bytes
    }

    fn from_bytes(bytes: &[u8]) -> Result<Self, String> {
        let (len, rest) = bytes
            .split_first_chunk::<4>()
            .ok_or("factory data truncated")?;
        let (ds_key, certificate_bytes) = rest
            .split_at_checked(u32::from_le_bytes(*len) as usize)
            .ok_or("factory data truncated")?;
        let ds_key = RsaPrivateKey::from_pkcs1_der(ds_key).map_err(|e| format!("DS key: {e}"))?;
        let (certificate, read) =
            bincode::decode_from_slice(certificate_bytes, frostsnap_comms::BINCODE_CONFIG)
                .map_err(|e| format!("certificate: {e}"))?;
        if read != certificate_bytes.len() {
            return Err("trailing bytes after the certificate".into());
        }
        Ok(Self {
            ds_key,
            certificate,
        })
    }
}

pub fn dev_factory_keypair() -> KeyPair<EvenY> {
    let bytes: [u8; 32] = hex::decode(DEV_FACTORY_SECRET.trim())
        .expect("dev factory key is hex")
        .try_into()
        .expect("dev factory key is 32 bytes");
    KeyPair::new_xonly(
        Scalar::from_bytes_mod_order(bytes)
            .non_zero()
            .expect("dev factory key is non-zero"),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::firmware::{FirmwareDigestCell, SimFirmware};
    use crate::secrets::SimCrypto;
    use crate::serial::pipe;
    use crate::thread::{spawn_device_thread, DeviceHandles, DeviceThread};
    use crate::{PortConnection, RamFlash, VirtualSerial};
    use frostsnap_comms::genuine_certificate::GenuineError;
    use frostsnap_comms::genuine_check::{self, AttestedDevice, DsSignedMessage};
    use frostsnap_comms::{CoordinatorSendMessage, GenuineChallenge, Sha256Digest};
    use frostsnap_coordinator::genuine_check::{GenuineCheck, GenuineStatus};
    use frostsnap_coordinator::{DeviceChange, FirmwareVersion, UsbSerialManager};
    use frostsnap_core::DeviceId;
    use frostsnap_embedded::device_hal::{AttestPoll, DeviceCrypto};
    use std::collections::VecDeque;
    use std::time::{Duration, Instant};

    /// A device on its own thread behind a coordinator running #522's genuine check, wired as the
    /// app wires it.
    struct Rig {
        device_id: DeviceId,
        hardware: SimHardware,
        _thread: DeviceThread,
        manager: UsbSerialManager,
        connection: PortConnection,
        check: GenuineCheck,
        /// The last factory-attestation reply that did not verify.
        rejected: Option<GenuineError>,
        replies: usize,
    }

    impl Rig {
        /// A device from `factory`, behind a coordinator that trusts `trusted`.
        fn new(seed: u64, factory: SimFactory, trusted: KeyPair<EvenY>) -> Self {
            let (upstream_io, host) = pipe();
            let identity = crate::identity::DeviceIdentityCell::new();
            let hardware = SimHardware::provision(seed, 0, factory);
            let thread = spawn_device_thread(
                hardware.clone(),
                FirmwareDigestCell::new(SimFirmware::PLACEHOLDER_DIGEST),
                identity.clone(),
                DeviceHandles {
                    upstream_io,
                    downstream_io: crate::serial::PipeByteIo::disconnected(),
                    framebuffer: crate::SharedFramebuffer::new(),
                    touch: crate::TouchQueue::new(),
                    observation: crate::SimObservation::new(),
                    downstream_present: None,
                    on_frame: Arc::new(|_, _, _| {}),
                },
                RamFlash::new(),
            );
            let serial = VirtualSerial::single("sim-0", host);
            let connection = serial.connection();
            Self {
                device_id: identity.get().expect("booted"),
                hardware,
                _thread: thread,
                manager: UsbSerialManager::new(Box::new(serial)),
                connection,
                check: GenuineCheck::new(trusted.public_key()),
                rejected: None,
                replies: 0,
            }
        }

        fn poll(&mut self) {
            let mut rng = rand_core::OsRng;
            for change in self.manager.poll_ports() {
                match change {
                    DeviceChange::NeedsName { id } => {
                        self.manager.accept_device_name(id, "Sim".to_string())
                    }
                    DeviceChange::Connected {
                        id,
                        firmware_digest,
                        ..
                    } => {
                        if let Some(request) = self.check.connected(
                            id,
                            FirmwareVersion::new(firmware_digest),
                            &mut rng,
                        ) {
                            self.manager
                                .usb_sender()
                                .send(CoordinatorSendMessage::to(id, request.into()));
                        }
                    }
                    DeviceChange::Disconnected { id } => self.check.disconnected(id),
                    DeviceChange::GenuineCheck { from, message } => {
                        self.replies += 1;
                        match self
                            .check
                            .recv(from, message, &mut VecDeque::new(), &mut rng)
                        {
                            Ok(Some(request)) => self
                                .manager
                                .usb_sender()
                                .send(CoordinatorSendMessage::to(from, request.into())),
                            Ok(None) => {}
                            Err(error) => self.rejected = Some(error),
                        }
                    }
                    _ => {}
                }
            }
            std::thread::sleep(Duration::from_millis(5));
        }

        fn poll_until(&mut self, what: &str, mut done: impl FnMut(&Self) -> bool) {
            let deadline = Instant::now() + Duration::from_secs(60);
            while !done(self) {
                assert!(Instant::now() < deadline, "timed out waiting for {what}");
                self.poll();
            }
        }

        fn status(&self) -> Option<GenuineStatus> {
            self.check.status(self.device_id)
        }

        fn genuine_certificate(&self) -> Option<CertificateBody> {
            match self.status()? {
                GenuineStatus::Genuine { certificate } => Some(*certificate),
                GenuineStatus::Unverified { .. } => None,
            }
        }
    }

    #[test]
    fn a_sim_device_proves_it_is_genuine_to_the_coordinators_check() {
        let mut rig = Rig::new(400, SimFactory::Genuine, dev_factory_keypair());
        rig.poll_until("the device to prove itself genuine", |rig| {
            rig.genuine_certificate().is_some()
        });
        let certificate = rig.genuine_certificate().unwrap();
        let provisioned = genuine_certificate::verify_certificate(
            rig.hardware.certificate().unwrap(),
            dev_factory_keypair().public_key(),
        )
        .unwrap();
        assert_eq!(certificate, provisioned);
    }

    // The app trusts the dev factory's public key file, and the sim signs with its secret key file:
    // every other test here verifies against a key derived from the secret, so only this one sees
    // the two files drift apart.
    #[test]
    fn the_sim_signs_with_the_key_dev_apps_trust() {
        let trusted = hex::decode(
            include_str!("../../../frostsnap_factory/genuine/dev/public_key.hex").trim(),
        )
        .expect("dev factory public key is hex");
        assert_eq!(
            dev_factory_keypair().public_key().to_xonly_bytes().to_vec(),
            trusted
        );
    }

    #[test]
    fn each_device_provisioned_is_distinct_hardware() {
        let devices: Vec<SimHardware> = (0..CASE_COLORS.len())
            .map(|nth| SimHardware::provision(0, nth, SimFactory::Genuine))
            .collect();
        let factory = dev_factory_keypair().public_key();
        let bodies: Vec<CertificateBody> = devices
            .iter()
            .map(|device| {
                genuine_certificate::verify_certificate(device.certificate().unwrap(), factory)
            })
            .collect::<Result<_, _>>()
            .expect("the dev factory signed every certificate");
        for (i, a) in devices.iter().enumerate() {
            for b in &devices[i + 1..] {
                assert!(!a.same_ds_key(b));
            }
        }
        let distinct = |of: fn(&CertificateBody) -> String| {
            bodies
                .iter()
                .map(of)
                .collect::<std::collections::HashSet<_>>()
                .len()
        };
        assert_eq!(distinct(|body| body.case_color().to_string()), bodies.len());
        assert_eq!(distinct(|body| body.serial_number()), bodies.len());
    }

    #[test]
    fn a_reconnected_device_is_challenged_again_and_shows_no_colour_until_it_proves_itself() {
        let mut rig = Rig::new(420, SimFactory::Genuine, dev_factory_keypair());
        rig.poll_until("the device to prove itself genuine", |rig| {
            rig.genuine_certificate().is_some()
        });

        rig.connection.set_connected(false);
        rig.poll_until("the device to disconnect", |rig| rig.status().is_none());
        rig.connection.set_connected(true);
        rig.poll_until("the device to reconnect", |rig| rig.status().is_some());
        assert!(
            rig.genuine_certificate().is_none(),
            "a new connection has proven nothing, so it carries no certificate or colour"
        );
        assert!(
            rig.check.certificate(rig.device_id).is_some(),
            "even though the factory attestation stays on file"
        );
        rig.poll_until("the device to prove itself again", |rig| {
            rig.genuine_certificate().is_some()
        });
    }

    #[test]
    fn a_device_from_an_untrusted_factory_answers_but_is_not_genuine() {
        let mut rig = Rig::new(430, SimFactory::Untrusted, dev_factory_keypair());
        rig.poll_until("the attestation to be rejected", |rig| {
            rig.rejected.is_some()
        });
        assert_eq!(rig.rejected, Some(GenuineError::UnknownFactoryKey));
        assert_eq!(
            rig.status(),
            Some(GenuineStatus::Unverified {
                firmware_supports_check: true
            })
        );
    }

    #[test]
    fn a_blank_device_never_answers_and_stays_unverified() {
        let mut rig = Rig::new(435, SimFactory::Blank, dev_factory_keypair());
        rig.poll_until("the device to connect", |rig| rig.status().is_some());
        // Absence can only be shown by waiting: a genuine device has answered well within this.
        let quiet_until = Instant::now() + Duration::from_secs(2);
        while Instant::now() < quiet_until {
            rig.poll();
        }
        assert_eq!(rig.replies, 0);
        assert_eq!(
            rig.status(),
            Some(GenuineStatus::Unverified {
                firmware_supports_check: true
            })
        );
    }

    #[test]
    fn a_certificate_for_another_ds_key_is_not_genuine() {
        let device = SimFactoryData::provision(0, dev_factory_keypair());
        let other = SimFactoryData::provision(1, dev_factory_keypair());
        let mismatched = SimFactoryData {
            ds_key: device.ds_key.clone(),
            certificate: other.certificate.clone(),
        };
        let mut crypto = SimCrypto::new(&SimHardware {
            seed: 440,
            factory: Some(Arc::new(mismatched)),
        });
        let device_id = DeviceId([2u8; 33]);
        let attested = AttestedDevice::V0 {
            device_id,
            certificate: crypto.certificate().unwrap(),
        };
        let challenge = GenuineChallenge([5u8; 32]);
        let signed = DsSignedMessage::GenuineAttestationV0 {
            challenge,
            attested: attested.clone(),
        };
        crypto.start_attestation(&signed.digest()).unwrap();
        let signature = loop {
            match crypto.poll() {
                AttestPoll::Done(outcome) => break outcome.unwrap(),
                AttestPoll::InFlight => {}
                AttestPoll::Normal => panic!("the attestation was dropped"),
            }
        };
        assert_eq!(
            genuine_check::verify_factory_attestation(
                &attested,
                dev_factory_keypair().public_key(),
                challenge,
                device_id,
                &genuine_check::AttestationSignature::Rsa3072(*signature),
            ),
            Err(GenuineError::FactoryAttestationSignatureInvalid)
        );
    }

    #[test]
    fn the_secrets_are_not_lent_while_an_attestation_is_in_flight() {
        let mut crypto = SimCrypto::new(&SimHardware::provision(450, 0, SimFactory::Genuine));
        crypto.start_attestation(&Sha256Digest([1u8; 32])).unwrap();
        assert!(crypto.try_normal_mode().is_none());
        assert_eq!(crypto.poll(), AttestPoll::InFlight);
        assert!(crypto.try_normal_mode().is_none());
        assert!(matches!(crypto.poll(), AttestPoll::Done(Ok(_))));
        assert!(crypto.try_normal_mode().is_some());
    }
}
