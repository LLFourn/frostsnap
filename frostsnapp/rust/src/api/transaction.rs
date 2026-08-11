use std::collections::HashSet;
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, RwLock};

use bitcoin::Address;
use flutter_rust_bridge::frb;
use frostsnap_core::{AccessStructureId, DeviceId, MasterAppkey};

use crate::api::bitcoin::BitcoinNetworkExt;
use crate::api::broadcast::{Broadcast, UnitBroadcastSubscription};
use crate::api::signing::UnsignedTx;
use crate::frb_generated::RustAutoOpaque;

use super::{
    coordinator::{AccessStructure, Coordinator, FrostKey},
    super_wallet::SuperWallet,
};

#[derive(Default, Clone, Copy, PartialEq)]
pub enum ConfirmationTarget {
    Low,
    #[default]
    Medium,
    High,
    /// Custom feerate.
    Custom(f32),
}

impl ConfirmationTarget {
    #[frb(sync)]
    pub fn feerate(self, estimates: Option<ConfirmationEstimates>) -> Option<f32> {
        Some(match self {
            ConfirmationTarget::Low => estimates?.low,
            ConfirmationTarget::Medium => estimates?.medium,
            ConfirmationTarget::High => estimates?.high,
            ConfirmationTarget::Custom(feerate) => feerate,
        })
    }

    #[frb(sync)]
    pub fn is_low(&self) -> bool {
        matches!(self, Self::Low)
    }

    #[frb(sync)]
    pub fn is_medium(&self) -> bool {
        matches!(self, Self::Medium)
    }

    #[frb(sync)]
    pub fn is_high(&self) -> bool {
        matches!(self, Self::High)
    }

    #[frb(sync)]
    pub fn is_custom(&self) -> bool {
        matches!(self, Self::Custom(_))
    }
}

#[derive(Clone, Copy, PartialEq)]
#[frb(type_64bit_int)]
pub struct ConfirmationEstimates {
    /// Unix timestamp of last refresh.
    pub last_refresh: u64,
    /// 1 confirmation.
    pub low: f32,
    /// 2 confirmations.
    pub medium: f32,
    /// 3 confirmations.
    pub high: f32,
}

#[derive(Clone, Copy, PartialEq, Eq)]
#[frb(type_64bit_int)]
pub enum AmountType {
    /// Send all.
    SendMax,
    /// Value in satoshis.
    Value(u64),
}

impl AmountType {
    #[frb(sync, type_64bit_int)]
    pub fn from_value(value: u64) -> Self {
        Self::Value(value)
    }

    #[frb(sync, type_64bit_int)]
    pub fn value(&self) -> Option<u64> {
        match self {
            Self::SendMax => None,
            Self::Value(v) => Some(*v),
        }
    }

    #[frb(sync)]
    pub fn is_send_max(&self) -> bool {
        matches!(self, Self::SendMax)
    }
}

#[derive(Clone, Default)]
pub struct Recipient {
    pub address: Option<Address>,
    pub amount: Option<AmountType>,
}

impl Recipient {
    #[frb(sync)]
    pub fn new(address: Option<Address>, amount: Option<AmountType>) -> Self {
        Self { address, amount }
    }
}

pub(crate) struct BuildTxInner {
    /// Confirmation estimates.
    pub(crate) confirmation_estimates: Option<ConfirmationEstimates>,
    /// Feerate in sats/vb.
    pub(crate) confirmation_target: ConfirmationTarget,
    /// Recipients to send to and amounts.
    pub(crate) recipients: Vec<Recipient>,
    /// The selected access structure.
    pub(crate) access_id: Option<AccessStructureId>,
    /// Selected devices to sign the transaction.
    pub(crate) signers: HashSet<DeviceId>,
}

impl BuildTxInner {
    fn get_or_create_recipient(&mut self, recipient: u32) -> &mut Recipient {
        let i: usize = recipient.try_into().expect("recipient index too large");
        while self.recipients.len() <= i {
            self.recipients.push(Recipient::default());
        }
        self.recipients.get_mut(i).expect("must exist")
    }

    /// Returns `None` if confirmation target is set to low/medium/high but we don't have confirmation estimates.
    fn feerate(&self) -> Option<f32> {
        self.confirmation_target
            .feerate(self.confirmation_estimates)
    }

    /// Returns `None` if no feerate is specified.
    fn available_amount(
        &self,
        super_wallet: &SuperWallet,
        master_appkey: MasterAppkey,
        recipient: u32,
        max_inputs: Option<u32>,
    ) -> Option<u64> {
        Some(
            super_wallet.calculate_available(
                master_appkey,
                self.recipients
                    .iter()
                    .skip(recipient.saturating_sub(1) as usize)
                    .filter_map(|r| r.address.clone())
                    .map(RustAutoOpaque::new)
                    .collect(),
                self.feerate()?,
                max_inputs,
            ),
        )
    }
}

