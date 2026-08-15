//! The sim's keyed-hash *primitive* — the only crypto leaf that differs from
//! hardware. esp keys an HMAC peripheral with an eFuse key; the sim keys software
//! HMAC-SHA256 with a RAM dev-key, using the *same* length-prefixed-domain
//! construction (`device/src/efuse.rs:473-500`). The portable derivation
//! (`ShareEncryptionSecrets`, share-encryption key + nonce seeds) lives once in
//! `frostsnap_embedded` and wraps this — the sim never re-implements the packing.
//!
//! The device is self-consistent (it both derives and uses its own keys; the
//! coordinator never recomputes them), so a real keyed PRF here makes
//! keygen/signing cryptographically sound and reproducible. A constant hash (the
//! smoke-test stub) is a degenerate key and nonce reuse; this replaces exactly that.

use bitcoin::hashes::{sha256, Hash, HashEngine, Hmac, HmacEngine};
use frostsnap_embedded::KeyedHash;

/// One software keyed-hash key. A device holds two distinct ones — the
/// fixed-entropy key (derives the device keypair, via `keypair_hasher`) and the
/// share-encryption key (wrapped in `ShareEncryptionSecrets` for keygen/signing) —
/// mirroring the esp `EfuseHmacKeys { fixed_entropy, share_encryption }` split.
#[derive(Clone)]
pub struct SimKeyedHash {
    key: [u8; 32],
}

impl SimKeyedHash {
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

impl KeyedHash for SimKeyedHash {
    fn keyed_hash(&mut self, domain: &str, input: &[u8]) -> [u8; 32] {
        let mut engine = HmacEngine::<sha256::Hash>::new(&self.key);
        engine.input(&[domain.len() as u8]);
        engine.input(domain.as_bytes());
        engine.input(input);
        Hmac::<sha256::Hash>::from_engine(engine).to_byte_array()
    }
}
