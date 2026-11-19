//! Guarded occupancy commands on a unit (EPIC-08 §3.3, STORY-08-06..08, 08-10).
//!
//! Move-in, move-out and the compound moves all come through
//! [`OccupancyService::transition`]: one transaction, the unit row locked, the
//! precondition checked by `domain::unit_state`, the sessions changed by
//! `db::occupancy_repository`. A move never changes ownership; an owner
//! move-in opens a session for an owner on record and accepts no new person.

use chrono::NaiveDate;
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

    /// Requests a four-eyes split correction when a transition changes one
    /// accrued liability into owner and tenant shares in an open period.
    pub async fn request_open_period_split(
        &self,
        caller: &Caller,
        unit_id: &str,
        effective_date: NaiveDate,
    ) -> FinanceResult<Option<crate::models::AccrualCorrection>> {
        let period = BillingPeriod::of_date(effective_date);
        let unit_key = parse_unit_id(unit_id)
            .map(|id| id.to_string())
            .unwrap_or_else(|| unit_id.to_string());
        let candidate = {
            let inner = self.state.inner.read().await;
            let enabled = inner
                .sites
                .iter()
                .find(|site| crate::auth::same_id(&site.id, &caller.site_id))
                .is_some_and(|site| site.proration_enabled);
            let closed = inner.dues_periods.iter().any(|row| {
                crate::auth::same_id(&row.site_id, &caller.site_id)
                    && BillingPeriod::parse(&row.period_name).ok() == Some(period)
                    && row.status.as_str() == "CLOSED"
            });
            let dues: Vec<_> = inner
                .dues
                .iter()
                .filter(|due| {
                    crate::auth::same_id(&due.unit_id, &unit_key)
                        && BillingPeriod::parse(&due.period).ok() == Some(period)
                        && due.expense_type == crate::models::ExpenseType::OperationalDues
                        && due.status != crate::models::DebtStatus::Cancelled
                })
                .cloned()
                .collect();
            if !enabled || closed || dues.len() != 1 {
                None
            } else {
                inner
                    .units
                    .iter()
                    .find(|unit| {
                        crate::auth::same_id(&unit.id, &unit_key)
                            && crate::auth::same_id(&unit.site_id, &caller.site_id)
                    })
                    .map(|unit| {
                        let history = inner
                            .unit_occupancies
                            .get(&unit.id)
                            .cloned()
                            .unwrap_or_default();
                        (dues[0].clone(), unit.created_on, history)
                    })
            }
        };
        let Some((due, created_on, history)) = candidate else {
            return Ok(None);
        };
        let shares = accrual_shares(
            due.principal_amount,
            period,
            created_on,
            &history,
            true,
            effective_date,
        );
        if shares.len() != 2 {
            return Ok(None);
        }
        let request = crate::models::RequestCorrectionRequest {
            due_id: due.id,
            kind: crate::models::CORRECTION_SPLIT_REISSUE.to_string(),
            amount: None,
            due_date: None,
            debtor_type: None,
            replacement_shares: shares
                .into_iter()
                .map(
                    |(debtor_type, amount)| crate::models::CorrectionReplacementShare {
                        debtor_type,
                        amount,
                    },
                )
                .collect(),
            reason: format!("Occupancy changed during open period {}", period.key()),
        };
        CorrectionService::new(&self.state)
            .request(caller, request)
            .await
            .map(Some)
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
        if let Some(closed_item) = closed.as_ref() {
            let mut inner = self.state.inner.write().await;
            let history = inner.unit_occupancies.entry(unit.to_string()).or_default();
            if let Some(existing) = history.iter_mut().find(|item| item.id == closed_item.id) {
                *existing = closed_item.clone();
            } else {
                history.push(closed_item.clone());
            }
            if let Some(opened_item) = opened.as_ref() {
                if !history.iter().any(|item| item.id == opened_item.id) {
                    history.push(opened_item.clone());
                }
            }
        } else if let Some(opened_item) = opened.as_ref() {
            let mut inner = self.state.inner.write().await;
            let history = inner.unit_occupancies.entry(unit.to_string()).or_default();
            if !history.iter().any(|item| item.id == opened_item.id) {
                history.push(opened_item.clone());
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