pub struct BuildTxState {
    pub(crate) coord: RustAutoOpaque<Coordinator>,
    pub(crate) super_wallet: SuperWallet,
    pub(crate) frost_key: FrostKey,
    pub(crate) broadcast: Broadcast<()>,
    pub(crate) is_refreshing: Arc<AtomicBool>,
    pub(crate) inner: Arc<RwLock<BuildTxInner>>,
}

impl BuildTxState {
    #[frb(sync)]
    pub fn subscribe(&self) -> UnitBroadcastSubscription {
        UnitBroadcastSubscription(self.broadcast.subscribe())
    }

    #[frb(sync)]
    pub fn master_appkey(&self) -> MasterAppkey {
        self.frost_key.master_appkey()
    }

    #[frb(sync)]
    pub fn confirmation_estimates(&self) -> Option<ConfirmationEstimates> {
        self.inner.read().unwrap().confirmation_estimates
    }

    #[frb(sync)]
    pub fn is_refreshing_confirmation_estimates(&self) -> bool {
        use std::sync::atomic::Ordering;

        self.is_refreshing.load(Ordering::Relaxed)
    }

    /// Refresh confirmation estimates.
    ///
    /// Returns `None` if a previous referesh request has not completed yet.
    pub fn refresh_confirmation_estimates(&self) -> anyhow::Result<Option<ConfirmationEstimates>> {
        use std::sync::atomic::Ordering;

        if self
            .is_refreshing
            .compare_exchange(false, true, Ordering::Acquire, Ordering::Relaxed)
            .is_err()
        {
            return Ok(None);
        }
        self._trigger_changed();

        let estimates = self._refresh_confirmation_estimates()?;

        self.is_refreshing.store(false, Ordering::Release);
        self._trigger_changed();

        Ok(Some(estimates))
    }

    fn _refresh_confirmation_estimates(&self) -> anyhow::Result<ConfirmationEstimates> {
        let estimates = self.super_wallet.estimate_fee(vec![3, 2, 1])?;
        let confirmation_estimates = ConfirmationEstimates {
            last_refresh: std::time::UNIX_EPOCH.elapsed()?.as_secs(),
            low: estimates[0].1 as _,
            medium: estimates[1].1 as _,
            high: estimates[2].1 as _,
        };
        let mut inner = self.inner.write().unwrap();
        if inner.confirmation_estimates != Some(confirmation_estimates) {
            inner.confirmation_estimates = Some(confirmation_estimates);
        }
        Ok(confirmation_estimates)
    }

    #[frb(sync)]
    pub fn confirmation_blocks_of_feerate(&self) -> Option<u32> {
        let inner = self.inner.read().unwrap();
        match inner.confirmation_target {
            ConfirmationTarget::Low => return Some(3),
            ConfirmationTarget::Medium => return Some(2),
            ConfirmationTarget::High => return Some(1),
            ConfirmationTarget::Custom(feerate) => {
                let targets = inner.confirmation_estimates?;
                if feerate <= targets.high {
                    return Some(1);
                }
                if feerate <= targets.medium {
                    return Some(2);
                }
                if feerate <= targets.low {
                    return Some(3);
                }
                return None;
            }
        };
    }

    /// Remaining amount that is available for recipient, no larger than what the devices'
    /// remaining signing nonces allow a single transaction to spend.
    ///
    /// Returns `None` if no feerate is specified.
    #[frb(sync)]
    pub fn available_amount(&self, recipient: u32) -> Option<u64> {
        let max_inputs = self.max_signable_inputs();
        let inner = self.inner.read().unwrap();
        inner.available_amount(
            &self.super_wallet,
            self.frost_key.master_appkey(),
            recipient,
            max_inputs,
        )
    }

    /// What [`Self::available_amount`] would be if signing nonces were plentiful. When this
    /// exceeds `available_amount` the difference is spendable balance the devices cannot
    /// currently sign for.
    #[frb(sync)]
    pub fn available_amount_ignoring_nonces(&self, recipient: u32) -> Option<u64> {
        let inner = self.inner.read().unwrap();
        inner.available_amount(
            &self.super_wallet,
            self.frost_key.master_appkey(),
            recipient,
            None,
        )
    }

