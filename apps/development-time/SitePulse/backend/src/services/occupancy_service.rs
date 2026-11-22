//! Guarded occupancy commands on a unit (EPIC-08 §3.3, STORY-08-06..08, 08-10).
//!
//! Move-in, move-out and the compound moves all come through
//! [`OccupancyService::transition`]: one transaction, the unit row locked, the
//! precondition checked by `domain::unit_state`, the sessions changed by
//! `db::occupancy_repository`. A move never changes ownership; an owner
//! move-in opens a session for an owner on record and accepts no new person.

use chrono::{Datelike, NaiveDate};
use deadpool_postgres::Transaction;

use crate::db::occupancy_repository::{
    self as repo, ClosedSession, OccupancyError, OpenedSession, TransitionInput, UnitSnapshot,
};
use crate::domain::billing_period::BillingPeriod;
use crate::domain::occupancy_proration::{
    self as proration, OccupancySpan, ProratedShare, ResponsibleParty,
};
use crate::domain::unit_state::{self, Command, CommandKind, SessionRole};
use crate::models::{
    DebtorType, OccupancyHistoryItem, OccupancyTransitionRequest, OccupancyTransitionResponse,
    UnitOccupancyStateResponse, UnitOccupantDto, UnitOwnerDto,
};
use crate::services::correction_service::CorrectionService;
use crate::services::finance_common::{Caller, FinanceResult};
use crate::state::AppState;
use rust_decimal::Decimal;

pub struct OccupancyService {
    state: AppState,
}

/// The owner on record before a sale.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Seller {
    pub person_id: i64,
    /// The owner has an active session in the unit (the unit is owner-occupied).
    pub owner_occupied: bool,
}

/// Computes one monthly operational dues liability per responsible role.
/// Invalid historical dates are ignored conservatively; uncovered days remain
/// the owner's responsibility.
pub fn accrual_shares(
    amount: Decimal,
    period: BillingPeriod,
    unit_created_on: Option<NaiveDate>,
    history: &[OccupancyHistoryItem],
    proration_enabled: bool,
    accrued_on: NaiveDate,
) -> Vec<(DebtorType, Decimal)> {
    let spans: Vec<OccupancySpan> = history
        .iter()
        .filter_map(|item| {
            let starts_on = NaiveDate::parse_from_str(&item.start_date, "%Y-%m-%d").ok()?;
            let ends_before = item
                .end_date
                .as_deref()
                .and_then(|end| NaiveDate::parse_from_str(end, "%Y-%m-%d").ok());
            Some(OccupancySpan {
                party: match item.role {
                    DebtorType::Owner => ResponsibleParty::Owner,
                    DebtorType::Tenant => ResponsibleParty::Tenant,
                },
                starts_on,
                ends_before,
            })
        })
        .collect();
    proration::split_monthly_dues(
        amount,
        period.first_day(),
        unit_created_on,
        &spans,
        proration_enabled,
        accrued_on,
    )
    .map(|shares| {
        shares
            .into_iter()
            .filter(|share| share.amount > Decimal::ZERO)
            .map(map_share)
            .collect()
    })
    .unwrap_or_default()
}

fn map_share(share: ProratedShare) -> (DebtorType, Decimal) {
    let debtor = match share.party {
        ResponsibleParty::Owner => DebtorType::Owner,
        ResponsibleParty::Tenant => DebtorType::Tenant,
    };
    (debtor, share.amount)
}

