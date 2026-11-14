use chrono::{DateTime, NaiveDate, Utc};
use rust_decimal::Decimal;

use crate::models::{
    AllocationBreakdownItem, AuthProvider, DebtAgingBracket, DebtAgingReport, DebtStatus,
    DebtorType, DuesLiability, ExpenseType, InterLedgerTransferRequest,
    InterLedgerTransferResponse, OccupancyHistoryItem, PaymentChannel, PaymentEntry,
    PaymentMatchStatus, PaymentReceipt, PaymentStreamFilter, PaymentStreamResponse,
    RecordManualPaymentRequest, ReversePaymentRequest, ReversePaymentResponse, Role,
    SettlementStatus, TransferOwnershipRequest, TransferOwnershipResponse, User,
    LEDGER_KIND_COLLECTION, LEDGER_KIND_REVERSAL,
};
use crate::services::dues_ledger;
use crate::state::AppState;

/// A ledger read that could not be served from PostgreSQL. It is surfaced
/// (503) rather than replaced by an empty or cached result, which would read as
/// "no money received" or "no debt".
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum LedgerReadError {
    #[error("ledger unavailable: {0}")]
    Unavailable(String),
}

pub struct PaymentTrackingService {
    pub state: AppState,
}

impl PaymentTrackingService {
    pub fn new(state: AppState) -> Self {
        Self { state }
    }

    /// Generates canonical SHA-256 verification hash for tamper-proof digital receipts
    pub fn compute_verification_hash(
        receipt_number: &str,
        unit_id: &str,
        total_amount: Decimal,
        issued_at: &DateTime<Utc>,
    ) -> String {
        // Persisted contract: see `crate::domain::fingerprint::receipt_canonical_v1`.
        crate::domain::fingerprint::receipt_hash_v1(&crate::domain::fingerprint::ReceiptFields {
            receipt_number,
            unit_id,
            total_amount,
            issued_at,
        })
    }

    /// SPEC-009 R15: the v2 hash of an issued receipt, which also covers the payer
    /// and the allocation lines. New receipts carry it; v1 receipts keep theirs.
    pub fn compute_verification_hash_v2(receipt: &PaymentReceipt) -> String {
        use crate::domain::fingerprint::{
            receipt_hash_v2, AllocationLine, ReceiptFields, ReceiptFieldsV2,
        };
        let lines: Vec<AllocationLine<'_>> = receipt
            .allocation_breakdown
            .iter()
            .map(|b| AllocationLine {
                due_id: b.due_id.as_deref().unwrap_or(&b.period),
                principal: b.principal_paid,
                penalty: b.penalty_paid,
            })
            .collect();
        receipt_hash_v2(&ReceiptFieldsV2 {
            base: ReceiptFields {
                receipt_number: &receipt.receipt_number,
                unit_id: &receipt.unit_id,
                total_amount: receipt.total_amount,
                issued_at: &receipt.issued_at,
            },
            payer_name: &receipt.payer_name,
            payer_role: receipt.payer_role.as_str(),
            allocations: &lines,
        })
    }

    /// Detects capital expenditure keyword intent in transaction description
    pub fn is_capital_expenditure_intent(desc: &str) -> bool {
        let upper = desc.to_uppercase();
        upper.contains("DEMİRBAŞ")
            || upper.contains("DEMIRBAS")
            || upper.contains("ASANSÖR")
            || upper.contains("ASANSOR")
            || upper.contains("ÇATI")
            || upper.contains("CATI")
            || upper.contains("YALITIM")
            || upper.contains("KAZAN")
            || upper.contains("MANTOLAMA")
            || upper.contains("ISI PAY")
    }

    /// Next sequential receipt number for a given site (e.g., #TAH-2026-000001)
    pub async fn next_receipt_number(&self, site_id: &str) -> (String, i64) {
        let year = Utc::now().format("%Y").to_string();
        if let Some(ref pool) = self.state.pool {
            if let Ok(next_seq) = crate::db::get_next_receipt_sequence(pool, site_id).await {
                let receipt_no = format!("TAH-{}-{:06}", year, next_seq);
                return (receipt_no, next_seq);
            }
        }
        let inner = self.state.inner.read().await;
        let max_seq = inner
            .payment_receipts
            .iter()
            .filter(|r| r.site_id == site_id && r.receipt_type == LEDGER_KIND_COLLECTION)
            .map(|r| r.sequence_number)
            .max()
            .unwrap_or(0);
        let next_seq = max_seq + 1;
        let receipt_no = format!("TAH-{}-{:06}", year, next_seq);
        (receipt_no, next_seq)
    }

    /// Query multi-channel payment stream with rich multi-criteria filters
    /// A database error is returned, never replaced by an empty list: an empty
    /// payment stream would read as "no money received".
    pub async fn get_payment_stream(
        &self,
        filter: PaymentStreamFilter,
    ) -> Result<PaymentStreamResponse, LedgerReadError> {
        let target_site = filter.site_id.unwrap_or_default();

        let all_entries = if let Some(p) = self.state.db_pool() {
            crate::db::fetch_payment_entries_from_db(p, Some(&target_site))
                .await
                .map_err(|e| LedgerReadError::Unavailable(format!("payment stream: {}", e)))?
        } else {
            let inner = self.state.inner.read().await;
            let mut entries = inner.payment_entries.clone();
            if entries.is_empty() {
                // Synthesize from existing homeowner payments and mock entries in memory mode
                for hp in &inner.homeowner_payments {
                    let unit_label = inner.unit_label(&hp.block_id, hp.unit_number);
                    let settlement_status = match hp.status {
                        PaymentMatchStatus::MatchedDebt
                        | PaymentMatchStatus::MatchedAdvance
                        | PaymentMatchStatus::PartiallyMatched => SettlementStatus::Settled,
                        PaymentMatchStatus::Pending => SettlementStatus::Unmatched,
                    };
                    entries.push(PaymentEntry {
                        id: crate::db::parse_id_to_i64(&hp.id).unwrap_or(0),
                        site_id: target_site.clone(),
                        unit_id: hp.unit_id.clone(),
                        unit_label: Some(unit_label),
                        payer_name: hp
                            .homeowner_name
                            .clone()
                            .unwrap_or_else(|| "Bilinmeyen Sakin".to_string()),
                        payer_role: DebtorType::Owner,
                        receipt_id: None,
                        receipt_number: hp
                            .reference_code
                            .clone()
                            .or_else(|| Some(format!("REC-{}", hp.id))),
                        amount: hp.amount,
                        payment_channel: hp.payment_method,
                        settlement_status,
                        description: hp.note.clone(),
                        external_reference: hp.reference_code.clone(),
                        payment_date: hp.created_at,
                        created_at: hp.created_at,
                        entry_type: LEDGER_KIND_COLLECTION.to_string(),
                        reverses_entry_id: None,
                        reversal_reason: None,
                        recorded_by: None,
                    });
                }
            }
            entries
        };

        // Apply filters
        let search_term = filter.search.as_ref().map(|s| s.to_lowercase());
        let filtered: Vec<PaymentEntry> = all_entries
            .into_iter()
            .filter(|e| {
                if !target_site.is_empty() && e.site_id != target_site && target_site != "all" {
                    return false;
                }
                if let Some(ch) = filter.channel {
                    if e.payment_channel != ch {
                        return false;
                    }
                }
                if let Some(role) = filter.payer_role {
                    if e.payer_role != role {
                        return false;
                    }
                }
                if let Some(status) = filter.settlement_status {
                    if e.settlement_status != status {
                        return false;
                    }
                }
                if let Some(ref uid) = filter.unit_id {
                    if !uid.is_empty() && &e.unit_id != uid {
                        return false;
                    }
                }
                if let Some(start) = filter.start_date {
                    if e.payment_date.date_naive() < start {
                        return false;
                    }
                }
                if let Some(end) = filter.end_date {
                    if e.payment_date.date_naive() > end {
                        return false;
                    }
                }
                if let Some(ref kw) = search_term {
                    let matches_name = e.payer_name.to_lowercase().contains(kw);
                    let matches_unit = e
                        .unit_label
                        .as_ref()
                        .map(|l| l.to_lowercase().contains(kw))
                        .unwrap_or(false);
                    let matches_desc = e
                        .description
                        .as_ref()
                        .map(|d| d.to_lowercase().contains(kw))
                        .unwrap_or(false);
                    let matches_rcp = e
                        .receipt_number
                        .as_ref()
                        .map(|r| r.to_lowercase().contains(kw))
                        .unwrap_or(false);
                    let matches_ref = e
                        .external_reference
                        .as_ref()
                        .map(|r| r.to_lowercase().contains(kw))
                        .unwrap_or(false);
                    if !(matches_name || matches_unit || matches_desc || matches_rcp || matches_ref)
                    {
                        return false;
                    }
                }
                true
            })
            .collect();

        let total_count = filtered.len();
        // A reversed payment and its contra entry (both REVERSED) cancel out.
        let total_volume: Decimal = filtered
            .iter()
            .filter(|e| e.settlement_status != SettlementStatus::Reversed)
            .map(|e| e.amount)
            .sum();
        let settled_volume: Decimal = filtered
            .iter()
            .filter(|e| e.settlement_status == SettlementStatus::Settled)
            .map(|e| e.amount)
            .sum();
        let unmatched_volume: Decimal = filtered
            .iter()
            .filter(|e| e.settlement_status == SettlementStatus::Unmatched)
            .map(|e| e.amount)
            .sum();

        let paged_entries = if let (Some(page), Some(page_size)) = (filter.page, filter.page_size) {
            let skip = page.saturating_sub(1) * page_size;
            filtered.into_iter().skip(skip).take(page_size).collect()
        } else if let Some(limit) = filter.limit {
            let offset = filter.offset.unwrap_or(0);
            filtered.into_iter().skip(offset).take(limit).collect()
        } else {
            filtered
        };

        Ok(PaymentStreamResponse {
            entries: paged_entries,
            total_volume,
            settled_volume,
            unmatched_volume,
            total_count,
        })
    }