    /// How many inputs a single transaction can have and still be signable.
    ///
    /// `Some(0)` means no spend is possible at all: fewer than `threshold` devices have any
    /// nonces left. `None` means there is nothing to limit by (no access structure).
    ///
    /// A device's capacity is its best single nonce stream — a signing session cannot span
    /// streams — and the cap is the minimum over devices that have nonces at all, so whichever
    /// signers the user picks later can sign the transaction built under it.
    #[frb(sync)]
    pub fn max_signable_inputs(&self) -> Option<u32> {
        let access_id = self.inner.read().unwrap().access_id;
        let access = access_id
            .and_then(|id| self.frost_key.get_access_structure(id))
            .or_else(|| self.frost_key.access_structures().into_iter().next())?;
        let coord = self.coord.blocking_read();
        let capacities = access.devices().map(|id| coord.nonces_available(id));
        Some(signable_input_cap(capacities, access.threshold() as usize))
    }

    #[frb(sync)]
    pub fn access_structures(&self) -> Vec<AccessStructure> {
        self.frost_key.access_structures()
    }

    #[frb(sync)]
    pub fn available_signers(&self) -> Vec<(DeviceId, Option<String>)> {
        let access_id_opt = self.inner.read().unwrap().access_id;
        let coord_lock = self.coord.blocking_read();
        access_id_opt
            .and_then(|a_id| self.frost_key.get_access_structure(a_id))
            .map_or(Vec::new(), |access| {
                access
                    .devices()
                    .map(move |d_id| {
                        let name = coord_lock.get_device_name(d_id);
                        (d_id, name)
                    })
                    .collect::<Vec<_>>()
            })
    }

    #[frb(sync)]
    pub fn selected_signers(&self) -> Vec<DeviceId> {
        self.inner.read().unwrap().signers.iter().copied().collect()
    }

    #[frb(sync)]
    pub fn access_struct(&self) -> Option<AccessStructure> {
        let inner = self.inner.read().unwrap();
        let access_id = inner.access_id?;
        self.frost_key.get_access_structure(access_id)
    }

    #[frb(sync)]
    pub fn access_id(&self) -> Option<AccessStructureId> {
        self.inner.read().unwrap().access_id
    }

    #[frb(sync)]
    pub fn set_access_id(&self, access_id: &AccessStructureId) {
        let mut inner = self.inner.write().unwrap();
        if inner.access_id.as_ref() != Some(access_id) {
            inner.access_id = Some(*access_id);
            inner.signers.clear();
            self._trigger_changed();
        }
    }

    #[frb(sync)]
    pub fn select_signer(&self, d_id: DeviceId) {
        let mut inner = self.inner.write().unwrap();
        if inner.signers.insert(d_id) {
            self._trigger_changed();
        }
    }

    #[frb(sync)]
    pub fn deselect_signer(&self, d_id: DeviceId) {
        let mut inner = self.inner.write().unwrap();
        if inner.signers.remove(&d_id) {
            self._trigger_changed();
        }
    }

    #[frb(sync)]
    pub fn is_signer_selected(&self, d_id: DeviceId) -> bool {
        let inner = self.inner.read().unwrap();
        inner.signers.contains(&d_id)
    }

    #[frb(sync)]
    pub fn recipient_count(&self) -> u64 {
        let inner = self.inner.read().unwrap();
        inner.recipients.len() as u64
    }

    #[frb(sync)]
    pub fn recipient(&self, recipient: u32) -> Option<Recipient> {
        let inner = self.inner.read().unwrap();
        inner.recipients.get(recipient as usize).cloned()
    }

    /// Determines the target feerate.
    ///
    /// If confirmation target is not `Custom`, this value uses the `ConfirmationEstimates` to
    /// determine the feerate.
    #[frb(sync)]
    pub fn feerate(&self) -> Option<f32> {
        let inner = self.inner.read().unwrap();
        inner
            .confirmation_target
            .feerate(inner.confirmation_estimates)
    }

    #[frb(sync)]
    pub fn confirmation_target(&self) -> ConfirmationTarget {
        let inner = self.inner.read().unwrap();
        inner.confirmation_target
    }

    #[frb(sync)]
    pub fn set_confirmation_target(&self, target: ConfirmationTarget) {
        let mut inner = self.inner.write().unwrap();
        if inner.confirmation_target != target {
            inner.confirmation_target = target;
            self._trigger_changed();
        }
    }

