//! Coin selection with an optional cap on the number of inputs.
//!
//! The cap exists because a FROST signing session draws one nonce per input from a single
//! nonce stream per device, so a transaction with more inputs than the scarcest signer's
//! stream can supply is unsignable. The cap arrives here as a plain number; nonce accounting
//! stays with the caller.

use bdk_coin_select::{
    metrics::LowestFee, Candidate, ChangePolicy, CoinSelector, FeeRate, InsufficientFunds, Target,
};
use tracing::{event, Level};

#[derive(Clone, Debug, Copy, PartialEq, Eq)]
pub enum SelectCoinsError {
    InsufficientFunds(InsufficientFunds),
    /// The target is reachable, but not with `max_inputs` inputs.
    InputLimitExceeded {
        max_inputs: usize,
    },
}

impl core::fmt::Display for SelectCoinsError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            SelectCoinsError::InsufficientFunds(e) => e.fmt(f),
            SelectCoinsError::InputLimitExceeded { max_inputs } => write!(
                f,
                "amount needs more than {max_inputs} coins, \
                 the most the devices' remaining nonces can sign"
            ),
        }
    }
}

impl std::error::Error for SelectCoinsError {}

/// Select coins for `target`, using at most `max_inputs` inputs when a cap is given.
///
/// The selector runs unconstrained first; the cap only intervenes when the natural answer
/// exceeds it. Then the selection is truncated to its largest inputs, and if that no longer
/// meets the target, selection is re-run over only the `max_inputs` largest candidates.
pub fn select_coins<'a>(
    candidates: &'a [Candidate],
    target: Target,
    change_policy: ChangePolicy,
    long_term_feerate: FeeRate,
    max_inputs: Option<usize>,
) -> Result<CoinSelector<'a>, SelectCoinsError> {
    let metric = LowestFee {
        target,
        long_term_feerate,
        change_policy,
    };

    let mut cs = CoinSelector::new(candidates);
    select_lowest_fee(&mut cs, metric, target).map_err(SelectCoinsError::InsufficientFunds)?;

    let max_inputs = match max_inputs {
        Some(max_inputs) if cs.selected_indices().len() > max_inputs => max_inputs,
        _ => return Ok(cs),
    };

    if truncate_to_largest(&mut cs, candidates, max_inputs, target) {
        return Ok(cs);
    }

    let mut cs = CoinSelector::new(candidates);
    for &i in indices_by_value_desc(candidates).iter().skip(max_inputs) {
        cs.ban(i);
    }
    select_lowest_fee(&mut cs, metric, target)
        .map_err(|_| SelectCoinsError::InputLimitExceeded { max_inputs })?;
    Ok(cs)
}

/// Sum up spendable value by selecting the largest candidates first, up to `max_inputs`.
///
/// With no cap this selects everything, matching what an uncapped wallet could spend.
pub fn select_available<'a>(
    candidates: &'a [Candidate],
    feerate: FeeRate,
    effective_only: bool,
    max_inputs: Option<usize>,
) -> CoinSelector<'a> {
    let mut cs = CoinSelector::new(candidates);
    match max_inputs {
        None => {
            if effective_only {
                cs.select_all_effective(feerate);
            } else {
                cs.select_all();
            }
        }
        Some(max_inputs) => {
            for &i in indices_by_value_desc(candidates)
                .iter()
                .filter(|&&i| !effective_only || candidates[i].effective_value(feerate) > 0.0)
                .take(max_inputs)
            {
                cs.select(i);
            }
        }
    }
    cs
}

fn select_lowest_fee(
    cs: &mut CoinSelector<'_>,
    metric: LowestFee,
    target: Target,
) -> Result<(), InsufficientFunds> {
    match cs.run_bnb(metric, 500_000) {
        Ok(score) => {
            event!(Level::INFO, "coin selection succeeded with score: {score}");
            Ok(())
        }
        Err(_) => {
            event!(Level::ERROR, "unable to find a selection with lowest fee");
            cs.select_until_target_met(target)
        }
    }
}

/// Keep only the `max_inputs` largest selected inputs; report whether the target is still met.
fn truncate_to_largest(
    cs: &mut CoinSelector<'_>,
    candidates: &[Candidate],
    max_inputs: usize,
    target: Target,
) -> bool {
    let mut selected_asc = cs.selected_indices().iter().copied().collect::<Vec<_>>();
    selected_asc.sort_by_key(|&i| candidates[i].value);
    let n_excess = selected_asc.len().saturating_sub(max_inputs);
    for &i in &selected_asc[..n_excess] {
        cs.deselect(i);
    }
    cs.is_target_met(target)
}

fn indices_by_value_desc(candidates: &[Candidate]) -> Vec<usize> {
    let mut indices = (0..candidates.len()).collect::<Vec<_>>();
    indices.sort_by_key(|&i| core::cmp::Reverse(candidates[i].value));
    indices
}

#[cfg(test)]
mod test {
    use super::*;
    use bdk_coin_select::{
        DrainWeights, TargetFee, TargetOutputs, TR_DUST_RELAY_MIN_VALUE, TR_KEYSPEND_TXIN_WEIGHT,
    };

    const P2TR_OUTPUT_WEIGHT: u64 = 172;

    fn candidates(values: &[u64]) -> Vec<Candidate> {
        values
            .iter()
            .map(|&value| Candidate {
                input_count: 1,
                value,
                weight: TR_KEYSPEND_TXIN_WEIGHT,
                is_segwit: true,
            })
            .collect()
    }