    /// Calculate debt aging report grouped by brackets: current, 1-30, 31-60, 60+ days
    /// With PostgreSQL the report comes from the database only; an error is
    /// returned rather than silently falling back to the in-memory copy.
    pub async fn get_debt_aging_report(
        &self,
        site_id: &str,
    ) -> Result<DebtAgingReport, LedgerReadError> {
        if let Some(p) = self.state.db_pool() {
            return crate::db::dues_repository::fetch_debt_aging_report_from_db(p, site_id)
                .await
                .map_err(|e| LedgerReadError::Unavailable(format!("debt aging report: {}", e)));
        }
        let inner = self.state.inner.read().await;
        let today = Utc::now().date_naive();

        let mut brackets_map: std::collections::HashMap<(String, DebtorType), DebtAgingBracket> =
            std::collections::HashMap::new();
        let calc = crate::services::DuesCalculationService::new();

        for stored in &inner.dues {
            if stored.status == DebtStatus::Paid {
                continue;
            }
            // Figures as of today: penalty accrued to date, amounts still unpaid.
            let due = calc.calculate_delay_penalty(stored.clone(), today);
            let due = &due;

            // Locate unit
            let unit = match inner.units.iter().find(|u| u.id == due.unit_id) {
                Some(u) => u,
                None => continue,
            };

            if unit.site_id != site_id && site_id != "all" {
                continue;
            }

            // The debtor is the liability's own (SPEC-005 R5), not the unit's current occupant.
            let debtor_type = due.debtor_type;

            let tenant_id = unit
                .tenant_user_id
                .as_ref()
                .filter(|_| debtor_type == DebtorType::Tenant);
            let resident_name = if let Some(tid) = tenant_id {
                inner
                    .users
                    .iter()
                    .find(|u| &u.id == tid)
                    .map(|u| u.full_name.clone())
                    .unwrap_or_else(|| "Kiracı".to_string())
            } else if let Some(ref oid) = unit.owner_user_id {
                inner
                    .users
                    .iter()
                    .find(|u| &u.id == oid)
                    .map(|u| u.full_name.clone())
                    .unwrap_or_else(|| "Kat Maliki".to_string())
            } else {
                "Daire Sakini".to_string()
            };

            let unit_label = inner.unit_label(&unit.block_id, unit.unit_number);
            let key = (unit.id.clone(), debtor_type);

            let bracket = brackets_map.entry(key).or_insert_with(|| DebtAgingBracket {
                unit_id: unit.id.clone(),
                unit_label,
                resident_name,
                debtor_type,
                current_due: Decimal::ZERO,
                overdue_1_30_days: Decimal::ZERO,
                overdue_31_60_days: Decimal::ZERO,
                overdue_60_plus_days: Decimal::ZERO,
                accrued_delay_penalty: Decimal::ZERO,
                total_outstanding: Decimal::ZERO,
            });

            let principal_remaining = dues_ledger::outstanding_principal(due);
            let penalty = dues_ledger::outstanding_penalty(due);
            bracket.accrued_delay_penalty += penalty;

            let days_overdue = (today - due.due_date).num_days();

            if days_overdue <= 0 {
                bracket.current_due += principal_remaining;
            } else if days_overdue <= 30 {
                bracket.overdue_1_30_days += principal_remaining;
            } else if days_overdue <= 60 {
                bracket.overdue_31_60_days += principal_remaining;
            } else {
                bracket.overdue_60_plus_days += principal_remaining;
            }

            bracket.total_outstanding += principal_remaining + penalty;
        }

        let mut brackets: Vec<DebtAgingBracket> = brackets_map.into_values().collect();
        brackets.sort_by_key(|b| std::cmp::Reverse(b.total_outstanding));

        let total_current: Decimal = brackets.iter().map(|b| b.current_due).sum();
        let total_1_30_days: Decimal = brackets.iter().map(|b| b.overdue_1_30_days).sum();
        let total_31_60_days: Decimal = brackets.iter().map(|b| b.overdue_31_60_days).sum();
        let total_60_plus_days: Decimal = brackets.iter().map(|b| b.overdue_60_plus_days).sum();
        let total_penalty: Decimal = brackets.iter().map(|b| b.accrued_delay_penalty).sum();
        let grand_total: Decimal = brackets.iter().map(|b| b.total_outstanding).sum();

        Ok(DebtAgingReport {
            as_of_date: today,
            total_current,
            total_1_30_days,
            total_31_60_days,
            total_60_plus_days,
            total_penalty,
            grand_total,
            brackets,
        })
    }