/// Computes monthly operational dues shares broken down by responsible role and person.
/// Uncovered days belong to the unit's titled owner.
pub fn detailed_accrual_shares(
    amount: Decimal,
    period: BillingPeriod,
    unit_created_on: Option<NaiveDate>,
    history: &[OccupancyHistoryItem],
    owner_person_id: Option<i64>,
    proration_enabled: bool,
) -> Vec<(DebtorType, Decimal, Option<i64>)> {
    if !proration_enabled {
        let active_tenant_pid = history
            .iter()
            .filter(|h| h.role == DebtorType::Tenant && h.is_active && h.person_id > 0)
            .map(|h| h.person_id)
            .next_back();
        return accrual_shares(
            amount,
            period,
            unit_created_on,
            history,
            proration_enabled,
            period.first_day(),
        )
        .into_iter()
        .map(|(debtor, amt)| {
            let pid = match debtor {
                DebtorType::Tenant => active_tenant_pid,
                DebtorType::Owner => owner_person_id,
            };
            (debtor, amt, pid)
        })
        .collect();
    }

    let period_start = period.first_day();
    let period_end = period.last_day();
    let days_in_month = i64::from(period_end.day());
    let charge_start = unit_created_on.unwrap_or(period_start).max(period_start);
    if charge_start > period_end {
        return Vec::new();
    }

    let chargeable_days = period_end.signed_duration_since(charge_start).num_days() + 1;
    let mut ordered_parties: Vec<(DebtorType, Option<i64>)> = Vec::new();
    let mut party_days: std::collections::HashMap<(DebtorType, Option<i64>), i64> =
        std::collections::HashMap::new();

    for offset in 0..chargeable_days {
        let Some(date) = charge_start.checked_add_days(chrono::Days::new(offset as u64)) else {
            continue;
        };

        let matched = history.iter().find(|item| {
            let start = NaiveDate::parse_from_str(&item.start_date, "%Y-%m-%d").ok();
            let end = item
                .end_date
                .as_deref()
                .and_then(|e| NaiveDate::parse_from_str(e, "%Y-%m-%d").ok());
            start.is_some_and(|s| s <= date) && end.is_none_or(|e| date < e)
        });

        let who = match matched {
            Some(item) if item.role == DebtorType::Tenant => {
                let pid = if item.person_id > 0 {
                    Some(item.person_id)
                } else {
                    None
                };
                (DebtorType::Tenant, pid)
            }
            Some(item) if item.role == DebtorType::Owner => {
                let pid = if item.person_id > 0 {
                    Some(item.person_id)
                } else {
                    owner_person_id
                };
                (DebtorType::Owner, pid)
            }
            _ => (DebtorType::Owner, owner_person_id),
        };

        if !party_days.contains_key(&who) {
            ordered_parties.push(who);
        }
        *party_days.entry(who).or_default() += 1;
    }

    let active_amount = (amount * Decimal::from(chargeable_days) / Decimal::from(days_in_month))
        .round_dp_with_strategy(2, rust_decimal::RoundingStrategy::MidpointAwayFromZero);

    if ordered_parties.is_empty() {
        return Vec::new();
    }
    if ordered_parties.len() == 1 {
        return vec![(ordered_parties[0].0, active_amount, ordered_parties[0].1)];
    }

    let mut shares = Vec::new();
    let mut allocated = Decimal::ZERO;
    let last_idx = ordered_parties.len() - 1;

    for (i, party) in ordered_parties.into_iter().enumerate() {
        let days = party_days.get(&party).copied().unwrap_or(0);
        let share_amount = if i == last_idx {
            active_amount - allocated
        } else {
            (amount * Decimal::from(days) / Decimal::from(days_in_month))
                .round_dp_with_strategy(2, rust_decimal::RoundingStrategy::MidpointAwayFromZero)
        };
        if share_amount > Decimal::ZERO {
            allocated += share_amount;
            shares.push((party.0, share_amount, party.1));
        }
    }

    shares
}

/// Reads a unit id in any of the forms the API accepts (`14`, `d-14`, `unit-14`).
pub fn parse_unit_id(unit_id: &str) -> Option<i64> {
    crate::db::parse_id_to_i64(unit_id).or_else(|| {
        unit_id
            .strip_prefix("unit-")
            .or_else(|| unit_id.strip_prefix("d-"))
            .and_then(|s| s.parse::<i64>().ok())
    })
}

/// The occupancy commands this service runs; owner registration and title
/// transfer have their own entry points because they also change ownership.
fn occupancy_command(kind: CommandKind) -> Result<Command, OccupancyError> {
    match kind {
        CommandKind::TenantMoveIn => Ok(Command::TenantMoveIn),
        CommandKind::OwnerMoveIn => Ok(Command::OwnerMoveIn),
        CommandKind::MoveOut => Ok(Command::MoveOut),
        CommandKind::ReplaceTenant => Ok(Command::ReplaceTenant),
        CommandKind::OwnerRentsOut => Ok(Command::OwnerRentsOut),
        CommandKind::OwnerTakesBack => Ok(Command::OwnerTakesBack),
        CommandKind::RegisterOwner | CommandKind::TitleTransfer => {
            Err(OccupancyError::UnsupportedCommand(kind.as_str()))
        }
    }
}