    fn target(value: u64, feerate: f32) -> Target {
        Target {
            fee: TargetFee::from_feerate(FeeRate::from_sat_per_vb(feerate)),
            outputs: TargetOutputs::fund_outputs([(P2TR_OUTPUT_WEIGHT, value)]),
        }
    }

    fn change_policy(feerate: f32, long_term_feerate: f32) -> ChangePolicy {
        ChangePolicy::min_value_and_waste(
            DrainWeights::TR_KEYSPEND,
            TR_DUST_RELAY_MIN_VALUE,
            FeeRate::from_sat_per_vb(feerate),
            FeeRate::from_sat_per_vb(long_term_feerate),
        )
    }

    fn run(
        values: &[u64],
        target_value: u64,
        max_inputs: Option<usize>,
    ) -> Result<Vec<u64>, SelectCoinsError> {
        run_with_long_term_feerate(values, target_value, max_inputs, 1.0)
    }

    fn run_with_long_term_feerate(
        values: &[u64],
        target_value: u64,
        max_inputs: Option<usize>,
        long_term_feerate: f32,
    ) -> Result<Vec<u64>, SelectCoinsError> {
        let candidates = candidates(values);
        let cs = select_coins(
            &candidates,
            target(target_value, 1.0),
            change_policy(1.0, long_term_feerate),
            FeeRate::from_sat_per_vb(long_term_feerate),
            max_inputs,
        )?;
        assert!(cs.is_target_met(target(target_value, 1.0)));
        let mut selected = cs
            .apply_selection(&candidates)
            .map(|c| c.value)
            .collect::<Vec<_>>();
        selected.sort_unstable();
        Ok(selected)
    }

    #[test]
    fn natural_fit_is_not_pre_constrained() {
        let unconstrained = run(&[10_000, 10_000, 10_000, 10_000], 25_000, None).unwrap();
        let capped = run(&[10_000, 10_000, 10_000, 10_000], 25_000, Some(3)).unwrap();
        assert_eq!(capped, unconstrained);
        assert!(capped.len() <= 3);
    }

    #[test]
    fn cap_forces_largest_inputs_when_natural_answer_is_wide() {
        // At a high long-term feerate a change output is expensive to spend later, so LowestFee
        // prefers the changeless pair of mid coins over one big coin plus change; the guard
        // assertion pins that preference so the capped run genuinely exercises the over-cap
        // path rather than a natural fit.
        let values = [10_000, 4_700, 4_700];
        assert_eq!(
            run_with_long_term_feerate(&values, 9_000, None, 10.0).unwrap(),
            vec![4_700, 4_700]
        );

        let selected = run_with_long_term_feerate(&values, 9_000, Some(1), 10.0).unwrap();
        assert_eq!(selected, vec![10_000]);
    }

    #[test]
    fn unreachable_within_cap_is_input_limit_error() {
        let values = [1_000; 40];
        let err = run(&values, 35_000, Some(30)).unwrap_err();
        assert_eq!(err, SelectCoinsError::InputLimitExceeded { max_inputs: 30 });
        assert!(run(&values, 35_000, None).is_ok());
    }

    #[test]
    fn zero_cap_cannot_select() {
        let err = run(&[10_000], 5_000, Some(0)).unwrap_err();
        assert_eq!(err, SelectCoinsError::InputLimitExceeded { max_inputs: 0 });
    }

    #[test]
    fn plain_insufficiency_is_not_blamed_on_the_cap() {
        let err = run(&[1_000, 1_000], 50_000, Some(30)).unwrap_err();
        assert!(matches!(err, SelectCoinsError::InsufficientFunds(_)));
    }

    #[test]
    fn truncation_keeps_the_largest_selected_inputs() {
        let candidates = candidates(&[1_000, 60_000, 2_000, 50_000, 3_000]);
        let t = target(30_000, 1.0);
        let mut cs = CoinSelector::new(&candidates);
        for i in 0..candidates.len() {
            cs.select(i);
        }

        assert!(truncate_to_largest(&mut cs, &candidates, 2, t));
        let selected = cs.selected_indices();
        assert_eq!(selected.len(), 2);
        assert!(selected.contains(&1) && selected.contains(&3));

        let mut cs = CoinSelector::new(&candidates);
        for i in [0, 2, 4] {
            cs.select(i);
        }
        assert!(!truncate_to_largest(&mut cs, &candidates, 2, t));
    }

    #[test]
    fn available_is_sum_of_largest_candidates_under_cap() {
        let values = [5_000, 1_000, 20_000, 3_000, 10_000];
        let candidates = candidates(&values);
        let feerate = FeeRate::from_sat_per_vb(1.0);
        let t = target(0, 1.0);

        let uncapped = select_available(&candidates, feerate, true, None);
        let capped = select_available(&candidates, feerate, true, Some(2));

        assert_eq!(uncapped.selected_indices().len(), 5);
        assert_eq!(
            capped
                .apply_selection(&candidates)
                .map(|c| c.value)
                .sum::<u64>(),
            30_000
        );
        assert!(
            capped.excess(t, bdk_coin_select::Drain::NONE)
                < uncapped.excess(t, bdk_coin_select::Drain::NONE)
        );
    }

    #[test]
    fn available_under_cap_skips_ineffective_candidates() {
        let values = [20_000, 10, 10_000];
        let candidates = candidates(&values);
        let feerate = FeeRate::from_sat_per_vb(10.0);

        let capped = select_available(&candidates, feerate, true, Some(2));
        assert_eq!(
            capped
                .apply_selection(&candidates)
                .map(|c| c.value)
                .sum::<u64>(),
            30_000
        );
    }
}