    /// The single ingestion path for every payment channel (SPEC-005 R1).
    ///
    /// Allocation: the payer's designated liabilities first (TBK 101), each with
    /// the TBK 100 waterfall (penalty, then principal); then the payer's other
    /// open liabilities oldest first (TBK 102); the surplus goes to the advance
    /// ledger of the settling debtor. Penalties are brought up to the payment
    /// date first (KMK 20 segmented accrual).
    ///
    /// With PostgreSQL the whole payment is one transaction: the unit and its open
    /// liabilities are locked (`FOR UPDATE`), the receipt number comes from the
    /// per-site counter row, and receipt, entry, allocations, liability updates,
    /// advance credit and idempotency key commit together. In-memory state is
    /// updated only after the commit, from the committed values. Any failure is
    /// returned to the caller and nothing is applied. A retry with the same
    /// idempotency key returns the first receipt.
    pub async fn record_and_allocate_payment(
        &self,
        req: RecordManualPaymentRequest,
    ) -> Result<PaymentReceipt, String> {
        let site_id = req
            .site_id
            .clone()
            .filter(|s| !s.trim().is_empty())
            .ok_or_else(|| "site_id is required".to_string())?;
        let unit_id = req.unit_id.clone();
        let payment_amount = req.amount;
        let issued_at = req.payment_date.unwrap_or_else(Utc::now);
        if payment_amount <= Decimal::ZERO {
            return Err("Ödeme tutarı 0.00'dan büyük olmalıdır".to_string());
        }
        if payment_amount.scale() > 2 {
            return Err("Payment amount must have at most 2 decimal places".to_string());
        }
        let payer_role = req.payer_role;
        let idempotency_key = req
            .idempotency_key
            .as_deref()
            .map(str::trim)
            .filter(|k| !k.is_empty())
            .map(str::to_string);
        let unmatched_entry = req
            .settles_unmatched_entry_id
            .as_deref()
            .map(str::trim)
            .filter(|k| !k.is_empty())
            .map(str::to_string);
        let designation = req.designation.clone().filter(|d| !d.is_empty());
        let description_hint = if designation.is_none() && req.designate_from_description {
            req.description.clone()
        } else {
            None
        };

        let desc = req.description.clone().unwrap_or_default();
        // A tenant paying capital dues explicitly does so on behalf of the owner
        // (KMK 22 rent offset); otherwise a tenant only settles tenant liabilities.
        let on_behalf_of_owner =
            payer_role == DebtorType::Tenant && Self::is_capital_expenditure_intent(&desc);
        let settling_role = if on_behalf_of_owner {
            DebtorType::Owner
        } else {
            payer_role
        };
        let credit_debtor = settling_role.as_str().to_string();
        let allocate = |dues: &mut Vec<DuesLiability>| {
            let candidates = dues_ledger::open_dues_for(dues, |_| true, settling_role.as_str());
            let designated = dues_ledger::designated_dues(
                dues,
                &candidates,
                designation.as_ref(),
                description_hint.as_deref(),
            );
            let (lines, surplus) = dues_ledger::allocate_with_designation(
                dues,
                &candidates,
                &designated,
                payment_amount,
            );
            (lines, surplus, !designated.is_empty())
        };

        let (unit, owner_name) = {
            let inner = self.state.inner.read().await;
            if let Some(key) = idempotency_key.as_deref() {
                if let Some(rid) = inner
                    .payment_idempotency
                    .get(&idempotency_slot(&site_id, key))
                {
                    if let Some(existing) = inner.payment_receipts.iter().find(|r| r.id == *rid) {
                        return Ok(existing.clone());
                    }
                }
            }
            let unit = inner
                .units
                .iter()
                .find(|u| {
                    crate::auth::same_id(&u.id, &unit_id)
                        && crate::auth::same_id(&u.site_id, &site_id)
                })
                .cloned()
                .ok_or_else(|| format!("Daire bulunamadı: {}", unit_id))?;
            let owner_name = unit.owner_user_id.as_ref().and_then(|oid| {
                inner
                    .users
                    .iter()
                    .find(|u| &u.id == oid)
                    .map(|u| u.full_name.clone())
            });
            (unit, owner_name)
        };

        let calc = crate::services::DuesCalculationService::new();
        let today = issued_at.date_naive();
        let ctx = ReceiptContext {
            site_id: site_id.clone(),
            unit_id: unit.id.clone(),
            unit_label: self
                .state
                .inner
                .read()
                .await
                .unit_label(&unit.block_id, unit.unit_number),
            payer_name: req.payer_name.clone(),
            payer_role,
            payment_channel: req.payment_channel,
            amount: payment_amount,
            issued_at,
            on_behalf_of_owner,
            owner_name,
            // O-4: the channel's own reference only; idempotency keys live in
            // payment_idempotency_keys (and AppStateInner.payment_idempotency).
            channel_reference: req
                .external_reference
                .clone()
                .filter(|r| !r.trim().is_empty()),
            description: None,
            external_reference: req
                .external_reference
                .clone()
                .filter(|r| !r.trim().is_empty()),
            advance_debtor: credit_debtor.clone(),
        };

        let (receipt, settled_dues, mut entry) = if let Some(ref pool) = self.state.pool {
            let site_num = crate::db::require_id("site", &site_id)?;
            let unit_num = crate::db::require_id("unit", &unit.id)?;
            let mut client = pool
                .get()
                .await
                .map_err(|e| format!("Database unavailable: {}", e))?;
            let tx = client
                .transaction()
                .await
                .map_err(|e| format!("Database unavailable: {}", e))?;
            let db_err = |e: Box<dyn std::error::Error + Send + Sync>| {
                format!(
                    "Payment was not recorded: {}",
                    crate::db::describe_db_error(e.as_ref())
                )
            };
            // Tenant guardrail: from here on PostgreSQL row-level security
            // hides every other site's rows (V21).
            crate::db::tx_bind_tenant(&tx, site_num)
                .await
                .map_err(db_err)?;

            if let Some(key) = idempotency_key.as_deref() {
                if let Some(rid) = crate::db::tx_find_idempotent_receipt(&tx, site_num, key)
                    .await
                    .map_err(db_err)?
                {
                    drop(tx);
                    return crate::db::get_payment_receipt_by_id(pool, rid)
                        .await
                        .map_err(db_err)?
                        .ok_or_else(|| "Idempotent receipt not found".to_string());
                }
            }
            if !crate::db::tx_lock_unit(&tx, unit_num, site_num)
                .await
                .map_err(db_err)?
            {
                return Err(format!("Daire bulunamadı: {}", unit_id));
            }
            let mut dues: Vec<DuesLiability> = crate::db::tx_load_open_dues(&tx, unit_num)
                .await
                .map_err(db_err)?
                .into_iter()
                .map(|d| calc.calculate_delay_penalty(d, today))
                .collect();
            let (lines, surplus, designated_any) = allocate(&mut dues);

            let sequence =
                crate::db::tx_next_receipt_sequence(&tx, site_num, LEDGER_KIND_COLLECTION)
                    .await
                    .map_err(db_err)?;
            let mut receipt = build_receipt(&ctx, &dues, &lines, surplus, sequence);
            crate::db::tx_insert_receipt(&tx, &mut receipt, site_num, unit_num)
                .await
                .map_err(db_err)?;
            let mut entry = build_entry(&ctx, &receipt);
            entry.description = entry_description(
                req.description.as_deref(),
                designation.as_ref(),
                designated_any,
            );
            entry.id = match unmatched_entry.as_deref() {
                Some(uid) => {
                    let entry_num = crate::db::require_id("payment entry", uid)?;
                    crate::db::tx_claim_unmatched_entry(&tx, entry_num, site_num, unit_num, payment_amount, receipt.id)
                        .await
                        .map_err(db_err)?
                        .ok_or_else(|| format!("Payment entry {} is not an open UNMATCHED entry of ₺{:.2} for this unit", uid, payment_amount))?
                }
                None => crate::db::tx_insert_entry(&tx, &entry, site_num, unit_num)
                    .await
                    .map_err(db_err)?,
            };
            for line in &lines {
                let d = &dues[line.due_index];
                crate::db::tx_settle_due(
                    &tx,
                    entry.id,
                    d,
                    line.settlement.principal,
                    line.settlement.penalty,
                )
                .await
                .map_err(db_err)?;
            }
            if surplus > Decimal::ZERO {
                crate::db::tx_credit_advance(
                    &tx,
                    unit_num,
                    &credit_debtor,
                    "PAYMENT_SURPLUS",
                    surplus,
                    Some(&receipt.receipt_number),
                    Some("Fazla ödeme avans bakiyesine aktarıldı"),
                )
                .await
                .map_err(db_err)?;
            }
            if let Some(key) = idempotency_key.as_deref() {
                crate::db::tx_store_idempotency_key(&tx, site_num, key, receipt.id)
                    .await
                    .map_err(db_err)?;
            }
            tx.commit()
                .await
                .map_err(|e| format!("Payment was not recorded: {}", e))?;
            let touched: Vec<DuesLiability> =
                lines.iter().map(|l| dues[l.due_index].clone()).collect();
            (receipt, touched, entry)
        } else {
            // No database (tests / demo): same allocation on the in-memory ledger.
            let inner = self.state.inner.read().await;
            if let Some(uid) = unmatched_entry.as_deref() {
                let open = inner.homeowner_payments.iter().any(|h| {
                    h.id == uid
                        && h.status == PaymentMatchStatus::Pending
                        && h.amount == payment_amount
                        && crate::auth::same_id(&h.unit_id, &unit.id)
                });
                if !open {
                    return Err(format!(
                        "Payment entry {} is not an open UNMATCHED entry of ₺{:.2} for this unit",
                        uid, payment_amount
                    ));
                }
            }
            let mut dues: Vec<DuesLiability> = inner
                .dues
                .iter()
                .filter(|d| {
                    d.status != DebtStatus::Paid && crate::auth::same_id(&d.unit_id, &unit.id)
                })
                .cloned()
                .map(|d| calc.calculate_delay_penalty(d, today))
                .collect();
            let next_seq = next_memory_sequence(&inner, &site_id, LEDGER_KIND_COLLECTION);
            let next_receipt_id = inner
                .payment_receipts
                .iter()
                .map(|r| r.id)
                .max()
                .unwrap_or(0)
                + 1;
            let next_entry_id = inner
                .payment_entries
                .iter()
                .map(|e| e.id)
                .max()
                .unwrap_or(0)
                + 1;
            let issuer = Issuer::of(&inner, &site_id);
            drop(inner);
            let (lines, surplus, designated_any) = allocate(&mut dues);
            let mut receipt = build_receipt(&ctx, &dues, &lines, surplus, next_seq);
            receipt.id = next_receipt_id;
            issuer.apply(&mut receipt);
            let mut entry = build_entry(&ctx, &receipt);
            entry.id = unmatched_entry
                .as_deref()
                .and_then(crate::db::parse_id_to_i64)
                .unwrap_or(next_entry_id);
            entry.description = entry_description(
                req.description.as_deref(),
                designation.as_ref(),
                designated_any,
            );
            let touched: Vec<DuesLiability> =
                lines.iter().map(|l| dues[l.due_index].clone()).collect();
            (receipt, touched, entry)
        };

        // Apply the committed result to the in-memory view.
        let mut inner = self.state.inner.write().await;
        for settled in &settled_dues {
            if let Some(d) = inner
                .dues
                .iter_mut()
                .find(|d| crate::auth::same_id(&d.id, &settled.id))
            {
                let unit_key = d.unit_id.clone();
                *d = settled.clone();
                d.unit_id = unit_key;
            }
        }
        if receipt.allocated_advance > Decimal::ZERO {
            inner.adjust_advance(&unit.id, &credit_debtor, receipt.allocated_advance);
        }
        if let Some(key) = idempotency_key.as_deref() {
            inner
                .payment_idempotency
                .insert(idempotency_slot(&site_id, key), receipt.id);
        }
        let cleared = receipt.allocated_principal + receipt.allocated_penalty;
        let match_status = if cleared > Decimal::ZERO && receipt.allocated_advance > Decimal::ZERO {
            PaymentMatchStatus::PartiallyMatched
        } else if cleared > Decimal::ZERO {
            PaymentMatchStatus::MatchedDebt
        } else {
            PaymentMatchStatus::MatchedAdvance
        };
        inner.payment_receipts.push(receipt.clone());
        let homeowner_id = match unmatched_entry.as_deref() {
            Some(uid) => uid.to_string(),
            None => format!("rec-{}", receipt.id),
        };
        if let Some(existing) = inner
            .payment_entries
            .iter_mut()
            .find(|e| unmatched_entry.is_some() && e.id == entry.id)
        {
            existing.settlement_status = SettlementStatus::Settled;
            existing.receipt_id = entry.receipt_id;
            existing.receipt_number = entry.receipt_number.clone();
        } else {
            if unmatched_entry.is_some() {
                // The pending row lives only in the legacy homeowner view.
                entry.external_reference = entry
                    .external_reference
                    .clone()
                    .or_else(|| Some(homeowner_id.clone()));
            }
            inner.payment_entries.push(entry);
        }
        if let Some(h) = inner
            .homeowner_payments
            .iter_mut()
            .find(|h| h.id == homeowner_id)
        {
            h.status = match_status;
            h.cleared_debt_amount = cleared;
            h.advance_credit_amount = receipt.allocated_advance;
            h.reference_code = h
                .reference_code
                .clone()
                .or_else(|| Some(receipt.receipt_number.clone()));
        } else {
            inner
                .homeowner_payments
                .push(crate::models::HomeownerPaymentRecord {
                    id: homeowner_id,
                    unit_id: unit.id.clone(),
                    block_id: unit.block_id.clone(),
                    unit_number: unit.unit_number,
                    homeowner_name: Some(req.payer_name.clone()),
                    amount: payment_amount,
                    payment_method: req.payment_channel,
                    reference_code: Some(receipt.receipt_number.clone()),
                    note: req.description.clone(),
                    status: match_status,
                    cleared_debt_amount: cleared,
                    advance_credit_amount: receipt.allocated_advance,
                    created_at: issued_at,
                });
        }
        Ok(receipt)
    }