impl OccupancyService {
    pub fn new(state: AppState) -> Self {
        Self { state }
    }

    /// Enables or disables occupancy-aware accrual for one site.
    pub async fn set_proration_policy(
        &self,
        site_id: &str,
        enabled: bool,
    ) -> Result<(), OccupancyError> {
        let exists = self
            .state
            .inner
            .read()
            .await
            .sites
            .iter()
            .any(|site| crate::auth::same_id(&site.id, site_id));
        if !exists {
            return Err(OccupancyError::UnitNotFound);
        }
        match self.state.db_pool() {
            Some(pool) => {
                crate::db::site_repository::set_proration_policy(pool, site_id, enabled)
                    .await
                    .map_err(|error| OccupancyError::Storage(error.to_string()))?;
            }
            None => tracing::debug!("Saving proration policy in memory without a database"),
        }
        let mut inner = self.state.inner.write().await;
        let site = inner
            .sites
            .iter_mut()
            .find(|site| crate::auth::same_id(&site.id, site_id))
            .ok_or(OccupancyError::UnitNotFound)?;
        site.proration_enabled = enabled;
        Ok(())
    }

    /// Requests four-eyes corrections when an occupancy transition changes accrued
    /// liabilities in open periods on or after `effective_date`.
    ///
    /// For the period containing `effective_date`, an accrued liability may be split
    /// between tenant and owner (SPLIT_REISSUE) or transferred if 100% owner.
    /// For later open periods already accrued (e.g. when a tenant moved out retrospectively),
    /// liabilities that no longer match the active occupancy are re-issued or split.
    pub async fn request_occupancy_corrections(
        &self,
        caller: &Caller,
        unit_id: &str,
        effective_date: NaiveDate,
    ) -> FinanceResult<Vec<crate::models::AccrualCorrection>> {
        let effective_period = BillingPeriod::of_date(effective_date);
        let unit_key = parse_unit_id(unit_id)
            .map(|id| id.to_string())
            .unwrap_or_else(|| unit_id.to_string());
        let candidate_periods = {
            let inner = self.state.inner.read().await;
            let enabled = inner
                .sites
                .iter()
                .find(|site| crate::auth::same_id(&site.id, &caller.site_id))
                .is_some_and(|site| site.proration_enabled);
            let Some(unit) = inner.units.iter().find(|unit| {
                crate::auth::same_id(&unit.id, &unit_key)
                    && crate::auth::same_id(&unit.site_id, &caller.site_id)
            }) else {
                return Ok(Vec::new());
            };
            if !enabled {
                return Ok(Vec::new());
            }
            let created_on = unit.created_on;
            let history = inner
                .unit_occupancies
                .get(&unit.id)
                .cloned()
                .unwrap_or_default();

            let mut periods: Vec<BillingPeriod> = inner
                .dues
                .iter()
                .filter(|due| {
                    crate::auth::same_id(&due.unit_id, &unit_key)
                        && due.expense_type == crate::models::ExpenseType::OperationalDues
                        && due.status != crate::models::DebtStatus::Cancelled
                })
                .filter_map(|due| BillingPeriod::parse(&due.period).ok())
                .filter(|p| *p >= effective_period)
                .collect();
            periods.sort();
            periods.dedup();

            let mut candidates = Vec::new();
            for p in periods {
                let is_closed = inner.dues_periods.iter().any(|row| {
                    crate::auth::same_id(&row.site_id, &caller.site_id)
                        && BillingPeriod::parse(&row.period_name).ok() == Some(p)
                        && row.status.as_str() == "CLOSED"
                });
                if is_closed {
                    continue;
                }
                let dues: Vec<_> = inner
                    .dues
                    .iter()
                    .filter(|due| {
                        crate::auth::same_id(&due.unit_id, &unit_key)
                            && BillingPeriod::parse(&due.period).ok() == Some(p)
                            && due.expense_type == crate::models::ExpenseType::OperationalDues
                            && due.status != crate::models::DebtStatus::Cancelled
                    })
                    .cloned()
                    .collect();
                if dues.len() == 1 {
                    candidates.push((p, dues[0].clone(), created_on, history.clone()));
                }
            }
            candidates
        };

        let mut results = Vec::new();
        let correction_service = CorrectionService::new(&self.state);
        for (period, due, created_on, history) in candidate_periods {
            let existing_pending = {
                let inner = self.state.inner.read().await;
                inner
                    .finance
                    .corrections
                    .iter()
                    .find(|c| {
                        c.status == crate::models::REQUEST_PENDING
                            && crate::auth::same_id(&c.due_id, &due.id)
                    })
                    .cloned()
            };
            if let Some(existing) = existing_pending {
                results.push(existing);
                continue;
            }

            let owner_person_id = {
                let inner = self.state.inner.read().await;
                inner
                    .units
                    .iter()
                    .find(|u| crate::auth::same_id(&u.id, &due.unit_id))
                    .and_then(|u| u.owner_user_id.as_deref())
                    .and_then(|s| s.strip_prefix("person-").unwrap_or(s).parse::<i64>().ok())
            };

            let shares = detailed_accrual_shares(
                due.principal_amount,
                period,
                created_on,
                &history,
                owner_person_id,
                true,
            );
            if shares.len() >= 2 {
                let request = crate::models::RequestCorrectionRequest {
                    due_id: due.id.clone(),
                    kind: crate::models::CORRECTION_SPLIT_REISSUE.to_string(),
                    amount: None,
                    due_date: None,
                    debtor_type: None,
                    replacement_shares: shares
                        .into_iter()
                        .map(|(debtor_type, amount, liable_person_id)| {
                            crate::models::CorrectionReplacementShare {
                                debtor_type,
                                amount,
                                liable_person_id,
                                due_date: None,
                            }
                        })
                        .collect(),
                    reason: format!("Occupancy changed during open period {}", period.key()),
                };
                match correction_service.request(caller, request).await {
                    Ok(c) => results.push(c),
                    Err(e) => {
                        let inner = self.state.inner.read().await;
                        if let Some(existing) = inner
                            .finance
                            .corrections
                            .iter()
                            .find(|c| {
                                c.status == crate::models::REQUEST_PENDING
                                    && crate::auth::same_id(&c.due_id, &due.id)
                            })
                            .cloned()
                        {
                            results.push(existing);
                        } else {
                            return Err(e);
                        }
                    }
                }
            } else if shares.len() == 1 {
                let (target_debtor, target_amount, target_person) = shares[0];
                if due.debtor_type != target_debtor
                    || due.principal_amount != target_amount
                    || (target_person.is_some() && due.liable_person_id != target_person)
                {
                    let request = crate::models::RequestCorrectionRequest {
                        due_id: due.id.clone(),
                        kind: crate::models::CORRECTION_REISSUE.to_string(),
                        amount: Some(target_amount),
                        due_date: None,
                        debtor_type: Some(target_debtor.as_str().to_string()),
                        replacement_shares: Vec::new(),
                        reason: format!("Occupancy changed during open period {}", period.key()),
                    };
                    match correction_service.request(caller, request).await {
                        Ok(c) => results.push(c),
                        Err(e) => {
                            let inner = self.state.inner.read().await;
                            if let Some(existing) = inner
                                .finance
                                .corrections
                                .iter()
                                .find(|c| {
                                    c.status == crate::models::REQUEST_PENDING
                                        && crate::auth::same_id(&c.due_id, &due.id)
                                })
                                .cloned()
                            {
                                results.push(existing);
                            } else {
                                return Err(e);
                            }
                        }
                    }
                }
            }
        }
        Ok(results)
    }

