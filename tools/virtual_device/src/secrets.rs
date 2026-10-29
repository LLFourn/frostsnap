//! The sim's crypto: the only crypto leaf that differs from hardware. esp keys
//! its HMAC peripheral with an eFuse key; the sim keys software HMAC-SHA256 with
//! a RAM dev-key. The derivation every secret goes through (`DevicePrf`'s
//! framing and its blanket `DeviceSecretDerivation`) lives once in
//! `frostsnap_core`, so the sim never re-implements the packing.
//!
//! The device is self-consistent (it both derives and uses its own keys; the
//! coordinator never recomputes them), so a real keyed PRF here makes
//! keygen/signing cryptographically sound and reproducible. A constant hash (the
//! smoke-test stub) is a degenerate key and nonce reuse; this replaces exactly that.

use crate::factory::{SimFactoryData, SimHardware};
use bitcoin::hashes::{sha256, Hash, HashEngine, Hmac, HmacEngine};
use frostsnap_comms::genuine_certificate::{Certificate, DsSignature};
use frostsnap_comms::Sha256Digest;
use frostsnap_core::device::DevicePrf;
use frostsnap_embedded::device_hal::{AttestError, AttestPoll, DeviceCrypto, NormalCrypto};
use std::sync::Arc;

/// One software PRF key, standing in for one eFuse HMAC key.
#[derive(Clone)]
pub struct SimPrf {
    key: [u8; 32],
}

impl SimPrf {
    pub fn new(key: [u8; 32]) -> Self {
        Self { key }
    }

    /// Derive a labelled dev-key from a sim seed, so a given seed yields the same
    /// device across boots and distinct labels yield independent keys.
    pub fn from_seed(seed: u64, label: &str) -> Self {
        let mut engine = sha256::Hash::engine();
        engine.input(label.as_bytes());
        engine.input(&seed.to_le_bytes());
        Self::new(sha256::Hash::from_engine(engine).to_byte_array())
    }
}

impl DevicePrf for SimPrf {
    fn prf(&mut self, message: &[&[u8]]) -> [u8; 32] {
        let mut engine = HmacEngine::<sha256::Hash>::new(&self.key);
        for part in message {
            engine.input(part);
        }
        Hmac::<sha256::Hash>::from_engine(engine).to_byte_array()
    }
}

impl DevicePrf for &mut SimPrf {
    fn prf(&mut self, message: &[&[u8]]) -> [u8; 32] {
        (**self).prf(message)
    }
}

/// The two device secrets, mirroring the esp `HmacKeyIds { share_encryption, fixed_entropy }`.
pub struct SimSecrets {
    share_encryption: SimPrf,
    fixed_entropy: SimPrf,
}

impl NormalCrypto for &mut SimSecrets {
    fn share_encryption(&mut self) -> impl DevicePrf + '_ {
        &mut self.share_encryption
    }

    fn fixed_entropy(&mut self) -> impl DevicePrf + '_ {
        &mut self.fixed_entropy
    }
}

/// A sim device's crypto. Its factory key stands in for the DS: provisioned by the sim factory,
/// it signs attestations in software.
pub struct SimCrypto {
    secrets: SimSecrets,
    factory: Option<Arc<SimFactoryData>>,
    attestation: Attestation,
}

/// The esp DS's states, so the device loop sees an attestation in flight for a tick, as on
/// hardware.
enum Attestation {
    Idle,
    Computing(Box<DsSignature>),
    Finishing(Box<DsSignature>),
}

impl SimCrypto {
    pub fn new(hardware: &SimHardware) -> Self {
        Self {
            secrets: SimSecrets {
                share_encryption: SimPrf::from_seed(hardware.seed(), "share-encryption-key"),
                fixed_entropy: SimPrf::from_seed(hardware.seed(), "fixed-entropy-key"),
            },
            factory: hardware.factory().cloned(),
            attestation: Attestation::Idle,
        }
    }
}

impl DeviceCrypto for SimCrypto {
    fn try_normal_mode(&mut self) -> Option<impl NormalCrypto + '_> {
        match self.attestation {
            Attestation::Idle => Some(&mut self.secrets),
            Attestation::Computing(_) | Attestation::Finishing(_) => None,
        }
    }

    fn force_normal_mode(&mut self) -> impl NormalCrypto + '_ {
        self.attestation = Attestation::Idle;
        &mut self.secrets
    }

    fn start_attestation(&mut self, digest: &Sha256Digest) -> Result<(), AttestError> {
        let factory = self.factory.as_ref().ok_or(AttestError::NoFactoryKey)?;
        self.attestation = Attestation::Computing(Box::new(factory.sign(&digest.0)));
        Ok(())
    }

    fn poll(&mut self) -> AttestPoll {
        match core::mem::replace(&mut self.attestation, Attestation::Idle) {
            Attestation::Idle => AttestPoll::Normal,
            Attestation::Computing(signature) => {
                self.attestation = Attestation::Finishing(signature);
                AttestPoll::InFlight
            }
            Attestation::Finishing(signature) => AttestPoll::Done(Ok(signature)),
        }
    }

    fn certificate(&self) -> Option<Certificate> {
        Some(self.factory.as_ref()?.certificate().clone())
    }
}