    /// Inter-ledger transfer (virman): moves advance balance onto open liabilities.
    ///
    /// `source_debtor` is whose advance is debited and `target_debtor` whose
    /// liabilities are settled (both default to OWNER). TENANT -> OWNER is the
    /// EPIC-09 §2.3 flow: the tenant's surplus pays the owner's capital dues on the
    /// owner's behalf (KMK 22 / TBK 314 rent offset). Only the amount that actually
    /// clears debt leaves the advance; with PostgreSQL the transfer is one
    /// transaction (O-1).
    pub async fn inter_ledger_transfer(
        &self,
        req: InterLedgerTransferRequest,
    ) -> Result<InterLedgerTransferResponse, String> {
        let site_id = req
            .site_id
            .clone()
            .filter(|s| !s.trim().is_empty())
            .ok_or_else(|| "site_id is required".to_string())?;
        let unit_id = req.unit_id.clone();
        let transfer_amount = req.amount;
        if transfer_amount <= Decimal::ZERO || transfer_amount.scale() > 2 {
            return Err("Virman tutarı 0.00'dan büyük olmalıdır".to_string());
        }
        let source = normalize_debtor(req.source_debtor.as_deref(), "source_debtor")?;
        let target = normalize_debtor(req.target_debtor.as_deref(), "target_debtor")?;

        let (unit, owner_name, tenant_name) = {
            let inner = self.state.inner.read().await;
            let unit = inner
                .units
                .iter()
                .find(|u| {
                    crate::auth::same_id(&u.id, &unit_id)
                        && crate::auth::same_id(&u.site_id, &site_id)
                })
                .cloned()
                .ok_or_else(|| format!("Daire bulunamadı: {}", unit_id))?;
            let name_of = |uid: &Option<String>| {
                uid.as_ref()
                    .and_then(|id| inner.users.iter().find(|u| &u.id == id))
                    .map(|u| u.full_name.clone())
            };
            (
                unit.clone(),
                name_of(&unit.owner_user_id),
                name_of(&unit.tenant_user_id),
            )
        };
        let payer_name = if source == dues_ledger::DEBTOR_OWNER {
            owner_name
                .clone()
                .unwrap_or_else(|| "Kat Maliki".to_string())
        } else {
            tenant_name.unwrap_or_else(|| "Kiracı".to_string())
        };
        let now = Utc::now();
        let calc = crate::services::DuesCalculationService::new();
        let ctx = ReceiptContext {
            site_id: site_id.clone(),
            unit_id: unit.id.clone(),
            unit_label: self
                .state
                .inner
                .read()
                .await
                .unit_label(&unit.block_id, unit.unit_number),
            payer_name,
            payer_role: DebtorType::from_str_loose(source),
            payment_channel: PaymentChannel::InterLedger,
            amount: Decimal::ZERO,
            issued_at: now,
            on_behalf_of_owner: source == dues_ledger::DEBTOR_TENANT
                && target == dues_ledger::DEBTOR_OWNER,
            owner_name,
            channel_reference: None,
            description: None,
            external_reference: None,
            advance_debtor: source.to_string(),
        };
        let insufficient = |have: Decimal| {
            format!(
                "Yetersiz avans bakiyesi ({}). Mevcut: ₺{:.2}, Talep Edilen: ₺{:.2}",
                source, have, transfer_amount
            )
        };
        let note = req.note.clone().unwrap_or_else(|| {
            format!(
                "Avans bakiyesinden borca virman yapıldı ({} -> {})",
                source, target
            )
        });
        let allocate = |dues: &mut Vec<DuesLiability>| {
            let candidates: Vec<usize> = dues_ledger::open_dues_for(dues, |_| true, target)
                .into_iter()
                .filter(|&i| dues[i].debtor_type.as_str().eq_ignore_ascii_case(target))
                .collect();
            dues_ledger::allocate_waterfall(dues, &candidates, transfer_amount)
        };

        let (receipt, settled, entry) = if let Some(ref pool) = self.state.pool {
            let site_num = crate::db::require_id("site", &site_id)?;
            let unit_num = crate::db::require_id("unit", &unit.id)?;
            let mut client = pool
                .get()
                .await
                .map_err(|e| format!("Database unavailable: {}", e))?;
            let tx = client
                .transaction()
                .await
                .map_err(|e| format!("Database unavailable: {}", e))?;
            let db_err = |e: Box<dyn std::error::Error + Send + Sync>| {
                format!(
                    "Transfer was not recorded: {}",
                    crate::db::describe_db_error(e.as_ref())
                )
            };
            // Tenant guardrail: from here on PostgreSQL row-level security
            // hides every other site's rows (V21).
            crate::db::tx_bind_tenant(&tx, site_num)
                .await
                .map_err(db_err)?;
            if !crate::db::tx_lock_unit(&tx, unit_num, site_num)
                .await
                .map_err(db_err)?
            {
                return Err(format!("Daire bulunamadı: {}", unit_id));
            }
            let credit = crate::db::tx_lock_advance(&tx, unit_num, source)
                .await
                .map_err(db_err)?;
            if credit < transfer_amount {
                return Err(insufficient(credit));
            }
            let mut dues: Vec<DuesLiability> = crate::db::tx_load_open_dues(&tx, unit_num)
                .await
                .map_err(db_err)?
                .into_iter()
                .map(|d| calc.calculate_delay_penalty(d, now.date_naive()))
                .collect();
            let (lines, unused) = allocate(&mut dues);
            let cleared = transfer_amount - unused;
            if cleared <= Decimal::ZERO {
                return Err("Mahsup edilecek açık borç bulunamadı".to_string());
            }
            let seq = crate::db::tx_next_receipt_sequence(&tx, site_num, LEDGER_KIND_COLLECTION)
                .await
                .map_err(db_err)?;
            let mut c = ctx;
            c.amount = cleared;
            let mut receipt = build_receipt(&c, &dues, &lines, Decimal::ZERO, seq);
            receipt
                .legal_statutory_note
                .get_or_insert_with(|| VIRMAN_NOTE.to_string());
            crate::db::tx_insert_receipt(&tx, &mut receipt, site_num, unit_num)
                .await
                .map_err(db_err)?;
            let mut entry = build_entry(&c, &receipt);
            entry.description = Some(note.clone());
            entry.id = crate::db::tx_insert_entry(&tx, &entry, site_num, unit_num)
                .await
                .map_err(db_err)?;
            for line in &lines {
                crate::db::tx_settle_due(
                    &tx,
                    entry.id,
                    &dues[line.due_index],
                    line.settlement.principal,
                    line.settlement.penalty,
                )
                .await
                .map_err(db_err)?;
            }
            crate::db::tx_debit_advance(
                &tx,
                unit_num,
                source,
                "VIRMAN_DEBIT",
                cleared,
                Some(&receipt.receipt_number),
                Some(&note),
            )
            .await
            .map_err(db_err)?;
            tx.commit()
                .await
                .map_err(|e| format!("Transfer was not recorded: {}", e))?;
            let touched: Vec<DuesLiability> =
                lines.iter().map(|l| dues[l.due_index].clone()).collect();
            (receipt, touched, entry)
        } else {
            let inner = self.state.inner.read().await;
            let have = inner.advance_of(&unit.id, source);
            if have < transfer_amount {
                return Err(insufficient(have));
            }
            let mut dues: Vec<DuesLiability> = inner
                .dues
                .iter()
                .filter(|d| {
                    d.status != DebtStatus::Paid && crate::auth::same_id(&d.unit_id, &unit.id)
                })
                .cloned()
                .map(|d| calc.calculate_delay_penalty(d, now.date_naive()))
                .collect();
            let seq = next_memory_sequence(&inner, &site_id, LEDGER_KIND_COLLECTION);
            let rid = inner
                .payment_receipts
                .iter()
                .map(|r| r.id)
                .max()
                .unwrap_or(0)
                + 1;
            let eid = inner
                .payment_entries
                .iter()
                .map(|e| e.id)
                .max()
                .unwrap_or(0)
                + 1;
            let issuer = Issuer::of(&inner, &site_id);
            drop(inner);
            let (lines, unused) = allocate(&mut dues);
            let cleared = transfer_amount - unused;
            if cleared <= Decimal::ZERO {
                return Err("Mahsup edilecek açık borç bulunamadı".to_string());
            }
            let mut c = ctx;
            c.amount = cleared;
            let mut receipt = build_receipt(&c, &dues, &lines, Decimal::ZERO, seq);
            receipt.id = rid;
            receipt
                .legal_statutory_note
                .get_or_insert_with(|| VIRMAN_NOTE.to_string());
            issuer.apply(&mut receipt);
            let mut entry = build_entry(&c, &receipt);
            entry.id = eid;
            entry.description = Some(note.clone());
            let touched: Vec<DuesLiability> =
                lines.iter().map(|l| dues[l.due_index].clone()).collect();
            (receipt, touched, entry)
        };

        let mut inner = self.state.inner.write().await;
        for d in &settled {
            if let Some(m) = inner
                .dues
                .iter_mut()
                .find(|x| crate::auth::same_id(&x.id, &d.id))
            {
                let key = m.unit_id.clone();
                *m = d.clone();
                m.unit_id = key;
            }
        }
        inner.adjust_advance(&unit.id, source, -receipt.total_amount);
        let remaining_advance = inner.advance_of(&unit.id, source).max(Decimal::ZERO);
        inner.payment_receipts.push(receipt.clone());
        inner.payment_entries.push(entry);

        Ok(InterLedgerTransferResponse {
            success: true,
            message: format!(
                "₺{:.2} tutarındaki avans bakiyesi başarıyla borca mahsup edildi.",
                receipt.total_amount
            ),
            receipt_number: receipt.receipt_number.clone(),
            transferred_amount: receipt.total_amount,
            remaining_advance_balance: remaining_advance,
            cleared_capital_due_amount: receipt.allocated_principal + receipt.allocated_penalty,
            verification_hash: receipt.verification_hash,
        })
    }