    /// Requests a four-eyes split correction when a transition changes one
    /// accrued liability into owner and tenant shares in an open period.
    pub async fn request_open_period_split(
        &self,
        caller: &Caller,
        unit_id: &str,
        effective_date: NaiveDate,
    ) -> FinanceResult<Option<crate::models::AccrualCorrection>> {
        let period = BillingPeriod::of_date(effective_date);
        let corrections = self
            .request_occupancy_corrections(caller, unit_id, effective_date)
            .await?;
        Ok(corrections
            .into_iter()
            .find(|c| BillingPeriod::parse(&c.period).ok() == Some(period)))
    }

    /// Requests the four-eyes split of the sale month's operational dues of an owner-occupied
    /// unit between seller and buyer, by calendar days (STORY-08-05). The seller keeps the days
    /// before `transfer_date` and the original due date; the buyer owes the rest from
    /// `transfer_date` (or the original due date, if later). Returns `None` when the month has
    /// no single open operational liability to split, is closed, or the transfer is on its
    /// first day.
    pub async fn request_sale_split(
        &self,
        caller: &Caller,
        unit_id: &str,
        seller_person_id: i64,
        buyer_person_id: i64,
        transfer_date: NaiveDate,
    ) -> FinanceResult<Option<crate::models::AccrualCorrection>> {
        let period = BillingPeriod::of_date(transfer_date);
        let unit_key = parse_unit_id(unit_id)
            .map(|id| id.to_string())
            .unwrap_or_else(|| unit_id.to_string());
        let due = {
            let inner = self.state.inner.read().await;
            let closed = inner.dues_periods.iter().any(|row| {
                crate::auth::same_id(&row.site_id, &caller.site_id)
                    && BillingPeriod::parse(&row.period_name).ok() == Some(period)
                    && row.status.as_str() == "CLOSED"
            });
            let mut dues = inner.dues.iter().filter(|due| {
                crate::auth::same_id(&due.unit_id, &unit_key)
                    && BillingPeriod::parse(&due.period).ok() == Some(period)
                    && due.expense_type == crate::models::ExpenseType::OperationalDues
                    && due.debtor_type == DebtorType::Owner
                    && due.status != crate::models::DebtStatus::Cancelled
            });
            match (closed, dues.next(), dues.next()) {
                (false, Some(only), None) => Some(only.clone()),
                _ => None,
            }
        };
        let Some(due) = due else {
            return Ok(None);
        };
        let Some((seller_share, buyer_share)) = crate::domain::sale_clearance::split_month_by_days(
            due.principal_amount,
            period.first_day(),
            transfer_date,
        ) else {
            return Ok(None);
        };
        let request = crate::models::RequestCorrectionRequest {
            due_id: due.id.clone(),
            kind: crate::models::CORRECTION_SPLIT_REISSUE.to_string(),
            amount: None,
            due_date: None,
            debtor_type: None,
            replacement_shares: vec![
                crate::models::CorrectionReplacementShare {
                    debtor_type: DebtorType::Owner,
                    amount: seller_share,
                    liable_person_id: Some(seller_person_id),
                    due_date: None,
                },
                crate::models::CorrectionReplacementShare {
                    debtor_type: DebtorType::Owner,
                    amount: buyer_share,
                    liable_person_id: Some(buyer_person_id),
                    due_date: Some(due.due_date.max(transfer_date)),
                },
            ],
            reason: format!(
                "Title transfer effective {} splits period {}",
                transfer_date,
                period.key()
            ),
        };
        CorrectionService::new(&self.state)
            .request(caller, request)
            .await
            .map(Some)
    }

