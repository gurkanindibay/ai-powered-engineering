//! Shared pieces of the SPEC-009 services: the typed error, the caller, and
//! tenant-scoped lookups over the in-memory state.

use chrono::{NaiveDate, Utc};
use rust_decimal::Decimal;

use crate::models::{DuesLiability, IndependentUnit, Role, User};
use crate::services::dues_ledger::{self, DEBTOR_OWNER, DEBTOR_TENANT};
use crate::state::AppStateInner;

/// Why a SPEC-009 operation was refused; handlers map it to an HTTP status.
#[derive(Debug, Clone, PartialEq, thiserror::Error)]
pub enum FinanceError {
    #[error("{0}")]
    NotFound(String),
    #[error("{0}")]
    Invalid(String),
    /// The request conflicts with the record's state or a legal rule (409).
    #[error("{0}")]
    Conflict(String),
    #[error("{0}")]
    Forbidden(String),
    #[error("{0}")]
    Unavailable(String),
}

pub type FinanceResult<T> = Result<T, FinanceError>;

impl From<Box<dyn std::error::Error + Send + Sync>> for FinanceError {
    fn from(e: Box<dyn std::error::Error + Send + Sync>) -> Self {
        FinanceError::Unavailable(format!("The change was not saved: {}", e))
    }
}

pub fn invalid(message: impl Into<String>) -> FinanceError {
    FinanceError::Invalid(message.into())
}
pub fn conflict(message: impl Into<String>) -> FinanceError {
    FinanceError::Conflict(message.into())
}

/// Returns the first date in an open period that can book an event dated in a
/// closed period. An open date is preserved; a closed month moves to the day
/// after its final day, repeating across consecutive closed periods.
pub fn open_period_booking_date(
    inner: &AppStateInner,
    site_id: &str,
    date: NaiveDate,
) -> NaiveDate {
    let mut booking_date = date;
    for _ in 0..=inner.dues_periods.len() {
        let closed_end = inner.dues_periods.iter().find_map(|period| {
            if !crate::auth::same_id(&period.site_id, site_id)
                || period.status != crate::models::DuesPeriodStatus::Closed
            {
                return None;
            }
            let billing_period =
                crate::domain::billing_period::BillingPeriod::parse(&period.period_name).ok()?;
            (booking_date >= billing_period.first_day()
                && booking_date <= billing_period.last_day())
            .then_some(billing_period.last_day())
        });
        let Some(closed_end) = closed_end else {
            break;
        };
        let Some(next_date) = closed_end.succ_opt() else {
            break;
        };
        booking_date = next_date;
    }
    booking_date
}
pub fn not_found(message: impl Into<String>) -> FinanceError {
    FinanceError::NotFound(message.into())
}

/// Who is calling, already authenticated and pinned to a site by the middleware.
#[derive(Debug, Clone)]
pub struct Caller {
    pub site_id: String,
    pub user_id: String,
    pub email: String,
    pub role: Role,
    pub unit_id: Option<String>,
}

impl Caller {
    pub fn from_claims(claims: &crate::auth::Claims) -> Self {
        Caller {
            site_id: claims.site_id.clone(),
            user_id: claims.sub.clone(),
            email: claims.email.clone(),
            role: claims.role,
            unit_id: claims.unit_id.clone(),
        }
    }

    /// A background job acting for a site.
    pub fn system(site_id: &str, name: &str) -> Self {
        Caller {
            site_id: site_id.to_string(),
            user_id: name.to_string(),
            email: format!("{}@system", name),
            role: Role::SiteManager,
            unit_id: None,
        }
    }

    /// The audit form used in `created_by` / `decided_by` columns.
    pub fn actor(&self) -> String {
        format!("user:{} <{}>", self.user_id, self.email)
    }

    pub fn is_staff(&self) -> bool {
        matches!(self.role, Role::SiteManager | Role::SaasAdmin)
    }

    pub fn is_auditor(&self) -> bool {
        self.role == Role::Auditor
    }
}

/// Two actor strings name the same person (`user:<id> <email>`).
pub fn same_actor(a: &str, b: &str) -> bool {
    let key = |s: &str| {
        s.split_whitespace()
            .next()
            .map(|t| t.trim_start_matches("user:").to_string())
            .unwrap_or_default()
    };
    let (ka, kb) = (key(a), key(b));
    !ka.is_empty() && (crate::auth::same_id(&ka, &kb) || a.trim() == b.trim())
}

/// `OWNER` or `TENANT` from user input (default `OWNER`).
pub fn parse_debtor(raw: Option<&str>) -> FinanceResult<&'static str> {
    match raw.map(|s| s.trim().to_ascii_uppercase()).as_deref() {
        None | Some("") | Some("OWNER") => Ok(DEBTOR_OWNER),
        Some("TENANT") => Ok(DEBTOR_TENANT),
        Some(other) => Err(invalid(format!(
            "debtor_type must be OWNER or TENANT, got '{}'",
            other
        ))),
    }
}

pub fn site_exists(inner: &AppStateInner, site_id: &str) -> bool {
    inner
        .sites
        .iter()
        .any(|s| crate::auth::same_id(&s.id, site_id))
}

pub fn site_name(inner: &AppStateInner, site_id: &str) -> String {
    inner
        .sites
        .iter()
        .find(|s| crate::auth::same_id(&s.id, site_id))
        .map(|s| s.name.clone())
        .unwrap_or_else(|| format!("Site {}", site_id))
}

/// Today in the site's time zone.
pub fn site_today(inner: &AppStateInner, site_id: &str) -> NaiveDate {
    site_today_at(inner, site_id, crate::e2e_clock::now_utc())
}