    /// Reverses a settled payment (SPEC-006 R2): issues an `IAD-YYYY-NNNNNN`
    /// reversal receipt, appends a contra entry (`REVERSAL`, linked by
    /// `reverses_entry_id`, with the reason and the operator), restores the paid
    /// amounts of every liability the payment settled, debits the advance it
    /// credited as `REFUND`, and moves the original entry SETTLED -> REVERSED.
    /// Nothing is updated in place except the liability state and the original's
    /// status (the ledger is append-only). One receipt is reversed at most once;
    /// asking again returns the existing reversal.
    ///
    /// A virman (`INTER_LEDGER`) receipt is reversed the same way, except that the
    /// advance it spent is credited back to the source debtor (`VIRMAN_REVERSAL`)
    /// instead of an advance being refunded (SPEC-007 R1).
    pub async fn reverse_payment(
        &self,
        req: ReversePaymentRequest,
        ctx: &crate::authorization::AuthzContext,
    ) -> Result<ReversePaymentResponse, String> {
        let site_id = req
            .site_id
            .clone()
            .filter(|s| !s.trim().is_empty())
            .ok_or_else(|| "site_id is required".to_string())?;
        let reason = req.reason.trim().to_string();
        if reason.chars().count() < 3 {
            return Err("A reversal reason of at least 3 characters is required".to_string());
        }
        ctx.require(crate::models::Permission::PaymentReverse, &site_id)
            .map_err(|e| e.to_string())?;
        let actor = ctx.claims.sub.trim();
        if actor.is_empty() {
            return Err("The operator reversing the payment must be known".to_string());
        }
        let identifier = req.receipt.trim().to_string();
        let now = Utc::now();
        let today = now.date_naive();

        let existing_reversal = |inner: &crate::state::AppStateInner, original: &PaymentReceipt| {
            inner
                .payment_receipts
                .iter()
                .find(|r| r.reverses_receipt_id == Some(original.id))
                .cloned()
        };

        let (original, reversal, lines, contra) = if let Some(ref pool) = self.state.pool {
            let site_num = crate::db::require_id("site", &site_id)?;
            let mut client = pool
                .get()
                .await
                .map_err(|e| format!("Database unavailable: {}", e))?;
            let tx = client
                .transaction()
                .await
                .map_err(|e| format!("Database unavailable: {}", e))?;
            let db_err = |e: Box<dyn std::error::Error + Send + Sync>| {
                format!(
                    "Reversal was not recorded: {}",
                    crate::db::describe_db_error(e.as_ref())
                )
            };
            // Tenant guardrail: from here on PostgreSQL row-level security
            // hides every other site's rows (V21).
            crate::db::tx_bind_tenant(&tx, site_num)
                .await
                .map_err(db_err)?;
            let target = crate::db::tx_lock_entry_of_receipt(&tx, site_num, &identifier)
                .await
                .map_err(db_err)?
                .ok_or_else(|| format!("Makbuz bulunamadı: {}", identifier))?;
            let original = target.receipt.clone();
            if original.receipt_type != LEDGER_KIND_COLLECTION
                || target.entry_type != LEDGER_KIND_COLLECTION
            {
                return Err(format!(
                    "{} is a reversal receipt and cannot be reversed",
                    original.receipt_number
                ));
            }
            if target.settlement_status == SettlementStatus::Reversed {
                drop(tx);
                let rev = {
                    let inner = self.state.inner.read().await;
                    existing_reversal(&inner, &original)
                };
                return Ok(reversal_response(
                    rev.ok_or("Reversal receipt not found")?,
                    &original,
                ));
            }
            check_reversible(&original, target.settlement_status)?;
            if !crate::db::tx_lock_unit(&tx, target.unit_id, site_num)
                .await
                .map_err(db_err)?
            {
                return Err("Daire bulunamadı".to_string());
            }
            let allocations = crate::db::tx_load_entry_allocations(&tx, target.entry_id)
                .await
                .map_err(db_err)?;
            let lines: Vec<(String, Decimal, Decimal)> = allocations
                .iter()
                .map(|(d, p, pen)| (d.id.clone(), *p, *pen))
                .collect();
            for (due_id, principal, penalty) in &lines {
                let due_num = crate::db::require_id("dues liability", due_id)?;
                crate::db::tx_unsettle_due(&tx, due_num, *principal, *penalty)
                    .await
                    .map_err(db_err)?;
            }
            let seq = crate::db::tx_next_receipt_sequence(&tx, site_num, LEDGER_KIND_REVERSAL)
                .await
                .map_err(db_err)?;
            let mut reversal = build_reversal_receipt(&original, seq, &reason, now);
            if original.allocated_advance > Decimal::ZERO {
                let debtor = advance_debtor_of(&original);
                let have = crate::db::tx_lock_advance(&tx, target.unit_id, &debtor)
                    .await
                    .map_err(db_err)?;
                if have < original.allocated_advance {
                    return Err(format!(
                        "The ₺{:.2} advance credited by {} has already been used (₺{:.2} left); reverse the later offsets first",
                        original.allocated_advance, original.receipt_number, have
                    ));
                }
                crate::db::tx_debit_advance(
                    &tx,
                    target.unit_id,
                    &debtor,
                    "REFUND",
                    original.allocated_advance,
                    Some(&reversal.receipt_number),
                    Some(&format!(
                        "Reversal of {}: {}",
                        original.receipt_number, reason
                    )),
                )
                .await
                .map_err(db_err)?;
            }
            if is_virman(&original) {
                crate::db::tx_credit_advance(
                    &tx,
                    target.unit_id,
                    original.payer_role.as_str(),
                    "VIRMAN_REVERSAL",
                    original.total_amount,
                    Some(&reversal.receipt_number),
                    Some(&format!(
                        "Reversal of virman {}: {}",
                        original.receipt_number, reason
                    )),
                )
                .await
                .map_err(db_err)?;
            }
            crate::db::tx_insert_receipt(&tx, &mut reversal, site_num, target.unit_id)
                .await
                .map_err(db_err)?;
            let mut contra =
                build_contra_entry(&original, &reversal, target.entry_id, &reason, actor);
            contra.id = crate::db::tx_insert_entry(&tx, &contra, site_num, target.unit_id)
                .await
                .map_err(db_err)?;
            crate::db::tx_mark_entry_reversed(&tx, target.entry_id)
                .await
                .map_err(db_err)?;
            tx.commit()
                .await
                .map_err(|e| format!("Reversal was not recorded: {}", e))?;
            (original, reversal, lines, contra)
        } else {
            let inner = self.state.inner.read().await;
            let original = inner
                .payment_receipts
                .iter()
                .find(|r| {
                    crate::auth::same_id(&r.site_id, &site_id)
                        && (r.receipt_number == identifier
                            || identifier.parse::<i64>().ok() == Some(r.id))
                })
                .cloned()
                .ok_or_else(|| format!("Makbuz bulunamadı: {}", identifier))?;
            if original.receipt_type != LEDGER_KIND_COLLECTION {
                return Err(format!(
                    "{} is a reversal receipt and cannot be reversed",
                    original.receipt_number
                ));
            }
            let entry = inner
                .payment_entries
                .iter()
                .find(|e| e.receipt_id == Some(original.id))
                .cloned()
                .ok_or_else(|| format!("{} has no ledger entry", original.receipt_number))?;
            if entry.settlement_status == SettlementStatus::Reversed {
                let rev =
                    existing_reversal(&inner, &original).ok_or("Reversal receipt not found")?;
                return Ok(reversal_response(rev, &original));
            }
            check_reversible(&original, entry.settlement_status)?;
            if original.allocated_advance > Decimal::ZERO {
                let have = inner.advance_of(&original.unit_id, &advance_debtor_of(&original));
                if have < original.allocated_advance {
                    return Err(format!(
                        "The ₺{:.2} advance credited by {} has already been used (₺{:.2} left); reverse the later offsets first",
                        original.allocated_advance, original.receipt_number, have
                    ));
                }
            }
            let lines: Vec<(String, Decimal, Decimal)> = original
                .allocation_breakdown
                .iter()
                .filter_map(|b| {
                    b.due_id
                        .clone()
                        .map(|id| (id, b.principal_paid, b.penalty_paid))
                })
                .collect();
            for (due_id, principal, penalty) in &lines {
                let due = inner
                    .dues
                    .iter()
                    .find(|d| crate::auth::same_id(&d.id, due_id))
                    .ok_or_else(|| format!("dues liability {} not found", due_id))?;
                if due.paid_principal < *principal || due.paid_penalty < *penalty {
                    return Err(format!(
                        "dues liability {} cannot be un-allocated (already reduced)",
                        due_id
                    ));
                }
            }
            let seq = next_memory_sequence(&inner, &site_id, LEDGER_KIND_REVERSAL);
            let mut reversal = build_reversal_receipt(&original, seq, &reason, now);
            reversal.id = inner
                .payment_receipts
                .iter()
                .map(|r| r.id)
                .max()
                .unwrap_or(0)
                + 1;
            Issuer::of(&inner, &site_id).apply(&mut reversal);
            let mut contra = build_contra_entry(&original, &reversal, entry.id, &reason, actor);
            contra.id = inner
                .payment_entries
                .iter()
                .map(|e| e.id)
                .max()
                .unwrap_or(0)
                + 1;
            (original, reversal, lines, contra)
        };

        // Apply the committed reversal to the in-memory view.
        let mut inner = self.state.inner.write().await;
        for (due_id, principal, penalty) in &lines {
            if let Some(d) = inner
                .dues
                .iter_mut()
                .find(|d| crate::auth::same_id(&d.id, due_id))
            {
                dues_ledger::unsettle(d, *principal, *penalty, today);
            }
        }
        if original.allocated_advance > Decimal::ZERO {
            inner.adjust_advance(
                &original.unit_id,
                &advance_debtor_of(&original),
                -original.allocated_advance,
            );
        }
        if is_virman(&original) {
            inner.adjust_advance(
                &original.unit_id,
                original.payer_role.as_str(),
                original.total_amount,
            );
        }
        if let Some(e) = inner
            .payment_entries
            .iter_mut()
            .find(|e| e.receipt_id == Some(original.id))
        {
            e.settlement_status = SettlementStatus::Reversed;
        }
        inner.payment_entries.push(contra);
        inner.payment_receipts.push(reversal.clone());
        Ok(reversal_response(reversal, &original))
    }

