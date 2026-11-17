//! Four-eyes payout or inter-debtor transfer of an exiting resident's advance.

use chrono::{DateTime, Utc};
use deadpool_postgres::Transaction;
use rust_decimal::Decimal;

use crate::models::{
    AdvanceExitSettlement, CreateAdvanceExitSettlementRequest, DecideAdvanceExitSettlementRequest,
};
use crate::services::finance_common::{
    conflict, invalid, money, not_found, opt_text, same_actor, Caller, FinanceError, FinanceResult,
};
use crate::state::AppState;

const OWNER: &str = "OWNER";
const TENANT: &str = "TENANT";
const PENDING: &str = "PENDING";
const APPROVED: &str = "APPROVED";
const REJECTED: &str = "REJECTED";

pub struct AdvanceExitSettlementService {
    state: AppState,
}

impl AdvanceExitSettlementService {
    pub fn new(state: &AppState) -> Self {
        Self {
            state: state.clone(),
        }
    }

    pub async fn create(
        &self,
        caller: &Caller,
        unit_id: &str,
        req: CreateAdvanceExitSettlementRequest,
    ) -> FinanceResult<AdvanceExitSettlement> {
        let ValidatedRequest {
            request_key,
            kind,
            source,
            target,
            amount,
            beneficiary_name,
            beneficiary_person_id,
            note,
        } = validate_request(&req)?;
        let site = parse_id("site", &caller.site_id)?;
        let unit = parse_id("unit", unit_id)?;
        let beneficiary_person = beneficiary_person_id
            .as_deref()
            .map(|id| parse_id("person", id))
            .transpose()?;
        let pool = self
            .state
            .pool
            .as_ref()
            .ok_or_else(|| FinanceError::Unavailable("Database unavailable".into()))?;
        let mut client = pool.get().await.map_err(db_unavailable)?;
        let tx = client.transaction().await.map_err(db_unavailable)?;
        crate::db::tx_bind_tenant(&tx, site)
            .await
            .map_err(db_unavailable)?;
        ensure_unit(&tx, site, unit).await?;
        if let Some(person_id) = beneficiary_person {
            ensure_person(&tx, site, unit, person_id, source).await?;
        }
        if let Some(existing) = find_by_request_key(&tx, site, &request_key).await? {
            if matches_request(
                &existing,
                unit,
                &request_key,
                kind,
                source,
                target,
                amount,
                &beneficiary_name,
                beneficiary_person,
                &note,
            ) {
                tx.commit().await.map_err(db_unavailable)?;
                return Ok(existing);
            }
            return Err(conflict(
                "request_key was already used for a different settlement",
            ));
        }
        lock_advance(&tx, unit, source).await?;
        // The advance-row lock serializes concurrent creates for this debtor.
        // Recheck after acquiring it so a matching retry returns the original row.
        if let Some(existing) = find_by_request_key(&tx, site, &request_key).await? {
            if matches_request(
                &existing,
                unit,
                &request_key,
                kind,
                source,
                target,
                amount,
                &beneficiary_name,
                beneficiary_person,
                &note,
            ) {
                tx.commit().await.map_err(db_unavailable)?;
                return Ok(existing);
            }
            return Err(conflict(
                "request_key was already used for a different settlement",
            ));
        }
        let available: Decimal = tx
            .query_one(
                "SELECT balance FROM advance_balances WHERE unit_id = $1 AND debtor_type = $2",
                &[&unit, &source],
            )
            .await
            .map_err(db_unavailable)?
            .get(0);
        let reserved: Decimal = tx
            .query_one(
                "SELECT COALESCE(SUM(amount), 0)::NUMERIC(15,2)
                   FROM advance_exit_settlements
                  WHERE site_id = $1 AND unit_id = $2 AND source_debtor = $3 AND status = 'PENDING'",
                &[&site, &unit, &source],
            )
            .await
            .map_err(db_unavailable)?
            .get(0);
        if available - reserved < amount {
            return Err(conflict(format!(
                "Available {} advance after pending exit requests is ₺{:.2}; ₺{:.2} was requested",
                source,
                available - reserved,
                amount
            )));
        }
        let row = tx
            .query_opt(
                "INSERT INTO advance_exit_settlements
                    (site_id, unit_id, request_key, kind, source_debtor, target_debtor, amount,
                     beneficiary_name, beneficiary_person_id, note, requested_by)
                 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
                 ON CONFLICT (site_id, request_key) DO NOTHING
                 RETURNING id, site_id, unit_id, request_key, kind, source_debtor, target_debtor, amount,
                           beneficiary_name, beneficiary_person_id, note, requested_by,
                           status, decided_by, decided_at, decision_note,
                           payment_reference, created_at",
                &[
                    &site,
                    &unit,
                    &request_key,
                    &kind.as_str(),
                    &source,
                    &target,
                    &amount,
                    &beneficiary_name,
                    &beneficiary_person,
                    &note,
                    &caller.actor(),
                ],
            )
            .await
            .map_err(db_unavailable)?;
        let row = match row {
            Some(row) => row,
            None => {
                let existing = find_by_request_key(&tx, site, &request_key)
                    .await?
                    .ok_or_else(|| conflict("settlement request could not be created"))?;
                if !matches_request(
                    &existing,
                    unit,
                    &request_key,
                    kind,
                    source,
                    target,
                    amount,
                    &beneficiary_name,
                    beneficiary_person,
                    &note,
                ) {
                    return Err(conflict(
                        "request_key was already used for a different settlement",
                    ));
                }
                tx.commit().await.map_err(db_unavailable)?;
                return Ok(existing);
            }
        };
        tx.commit().await.map_err(db_unavailable)?;
        Ok(from_row(&row))
    }