    #[frb(sync, type_64bit_int)]
    pub fn fee(&self) -> Option<u64> {
        let max_inputs = self.max_signable_inputs();
        let inner = self.inner.read().unwrap();
        let mut sw = self.super_wallet.inner.lock().unwrap();
        sw.send_to(
            self.frost_key.master_appkey(),
            inner.recipients.iter().filter_map(|r| {
                let addr = r.address.clone()?;
                let amount = r.amount.map_or(Some(0), |a| a.value());
                Some((addr, amount))
            }),
            inner.feerate()?,
            max_inputs.map(|n| n as usize),
        )
        .ok()?
        .fee()
    }

    #[frb(sync)]
    pub fn set_recipient_with_uri(&self, recipient: u32, uri: &str) -> Result<(), String> {
        let info = self
            .super_wallet
            .network
            .validate_destination_address(uri)?;

        let mut inner = self.inner.write().unwrap();
        let r = inner.get_or_create_recipient(recipient);

        let mut changed = false;
        if r.address.as_ref() != Some(&info.address) {
            r.address = Some(info.address);
            changed = true;
        }
        if r.amount != info.amount.map(AmountType::Value) {
            r.amount = info.amount.map(AmountType::Value);
            changed = true;
        }
        if changed {
            self._trigger_changed();
        }

        Ok(())
    }

    #[frb(sync)]
    pub fn remove_recipient(&self, recipient: u32) -> bool {
        let i: usize = recipient
            .try_into()
            .expect("recipient index must fit into usize");
        let mut inner = self.inner.write().unwrap();
        if inner.recipients.len() <= i {
            false
        } else {
            inner.recipients.remove(i);
            self._trigger_changed();
            true
        }
    }

    #[frb(sync)]
    pub fn set_address(&self, recipient: u32, address: &Address) {
        let mut inner = self.inner.write().unwrap();
        let r = inner.get_or_create_recipient(recipient);
        if r.address.as_ref() != Some(address) {
            r.address = Some(address.clone());
            self._trigger_changed();
        }
    }

    #[frb(sync)]
    pub fn clear_address(&self, recipient: u64) {
        let i: usize = recipient
            .try_into()
            .expect("recipient index must fit in usize");
        let mut inner = self.inner.write().unwrap();
        let addr_opt = inner.recipients.get_mut(i).map(|r| &mut r.address);
        if let Some(addr) = addr_opt {
            if addr.is_some() {
                *addr = None;
                self._trigger_changed();
            }
        }
    }

    #[frb(sync)]
    pub fn set_amount(&self, recipient: u32, amount: u64) {
        let mut inner = self.inner.write().unwrap();
        let r = inner.get_or_create_recipient(recipient);
        if r.amount != Some(AmountType::Value(amount)) {
            r.amount = Some(AmountType::Value(amount));
            self._trigger_changed();
        }
    }

    #[frb(sync)]
    pub fn set_send_max(&self, recipient: u32) {
        let mut inner = self.inner.write().unwrap();
        let r = inner.get_or_create_recipient(recipient);
        if r.amount != Some(AmountType::SendMax) {
            r.amount = Some(AmountType::SendMax);
            self._trigger_changed();
        }
    }

    #[frb(sync)]
    pub fn clear_amount(&self, recipient: u32) {
        let mut inner = self.inner.write().unwrap();
        if let Some(r) = inner.recipients.get_mut(recipient as usize) {
            if r.amount.is_some() {
                r.amount = None;
                self._trigger_changed();
            }
        }
    }

    /// Only returns `Some` if the amount is valid and a recipient address is provided.
    #[frb(sync)]
    pub fn amount(&self, recipient: u32) -> Result<u64, AmountError> {
        let available = self
            .available_amount(recipient)
            .ok_or(AmountError::UnspecifiedFeerate)?;
        if available == 0 {
            // TODO: Have amount below dust error.
            return Err(AmountError::NoAmountAvailable);
        }

        let r = self.recipient(recipient);

        let amount = match r
            .as_ref()
            .and_then(|r| r.amount)
            .ok_or(AmountError::UnspecifiedAmount)?
        {
            AmountType::SendMax => available,
            AmountType::Value(target) => {
                if target > available {
                    return Err(AmountError::TargetExceedsAvailable { target, available });
                }
                target
            }
        };

        let addr = r
            .and_then(|r| r.address.clone())
            .ok_or(AmountError::UnspecifiedAddress)?;

        let min_non_dust = addr.script_pubkey().minimal_non_dust().to_sat();
        if amount < min_non_dust {
            return Err(AmountError::AmountBelowDust { min_non_dust });
        }

        Ok(amount)
    }

    #[frb(sync)]
    pub fn is_send_max(&self, recipient: u32) -> bool {
        let inner = self.inner.read().unwrap();
        inner
            .recipients
            .get(recipient as usize)
            .map_or(false, |r| match r.amount {
                None => false,
                Some(t) => t.is_send_max(),
            })
    }

