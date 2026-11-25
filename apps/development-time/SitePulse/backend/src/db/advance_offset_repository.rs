//! Candidates for the advance-balance offset (avans mahsubu).
//!
//! The offset itself is booked as a same-debtor inter-ledger transfer
//! (`PaymentTrackingService::inter_ledger_transfer`): one tenant-bound
//! transaction that locks the unit, the advance row and the open liabilities,
//! issues a receipt and a ledger entry, writes `payment_allocations` and debits
//! the advance (`VIRMAN_DEBIT`). That keeps `v_integrity_violations`
//! (allocations = paid amounts) clean and makes every offset reversible.
//!
//! The former implementation offset the in-memory copy and wrote *absolute*
//! paid amounts and balances back, so a stale copy could overwrite a payment
//! committed in the meantime or re-credit an advance that had been spent.

use deadpool_postgres::Pool;
use rust_decimal::Decimal;

use super::base::DbResult;

/// One debtor of one unit with a positive advance and an open liability.
#[derive(Debug, Clone, PartialEq)]
pub struct OffsetCandidate {
    pub site_id: i64,
    pub unit_id: i64,
    pub debtor_type: String,
    pub advance: Decimal,
}

/// Debtors that have a positive spendable advance (balance minus the amount reserved by
/// pending advance-exit settlements, as the transfer itself computes it) and an open
/// liability of their own.
/// `site_id` scopes the search to one tenant; `None` is the platform-wide
/// sweep (scheduler only).
pub async fn units_with_offsettable_advance(
    pool: &Pool,
    site_id: Option<i64>,
) -> DbResult<Vec<OffsetCandidate>> {
    let client = pool.get().await?;
    let rows = client
        .query(
            "SELECT u.site_id, u.id, ab.debtor_type,
                    (ab.balance - COALESCE((SELECT SUM(s.amount) FROM advance_exit_settlements s
                                             WHERE s.unit_id = ab.unit_id
                                               AND s.source_debtor = ab.debtor_type
                                               AND s.status = 'PENDING'), 0))::NUMERIC(15,2)
               FROM advance_balances ab
               JOIN units u ON u.id = ab.unit_id
              WHERE (ab.balance - COALESCE((SELECT SUM(s.amount) FROM advance_exit_settlements s
                                             WHERE s.unit_id = ab.unit_id
                                               AND s.source_debtor = ab.debtor_type
                                               AND s.status = 'PENDING'), 0)) > 0
                AND ($1::BIGINT IS NULL OR u.site_id = $1)
                AND EXISTS (SELECT 1 FROM dues_liabilities d
                             WHERE d.unit_id = ab.unit_id
                               AND d.debtor_type = ab.debtor_type
                               AND d.status NOT IN ('PAID', 'CANCELLED'))
              ORDER BY u.site_id, u.id, ab.debtor_type",
            &[&site_id],
        )
        .await?;
    Ok(rows
        .iter()
        .map(|r| OffsetCandidate {
            site_id: r.get(0),
            unit_id: r.get(1),
            debtor_type: r.get(2),
            advance: r.get(3),
        })
        .collect())
}