    /// The owner on record and whether they live in the unit, read before a title transfer
    /// replaces them. `None` without a database or an owner on record.
    pub async fn seller_before_transfer(&self, site_id: &str, unit_id: &str) -> Option<Seller> {
        let pool = self.state.db_pool()?;
        let site = crate::db::require_id("site", site_id).ok()?;
        let unit = parse_unit_id(unit_id)?;
        let client = pool
            .get()
            .await
            .inspect_err(
                |error| tracing::warn!(%error, "seller lookup could not reach the database"),
            )
            .ok()?;
        let row = client
            .query_opt(
                "SELECT u.owner_person_id,
                        EXISTS (SELECT 1 FROM unit_occupancies o
                                 WHERE o.unit_id = u.id AND o.is_active AND o.end_date IS NULL
                                   AND o.occupancy_type = 'OWNER'
                                   AND o.person_id = u.owner_person_id)
                   FROM units u WHERE u.id = $1 AND u.site_id = $2",
                &[&unit, &site],
            )
            .await
            .inspect_err(|error| tracing::warn!(%error, "seller lookup failed"))
            .ok()??;
        let person_id: Option<i64> = row.get(0);
        person_id.map(|person_id| Seller {
            person_id,
            owner_occupied: row.get(1),
        })
    }

    /// Today's date in the site's time zone.
    pub async fn site_today(&self, site_id: &str) -> NaiveDate {
        self.today(site_id).await
    }