/// Today's site-local date as of a supplied instant.
pub fn site_today_at(
    inner: &AppStateInner,
    site_id: &str,
    now: chrono::DateTime<Utc>,
) -> NaiveDate {
    let tz = inner
        .sites
        .iter()
        .find(|s| crate::auth::same_id(&s.id, site_id))
        .map(|s| s.timezone.clone())
        .unwrap_or_else(crate::models::default_site_timezone);
    crate::scheduler::site_local_date(&tz, now)
}

/// A timestamp's calendar date in the site's time zone (receipts are stored in
/// UTC; an Istanbul evening is already the next day there).
pub fn local_date(inner: &AppStateInner, site_id: &str, at: chrono::DateTime<Utc>) -> NaiveDate {
    let tz = inner
        .sites
        .iter()
        .find(|s| crate::auth::same_id(&s.id, site_id))
        .map(|s| s.timezone.clone())
        .unwrap_or_else(crate::models::default_site_timezone);
    crate::scheduler::site_local_date(&tz, at)
}

pub fn site_units<'a>(
    inner: &'a AppStateInner,
    site_id: &'a str,
) -> impl Iterator<Item = &'a IndependentUnit> + 'a {
    inner
        .units
        .iter()
        .filter(move |u| crate::auth::same_id(&u.site_id, site_id))
}

/// The unit, if it belongs to the site.
pub fn find_unit(
    inner: &AppStateInner,
    site_id: &str,
    unit_id: &str,
) -> FinanceResult<IndependentUnit> {
    site_units(inner, site_id)
        .find(|u| crate::auth::same_id(&u.id, unit_id))
        .cloned()
        .ok_or_else(|| not_found(format!("Unit {} not found in this site", unit_id)))
}

pub fn unit_label(inner: &AppStateInner, unit: &IndependentUnit) -> String {
    inner.unit_label(&unit.block_id, unit.unit_number)
}

pub fn label_of(inner: &AppStateInner, unit_id: &str) -> String {
    inner
        .units
        .iter()
        .find(|u| crate::auth::same_id(&u.id, unit_id))
        .map(|u| unit_label(inner, u))
        .unwrap_or_else(|| unit_id.to_string())
}

/// The user holding the debtor role on a unit.
pub fn debtor_user<'a>(
    inner: &'a AppStateInner,
    unit: &IndependentUnit,
    debtor: &str,
) -> Option<&'a User> {
    let id = if debtor == DEBTOR_TENANT {
        unit.tenant_user_id.as_ref()
    } else {
        unit.owner_user_id.as_ref()
    }?;
    inner.users.iter().find(|u| crate::auth::same_id(&u.id, id))
}

pub fn debtor_name(inner: &AppStateInner, unit: &IndependentUnit, debtor: &str) -> String {
    debtor_user(inner, unit, debtor)
        .map(|u| u.full_name.clone())
        .unwrap_or_else(|| {
            if debtor == DEBTOR_TENANT {
                "Kiracı"
            } else {
                "Kat Maliki"
            }
            .to_string()
        })
}

/// The debtor role of a signed-in resident on a unit; `None` for staff.
pub fn resident_debtor(caller: &Caller, unit: &IndependentUnit) -> Option<&'static str> {
    if caller.is_staff() {
        return None;
    }
    if unit
        .tenant_user_id
        .as_deref()
        .is_some_and(|t| crate::auth::same_id(t, &caller.user_id))
    {
        return Some(DEBTOR_TENANT);
    }
    if unit
        .owner_user_id
        .as_deref()
        .is_some_and(|o| crate::auth::same_id(o, &caller.user_id))
    {
        return Some(DEBTOR_OWNER);
    }
    match caller.role {
        Role::HomeResident if unit.tenant_user_id.is_some() => Some(DEBTOR_TENANT),
        _ => Some(DEBTOR_OWNER),
    }
}

/// Every liability of the site's units.
pub fn site_dues<'a>(
    inner: &'a AppStateInner,
    site_id: &str,
) -> impl Iterator<Item = &'a DuesLiability> + 'a {
    let units: Vec<&'a str> = inner
        .units
        .iter()
        .filter(|u| crate::auth::same_id(&u.site_id, site_id))
        .map(|u| u.id.as_str())
        .collect();
    inner
        .dues
        .iter()
        .filter(move |d| units.iter().any(|u| crate::auth::same_id(u, &d.unit_id)))
}

pub fn is_open(d: &DuesLiability) -> bool {
    d.status.is_collectable() && dues_ledger::outstanding(d) > Decimal::ZERO
}

pub fn find_due<'a>(
    inner: &'a AppStateInner,
    site_id: &str,
    due_id: &str,
) -> FinanceResult<&'a DuesLiability> {
    site_dues(inner, site_id)
        .find(|d| d.id == due_id || crate::auth::same_id(&d.id, due_id))
        .ok_or_else(|| not_found(format!("Liability {} not found in this site", due_id)))
}

/// Validates a positive money amount with at most two decimals.
pub fn money(amount: Decimal, field: &str) -> FinanceResult<Decimal> {
    if amount <= Decimal::ZERO || amount.scale() > 2 {
        return Err(invalid(format!(
            "{} must be positive with at most 2 decimals",
            field
        )));
    }
    Ok(amount)
}

pub fn non_empty(value: &str, min: usize, field: &str) -> FinanceResult<String> {
    let v = value.trim();
    if v.chars().count() < min {
        return Err(invalid(format!(
            "{} needs at least {} characters",
            field, min
        )));
    }
    Ok(v.to_string())
}

pub fn opt_text(value: &Option<String>) -> Option<String> {
    value
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(str::to_string)
}