    pub async fn list(&self, caller: &Caller) -> FinanceResult<Vec<AdvanceExitSettlement>> {
        let site = parse_id("site", &caller.site_id)?;
        let pool = self
            .state
            .pool
            .as_ref()
            .ok_or_else(|| FinanceError::Unavailable("Database unavailable".into()))?;
        let mut client = pool.get().await.map_err(db_unavailable)?;
        let tx = client.transaction().await.map_err(db_unavailable)?;
        crate::db::tx_bind_tenant(&tx, site)
            .await
            .map_err(db_unavailable)?;
        let rows = tx
            .query(
                "SELECT id, site_id, unit_id, request_key, kind, source_debtor, target_debtor, amount,
                        beneficiary_name, beneficiary_person_id, note, requested_by,
                        status, decided_by, decided_at, decision_note,
                        payment_reference, created_at
                   FROM advance_exit_settlements
                  WHERE site_id = $1
                  ORDER BY created_at DESC, id DESC",
                &[&site],
            )
            .await
            .map_err(db_unavailable)?;
        tx.commit().await.map_err(db_unavailable)?;
        Ok(rows.iter().map(from_row).collect())
    }

    pub async fn decide(
        &self,
        caller: &Caller,
        settlement_id: i64,
        decision: DecideAdvanceExitSettlementRequest,
    ) -> FinanceResult<AdvanceExitSettlement> {
        if settlement_id <= 0 {
            return Err(invalid("settlement id must be positive"));
        }
        let reference = decision
            .payment_reference
            .as_deref()
            .map(str::trim)
            .filter(|v| !v.is_empty())
            .map(str::to_string);
        let decision_note = opt_text(&decision.note);
        let site = parse_id("site", &caller.site_id)?;
        let pool = self
            .state
            .pool
            .as_ref()
            .ok_or_else(|| FinanceError::Unavailable("Database unavailable".into()))?;
        let mut client = pool.get().await.map_err(db_unavailable)?;
        let tx = client.transaction().await.map_err(db_unavailable)?;
        crate::db::tx_bind_tenant(&tx, site)
            .await
            .map_err(db_unavailable)?;
        let row = tx
            .query_opt(
                "SELECT id, site_id, unit_id, request_key, kind, source_debtor, target_debtor, amount,
                        beneficiary_name, beneficiary_person_id, note, requested_by,
                        status, decided_by, decided_at, decision_note,
                        payment_reference, created_at
                   FROM advance_exit_settlements WHERE site_id = $1 AND id = $2 FOR UPDATE",
                &[&site, &settlement_id],
            )
            .await
            .map_err(db_unavailable)?
            .ok_or_else(|| {
                not_found(format!(
                    "Advance exit settlement {} not found",
                    settlement_id
                ))
            })?;
        let mut settlement = from_row(&row);
        if settlement.status != PENDING {
            return Err(conflict(format!(
                "Advance exit settlement {} is already {}",
                settlement.id, settlement.status
            )));
        }
        if same_actor(&settlement.requested_by, &caller.actor()) {
            return Err(FinanceError::Forbidden(
                "The approver must be a different person from the requester (four-eyes)".into(),
            ));
        }
        if decision.approve {
            if settlement.kind == "PAYOUT" && reference.is_none() {
                return Err(invalid("payment_reference is required to approve a payout"));
            }
            if settlement.kind == "TRANSFER" && reference.is_some() {
                return Err(invalid("payment_reference is only valid for a payout"));
            }
            apply_settlement(&tx, site, &settlement, caller, reference.as_deref()).await?;
            settlement.status = APPROVED.to_string();
        } else {
            if reference.is_some() {
                return Err(invalid(
                    "payment_reference is only valid when approving a payout",
                ));
            }
            settlement.status = REJECTED.to_string();
        }
        settlement.decided_by = Some(caller.actor());
        settlement.decided_at = Some(Utc::now());
        settlement.decision_note = decision_note;
        settlement.payment_reference = reference;
        let updated = tx
            .query_one(
                "UPDATE advance_exit_settlements
                    SET status = $3, decided_by = $4, decided_at = $5, decision_note = $6,
                        payment_reference = $7
                  WHERE site_id = $1 AND id = $2
                  RETURNING id, site_id, unit_id, request_key, kind, source_debtor, target_debtor, amount,
                            beneficiary_name, beneficiary_person_id, note, requested_by,
                            status, decided_by, decided_at, decision_note,
                            payment_reference, created_at",
                &[
                    &site,
                    &settlement_id,
                    &settlement.status,
                    &settlement.decided_by,
                    &settlement.decided_at,
                    &settlement.decision_note,
                    &settlement.payment_reference,
                ],
            )
            .await
            .map_err(db_unavailable)?;
        tx.commit().await.map_err(db_unavailable)?;
        Ok(from_row(&updated))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SettlementKind {
    Payout,
    Transfer,
}

impl SettlementKind {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Payout => "PAYOUT",
            Self::Transfer => "TRANSFER",
        }
    }
}