    #[frb(sync)]
    pub fn toggle_send_max(&self, recipient: u32, fallback_amount: Option<u64>) -> bool {
        let mut is_send_max = false;
        let mut inner = self.inner.write().unwrap();
        if let Some(r) = inner.recipients.get_mut(recipient as usize) {
            is_send_max = r.amount == Some(AmountType::SendMax);
            r.amount = if is_send_max {
                fallback_amount.map(AmountType::Value)
            } else {
                Some(AmountType::SendMax)
            };
            self._trigger_changed();
        }
        is_send_max
    }

    fn _trigger_changed(&self) {
        self.broadcast.add(&());
    }

    #[frb(sync)]
    pub fn try_finish(&self) -> Result<UnsignedTx, TryFinishTxError> {
        let master_appkey = self.master_appkey();

        let inner = self.inner.read().unwrap();
        let feerate = inner.feerate().ok_or(TryFinishTxError::MissingFeerate)?;
        let recipients = inner
            .recipients
            .iter()
            .filter_map(|r| Some((r.address.clone()?, r.amount?.value())))
            .collect::<Vec<_>>();
        if recipients.len() != inner.recipients.len() {
            return Err(TryFinishTxError::IncompleteRecipientValues);
        }
        drop(inner);

        let max_inputs = self.max_signable_inputs();
        let mut sw_inner = self.super_wallet.inner.lock().unwrap();
        sw_inner
            .send_to(
                master_appkey,
                recipients,
                feerate,
                max_inputs.map(|n| n as usize),
            )
            .map(|template_tx| UnsignedTx { template_tx })
            .map_err(|e| {
                use frostsnap_coordinator::bitcoin::coin_select::SelectCoinsError;
                match e.downcast_ref::<SelectCoinsError>() {
                    Some(SelectCoinsError::InputLimitExceeded { .. }) => {
                        TryFinishTxError::NonceLimitExceeded
                    }
                    _ => TryFinishTxError::InsufficientBalance,
                }
            })
    }
}

#[derive(Debug)]
pub enum AmountError {
    UnspecifiedFeerate,
    UnspecifiedAmount,
    UnspecifiedAddress,
    NoAmountAvailable,
    AmountBelowDust { min_non_dust: u64 },
    TargetExceedsAvailable { target: u64, available: u64 },
}

#[derive(Debug)]
pub enum TryFinishTxError {
    /// Occurs when feerate target set to low/medium/high, however, we do not have feerate estimates.
    MissingFeerate,
    IncompleteRecipientValues,
    InsufficientBalance,
    /// The balance covers the amount but the devices' remaining signing nonces no longer do —
    /// the cap can shrink between amount entry and finishing, e.g. when another signing
    /// session starts meanwhile.
    NonceLimitExceeded,
}

/// The per-transaction input cap from each candidate device's usable nonce `capacities` (its best
/// single stream — a session cannot span streams) and the signing `threshold`.
///
/// A zero-capacity device is not a candidate signer, so it is excluded rather than dragging the
/// cap to zero. Fewer than `threshold` candidates means no spend is possible (0). Otherwise the
/// cap is the minimum over candidates, so any threshold-sized subset can sign a transaction built
/// under it. Kept here at the app boundary — nonce policy stays out of the wallet and core.
fn signable_input_cap(capacities: impl IntoIterator<Item = u32>, threshold: usize) -> u32 {
    let candidates = capacities
        .into_iter()
        .filter(|&n| n > 0)
        .collect::<Vec<_>>();
    if candidates.len() < threshold {
        return 0;
    }
    candidates.into_iter().min().unwrap_or(0)
}

#[cfg(test)]
mod test {
    use super::signable_input_cap;

    #[test]
    fn no_spend_when_fewer_than_threshold_have_nonces() {
        assert_eq!(signable_input_cap([30, 0, 0], 2), 0);
        assert_eq!(signable_input_cap([0, 0, 0], 2), 0);
        assert_eq!(signable_input_cap([0u32; 0], 1), 0);
    }

    #[test]
    fn cap_is_min_over_candidates() {
        assert_eq!(signable_input_cap([30, 12, 30], 2), 12);
        assert_eq!(signable_input_cap([7, 9], 2), 7);
    }

    #[test]
    fn zero_capacity_device_is_excluded_not_a_floor() {
        assert_eq!(signable_input_cap([30, 0, 20], 2), 20);
    }

    #[test]
    fn exactly_threshold_candidates_still_spendable() {
        assert_eq!(signable_input_cap([9, 0, 4], 2), 4);
    }
}
