//! Heat-cost sharing for central heating, SPEC-009 R11 (verify the split against
//! the current "Merkezi Isıtma ve Sıhhi Sıcak Su Sistemlerinde Isınma ve Sıhhi
//! Sıcak Su Giderlerinin Paylaştırılmasına İlişkin Yönetmelik").
//!
//! The period's cost is split into a consumption part (by heat-cost-allocator
//! readings) and a fixed part (by area weights). Both splits use
//! [`super::apportion`], so the unit shares add up to the cost exactly.

use rust_decimal::{Decimal, RoundingStrategy};
use thiserror::Error;

use super::apportionment::{apportion, ApportionmentError};

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum HeatShareError {
    #[error("the consumption share is a percentage between 0 and 100")]
    Percent,
    #[error("unit {0}: the current reading is below the previous one")]
    Reading(usize),
    #[error("there are no units to share the cost")]
    NoUnits,
    #[error("a consumption value is out of range")]
    Range,
    #[error(transparent)]
    Apportion(#[from] ApportionmentError),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeatInput {
    pub area_weight: u64,
    pub previous_reading: Decimal,
    pub current_reading: Decimal,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeatShare {
    pub fixed: Decimal,
    pub consumption: Decimal,
}

impl HeatShare {
    pub fn total(&self) -> Decimal {
        self.fixed + self.consumption
    }
}

/// Consumption values are compared at 0.001 units (meter resolution).
fn consumption_weight(input: &HeatInput) -> Result<u64, HeatShareError> {
    use rust_decimal::prelude::ToPrimitive;
    let units = ((input.current_reading - input.previous_reading) * Decimal::from(1000))
        .round_dp_with_strategy(0, RoundingStrategy::MidpointNearestEven);
    units.to_u64().ok_or(HeatShareError::Range)
}

/// Splits `total` into the fixed and consumption parts per unit.
///
/// When nobody consumed anything, the consumption part is split by area like
/// the fixed part (apportion splits an all-zero weight vector equally, which
/// would ignore area).
pub fn split(
    total: Decimal,
    consumption_percent: Decimal,
    units: &[HeatInput],
) -> Result<Vec<HeatShare>, HeatShareError> {
    if units.is_empty() {
        return Err(HeatShareError::NoUnits);
    }
    if consumption_percent < Decimal::ZERO || consumption_percent > Decimal::ONE_HUNDRED {
        return Err(HeatShareError::Percent);
    }
    for (i, u) in units.iter().enumerate() {
        if u.current_reading < u.previous_reading {
            return Err(HeatShareError::Reading(i));
        }
    }
    let consumption_total = (total * consumption_percent / Decimal::ONE_HUNDRED)
        .round_dp_with_strategy(2, RoundingStrategy::MidpointNearestEven);
    let fixed_total = total - consumption_total;
    let areas: Vec<u64> = units.iter().map(|u| u.area_weight).collect();
    let mut consumption_weights = units
        .iter()
        .map(consumption_weight)
        .collect::<Result<Vec<u64>, _>>()?;
    if consumption_weights.iter().all(|w| *w == 0) {
        consumption_weights = areas.clone();
    }
    let fixed = apportion(fixed_total, &areas)?;
    let consumption = apportion(consumption_total, &consumption_weights)?;
    Ok(fixed
        .into_iter()
        .zip(consumption)
        .map(|(fixed, consumption)| HeatShare { fixed, consumption })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(s: &str) -> Decimal {
        Decimal::from_str_exact(s).unwrap_or_default()
    }
    fn unit(area: u64, prev: &str, cur: &str) -> HeatInput {
        HeatInput {
            area_weight: area,
            previous_reading: d(prev),
            current_reading: d(cur),
        }
    }

    #[test]
    fn shares_add_up_and_follow_consumption_and_area() {
        let units = vec![
            unit(100, "10", "40"),
            unit(100, "5", "15"),
            unit(50, "0", "0"),
        ];
        let shares = split(d("10000.00"), d("70"), &units).unwrap_or_default();
        let total: Decimal = shares.iter().map(HeatShare::total).sum();
        assert_eq!(total, d("10000.00"));
        // Fixed 3000 by area 100/100/50: 1200/1200/600.
        assert_eq!(shares[0].fixed, d("1200.00"));
        assert_eq!(shares[2].fixed, d("600.00"));
        // Consumption 7000 by 30/10/0: 5250/1750/0.
        assert_eq!(shares[0].consumption, d("5250.00"));
        assert_eq!(shares[1].consumption, d("1750.00"));
        assert_eq!(shares[2].consumption, d("0.00"));
    }

    #[test]
    fn without_any_consumption_the_area_decides_and_bad_input_is_refused() {
        let units = vec![unit(2, "1", "1"), unit(1, "3", "3")];
        let shares = split(d("300.00"), d("70"), &units).unwrap_or_default();
        assert_eq!(shares[0].total(), d("200.00"));
        assert_eq!(
            split(d("1"), d("101"), &units),
            Err(HeatShareError::Percent)
        );
        assert_eq!(
            split(d("1"), d("50"), &[unit(1, "5", "4")]),
            Err(HeatShareError::Reading(0))
        );
        assert_eq!(split(d("1"), d("50"), &[]), Err(HeatShareError::NoUnits));
    }
}