fn parse_kind(raw: &str) -> FinanceResult<SettlementKind> {
    match raw.trim().to_ascii_uppercase().as_str() {
        "PAYOUT" => Ok(SettlementKind::Payout),
        "TRANSFER" => Ok(SettlementKind::Transfer),
        _ => Err(invalid("kind must be PAYOUT or TRANSFER")),
    }
}

fn parse_debtor(raw: &str) -> FinanceResult<&'static str> {
    match raw.trim().to_ascii_uppercase().as_str() {
        OWNER => Ok(OWNER),
        TENANT => Ok(TENANT),
        _ => Err(invalid("debtor must be OWNER or TENANT")),
    }
}

fn parse_id(kind: &str, raw: &str) -> FinanceResult<i64> {
    crate::db::require_id(kind, raw).map_err(invalid)
}

struct ValidatedRequest {
    request_key: String,
    kind: SettlementKind,
    source: &'static str,
    target: Option<&'static str>,
    amount: Decimal,
    beneficiary_name: String,
    beneficiary_person_id: Option<String>,
    note: Option<String>,
}

fn validate_request(req: &CreateAdvanceExitSettlementRequest) -> FinanceResult<ValidatedRequest> {
    let request_key = req.request_key.trim();
    if request_key.is_empty() || request_key.chars().count() > 100 {
        return Err(invalid("request_key must contain 1 to 100 characters"));
    }
    let amount = money(req.amount, "amount")?;
    let kind = parse_kind(&req.kind)?;
    let source = parse_debtor(&req.source_debtor)?;
    let beneficiary_name = req.beneficiary_name.trim();
    if beneficiary_name.is_empty() || beneficiary_name.chars().count() > 200 {
        return Err(invalid("beneficiary_name must contain 1 to 200 characters"));
    }
    let beneficiary_person_id = req
        .beneficiary_person_id
        .as_deref()
        .map(str::trim)
        .filter(|id| !id.is_empty())
        .map(str::to_string);
    let target = match (
        kind,
        req.target_debtor
            .as_deref()
            .map(str::trim)
            .filter(|v| !v.is_empty()),
    ) {
        (SettlementKind::Payout, None) => None,
        (SettlementKind::Payout, Some(_)) => {
            return Err(invalid("target_debtor is only valid for a transfer"));
        }
        (SettlementKind::Transfer, Some(raw)) => {
            let target = parse_debtor(raw)?;
            if source == target {
                return Err(invalid("source_debtor and target_debtor must differ"));
            }
            Some(target)
        }
        (SettlementKind::Transfer, None) => {
            return Err(invalid("target_debtor is required for a transfer"));
        }
    };
    Ok(ValidatedRequest {
        request_key: request_key.to_string(),
        kind,
        source,
        target,
        amount,
        beneficiary_name: beneficiary_name.to_string(),
        beneficiary_person_id,
        note: opt_text(&req.note),
    })
}