    async fn today(&self, site_id: &str) -> NaiveDate {
        let inner = self.state.inner.read().await;
        crate::services::finance_common::site_today(&inner, site_id)
    }

    /// Runs one occupancy command atomically.
    pub async fn transition(
        &self,
        site_id: &str,
        unit_id: &str,
        req: OccupancyTransitionRequest,
    ) -> Result<OccupancyTransitionResponse, OccupancyError> {
        let site =
            crate::db::require_id("site", site_id).map_err(|_| OccupancyError::UnitNotFound)?;
        let unit = parse_unit_id(unit_id).ok_or(OccupancyError::UnitNotFound)?;
        let command = occupancy_command(req.command)?;
        let today = self.today(site_id).await;
        let pool = self.state.pool.as_ref().ok_or_else(|| {
            OccupancyError::Storage("Database connection unavailable".to_string())
        })?;
        let mut client = pool
            .get()
            .await
            .map_err(|e| OccupancyError::Storage(e.to_string()))?;
        let tx = client.transaction().await?;
        crate::db::tx_bind_tenant(&tx, site)
            .await
            .map_err(|e| OccupancyError::Storage(e.to_string()))?;

        let opens_tenant = matches!(
            command,
            Command::TenantMoveIn | Command::ReplaceTenant | Command::OwnerRentsOut
        );
        let opens_owner = matches!(command, Command::OwnerMoveIn | Command::OwnerTakesBack);
        let tenant_person_id = if opens_tenant {
            Some(resolve_tenant(&tx, site, &req).await?)
        } else {
            None
        };
        let owner_person_id = if opens_owner {
            resolve_owner_choice(&tx, site, &req).await?
        } else {
            None
        };
        let input = TransitionInput {
            effective_date: req.effective_date.unwrap_or(today),
            today,
            tenant_person_id,
            owner_person_id,
            new_owner_person_id: None,
            notes: req.notes.clone().filter(|n| !n.trim().is_empty()),
        };
        let outcome = repo::apply_occupancy_command(&tx, site, unit, command, &input).await?;
        let closed = match outcome.closed.as_ref() {
            Some(c) => Some(closed_item(&tx, unit, c, input.notes.clone()).await?),
            None => None,
        };
        let opened = match outcome.opened.as_ref() {
            Some(o) => Some(opened_item(&tx, unit, o, input.notes.clone()).await?),
            None => None,
        };
        tx.commit().await?;
        {
            let mut inner = self.state.inner.write().await;
            let history = inner.unit_occupancies.entry(unit.to_string()).or_default();
            if let Some(closed_item) = closed.as_ref() {
                if let Some(existing) = history.iter_mut().find(|item| item.id == closed_item.id) {
                    *existing = closed_item.clone();
                } else {
                    history.push(closed_item.clone());
                }
            }
            if let Some(opened_item) = opened.as_ref() {
                if !history.iter().any(|item| item.id == opened_item.id) {
                    history.push(opened_item.clone());
                }
            }
            if let Some(unit_obj) = inner
                .units
                .iter_mut()
                .find(|u| crate::auth::same_id(&u.id, &unit.to_string()))
            {
                match outcome.plan.to.occupancy {
                    crate::domain::unit_state::Occupancy::Vacant
                    | crate::domain::unit_state::Occupancy::OwnerOccupied => {
                        unit_obj.tenant_user_id = None;
                    }
                    crate::domain::unit_state::Occupancy::TenantOccupied => {
                        if let Some(opened_item) = opened.as_ref() {
                            unit_obj.tenant_user_id =
                                Some(format!("person-{}", opened_item.person_id));
                        }
                    }
                }
            }
        }
        tracing::info!(
            unit_id = unit,
            command = outcome.plan.command.as_str(),
            from = %outcome.plan.from.label(),
            to = %outcome.plan.to.label(),
            "Unit occupancy transition applied"
        );
        if outcome.closed.is_some() {
            self.forget_household(unit_id, unit).await;
        }
        Ok(OccupancyTransitionResponse {
            unit_id: unit,
            command: outcome.plan.command,
            from_state: outcome.plan.from,
            to_state: outcome.plan.to,
            closed,
            opened,
            correction_requests: Vec::new(),
            supplementary_charges: Vec::new(),
        })
    }

