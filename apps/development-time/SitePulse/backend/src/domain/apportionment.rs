//! Splits a monetary total across recipients by integer weight.
//!
//! Uses the largest-remainder (Hamilton) method on whole cents, so:
//!
//! * the shares always sum exactly to the total (no "kuruş drift");
//! * every share differs from its exact proportional value by less than one cent;
//! * the result is deterministic: leftover cents go to the largest fractional
//!   remainders, ties broken by larger weight, then by lower position.
//!
//! All arithmetic is exact integer arithmetic on cents, so no midpoint rounding
//! strategy is involved and the result does not depend on `Decimal` division
//! precision.

use rust_decimal::prelude::ToPrimitive;
use rust_decimal::Decimal;
use thiserror::Error;

/// Monetary amounts are apportioned at two decimal places (kuruş).
pub const MONEY_SCALE: u32 = 2;

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum ApportionmentError {
    #[error("there are no recipients to apportion across")]
    NoRecipients,
    #[error("the total to apportion must not be negative")]
    NegativeTotal,
    #[error("the total to apportion must have at most {MONEY_SCALE} decimal places")]
    TotalScale,
    #[error("the apportionment exceeds the supported numeric range")]
    Overflow,
}

/// Apportions `total` across `weights`. A weight of zero receives nothing unless
/// every weight is zero, in which case the total is split equally.
///
/// Returns one share per weight, in the same order.
pub fn apportion(total: Decimal, weights: &[u64]) -> Result<Vec<Decimal>, ApportionmentError> {
    if weights.is_empty() {
        return Err(ApportionmentError::NoRecipients);
    }
    if total < Decimal::ZERO {
        return Err(ApportionmentError::NegativeTotal);
    }
    if total.normalize().scale() > MONEY_SCALE {
        return Err(ApportionmentError::TotalScale);
    }

    let total_cents: u128 = (total * Decimal::ONE_HUNDRED)
        .to_u128()
        .ok_or(ApportionmentError::Overflow)?;

    let weight_sum: u128 = weights.iter().map(|&w| u128::from(w)).sum();
    let equal_split = weight_sum == 0;
    let effective_sum = if equal_split {
        u128::try_from(weights.len()).map_err(|_| ApportionmentError::Overflow)?
    } else {
        weight_sum
    };

    let mut cents: Vec<u128> = Vec::with_capacity(weights.len());
    let mut remainders: Vec<(usize, u128)> = Vec::with_capacity(weights.len());
    for (position, &weight) in weights.iter().enumerate() {
        let numerator = total_cents
            .checked_mul(if equal_split { 1 } else { u128::from(weight) })
            .ok_or(ApportionmentError::Overflow)?;
        cents.push(numerator / effective_sum);
        remainders.push((position, numerator % effective_sum));
    }

    let assigned: u128 = cents.iter().sum();
    // Each floor loses less than one cent, so fewer than `weights.len()` cents remain.
    let leftover =
        usize::try_from(total_cents - assigned).map_err(|_| ApportionmentError::Overflow)?;

    remainders.sort_by(|a, b| {
        b.1.cmp(&a.1)
            .then_with(|| weights[b.0].cmp(&weights[a.0]))
            .then_with(|| a.0.cmp(&b.0))
    });
    for &(position, _) in remainders.iter().take(leftover) {
        cents[position] += 1;
    }

    cents
        .into_iter()
        .map(|c| {
            i128::try_from(c)
                .map(|c| Decimal::from_i128_with_scale(c, MONEY_SCALE))
                .map_err(|_| ApportionmentError::Overflow)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(s: &str) -> Decimal {
        Decimal::from_str_exact(s).unwrap()
    }

    #[test]
    fn equal_weights_split_with_deterministic_leftover() {
        let shares = apportion(d("100.00"), &[1, 1, 1]).unwrap();
        assert_eq!(shares, vec![d("33.34"), d("33.33"), d("33.33")]);
    }

    #[test]
    fn all_zero_weights_split_equally() {
        let shares = apportion(d("10.00"), &[0, 0, 0, 0]).unwrap();
        assert_eq!(shares, vec![d("2.50"); 4]);
    }

    #[test]
    fn leftover_goes_to_largest_remainder_not_first_position() {
        // 5 cents over weights 1:2 -> exact 1.67 / 3.33 cents, floors 1 / 3,
        // one cent left; the first recipient has the larger remainder.
        let shares = apportion(d("0.05"), &[1, 2]).unwrap();
        assert_eq!(shares, vec![d("0.02"), d("0.03")]);
    }

    #[test]
    fn ties_prefer_larger_weight() {
        // 2 cents over weights 1:3 -> exact 0.5 / 1.5 cents: equal remainders,
        // so the larger weight takes the leftover cent.
        let shares = apportion(d("0.02"), &[1, 3]).unwrap();
        assert_eq!(shares, vec![d("0.00"), d("0.02")]);
        // Equal remainders and equal weights: the lower position wins.
        assert_eq!(
            apportion(d("0.01"), &[1, 1]).unwrap(),
            vec![d("0.01"), d("0.00")]
        );
    }

    #[test]
    fn shares_always_sum_to_total() {
        let weights_sets: [&[u64]; 5] = [
            &[24, 24, 24],
            &[1],
            &[7, 13, 0, 29, 1],
            &[3; 47],
            &[1, 1_000_000],
        ];
        for total in [
            "0.00",
            "0.01",
            "9999.99",
            "300000.00",
            "10000.00",
            "1234567.89",
        ] {
            for weights in weights_sets {
                let shares = apportion(d(total), weights).unwrap();
                assert_eq!(
                    shares.iter().copied().sum::<Decimal>(),
                    d(total),
                    "{total} over {weights:?}"
                );
                let weight_sum: u64 = weights.iter().sum();
                for (share, &w) in shares.iter().zip(weights) {
                    let exact = d(total) * Decimal::from(w) / Decimal::from(weight_sum);
                    assert!((*share - exact).abs() < d("0.01"), "{share} vs {exact}");
                }
            }
        }
    }

    #[test]
    fn rejects_invalid_input() {
        assert_eq!(
            apportion(d("1.00"), &[]),
            Err(ApportionmentError::NoRecipients)
        );
        assert_eq!(
            apportion(d("-1.00"), &[1]),
            Err(ApportionmentError::NegativeTotal)
        );
        assert_eq!(
            apportion(d("1.005"), &[1]),
            Err(ApportionmentError::TotalScale)
        );
        assert!(
            apportion(d("1.500"), &[1]).is_ok(),
            "trailing zeros are not extra precision"
        );
    }
}