async fn find_by_request_key(
    tx: &Transaction<'_>,
    site: i64,
    request_key: &str,
) -> FinanceResult<Option<AdvanceExitSettlement>> {
    tx.query_opt(
        "SELECT id, site_id, unit_id, request_key, kind, source_debtor, target_debtor, amount,
                beneficiary_name, beneficiary_person_id, note, requested_by, status,
                decided_by, decided_at, decision_note, payment_reference, created_at
           FROM advance_exit_settlements WHERE site_id = $1 AND request_key = $2",
        &[&site, &request_key],
    )
    .await
    .map(|row| row.as_ref().map(from_row))
    .map_err(db_unavailable)
}

#[allow(clippy::too_many_arguments)]
fn matches_request(
    existing: &AdvanceExitSettlement,
    unit: i64,
    request_key: &str,
    kind: SettlementKind,
    source: &str,
    target: Option<&str>,
    amount: Decimal,
    beneficiary_name: &str,
    beneficiary_person: Option<i64>,
    note: &Option<String>,
) -> bool {
    crate::db::parse_id_to_i64(&existing.unit_id) == Some(unit)
        && existing.request_key == request_key
        && existing.kind == kind.as_str()
        && existing.source_debtor == source
        && existing.target_debtor.as_deref() == target
        && existing.amount == amount
        && existing.beneficiary_name == beneficiary_name
        && existing.beneficiary_person_id.as_deref()
            == beneficiary_person.map(|id| id.to_string()).as_deref()
        && existing.note == *note
}

fn db_unavailable<E: std::fmt::Display>(error: E) -> FinanceError {
    FinanceError::Unavailable(format!("Database operation failed: {}", error))
}

async fn ensure_unit(tx: &Transaction<'_>, site: i64, unit: i64) -> FinanceResult<()> {
    let exists: bool = tx
        .query_one(
            "SELECT EXISTS(SELECT 1 FROM units WHERE id = $1 AND site_id = $2)",
            &[&unit, &site],
        )
        .await
        .map_err(db_unavailable)?
        .get(0);
    if exists {
        Ok(())
    } else {
        Err(not_found("Unit not found in this site"))
    }
}

async fn ensure_person(
    tx: &Transaction<'_>,
    site: i64,
    unit: i64,
    person: i64,
    source_debtor: &str,
) -> FinanceResult<()> {
    let exists: bool = tx
        .query_one(
            "SELECT EXISTS (
                SELECT 1 FROM persons p
                 WHERE p.id = $1 AND p.site_id = $2
                   AND (
                     ($4 = 'TENANT' AND EXISTS (
                         SELECT 1 FROM unit_occupancies o
                          WHERE o.unit_id = $3 AND o.person_id = p.id AND o.occupancy_type = 'TENANT'
                     )) OR
                     ($4 = 'OWNER' AND (
                         EXISTS (SELECT 1 FROM unit_ownerships o WHERE o.unit_id = $3 AND o.person_id = p.id) OR
                         EXISTS (SELECT 1 FROM unit_occupancies o WHERE o.unit_id = $3 AND o.person_id = p.id AND o.occupancy_type = 'OWNER')
                     ))
                   )
            )",
            &[&person, &site, &unit, &source_debtor],
        )
        .await
        .map_err(db_unavailable)?
        .get(0);
    if exists {
        Ok(())
    } else {
        Err(not_found("Beneficiary person not found in this site"))
    }
}

async fn lock_advance(tx: &Transaction<'_>, unit: i64, debtor: &str) -> FinanceResult<()> {
    tx.execute(
        "INSERT INTO advance_balances (unit_id, debtor_type, balance)
         VALUES ($1, $2, 0) ON CONFLICT (unit_id, debtor_type) DO NOTHING",
        &[&unit, &debtor],
    )
    .await
    .map_err(db_unavailable)?;
    tx.query_one(
        "SELECT balance FROM advance_balances WHERE unit_id = $1 AND debtor_type = $2 FOR UPDATE",
        &[&unit, &debtor],
    )
    .await
    .map_err(db_unavailable)?;
    Ok(())
}