    /// The unit's ownership and occupancy and the commands legal from there.
    pub async fn unit_state(
        &self,
        site_id: &str,
        unit_id: &str,
    ) -> Result<UnitOccupancyStateResponse, OccupancyError> {
        let site =
            crate::db::require_id("site", site_id).map_err(|_| OccupancyError::UnitNotFound)?;
        let unit = parse_unit_id(unit_id).ok_or(OccupancyError::UnitNotFound)?;
        let pool = self.state.pool.as_ref().ok_or_else(|| {
            OccupancyError::Storage("Database connection unavailable".to_string())
        })?;
        let mut client = pool
            .get()
            .await
            .map_err(|e| OccupancyError::Storage(e.to_string()))?;
        let tx = crate::db::begin_tenant_read(&mut client, site)
            .await
            .map_err(|e| OccupancyError::Storage(e.to_string()))?;
        let snapshot = repo::read_unit_snapshot(&tx, site, unit).await?;
        tx.commit().await?;
        Ok(state_response(&snapshot))
    }

    /// Active household members are those of an active session; the cache
    /// of the closed one is dropped.
    async fn forget_household(&self, unit_id: &str, unit: i64) {
        let mut inner = self.state.inner.write().await;
        for key in [
            unit.to_string(),
            format!("d-{unit}"),
            format!("unit-{unit}"),
            unit_id.to_string(),
        ] {
            inner.unit_members.remove(&key);
        }
    }
}

/// Builds the state response from a snapshot (shared with the UI contract).
pub fn state_response(snapshot: &UnitSnapshot) -> UnitOccupancyStateResponse {
    UnitOccupancyStateResponse {
        unit_id: snapshot.unit_id,
        ownership: snapshot.state.ownership,
        occupancy: snapshot.state.occupancy,
        owners: snapshot
            .owners
            .iter()
            .map(|o| UnitOwnerDto {
                person_id: o.person_id,
                full_name: o.full_name.clone(),
                share_percentage: o.share_percentage,
            })
            .collect(),
        occupant: snapshot.session.as_ref().map(|s| UnitOccupantDto {
            occupancy_id: s.occupancy_id,
            person_id: s.person_id,
            full_name: s.full_name.clone(),
            role: debtor_type(s.role),
            start_date: s.start_date,
        }),
        allowed_commands: unit_state::allowed_commands(snapshot.state),
    }
}

fn debtor_type(role: SessionRole) -> DebtorType {
    match role {
        SessionRole::Owner => DebtorType::Owner,
        SessionRole::Tenant => DebtorType::Tenant,
    }
}

/// The incoming tenant: an existing person of this site, or a new one.
async fn resolve_tenant(
    tx: &Transaction<'_>,
    site: i64,
    req: &OccupancyTransitionRequest,
) -> Result<i64, OccupancyError> {
    if let Some(person) = &req.person {
        return Ok(crate::services::person_service::resolve_person_ref(tx, site, person).await?);
    }
    if let Some(person_id) = req.person_id {
        return tx
            .query_opt(
                "SELECT id FROM persons WHERE id = $1 AND site_id = $2 AND deleted_at IS NULL",
                &[&person_id, &site],
            )
            .await?
            .map(|row| row.get(0))
            .ok_or(OccupancyError::PersonNotFound);
    }
    let email = req
        .email
        .as_deref()
        .map(crate::domain::email::NormalizedEmail::normalize)
        .filter(|e| !e.is_empty());
    if let Some(ref email) = email {
        crate::services::site_admin_service::validate_email(email)
            .map_err(OccupancyError::InvalidEmail)?;
        if let Some(row) = tx
            .query_opt(
                "SELECT id FROM persons WHERE site_id = $2 AND LOWER(email) = $1 AND deleted_at IS NULL",
                &[email, &site],
            )
            .await?
        {
            return Ok(row.get(0));
        }
    }
    let full_name = req
        .full_name
        .as_deref()
        .map(str::trim)
        .filter(|n| !n.is_empty())
        .ok_or(OccupancyError::TenantRequired)?;
    let phone = req.phone.clone().unwrap_or_default();
    crate::db::person_repository::resolve_new_site_person(
        tx,
        full_name,
        Some(&phone),
        email.as_deref(),
        "HOME_RESIDENT",
        site,
        true,
    )
    .await
    .map_err(|error| OccupancyError::Storage(error.to_string()))
}

