//! Central heating cost sharing, SPEC-009 R11 (verify the split rule).
//!
//! A heating period has a total cost and a consumption share (default 70%).
//! Meter readings give each unit's consumption; the fixed part is split by
//! area weights (default the land share). Approval stores the shares and accrues
//! one operational liability per unit for its occupant.

use chrono::Utc;
use rust_decimal::Decimal;

use crate::db::finance_store::FinanceStore;
use crate::domain::heat_share::{split, HeatInput};
use crate::finance_book::col;
use crate::models::*;
use crate::services::finance_common::*;
use crate::state::{AppState, AppStateInner};

pub const DEFAULT_CONSUMPTION_PERCENT: i64 = 70;
pub const HEAT_NOTE: &str = "Paylaşım: toplam giderin tüketim payı ısı pay ölçer okumalarına, kalanı alan (arsa payı) ağırlığına göre dağıtılır. Oranlar Merkezi Isıtma ve Sıhhi Sıcak Su Giderlerinin Paylaştırılmasına İlişkin Yönetmelik'e göre doğrulanmalıdır (verify).";

fn readings_of(inner: &AppStateInner, period_id: i64) -> Vec<HeatMeterReading> {
    let mut r: Vec<HeatMeterReading> = inner
        .finance
        .heat_readings
        .iter()
        .filter(|r| r.period_id == period_id)
        .cloned()
        .collect();
    r.sort_by(|a, b| a.unit_id.cmp(&b.unit_id));
    r
}

fn preview(inner: &AppStateInner, period: &HeatCostPeriod) -> FinanceResult<Vec<HeatShareView>> {
    let readings = readings_of(inner, period.id);
    if readings.is_empty() {
        return Ok(Vec::new());
    }
    let inputs: Vec<HeatInput> = readings
        .iter()
        .map(|r| HeatInput {
            area_weight: u64::try_from(r.area_weight).unwrap_or(0),
            previous_reading: r.previous_reading,
            current_reading: r.current_reading,
        })
        .collect();
    let shares = split(period.total_cost, period.consumption_share_percent, &inputs)
        .map_err(|e| invalid(e.to_string()))?;
    Ok(readings
        .iter()
        .zip(shares)
        .map(|(r, s)| HeatShareView {
            unit_label: label_of(inner, &r.unit_id),
            unit_id: r.unit_id.clone(),
            consumption: r.current_reading - r.previous_reading,
            fixed_amount: s.fixed,
            consumption_amount: s.consumption,
            total_amount: s.total(),
            due_id: None,
        })
        .collect())
}

fn view(inner: &AppStateInner, period: &HeatCostPeriod) -> FinanceResult<HeatPeriodView> {
    let shares = if period.status == "APPROVED" {
        inner
            .finance
            .heat_shares
            .iter()
            .filter(|s| s.period_id == period.id)
            .map(|s| HeatShareView {
                unit_label: label_of(inner, &s.unit_id),
                unit_id: s.unit_id.clone(),
                consumption: inner
                    .finance
                    .heat_readings
                    .iter()
                    .find(|r| r.period_id == period.id && r.unit_id == s.unit_id)
                    .map(|r| r.current_reading - r.previous_reading)
                    .unwrap_or(Decimal::ZERO),
                fixed_amount: s.fixed_amount,
                consumption_amount: s.consumption_amount,
                total_amount: s.total_amount,
                due_id: s.due_id.clone(),
            })
            .collect()
    } else {
        preview(inner, period)?
    };
    Ok(HeatPeriodView {
        period: period.clone(),
        readings: readings_of(inner, period.id),
        shares,
        legal_note: HEAT_NOTE.to_string(),
    })
}

pub struct HeatShareService {
    store: FinanceStore,
}

impl HeatShareService {
    pub fn new(state: &AppState) -> Self {
        Self {
            store: FinanceStore::new(state),
        }
    }

    pub async fn create_period(
        &self,
        caller: &Caller,
        req: CreateHeatPeriodRequest,
    ) -> FinanceResult<HeatPeriodView> {
        let label = non_empty(&req.label, 3, "label")?;
        money(req.total_cost, "total_cost")?;
        if req.period_end < req.period_start {
            return Err(invalid("period_end is before period_start"));
        }
        let percent = req
            .consumption_share_percent
            .unwrap_or_else(|| Decimal::from(DEFAULT_CONSUMPTION_PERCENT));
        if percent < Decimal::ZERO || percent > Decimal::ONE_HUNDRED || percent.scale() > 2 {
            return Err(invalid(
                "consumption_share_percent must be between 0 and 100",
            ));
        }
        let duplicate =
            self.store
                .read(|inner| {
                    inner.finance.heat_periods.iter().any(|p| {
                        crate::auth::same_id(&p.site_id, &caller.site_id) && p.label == label
                    })
                })
                .await;
        if duplicate {
            return Err(conflict(format!("A heating period '{}' exists", label)));
        }
        let period = HeatCostPeriod {
            id: 0,
            site_id: caller.site_id.clone(),
            label,
            period_start: req.period_start,
            period_end: req.period_end,
            total_cost: req.total_cost,
            consumption_share_percent: percent,
            due_date: req.due_date,
            status: "DRAFT".into(),
            approved_by: None,
            approved_at: None,
            created_by: caller.actor(),
            created_at: Utc::now(),
        };
        let saved = self.store.insert(period, col::heat_periods).await?;
        self.store.read(|inner| view(inner, &saved)).await
    }