async fn apply_settlement(
    tx: &Transaction<'_>,
    site: i64,
    settlement: &AdvanceExitSettlement,
    caller: &Caller,
    payment_reference: Option<&str>,
) -> FinanceResult<()> {
    let unit = crate::db::require_id("unit", &settlement.unit_id).map_err(invalid)?;
    let source = settlement.source_debtor.as_str();
    let target = settlement.target_debtor.as_deref();
    let mut debtors = vec![source];
    if let Some(target) = target {
        debtors.push(target);
    }
    debtors.sort_unstable();
    debtors.dedup();
    for debtor in debtors {
        lock_advance(tx, unit, debtor).await?;
    }
    let source_updated = tx
        .execute(
            "UPDATE advance_balances SET balance = balance - $3
              WHERE unit_id = $1 AND debtor_type = $2 AND balance >= $3",
            &[&unit, &source, &settlement.amount],
        )
        .await
        .map_err(db_unavailable)?;
    if source_updated != 1 {
        return Err(conflict(format!(
            "The {} advance no longer has ₺{:.2} available",
            source, settlement.amount
        )));
    }
    let reference_id = format!("EXIT-SETTLEMENT-{}", settlement.id);
    let beneficiary_note = format!(" for {}", settlement.beneficiary_name);
    if let Some(target) = target {
        tx.execute(
            "UPDATE advance_balances SET balance = balance + $3
              WHERE unit_id = $1 AND debtor_type = $2",
            &[&unit, &target, &settlement.amount],
        )
        .await
        .map_err(db_unavailable)?;
        insert_ledger_entry(
            tx,
            unit,
            source,
            "EXIT_TRANSFER_DEBIT",
            settlement.amount,
            &reference_id,
            &format!("Approved move-out advance transfer{}", beneficiary_note),
        )
        .await?;
        insert_ledger_entry(
            tx,
            unit,
            target,
            "EXIT_TRANSFER_CREDIT",
            settlement.amount,
            &reference_id,
            &format!("Approved move-out advance transfer{}", beneficiary_note),
        )
        .await?;
    } else {
        let payment_reference = payment_reference
            .ok_or_else(|| invalid("payment_reference is required to approve a payout"))?;
        tx.execute(
            "INSERT INTO advance_exit_disbursements
                (site_id, settlement_id, unit_id, debtor_type, amount, beneficiary_name,
                 beneficiary_person_id, payment_reference, recorded_by)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
            &[
                &site,
                &settlement.id,
                &unit,
                &source,
                &settlement.amount,
                &settlement.beneficiary_name,
                &settlement
                    .beneficiary_person_id
                    .as_deref()
                    .map(|id| parse_id("person", id))
                    .transpose()?,
                &payment_reference,
                &caller.actor(),
            ],
        )
        .await
        .map_err(db_unavailable)?;
        insert_ledger_entry(
            tx,
            unit,
            source,
            "EXIT_PAYOUT_DEBIT",
            settlement.amount,
            &reference_id,
            &format!(
                "Payout for {}: {}",
                settlement.beneficiary_name, payment_reference
            ),
        )
        .await?;
    }
    Ok(())
}

async fn insert_ledger_entry(
    tx: &Transaction<'_>,
    unit: i64,
    debtor: &str,
    entry_type: &str,
    amount: Decimal,
    reference_id: &str,
    description: &str,
) -> FinanceResult<()> {
    tx.execute(
        "INSERT INTO advance_ledger_entries
            (unit_id, debtor_type, entry_type, amount, reference_id, description)
         VALUES ($1, $2, $3, $4, $5, $6)",
        &[
            &unit,
            &debtor,
            &entry_type,
            &amount,
            &reference_id,
            &description,
        ],
    )
    .await
    .map_err(db_unavailable)?;
    Ok(())
}

