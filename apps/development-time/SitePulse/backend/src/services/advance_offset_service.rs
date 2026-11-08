//! Advance offset (avans mahsubu) as an explicit write operation.
//!
//! Offsetting moves money (it settles liabilities from advance balances), so it
//! runs only from the write paths that create liabilities: the dues accrual
//! endpoint, the scheduled accrual, capital installment accrual and site
//! provisioning. Read endpoints never call it, and there is no timer.
//!
//! * With PostgreSQL each (unit, debtor) with an advance and an open liability
//!   is booked as a same-debtor virman (`PaymentTrackingService::
//!   inter_ledger_transfer`): one tenant-bound transaction that locks the rows,
//!   issues a receipt and entry, writes allocations and debits the advance
//!   (`VIRMAN_DEBIT`). The in-memory view is updated from the committed result,
//!   and the offset can be reversed like any receipt.
//! * Without a database (tests, demo) the in-memory ledger is offset directly.
//!
//! Every call names its tenant scope; only the platform scheduler may sweep all
//! sites.

use rust_decimal::Decimal;

use crate::services::ledger_application::{
    apply_advance_payments_offset, apply_advance_payments_offset_for_site,
};
use crate::state::AppState;

/// Why an offset run did not complete.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum OffsetError {
    /// A site or unit id in the scope is not a valid id.
    #[error("invalid offset scope: {0}")]
    InvalidScope(String),
    /// The candidates could not be read from PostgreSQL.
    #[error("advance offset candidates could not be read: {0}")]
    Database(String),
    /// Some units were not offset; nothing partial was committed for them.
    #[error("advance offset incomplete: {}", .0.join("; "))]
    Incomplete(Vec<String>),
}

/// Which units an offset run may touch.
#[derive(Debug, Clone, Copy)]
pub enum OffsetScope<'a> {
    /// One unit of one site.
    Unit { site_id: &'a str, unit_id: &'a str },
    /// Every unit of one site.
    Site(&'a str),
    /// Every site: reserved for the platform scheduler.
    Platform,
}

/// What an offset run settled.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct OffsetSummary {
    /// Offset bookings (database: one mahsup receipt per unit and debtor).
    pub settled_lines: usize,
    /// Units (database) or fully settled liabilities (in-memory) affected.
    pub fully_settled_dues: usize,
    pub total_offset: Decimal,
}

/// Offsets advance balances against open liabilities within `scope`.
///
/// Errors of individual units are collected; the run continues with the other
/// units and the error lists every unit that was not offset (nothing partial is
/// committed for a failed unit).
pub async fn settle_advances(
    state: &AppState,
    scope: OffsetScope<'_>,
) -> Result<OffsetSummary, OffsetError> {
    match state.db_pool() {
        Some(pool) => settle_in_db(state, pool, scope).await,
        None => Ok(settle_in_memory(state, scope).await),
    }
}

async fn settle_in_memory(state: &AppState, scope: OffsetScope<'_>) -> OffsetSummary {
    let mut inner = state.inner.write().await;
    let (count, total) = match scope {
        OffsetScope::Unit { site_id, unit_id } => {
            let belongs = inner.units.iter().any(|u| {
                crate::auth::same_id(&u.id, unit_id) && crate::auth::same_id(&u.site_id, site_id)
            });
            if !belongs {
                return OffsetSummary::default();
            }
            let key = inner
                .units
                .iter()
                .find(|u| crate::auth::same_id(&u.id, unit_id))
                .map(|u| u.id.clone())
                .unwrap_or_else(|| unit_id.to_string());
            apply_advance_payments_offset(&mut inner, Some(&key))
        }
        OffsetScope::Site(site_id) => apply_advance_payments_offset_for_site(&mut inner, site_id),
        OffsetScope::Platform => apply_advance_payments_offset(&mut inner, None),
    };
    OffsetSummary {
        settled_lines: count,
        fully_settled_dues: count,
        total_offset: total,
    }
}

async fn settle_in_db(
    state: &AppState,
    pool: &deadpool_postgres::Pool,
    scope: OffsetScope<'_>,
) -> Result<OffsetSummary, OffsetError> {
    let read_err = |e: Box<dyn std::error::Error + Send + Sync>| {
        OffsetError::Database(crate::db::describe_db_error(e.as_ref()))
    };
    let mut candidates = match scope {
        OffsetScope::Unit { site_id, .. } | OffsetScope::Site(site_id) => {
            let site = crate::db::require_id("site", site_id).map_err(OffsetError::InvalidScope)?;
            crate::db::units_with_offsettable_advance(pool, Some(site))
                .await
                .map_err(read_err)?
        }
        OffsetScope::Platform => crate::db::units_with_offsettable_advance(pool, None)
            .await
            .map_err(read_err)?,
    };
    if let OffsetScope::Unit { unit_id, .. } = scope {
        let unit = crate::db::require_id("unit", unit_id).map_err(OffsetError::InvalidScope)?;
        candidates.retain(|c| c.unit_id == unit);
    }

    let payments = crate::services::PaymentTrackingService::new(state.clone());
    let mut summary = OffsetSummary::default();
    let mut errors = Vec::new();
    let mut units_offset = std::collections::BTreeSet::new();
    for c in candidates {
        // A same-debtor virman: the debtor's own advance settles the debtor's
        // own open liabilities (O-1), booked with receipt, entry and
        // allocations in one tenant-bound transaction. The amount is the
        // balance seen here; the transfer re-reads it under lock and only
        // clears what is actually open.
        let request = crate::models::InterLedgerTransferRequest {
            site_id: Some(c.site_id.to_string()),
            unit_id: c.unit_id.to_string(),
            amount: c.advance,
            note: Some(format!(
                "Avans mahsubu (otomatik): {} avansı açık borca mahsup edildi",
                c.debtor_type
            )),
            operator_user_id: None,
            source_debtor: Some(c.debtor_type.clone()),
            target_debtor: Some(c.debtor_type.clone()),
        };
        match payments.inter_ledger_transfer(request).await {
            Ok(done) => {
                summary.settled_lines += 1;
                summary.total_offset += done.transferred_amount;
                units_offset.insert(c.unit_id);
            }
            Err(e) => errors.push(format!("unit {} ({}): {}", c.unit_id, c.debtor_type, e)),
        }
    }
    summary.fully_settled_dues = units_offset.len();
    if errors.is_empty() {
        Ok(summary)
    } else {
        let err = OffsetError::Incomplete(errors);
        tracing::error!("{}", err);
        Err(err)
    }
}