    /// Writes today's debt aging report of every site to `debt_aging_snapshots`
    /// (O-8, regulatory report F17). Re-running on the same day replaces that
    /// day's rows. Returns the number of unit/debtor rows written.
    pub async fn snapshot_debt_aging(&self, site_filter: Option<&str>) -> Result<usize, String> {
        let site_ids: Vec<String> = {
            let inner = self.state.inner.read().await;
            inner
                .sites
                .iter()
                .filter(|s| {
                    site_filter
                        .map(|f| crate::auth::same_id(f, &s.id))
                        .unwrap_or(true)
                })
                .map(|s| s.id.clone())
                .collect()
        };
        let mut written = 0;
        for site in site_ids {
            let report = self
                .get_debt_aging_report(&site)
                .await
                .map_err(|e| e.to_string())?;
            written += match self.state.pool {
                Some(ref pool) => crate::db::save_debt_aging_snapshot(pool, &site, &report)
                    .await
                    .map_err(|e| e.to_string())?,
                None => report.brackets.len(),
            };
        }
        Ok(written)
    }

    /// Retrieve digital receipt by ID or receipt number
    pub async fn get_receipt(
        &self,
        site_id: &str,
        identifier: &str,
    ) -> Result<PaymentReceipt, String> {
        let inner = self.state.inner.read().await;

        let num_id = identifier.parse::<i64>().ok();

        let receipt = inner
            .payment_receipts
            .iter()
            .find(|r| {
                if !site_id.is_empty() && r.site_id != site_id && site_id != "all" {
                    return false;
                }
                r.receipt_number == identifier || num_id.map(|n| r.id == n).unwrap_or(false)
            })
            .cloned();
        drop(inner);

        if let Some(r) = receipt {
            return Ok(r);
        }

        if let Some(ref pool) = self.state.pool {
            let site_num = if site_id.is_empty() || site_id == "all" {
                0
            } else {
                crate::db::require_id("site", site_id)?
            };
            if let Some(r) = crate::db::find_payment_receipt(pool, site_num, identifier)
                .await
                .map_err(|e| e.to_string())?
            {
                return Ok(r);
            }
        }

        Err(format!("Makbuz bulunamadı: {}", identifier))
    }