/// Which owner moves in. Person data never creates an owner: an email is only
/// used to find an existing person, who must then be an owner on record.
async fn resolve_owner_choice(
    tx: &Transaction<'_>,
    site: i64,
    req: &OccupancyTransitionRequest,
) -> Result<Option<i64>, OccupancyError> {
    let referenced = match &req.person {
        Some(crate::models::PersonRef::Existing { person_id }) => Some(*person_id),
        Some(crate::models::PersonRef::New { .. }) => return Err(OccupancyError::NotAnOwner),
        None => None,
    };
    if let Some(person_id) = req.owner_person_id.or(referenced).or(req.person_id) {
        return Ok(Some(person_id));
    }
    let email = req
        .email
        .as_deref()
        .map(crate::domain::email::NormalizedEmail::normalize)
        .filter(|e| !e.is_empty());
    if let Some(email) = email {
        return tx
            .query_opt(
                "SELECT id FROM persons WHERE site_id = $2 AND LOWER(email) = $1 AND deleted_at IS NULL",
                &[&email, &site],
            )
            .await?
            .map(|row| Some(row.get(0)))
            .ok_or(OccupancyError::NotAnOwner);
    }
    if req
        .full_name
        .as_deref()
        .is_some_and(|name| !name.trim().is_empty())
    {
        return Err(OccupancyError::NotAnOwner);
    }
    Ok(None)
}

async fn person_contact(
    tx: &Transaction<'_>,
    person_id: i64,
) -> Result<(String, Option<String>, Option<String>), OccupancyError> {
    let row = tx
        .query_one(
            "SELECT full_name, phone, email FROM persons WHERE id = $1",
            &[&person_id],
        )
        .await?;
    Ok((row.get(0), row.get(1), row.get(2)))
}

async fn closed_item(
    tx: &Transaction<'_>,
    unit: i64,
    closed: &ClosedSession,
    notes: Option<String>,
) -> Result<OccupancyHistoryItem, OccupancyError> {
    let (name, phone, email) = person_contact(tx, closed.person_id).await?;
    Ok(OccupancyHistoryItem {
        id: closed.occupancy_id,
        unit_id: unit,
        person_id: closed.person_id,
        person_name: name,
        person_phone: phone,
        person_email: email,
        role: debtor_type(closed.role),
        start_date: closed.start_date.to_string(),
        end_date: Some(closed.end_date.to_string()),
        is_active: false,
        exit_balance: closed.exit_balance,
        notes,
        created_at: chrono::Utc::now(),
    })
}

async fn opened_item(
    tx: &Transaction<'_>,
    unit: i64,
    opened: &OpenedSession,
    notes: Option<String>,
) -> Result<OccupancyHistoryItem, OccupancyError> {
    let (name, phone, email) = person_contact(tx, opened.person_id).await?;
    Ok(OccupancyHistoryItem {
        id: opened.occupancy_id,
        unit_id: unit,
        person_id: opened.person_id,
        person_name: name,
        person_phone: phone,
        person_email: email,
        role: debtor_type(opened.role),
        start_date: opened.start_date.to_string(),
        end_date: None,
        is_active: true,
        exit_balance: rust_decimal::Decimal::ZERO,
        notes,
        created_at: chrono::Utc::now(),
    })
}