    async fn find(&self, site_id: &str, id: i64) -> FinanceResult<HeatCostPeriod> {
        self.store
            .read(|inner| {
                inner
                    .finance
                    .heat_periods
                    .iter()
                    .find(|p| p.id == id && crate::auth::same_id(&p.site_id, site_id))
                    .cloned()
            })
            .await
            .ok_or_else(|| not_found(format!("Heating period {} not found", id)))
    }

    pub async fn periods(&self, site_id: &str) -> FinanceResult<Vec<HeatPeriodView>> {
        self.store
            .read(|inner| {
                inner
                    .finance
                    .heat_periods
                    .iter()
                    .filter(|p| crate::auth::same_id(&p.site_id, site_id))
                    .map(|p| view(inner, p))
                    .collect()
            })
            .await
    }

    pub async fn period(&self, site_id: &str, id: i64) -> FinanceResult<HeatPeriodView> {
        let p = self.find(site_id, id).await?;
        self.store.read(|inner| view(inner, &p)).await
    }

    /// Records (or replaces) the readings of a draft period.
    pub async fn record_readings(
        &self,
        caller: &Caller,
        id: i64,
        req: RecordReadingsRequest,
    ) -> FinanceResult<HeatPeriodView> {
        let period = self.find(&caller.site_id, id).await?;
        if period.status != "DRAFT" {
            return Err(conflict("Readings of an approved period cannot change"));
        }
        for input in req.readings {
            if input.current_reading < input.previous_reading
                || input.previous_reading < Decimal::ZERO
            {
                return Err(invalid(format!(
                    "Unit {}: the current reading is below the previous one",
                    input.unit_id
                )));
            }
            let (unit, existing) = self
                .store
                .read(|inner| {
                    let unit = find_unit(inner, &caller.site_id, &input.unit_id)?;
                    let existing = inner
                        .finance
                        .heat_readings
                        .iter()
                        .find(|r| r.period_id == id && crate::auth::same_id(&r.unit_id, &unit.id))
                        .map(|r| r.id);
                    Ok::<_, FinanceError>((unit, existing))
                })
                .await?;
            let weight = input.area_weight.unwrap_or(unit.land_share.max(1));
            if weight < 0 {
                return Err(invalid("area_weight must not be negative"));
            }
            let reading = HeatMeterReading {
                id: existing.unwrap_or(0),
                period_id: id,
                unit_id: unit.id.clone(),
                area_weight: weight,
                previous_reading: input.previous_reading,
                current_reading: input.current_reading,
            };
            self.store.upsert(reading, col::heat_readings).await?;
        }
        self.store.read(|inner| view(inner, &period)).await
    }

    /// Stores the shares and accrues one liability per unit for its occupant.
    pub async fn approve(&self, caller: &Caller, id: i64) -> FinanceResult<HeatPeriodView> {
        let mut period = self.find(&caller.site_id, id).await?;
        if period.status != "DRAFT" {
            return Err(conflict("The period is already approved"));
        }
        let (shares, missing) = self
            .store
            .read(|inner| {
                let shares = preview(inner, &period)?;
                let missing: Vec<String> = site_units(inner, &caller.site_id)
                    .filter(|u| {
                        !shares
                            .iter()
                            .any(|s| crate::auth::same_id(&s.unit_id, &u.id))
                    })
                    .map(|u| unit_label(inner, u))
                    .collect();
                Ok::<_, FinanceError>((shares, missing))
            })
            .await?;
        if shares.is_empty() {
            return Err(conflict("Record the meter readings first"));
        }
        if !missing.is_empty() {
            return Err(conflict(format!(
                "Readings are missing for: {}",
                missing.join(", ")
            )));
        }
        let tenanted = self.store.tenanted_units(&caller.site_id).await?;
        for s in shares {
            let debtor = if tenanted.iter().any(|t| crate::auth::same_id(t, &s.unit_id)) {
                DebtorType::Tenant
            } else {
                DebtorType::Owner
            };
            let mut due_id = None;
            if s.total_amount > Decimal::ZERO {
                let due = DuesLiability {
                    id: String::new(),
                    unit_id: s.unit_id.clone(),
                    period: format!("Isınma {}", period.label),
                    principal_amount: s.total_amount,
                    delay_penalty: Decimal::ZERO,
                    total_amount: s.total_amount,
                    due_date: period.due_date,
                    status: DebtStatus::Pending,
                    paid_principal: Decimal::ZERO,
                    paid_penalty: Decimal::ZERO,
                    debtor_type: debtor,
                    expense_type: ExpenseType::OperationalDues,
                    penalty_accrued_through: None,
                };
                due_id = self.store.insert_due(due).await?.map(|d| d.id);
            }
            let share = HeatCostShare {
                id: 0,
                period_id: period.id,
                unit_id: s.unit_id.clone(),
                fixed_amount: s.fixed_amount,
                consumption_amount: s.consumption_amount,
                total_amount: s.total_amount,
                due_id,
            };
            self.store.insert(share, col::heat_shares).await?;
        }
        period.status = "APPROVED".into();
        period.approved_by = Some(caller.actor());
        period.approved_at = Some(Utc::now());
        let saved = self.store.update(period, col::heat_periods).await?;
        self.store.read(|inner| view(inner, &saved)).await
    }
}