    /// Transfer property title deed ownership (ev satışı) with debt freeze & handover
    pub async fn transfer_ownership(
        &self,
        req: TransferOwnershipRequest,
    ) -> Result<TransferOwnershipResponse, String> {
        let site_id = req.site_id.unwrap_or_default();
        let unit_id = req.unit_id.clone();
        let now = Utc::now();
        let mut inner = self.state.inner.write().await;
        // Dates are the site's local dates (an Istanbul evening is already tomorrow in UTC).
        let today = crate::services::finance_common::site_today(&inner, &site_id);
        let transfer_date = req.transfer_date.unwrap_or(today);

        // Find unit
        let mut unit_idx = inner
            .units
            .iter()
            .position(|u| u.id == unit_id)
            .ok_or_else(|| format!("Daire bulunamadı: {}", unit_id))?;
        if !crate::auth::same_id(&inner.units[unit_idx].site_id, &site_id) {
            return Err("Daire belirtilen siteye ait değil.".to_string());
        }

        let old_owner_user_id = inner.units[unit_idx].owner_user_id.clone();
        let old_owner_name = old_owner_user_id
            .as_ref()
            .and_then(|oid| {
                inner
                    .users
                    .iter()
                    .find(|u| &u.id == oid)
                    .map(|u| u.full_name.clone())
            })
            .unwrap_or_else(|| "Eski Kat Maliki".to_string());

        // Calculate exit balance for old owner (all unpaid debts as of transfer date)
        let old_owner_exit_balance: Decimal = inner
            .dues
            .iter()
            .filter(|d| d.unit_id == unit_id && d.status != DebtStatus::Paid)
            .map(|d| d.total_amount)
            .sum();

        // Register new owner user
        let max_u = inner
            .users
            .iter()
            .filter_map(|u| crate::db::parse_id_to_i64(&u.id))
            .max()
            .unwrap_or(0);
        let new_user_id = (max_u + 1).to_string();
        let new_owner_email = req
            .new_owner_email
            .clone()
            .unwrap_or_else(|| format!("owner.{}@sitepulse.local", new_user_id));

        let new_user = User {
            id: new_user_id.clone(),
            site_id: site_id.clone(),
            full_name: req.new_owner_name.clone(),
            email: new_owner_email.clone(),
            phone: req.new_owner_phone.clone().unwrap_or_default(),
            password_hash: Some("ARGON2_TEMP_HASH".to_string()),
            role: Role::HomeOwner,
            must_change_password: true,
            auth_provider: AuthProvider::Local,
            google_sub: None,
            avatar_url: None,
            created_at: now,
            person_id: None,
        };

        // Archive old owner in unit_occupancies
        let notes = format!(
            "Mülk satışı / Tapu devri. Eski malik: {}, Çıkış bakiyesi: ₺{:.2}. Yeni malik: {}. {}",
            old_owner_name,
            old_owner_exit_balance,
            req.new_owner_name,
            req.notes.as_deref().unwrap_or_default()
        );

        let unit_num_i64 = crate::db::require_id("entity", &unit_id)?;
        // Resolve the previous owner's person id from the account itself; an
        // unknown owner is recorded as 0 (never as someone else's person id).
        let old_person_id = old_owner_user_id
            .as_deref()
            .and_then(|uid| {
                inner
                    .users
                    .iter()
                    .find(|u| u.id == uid)
                    .and_then(|u| u.person_id)
                    .or_else(|| uid.strip_prefix("person-").and_then(|n| n.parse().ok()))
            })
            .unwrap_or(0);
        let old_owner_start_date = old_owner_user_id
            .as_deref()
            .and_then(|uid| inner.users.iter().find(|u| u.id == uid))
            .map(|user| user.created_at.date_naive())
            .unwrap_or_else(|| NaiveDate::from_ymd_opt(2020, 1, 1).unwrap_or(transfer_date))
            .min(transfer_date);

        let history_item = OccupancyHistoryItem {
            id: now.timestamp_millis(),
            unit_id: unit_num_i64,
            person_id: old_person_id,
            person_name: old_owner_name.clone(),
            person_phone: None,
            person_email: None,
            role: DebtorType::Owner,
            start_date: old_owner_start_date.to_string(),
            end_date: Some(transfer_date.to_string()),
            is_active: false,
            exit_balance: old_owner_exit_balance,
            notes: Some(notes.clone()),
            created_at: now,
        };

        // PostgreSQL is the source of truth: a refused transfer changes nothing,
        // in the database or in memory.
        let mut old_owner_exit_balance = old_owner_exit_balance;
        if let Some(pool) = self.state.pool.clone() {
            let unit_index_id = inner.units[unit_idx].id.clone();
            drop(inner);
            let persisted = crate::db::transfer_unit_ownership_db(
                &pool,
                &crate::db::TitleTransfer {
                    unit_id: &unit_id,
                    site_id: &site_id,
                    new_user: &new_user,
                    buyer_person_id: req.new_owner_person_id,
                    new_owner_moves_in: req.new_owner_moves_in,
                    transfer_date,
                    today,
                    notes: req.notes.as_deref(),
                },
            )
            .await
            .map_err(|e| e.to_string())?;
            if let Some(balance) = persisted {
                old_owner_exit_balance = balance;
            }
            inner = self.state.inner.write().await;
            unit_idx = inner
                .units
                .iter()
                .position(|u| u.id == unit_index_id)
                .ok_or_else(|| format!("Daire bulunamadı: {}", unit_id))?;
        } else if transfer_date > today {
            return Err(crate::domain::unit_state::TransitionError::FutureDate {
                date: transfer_date,
            }
            .to_string());
        }

        let history_item = OccupancyHistoryItem {
            exit_balance: old_owner_exit_balance,
            ..history_item
        };
        inner.users.push(new_user.clone());
        inner
            .unit_occupancies
            .entry(unit_id.clone())
            .or_default()
            .push(history_item);

        // Update unit owner
        inner.units[unit_idx].owner_user_id = Some(new_user_id);
        drop(inner);

        Ok(TransferOwnershipResponse {
            success: true,
            message: format!(
                "Mülk tapu devri başarıyla tamamlandı. Yeni malik ({}) kaydedildi. Eski malik bakiye dökümü arşivlendi.",
                req.new_owner_name
            ),
            unit_id,
            old_owner_name,
            old_owner_exit_balance,
            new_owner_name: req.new_owner_name,
            transferred_at: now,
        })
    }
}

/// Inputs shared by the persisted and in-memory payment paths.
struct ReceiptContext {
    site_id: String,
    unit_id: String,
    payer_name: String,
    payer_role: DebtorType,
    payment_channel: PaymentChannel,
    amount: Decimal,
    issued_at: DateTime<Utc>,
    on_behalf_of_owner: bool,
    owner_name: Option<String>,
    channel_reference: Option<String>,
    description: Option<String>,
    external_reference: Option<String>,
    /// The debtor whose advance receives the surplus (or is debited by a virman).
    advance_debtor: String,
    /// Display label of the unit ("A Blok D:14").
    unit_label: String,
}

const VIRMAN_NOTE: &str = "Avans bakiyesinden demirbaş/ortak gider borcuna virman işlemi.";

/// Key of `AppStateInner.payment_idempotency`: the site id in its numeric form
/// (in-memory `site-1` and PostgreSQL `1` are the same site) and the key.
fn idempotency_slot(site_id: &str, key: &str) -> (String, String) {
    let site = crate::db::parse_id_to_i64(site_id)
        .map(|n| n.to_string())
        .unwrap_or_else(|| site_id.to_string());
    (site, key.to_string())
}

/// Next in-memory receipt sequence of a site within one series.
fn next_memory_sequence(
    inner: &crate::state::AppStateInner,
    site_id: &str,
    receipt_type: &str,
) -> i64 {
    inner
        .payment_receipts
        .iter()
        .filter(|r| crate::auth::same_id(&r.site_id, site_id) && r.receipt_type == receipt_type)
        .map(|r| r.sequence_number)
        .max()
        .unwrap_or(0)
        + 1
}

/// `OWNER` / `TENANT` from an optional request field (default OWNER).
fn normalize_debtor(raw: Option<&str>, field: &str) -> Result<&'static str, String> {
    match raw.map(|r| r.trim().to_uppercase()) {
        None => Ok(dues_ledger::DEBTOR_OWNER),
        Some(r) if r.is_empty() || r == dues_ledger::DEBTOR_OWNER => Ok(dues_ledger::DEBTOR_OWNER),
        Some(r) if r == dues_ledger::DEBTOR_TENANT => Ok(dues_ledger::DEBTOR_TENANT),
        Some(r) => Err(format!("{} must be OWNER or TENANT, got '{}'", field, r)),
    }
}

/// Issuer legal details snapshotted on a receipt (O-5). With PostgreSQL the
/// insert takes them from `sites` in the same statement.
struct Issuer {
    name: Option<String>,
    address: Option<String>,
    tax_id: Option<String>,
    tax_office: Option<String>,
}

impl Issuer {
    fn of(inner: &crate::state::AppStateInner, site_id: &str) -> Self {
        let site = inner
            .sites
            .iter()
            .find(|s| crate::auth::same_id(&s.id, site_id));
        Issuer {
            name: site.map(|s| s.name.clone()),
            address: site.map(|s| s.address.clone()).filter(|a| !a.is_empty()),
            tax_id: site.and_then(|s| s.tax_id.clone()),
            tax_office: site.and_then(|s| s.tax_office.clone()),
        }
    }

    fn apply(&self, receipt: &mut PaymentReceipt) {
        receipt.issuer_name = self.name.clone();
        receipt.issuer_address = self.address.clone();
        receipt.issuer_tax_id = self.tax_id.clone();
        receipt.issuer_tax_office = self.tax_office.clone();
    }
}

/// The debtor whose advance a receipt credited.
fn advance_debtor_of(receipt: &PaymentReceipt) -> String {
    receipt
        .advance_debtor_type
        .clone()
        .unwrap_or_else(|| receipt.payer_role.to_string())
}

fn check_reversible(
    original: &PaymentReceipt,
    settlement_status: SettlementStatus,
) -> Result<(), String> {
    if settlement_status != SettlementStatus::Settled {
        return Err(format!(
            "{} is {} and cannot be reversed",
            original.receipt_number, settlement_status
        ));
    }
    Ok(())
}

/// A virman receipt: its amount was taken from the payer's advance, not paid in.
fn is_virman(receipt: &PaymentReceipt) -> bool {
    receipt.payment_channel == PaymentChannel::InterLedger
}

/// The `IAD-YYYY-NNNNNN` reversal receipt: the original's amounts and lines, in
/// the reversal series, linked by `reverses_receipt_id`.
fn build_reversal_receipt(
    original: &PaymentReceipt,
    sequence_number: i64,
    reason: &str,
    issued_at: DateTime<Utc>,
) -> PaymentReceipt {
    let receipt_number = format!("IAD-{}-{:06}", issued_at.format("%Y"), sequence_number);
    PaymentReceipt {
        id: 0,
        site_id: original.site_id.clone(),
        unit_id: original.unit_id.clone(),
        verification_hash: PaymentTrackingService::compute_verification_hash(
            &receipt_number,
            &original.unit_id,
            original.total_amount,
            &issued_at,
        ),
        receipt_number,
        sequence_number,
        payer_name: original.payer_name.clone(),
        payer_role: original.payer_role,
        on_behalf_of_name: original.on_behalf_of_name.clone(),
        on_behalf_of_role: original.on_behalf_of_role,
        total_amount: original.total_amount,
        payment_channel: original.payment_channel,
        channel_reference: Some(original.receipt_number.clone()),
        allocated_principal: original.allocated_principal,
        allocated_penalty: original.allocated_penalty,
        allocated_advance: original.allocated_advance,
        allocation_breakdown: original.allocation_breakdown.clone(),
        is_rent_offset_eligible: false,
        legal_statutory_note: Some(if is_virman(original) {
            format!("{} numaralı virman makbuzunun iptali; tutar avans bakiyesine geri alındı. Gerekçe: {}", original.receipt_number, reason)
        } else {
            format!(
                "{} numaralı tahsilat makbuzunun iptali / iadesi. Gerekçe: {}",
                original.receipt_number, reason
            )
        }),
        issued_at,
        receipt_type: LEDGER_KIND_REVERSAL.to_string(),
        reverses_receipt_id: Some(original.id),
        advance_debtor_type: original.advance_debtor_type.clone().or_else(|| {
            (original.allocated_advance > Decimal::ZERO).then(|| original.payer_role.to_string())
        }),
        issuer_name: None,
        issuer_address: None,
        issuer_tax_id: None,
        issuer_tax_office: None,
    }
}