fn from_row(row: &tokio_postgres::Row) -> AdvanceExitSettlement {
    AdvanceExitSettlement {
        id: row.get(0),
        site_id: row.get::<_, i64>(1).to_string(),
        unit_id: row.get::<_, i64>(2).to_string(),
        request_key: row.get(3),
        kind: row.get(4),
        source_debtor: row.get(5),
        target_debtor: row.get(6),
        amount: row.get(7),
        beneficiary_name: row.get(8),
        beneficiary_person_id: row
            .get::<_, Option<i64>>(9)
            .map(|person_id| person_id.to_string()),
        note: row.get(10),
        requested_by: row.get(11),
        status: row.get(12),
        decided_by: row.get(13),
        decided_at: row.get::<_, Option<DateTime<Utc>>>(14),
        decision_note: row.get(15),
        payment_reference: row.get(16),
        created_at: row.get(17),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(
        kind: &str,
        source: &str,
        target: Option<&str>,
        amount: Decimal,
    ) -> CreateAdvanceExitSettlementRequest {
        CreateAdvanceExitSettlementRequest {
            request_key: "unit-test-key".to_string(),
            kind: kind.to_string(),
            source_debtor: source.to_string(),
            target_debtor: target.map(str::to_string),
            amount,
            beneficiary_name: "Departing Resident".to_string(),
            beneficiary_person_id: None,
            note: None,
        }
    }

    #[test]
    fn settlement_kind_and_debtor_inputs_are_normalized() {
        assert_eq!(parse_kind("payout"), Ok(SettlementKind::Payout));
        assert_eq!(parse_kind("Transfer"), Ok(SettlementKind::Transfer));
        assert_eq!(parse_debtor("tenant"), Ok(TENANT));
        assert_eq!(parse_debtor("OWNER"), Ok(OWNER));
    }

    #[test]
    fn invalid_kind_and_debtor_are_rejected() {
        assert!(parse_kind("REFUND").is_err());
        assert!(parse_debtor("RESIDENT").is_err());
    }

    #[test]
    fn request_rejects_unknown_kind_or_source() {
        assert!(validate_request(&request("REFUND", OWNER, None, Decimal::new(100, 0))).is_err());
        assert!(
            validate_request(&request("PAYOUT", "RESIDENT", None, Decimal::new(100, 0))).is_err()
        );
    }

    #[test]
    fn payout_forbids_target_and_transfer_requires_distinct_target() {
        assert!(validate_request(&request(
            "PAYOUT",
            TENANT,
            Some(OWNER),
            Decimal::new(100, 0)
        ))
        .is_err());
        assert!(
            validate_request(&request("TRANSFER", TENANT, None, Decimal::new(100, 0))).is_err()
        );
        assert!(validate_request(&request(
            "TRANSFER",
            TENANT,
            Some(TENANT),
            Decimal::new(100, 0)
        ))
        .is_err());
        assert!(validate_request(&request(
            "TRANSFER",
            TENANT,
            Some(OWNER),
            Decimal::new(100, 0)
        ))
        .is_ok());
    }

    #[test]
    fn request_requires_positive_amount_with_at_most_two_decimal_places() {
        assert!(validate_request(&request("PAYOUT", TENANT, None, Decimal::ZERO)).is_err());
        assert!(validate_request(&request("PAYOUT", TENANT, None, Decimal::new(-1, 0))).is_err());
        assert!(validate_request(&request("PAYOUT", TENANT, None, Decimal::new(1001, 3))).is_err());
        assert!(validate_request(&request("PAYOUT", TENANT, None, Decimal::new(1001, 2))).is_ok());
    }

    #[test]
    fn request_requires_a_bounded_beneficiary_name() {
        let mut req = request("PAYOUT", TENANT, None, Decimal::new(100, 0));
        req.beneficiary_name = "   ".to_string();
        assert!(validate_request(&req).is_err());
        req.beneficiary_name = "x".repeat(201);
        assert!(validate_request(&req).is_err());
    }

    #[test]
    fn request_requires_a_bounded_idempotency_key() {
        let mut req = request("PAYOUT", TENANT, None, Decimal::new(100, 0));
        req.request_key = "  ".to_string();
        assert!(validate_request(&req).is_err());
        req.request_key = "k".repeat(101);
        assert!(validate_request(&req).is_err());
    }

    #[test]
    fn same_person_cannot_satisfy_the_four_eyes_check() {
        let requester = "user:42 <first@example.test>";
        let same_person = "user:42 <updated@example.test>";
        let checker = "user:43 <checker@example.test>";
        assert!(same_actor(requester, same_person));
        assert!(!same_actor(requester, checker));
    }
}
