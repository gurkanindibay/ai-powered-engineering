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
            .transpose()?
            .ok_or_else(|| invalid("beneficiary_person_id is required for an exit settlement"))?;
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
        ensure_person(&tx, site, unit, beneficiary_person, source).await?;
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
                Some(beneficiary_person),
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
                Some(beneficiary_person),
                &note,
            ) {
                tx.commit().await.map_err(db_unavailable)?;
                return Ok(existing);
            }
            return Err(conflict(
                "request_key was already used for a different settlement",
            ));
        }
        let exit_balance = outstanding_exit_balance(&tx, unit, beneficiary_person, source).await?;
        if exit_balance > Decimal::ZERO {
            return Err(conflict(format!(
                "Cannot request an exit settlement while the departing resident has ₺{:.2} in unpaid exit dues",
                exit_balance
            )));
        }
        let available = claimable_advance(&tx, unit, beneficiary_person, source, None).await?;
        if available < amount {
            return Err(conflict(format!(
                "Available {} advance after pending exit requests is ₺{:.2}; ₺{:.2} was requested",
                source, available, amount
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
                    Some(beneficiary_person),
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
        let settlement = from_row(&row);
        self.state.inner.write().await.reserve_exit_advance(
            &settlement.unit_id,
            source,
            settlement.amount,
        );
        Ok(settlement)
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
            let beneficiary_person = settlement
                .beneficiary_person_id
                .as_deref()
                .ok_or_else(|| invalid("beneficiary_person_id is required for an exit settlement"))
                .and_then(|id| parse_id("person", id))?;
            let exit_balance = outstanding_exit_balance(
                &tx,
                parse_id("unit", &settlement.unit_id)?,
                beneficiary_person,
                &settlement.source_debtor,
            )
            .await?;
            if exit_balance > Decimal::ZERO {
                return Err(conflict(format!(
                    "Cannot approve an exit settlement while the departing resident has ₺{:.2} in unpaid exit dues",
                    exit_balance
                )));
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
        let decided = from_row(&updated);
        let mut inner = self.state.inner.write().await;
        inner.release_exit_advance_reservation(
            &decided.unit_id,
            &decided.source_debtor,
            decided.amount,
        );
        if decided.status == APPROVED {
            let beneficiary = decided
                .beneficiary_person_id
                .as_deref()
                .and_then(crate::db::parse_id_to_i64);
            let mut remaining = decided.amount;
            if let Some(person) = beneficiary {
                let person_id = person.to_string();
                let held =
                    inner.held_advance_of(&decided.unit_id, &person_id, &decided.source_debtor);
                let from_hold = held.min(remaining);
                if from_hold > Decimal::ZERO {
                    inner.hold_advance(
                        &decided.unit_id,
                        &person_id,
                        &decided.source_debtor,
                        -from_hold,
                    );
                    remaining -= from_hold;
                }
            }
            if remaining > Decimal::ZERO {
                inner.adjust_advance(&decided.unit_id, &decided.source_debtor, -remaining);
            }
            if let Some(target) = decided.target_debtor.as_deref() {
                inner.adjust_advance(&decided.unit_id, target, decided.amount);
            }
        }
        Ok(decided)
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
    if beneficiary_person_id.is_none() {
        return Err(invalid(
            "beneficiary_person_id is required for an exit settlement",
        ));
    }
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

async fn outstanding_exit_balance(
    tx: &Transaction<'_>,
    unit: i64,
    person: i64,
    source_debtor: &str,
) -> FinanceResult<Decimal> {
    let balance: Decimal = tx
        .query_one(
            "SELECT COALESCE(SUM(GREATEST(d.principal_amount + d.delay_penalty - d.paid_amount, 0)), 0)::NUMERIC(15,2)
               FROM unit_occupancies o
               JOIN dues_liabilities d ON d.unit_id = o.unit_id
              WHERE o.unit_id = $1 AND o.person_id = $2
                AND o.occupancy_type = $3 AND NOT o.is_active
                AND d.status NOT IN ('PAID', 'CANCELLED')
                AND ($3 = 'OWNER' OR d.expense_type <> 'CAPITAL_DUES')
                AND (d.liable_person_id = o.person_id OR d.occupancy_id = o.id
                     OR (d.liable_person_id IS NULL AND d.occupancy_id IS NULL
                         AND d.debtor_type = $3 AND d.due_date >= o.start_date
                         AND d.due_date <= o.end_date))",
            &[&unit, &person, &source_debtor],
        )
        .await
        .map_err(db_unavailable)?
        .get(0);
    Ok(balance.max(Decimal::ZERO))
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
    let beneficiary_person = settlement
        .beneficiary_person_id
        .as_deref()
        .ok_or_else(|| invalid("beneficiary_person_id is required for an exit settlement"))
        .and_then(|id| parse_id("person", id))?;
    let available =
        claimable_advance(tx, unit, beneficiary_person, source, Some(settlement.id)).await?;
    if available < settlement.amount {
        return Err(conflict(format!(
            "The {} advance has ₺{:.2} available after other pending exit requests",
            source, available
        )));
    }
    // A departing person's own hold is spent before the role bucket, so an
    // approved payout or transfer never reaches money that belongs to someone else.
    let held: Decimal = tx
        .query_opt(
            "SELECT balance FROM person_advance_holds
              WHERE unit_id = $1 AND person_id = $2 AND debtor_type = $3 FOR UPDATE",
            &[&unit, &beneficiary_person, &source],
        )
        .await
        .map_err(db_unavailable)?
        .map(|row| row.get(0))
        .unwrap_or(Decimal::ZERO);
    let from_hold = held.min(settlement.amount);
    if from_hold > Decimal::ZERO {
        let updated = tx
            .execute(
                "UPDATE person_advance_holds
                    SET balance = balance - $4, updated_at = CURRENT_TIMESTAMP
                  WHERE unit_id = $1 AND person_id = $2 AND debtor_type = $3 AND balance >= $4",
                &[&unit, &beneficiary_person, &source, &from_hold],
            )
            .await
            .map_err(db_unavailable)?;
        if updated != 1 {
            return Err(conflict(format!(
                "The {} advance hold no longer has ₺{:.2} available",
                source, from_hold
            )));
        }
    }
    let from_unit = settlement.amount - from_hold;
    if from_unit > Decimal::ZERO {
        let source_updated = tx
            .execute(
                "UPDATE advance_balances SET balance = balance - $3
                  WHERE unit_id = $1 AND debtor_type = $2 AND balance >= $3",
                &[&unit, &source, &from_unit],
            )
            .await
            .map_err(db_unavailable)?;
        if source_updated != 1 {
            return Err(conflict(format!(
                "The {} advance no longer has ₺{:.2} available",
                source, from_unit
            )));
        }
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
        if from_hold > Decimal::ZERO {
            insert_ledger_entry(
                tx,
                unit,
                source,
                Some(beneficiary_person),
                "EXIT_TRANSFER_DEBIT",
                from_hold,
                &reference_id,
                &format!("Approved move-out advance transfer{}", beneficiary_note),
            )
            .await?;
        }
        if from_unit > Decimal::ZERO {
            insert_ledger_entry(
                tx,
                unit,
                source,
                None,
                "EXIT_TRANSFER_DEBIT",
                from_unit,
                &reference_id,
                &format!("Approved move-out advance transfer{}", beneficiary_note),
            )
            .await?;
        }
        insert_ledger_entry(
            tx,
            unit,
            target,
            None,
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
        if from_hold > Decimal::ZERO {
            insert_ledger_entry(
                tx,
                unit,
                source,
                Some(beneficiary_person),
                "EXIT_PAYOUT_DEBIT",
                from_hold,
                &reference_id,
                &format!(
                    "Payout for {}: {}",
                    settlement.beneficiary_name, payment_reference
                ),
            )
            .await?;
        }
        if from_unit > Decimal::ZERO {
            insert_ledger_entry(
                tx,
                unit,
                source,
                None,
                "EXIT_PAYOUT_DEBIT",
                from_unit,
                &reference_id,
                &format!(
                    "Payout for {}: {}",
                    settlement.beneficiary_name, payment_reference
                ),
            )
            .await?;
        }
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
async fn insert_ledger_entry(
    tx: &Transaction<'_>,
    unit: i64,
    debtor: &str,
    person: Option<i64>,
    entry_type: &str,
    amount: Decimal,
    reference_id: &str,
    description: &str,
) -> FinanceResult<()> {
    tx.execute(
        "INSERT INTO advance_ledger_entries
            (unit_id, debtor_type, person_id, entry_type, amount, reference_id, description)
         VALUES ($1, $2, $3, $4, $5, $6, $7)",
        &[
            &unit,
            &debtor,
            &person,
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

/// Advance one person can still claim from a unit after other pending exit
/// requests: their own person-scoped hold, plus the unit's role bucket while
/// they hold that role. Pending requests are allocated hold first, then the
/// shared role bucket, so two beneficiaries never both count the same money.
/// A tenant's advance stays in the role bucket until it is settled, so the
/// bucket remains claimable for a departing tenant (a payout or transfer is the
/// only way it leaves); an owner's role bucket belongs to the current owner.
async fn claimable_advance(
    tx: &Transaction<'_>,
    unit: i64,
    person: i64,
    debtor: &str,
    exclude_settlement: Option<i64>,
) -> FinanceResult<Decimal> {
    let holds: Vec<(i64, Decimal)> = tx
        .query(
            "SELECT person_id, balance FROM person_advance_holds
              WHERE unit_id = $1 AND debtor_type = $2",
            &[&unit, &debtor],
        )
        .await
        .map_err(db_unavailable)?
        .iter()
        .map(|row| (row.get(0), row.get(1)))
        .collect();

    let holds_role: bool = tx
        .query_one(
            "SELECT (EXISTS (SELECT 1 FROM units u
                              WHERE u.id = $1
                                AND (($3 = 'OWNER' AND u.owner_person_id = $2)
                                  OR ($3 = 'TENANT' AND u.tenant_person_id = $2))))
                 OR EXISTS (SELECT 1 FROM unit_ownerships o
                             WHERE o.unit_id = $1 AND o.person_id = $2
                               AND o.is_active AND $3 = 'OWNER')
                 OR EXISTS (SELECT 1 FROM unit_occupancies o
                             WHERE o.unit_id = $1 AND o.person_id = $2
                               AND o.is_active AND o.occupancy_type = $3)",
            &[&unit, &person, &debtor],
        )
        .await
        .map_err(db_unavailable)?
        .get(0);
    let bucket_accessible = holds_role || !debtor.eq_ignore_ascii_case("OWNER");

    let pending_rows = tx
        .query(
            "SELECT beneficiary_person_id, amount FROM advance_exit_settlements
              WHERE unit_id = $1 AND source_debtor = $2 AND status = 'PENDING'
                AND ($3::bigint IS NULL OR id <> $3)",
            &[&unit, &debtor, &exclude_settlement],
        )
        .await
        .map_err(db_unavailable)?;
    // Allocate each pending request hold first, reducing that person's remaining
    // hold as we go, so several requests from one holder cannot each count the
    // whole hold against the shared bucket.
    let mut remaining_holds: std::collections::HashMap<i64, Decimal> =
        holds.iter().copied().collect();
    let mut bucket_committed = Decimal::ZERO;
    for row in pending_rows {
        let beneficiary: Option<i64> = row.get(0);
        let amount: Decimal = row.get(1);
        let from_hold = beneficiary
            .and_then(|id| remaining_holds.get_mut(&id))
            .map(|balance| {
                let from_hold = (*balance).min(amount);
                *balance -= from_hold;
                from_hold
            })
            .unwrap_or(Decimal::ZERO);
        bucket_committed += amount - from_hold;
    }

    let held_available = remaining_holds
        .get(&person)
        .copied()
        .unwrap_or(Decimal::ZERO)
        .max(Decimal::ZERO);
    if !bucket_accessible {
        return Ok(held_available);
    }
    let bucket: Decimal = tx
        .query_opt(
            "SELECT balance FROM advance_balances WHERE unit_id = $1 AND debtor_type = $2",
            &[&unit, &debtor],
        )
        .await
        .map_err(db_unavailable)?
        .map(|row| row.get(0))
        .unwrap_or(Decimal::ZERO);
    Ok(held_available + (bucket - bucket_committed).max(Decimal::ZERO))
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
            beneficiary_person_id: Some("1".to_string()),
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
    fn request_requires_departing_beneficiary_identity() {
        let mut req = request("PAYOUT", TENANT, None, Decimal::new(100, 2));
        req.beneficiary_person_id = None;
        assert!(validate_request(&req).is_err());
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