/// The contra entry of a reversal: same amount and unit, REVERSED, linked.
fn build_contra_entry(
    original: &PaymentReceipt,
    reversal: &PaymentReceipt,
    original_entry_id: i64,
    reason: &str,
    actor: &str,
) -> PaymentEntry {
    PaymentEntry {
        id: 0,
        site_id: original.site_id.clone(),
        unit_id: original.unit_id.clone(),
        unit_label: None,
        payer_name: original.payer_name.clone(),
        payer_role: original.payer_role,
        receipt_id: Some(reversal.id),
        receipt_number: Some(reversal.receipt_number.clone()),
        amount: original.total_amount,
        payment_channel: original.payment_channel,
        settlement_status: SettlementStatus::Reversed,
        description: Some(format!(
            "Reversal of {}: {}",
            original.receipt_number, reason
        )),
        external_reference: None,
        payment_date: reversal.issued_at,
        created_at: Utc::now(),
        entry_type: LEDGER_KIND_REVERSAL.to_string(),
        reverses_entry_id: Some(original_entry_id),
        reversal_reason: Some(reason.to_string()),
        recorded_by: Some(actor.to_string()),
    }
}

fn reversal_response(
    reversal: PaymentReceipt,
    original: &PaymentReceipt,
) -> ReversePaymentResponse {
    ReversePaymentResponse {
        refunded_advance: reversal.allocated_advance,
        reopened_due_ids: reversal
            .allocation_breakdown
            .iter()
            .filter_map(|b| b.due_id.clone())
            .collect(),
        reversed_receipt_number: original.receipt_number.clone(),
        restored_advance: if is_virman(original) {
            original.total_amount
        } else {
            Decimal::ZERO
        },
        reversal_receipt: reversal,
    }
}

/// SPEC-009 R3: the tenant pays the owner's items as the owner's joint debtor
/// (KMK 22, capped at the rent) and deducts it from the rent (TBK 314). Verify
/// the wording with counsel before it is printed in production.
const RENT_OFFSET_NOTE: &str = "634 sayılı KMK Madde 22 uyarınca kiracı, kat malikinin ortak gider ve avans borcundan kira bedeli ile sınırlı olarak malikle birlikte sorumludur; ana gayrimenkulün demirbaş/yatırım giderleri kat malikine aittir (KMK Madde 20). Kiracının kat maliki adına ödediği bu tutar kira bedelinden mahsup edilebilir (TBK md. 314; verify).";

fn build_receipt(
    ctx: &ReceiptContext,
    dues: &[DuesLiability],
    lines: &[dues_ledger::AllocationLine],
    surplus: Decimal,
    sequence_number: i64,
) -> PaymentReceipt {
    let receipt_number = format!("TAH-{}-{:06}", ctx.issued_at.format("%Y"), sequence_number);
    let allocation_breakdown: Vec<AllocationBreakdownItem> = lines
        .iter()
        .map(|l| {
            let d = &dues[l.due_index];
            AllocationBreakdownItem {
                due_id: Some(d.id.clone()),
                period: d.period.clone(),
                // Taken from the liability itself, never guessed from the description.
                expense_type: d.expense_type,
                principal_paid: l.settlement.principal,
                penalty_paid: l.settlement.penalty,
            }
        })
        .collect();
    let allocated_principal: Decimal = lines.iter().map(|l| l.settlement.principal).sum();
    let allocated_penalty: Decimal = lines.iter().map(|l| l.settlement.penalty).sum();
    let paid_capital = allocation_breakdown
        .iter()
        .any(|b| b.expense_type == ExpenseType::CapitalDues);
    let is_rent_offset_eligible = ctx.on_behalf_of_owner && paid_capital;
    let mut receipt = PaymentReceipt {
        id: 0,
        site_id: ctx.site_id.clone(),
        unit_id: ctx.unit_id.clone(),
        verification_hash: String::new(),
        receipt_number,
        sequence_number,
        payer_name: ctx.payer_name.clone(),
        payer_role: ctx.payer_role,
        on_behalf_of_name: if is_rent_offset_eligible {
            ctx.owner_name.clone()
        } else {
            None
        },
        on_behalf_of_role: if is_rent_offset_eligible {
            Some(DebtorType::Owner)
        } else {
            None
        },
        total_amount: ctx.amount,
        payment_channel: ctx.payment_channel,
        channel_reference: ctx.channel_reference.clone(),
        allocated_principal,
        allocated_penalty,
        allocated_advance: surplus,
        allocation_breakdown,
        is_rent_offset_eligible,
        legal_statutory_note: if is_rent_offset_eligible {
            Some(RENT_OFFSET_NOTE.to_string())
        } else {
            None
        },
        issued_at: ctx.issued_at,
        receipt_type: LEDGER_KIND_COLLECTION.to_string(),
        reverses_receipt_id: None,
        advance_debtor_type: (surplus > Decimal::ZERO).then(|| ctx.advance_debtor.clone()),
        issuer_name: None,
        issuer_address: None,
        issuer_tax_id: None,
        issuer_tax_office: None,
    };
    // SPEC-009 R15: new collection receipts carry the v2 hash (payer + allocation).
    receipt.verification_hash = PaymentTrackingService::compute_verification_hash_v2(&receipt);
    receipt
}

fn build_entry(ctx: &ReceiptContext, receipt: &PaymentReceipt) -> PaymentEntry {
    PaymentEntry {
        id: 0,
        site_id: ctx.site_id.clone(),
        unit_id: ctx.unit_id.clone(),
        unit_label: Some(ctx.unit_label.clone()),
        payer_name: ctx.payer_name.clone(),
        payer_role: ctx.payer_role,
        receipt_id: if receipt.id > 0 {
            Some(receipt.id)
        } else {
            None
        },
        receipt_number: Some(receipt.receipt_number.clone()),
        amount: ctx.amount,
        payment_channel: ctx.payment_channel,
        settlement_status: SettlementStatus::Settled,
        description: ctx.description.clone(),
        external_reference: ctx.external_reference.clone(),
        payment_date: ctx.issued_at,
        created_at: Utc::now(),
        entry_type: LEDGER_KIND_COLLECTION.to_string(),
        reverses_entry_id: None,
        reversal_reason: None,
        recorded_by: None,
    }
}

/// Canonical `payment_channel` (the V14 vocabulary) for a client-supplied value.
pub fn normalize_payment_channel(raw: &str) -> Result<String, String> {
    const KNOWN: [&str; 7] = [
        "VIRTUAL_IBAN",
        "BANK_STATEMENT",
        "BANK_TRANSFER",
        "CREDIT_CARD",
        "MANUAL_CASH",
        "INTER_LEDGER",
        "ONLINE_PAYMENT",
    ];
    let folded = dues_ledger::fold_turkish(raw.trim()).to_uppercase();
    if let Some(k) = KNOWN.iter().find(|k| **k == folded) {
        return Ok(k.to_string());
    }
    let channel = if folded == "CASH" || folded.contains("NAKIT") || folded.contains("CASH") {
        "MANUAL_CASH"
    } else if folded.contains("CARD") || folded.contains("KART") || folded.contains("POS") {
        "CREDIT_CARD"
    } else if folded.contains("IBAN") {
        "VIRTUAL_IBAN"
    } else if folded.contains("FAST")
        || folded.contains("EFT")
        || folded.contains("HAVALE")
        || folded.contains("TRANSFER")
    {
        "BANK_TRANSFER"
    } else if folded.contains("STATEMENT") || folded.contains("EKSTRE") {
        "BANK_STATEMENT"
    } else if folded.contains("ONLINE") {
        "ONLINE_PAYMENT"
    } else {
        return Err(format!("Unknown payment channel '{}'", raw));
    };
    Ok(channel.to_string())
}

/// Ledger-entry description: the payer's note plus the designation applied.
fn entry_description(
    note: Option<&str>,
    designation: Option<&crate::models::PaymentDesignation>,
    designated_any: bool,
) -> Option<String> {
    let note = note.map(str::trim).filter(|n| !n.is_empty());
    let applied = match designation {
        Some(d) if designated_any => Some(format!("Designation (TBK 101): {}", d.describe())),
        Some(d) => Some(format!(
            "Designation (TBK 101) matched no open liability: {}",
            d.describe()
        )),
        None => None,
    };
    match (note, applied) {
        (Some(n), Some(a)) => Some(format!("{} | {}", n, a)),
        (Some(n), None) => Some(n.to_string()),
        (None, Some(a)) => Some(a),
        (None, None) => None,
    }
}
