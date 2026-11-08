use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use sha2::{Digest, Sha256};

use crate::models::{
    AllocationBreakdownItem, DebtAgingBracket, DebtAgingReport, DebtStatus,
    InterLedgerTransferRequest, InterLedgerTransferResponse, OccupancyHistoryItem,
    DuesLiability, PaymentEntry, PaymentMatchStatus, PaymentReceipt, PaymentStreamFilter, PaymentStreamResponse,
    RecordManualPaymentRequest, Role, TransferOwnershipRequest, TransferOwnershipResponse, User,
};
use crate::services::dues_ledger;
use crate::state::AppState;

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
        let mut hasher = Sha256::new();
        let payload = format!(
            "sitepulse:{}:{}:{:.2}:{}",
            receipt_number,
            unit_id,
            total_amount,
            issued_at.to_rfc3339()
        );
        hasher.update(payload.as_bytes());
        format!("{:x}", hasher.finalize())
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
            .filter(|r| r.site_id == site_id)
            .map(|r| r.sequence_number)
            .max()
            .unwrap_or(0);
        let next_seq = max_seq + 1;
        let receipt_no = format!("TAH-{}-{:06}", year, next_seq);
        (receipt_no, next_seq)
    }

    /// Query multi-channel payment stream with rich multi-criteria filters
    pub async fn get_payment_stream(&self, filter: PaymentStreamFilter) -> PaymentStreamResponse {
        let inner = self.state.inner.read().await;
        let target_site = filter.site_id.unwrap_or_default();

        // Gather all payment entries (including synthesizing from homeowner_payments if empty)
        let mut all_entries = inner.payment_entries.clone();

        if all_entries.is_empty() {
            // Synthesize from existing homeowner payments and mock entries
            for hp in &inner.homeowner_payments {
                let unit_label = format!("{} Blok D:{}", hp.block_id, hp.unit_number);
                let settlement_status = match hp.status {
                    PaymentMatchStatus::MatchedDebt
                    | PaymentMatchStatus::MatchedAdvance
                    | PaymentMatchStatus::PartiallyMatched => "SETTLED".to_string(),
                    PaymentMatchStatus::Pending => "UNMATCHED".to_string(),
                };

                all_entries.push(PaymentEntry {
                    id: crate::db::parse_id_to_i64(&hp.id).unwrap_or(0),
                    site_id: target_site.clone(),
                    unit_id: hp.unit_id.clone(),
                    unit_label: Some(unit_label),
                    payer_name: hp.homeowner_name.clone().unwrap_or_else(|| "Bilinmeyen Sakin".to_string()),
                    payer_role: "OWNER".to_string(),
                    receipt_id: None,
                    receipt_number: hp.reference_code.clone().or_else(|| Some(format!("REC-{}", hp.id))),
                    amount: hp.amount,
                    payment_channel: hp.payment_method.clone(),
                    settlement_status,
                    description: hp.note.clone(),
                    external_reference: hp.reference_code.clone(),
                    payment_date: hp.created_at,
                    created_at: hp.created_at,
                });
            }
        }

        // Apply filters
        let search_term = filter.search.as_ref().map(|s| s.to_lowercase());
        let filtered: Vec<PaymentEntry> = all_entries
            .into_iter()
            .filter(|e| {
                if !target_site.is_empty() && e.site_id != target_site && target_site != "all" {
                    return false;
                }
                if let Some(ref ch) = filter.channel {
                    if !ch.is_empty() && &e.payment_channel != ch {
                        return false;
                    }
                }
                if let Some(ref role) = filter.payer_role {
                    if !role.is_empty() && &e.payer_role != role {
                        return false;
                    }
                }
                if let Some(ref status) = filter.settlement_status {
                    if !status.is_empty() && &e.settlement_status != status {
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
                    let matches_unit = e.unit_label.as_ref().map(|l| l.to_lowercase().contains(kw)).unwrap_or(false);
                    let matches_desc = e.description.as_ref().map(|d| d.to_lowercase().contains(kw)).unwrap_or(false);
                    let matches_rcp = e.receipt_number.as_ref().map(|r| r.to_lowercase().contains(kw)).unwrap_or(false);
                    let matches_ref = e.external_reference.as_ref().map(|r| r.to_lowercase().contains(kw)).unwrap_or(false);
                    if !(matches_name || matches_unit || matches_desc || matches_rcp || matches_ref) {
                        return false;
                    }
                }
                true
            })
            .collect();

        let total_count = filtered.len();
        let total_volume: Decimal = filtered.iter().map(|e| e.amount).sum();
        let settled_volume: Decimal = filtered
            .iter()
            .filter(|e| e.settlement_status == "SETTLED")
            .map(|e| e.amount)
            .sum();
        let unmatched_volume: Decimal = filtered
            .iter()
            .filter(|e| e.settlement_status == "UNMATCHED")
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

        PaymentStreamResponse {
            entries: paged_entries,
            total_volume,
            settled_volume,
            unmatched_volume,
            total_count,
        }
    }

    /// Calculate debt aging report grouped by brackets: current, 1-30, 31-60, 60+ days
    pub async fn get_debt_aging_report(&self, site_id: &str) -> DebtAgingReport {
        let inner = self.state.inner.read().await;
        let today = Utc::now().date_naive();

        let mut brackets_map: std::collections::HashMap<(String, String), DebtAgingBracket> =
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
            let debtor_type = if due.debtor_type.eq_ignore_ascii_case(dues_ledger::DEBTOR_OWNER) {
                dues_ledger::DEBTOR_OWNER.to_string()
            } else {
                dues_ledger::DEBTOR_TENANT.to_string()
            };

            let tenant_id = unit.tenant_user_id.as_ref().filter(|_| debtor_type == dues_ledger::DEBTOR_TENANT);
            let resident_name = if let Some(tid) = tenant_id {
                inner.users.iter().find(|u| &u.id == tid).map(|u| u.full_name.clone()).unwrap_or_else(|| "Kiracı".to_string())
            } else if let Some(ref oid) = unit.owner_user_id {
                inner.users.iter().find(|u| &u.id == oid).map(|u| u.full_name.clone()).unwrap_or_else(|| "Kat Maliki".to_string())
            } else {
                "Daire Sakini".to_string()
            };

            let unit_label = format!("{} Blok D:{}", unit.block_id, unit.unit_number);
            let key = (unit.id.clone(), debtor_type.clone());

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

        DebtAgingReport {
            as_of_date: today,
            total_current,
            total_1_30_days,
            total_31_60_days,
            total_60_plus_days,
            total_penalty,
            grand_total,
            brackets,
        }
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
        let payer_role = req.payer_role.trim().to_uppercase();
        if payer_role != dues_ledger::DEBTOR_OWNER && payer_role != dues_ledger::DEBTOR_TENANT {
            return Err(format!("payer_role must be OWNER or TENANT, got '{}'", req.payer_role));
        }
        let payment_channel = normalize_payment_channel(&req.payment_channel)?;
        let idempotency_key = req.idempotency_key.as_deref().map(str::trim).filter(|k| !k.is_empty()).map(str::to_string);
        let unmatched_entry = req.settles_unmatched_entry_id.as_deref().map(str::trim).filter(|k| !k.is_empty()).map(str::to_string);
        let designation = req.designation.clone().filter(|d| !d.is_empty());
        let description_hint = if designation.is_none() && req.designate_from_description { req.description.clone() } else { None };

        let desc = req.description.clone().unwrap_or_default();
        // A tenant paying capital dues explicitly does so on behalf of the owner
        // (KMK 22 rent offset); otherwise a tenant only settles tenant liabilities.
        let on_behalf_of_owner = payer_role == dues_ledger::DEBTOR_TENANT && Self::is_capital_expenditure_intent(&desc);
        let settling_role = if on_behalf_of_owner { dues_ledger::DEBTOR_OWNER } else { payer_role.as_str() };
        let credit_debtor = settling_role.to_string();
        let allocate = |dues: &mut Vec<DuesLiability>| {
            let candidates = dues_ledger::open_dues_for(dues, |_| true, settling_role);
            let designated = dues_ledger::designated_dues(dues, &candidates, designation.as_ref(), description_hint.as_deref());
            let (lines, surplus) = dues_ledger::allocate_with_designation(dues, &candidates, &designated, payment_amount);
            (lines, surplus, !designated.is_empty())
        };

        let (unit, owner_name) = {
            let inner = self.state.inner.read().await;
            if let Some(key) = idempotency_key.as_deref() {
                if let Some(existing) = inner.payment_receipts.iter().find(|r| {
                    r.site_id == site_id && r.channel_reference.as_deref() == Some(&format!("IDEMPOTENCY:{}", key))
                }) {
                    return Ok(existing.clone());
                }
            }
            let unit = inner
                .units
                .iter()
                .find(|u| crate::auth::same_id(&u.id, &unit_id) && crate::auth::same_id(&u.site_id, &site_id))
                .cloned()
                .ok_or_else(|| format!("Daire bulunamadı: {}", unit_id))?;
            let owner_name = unit
                .owner_user_id
                .as_ref()
                .and_then(|oid| inner.users.iter().find(|u| &u.id == oid).map(|u| u.full_name.clone()));
            (unit, owner_name)
        };

        let calc = crate::services::DuesCalculationService::new();
        let today = issued_at.date_naive();
        let ctx = ReceiptContext {
            site_id: site_id.clone(),
            unit_id: unit.id.clone(),
            payer_name: req.payer_name.clone(),
            payer_role: payer_role.clone(),
            payment_channel: payment_channel.clone(),
            amount: payment_amount,
            issued_at,
            on_behalf_of_owner,
            owner_name,
            channel_reference: idempotency_key.as_ref().map(|k| format!("IDEMPOTENCY:{}", k)),
            description: None,
            external_reference: req.external_reference.clone().filter(|r| !r.trim().is_empty()),
        };

        let (receipt, settled_dues, mut entry) = if let Some(ref pool) = self.state.pool {
            let site_num = crate::db::require_id("site", &site_id)?;
            let unit_num = crate::db::require_id("unit", &unit.id)?;
            let mut client = pool.get().await.map_err(|e| format!("Database unavailable: {}", e))?;
            let tx = client.transaction().await.map_err(|e| format!("Database unavailable: {}", e))?;
            let db_err = |e: Box<dyn std::error::Error + Send + Sync>| format!("Payment was not recorded: {}", e);

            if let Some(key) = idempotency_key.as_deref() {
                if let Some(rid) = crate::db::tx_find_idempotent_receipt(&tx, site_num, key).await.map_err(db_err)? {
                    drop(tx);
                    return crate::db::get_payment_receipt_by_id(pool, rid)
                        .await
                        .map_err(db_err)?
                        .ok_or_else(|| "Idempotent receipt not found".to_string());
                }
            }
            if !crate::db::tx_lock_unit(&tx, unit_num, site_num).await.map_err(db_err)? {
                return Err(format!("Daire bulunamadı: {}", unit_id));
            }
            let mut dues: Vec<DuesLiability> = crate::db::tx_load_open_dues(&tx, unit_num)
                .await
                .map_err(db_err)?
                .into_iter()
                .map(|d| calc.calculate_delay_penalty(d, today))
                .collect();
            let (lines, surplus, designated_any) = allocate(&mut dues);

            let sequence = crate::db::tx_next_receipt_sequence(&tx, site_num).await.map_err(db_err)?;
            let mut receipt = build_receipt(&ctx, &dues, &lines, surplus, sequence);
            receipt.id = crate::db::tx_insert_receipt(&tx, &receipt, site_num, unit_num).await.map_err(db_err)?;
            let mut entry = build_entry(&ctx, &unit, &receipt);
            entry.description = entry_description(req.description.as_deref(), designation.as_ref(), designated_any);
            entry.id = match unmatched_entry.as_deref() {
                Some(uid) => {
                    let entry_num = crate::db::require_id("payment entry", uid)?;
                    crate::db::tx_claim_unmatched_entry(&tx, entry_num, site_num, unit_num, payment_amount, receipt.id)
                        .await
                        .map_err(db_err)?
                        .ok_or_else(|| format!("Payment entry {} is not an open UNMATCHED entry of ₺{:.2} for this unit", uid, payment_amount))?
                }
                None => crate::db::tx_insert_entry(&tx, &entry, site_num, unit_num).await.map_err(db_err)?,
            };
            for line in &lines {
                let d = &dues[line.due_index];
                crate::db::tx_settle_due(&tx, entry.id, d, line.settlement.principal, line.settlement.penalty)
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
                crate::db::tx_store_idempotency_key(&tx, site_num, key, receipt.id).await.map_err(db_err)?;
            }
            tx.commit().await.map_err(|e| format!("Payment was not recorded: {}", e))?;
            let touched: Vec<DuesLiability> = lines.iter().map(|l| dues[l.due_index].clone()).collect();
            (receipt, touched, entry)
        } else {
            // No database (tests / demo): same allocation on the in-memory ledger.
            let inner = self.state.inner.read().await;
            if let Some(uid) = unmatched_entry.as_deref() {
                let open = inner.homeowner_payments.iter().any(|h| {
                    h.id == uid && h.status == PaymentMatchStatus::Pending && h.amount == payment_amount && crate::auth::same_id(&h.unit_id, &unit.id)
                });
                if !open {
                    return Err(format!("Payment entry {} is not an open UNMATCHED entry of ₺{:.2} for this unit", uid, payment_amount));
                }
            }
            let mut dues: Vec<DuesLiability> = inner
                .dues
                .iter()
                .filter(|d| d.status != DebtStatus::Paid && crate::auth::same_id(&d.unit_id, &unit.id))
                .cloned()
                .map(|d| calc.calculate_delay_penalty(d, today))
                .collect();
            let next_seq = inner.payment_receipts.iter().filter(|r| r.site_id == site_id).map(|r| r.sequence_number).max().unwrap_or(0) + 1;
            let next_receipt_id = inner.payment_receipts.iter().map(|r| r.id).max().unwrap_or(0) + 1;
            let next_entry_id = inner.payment_entries.iter().map(|e| e.id).max().unwrap_or(0) + 1;
            drop(inner);
            let (lines, surplus, designated_any) = allocate(&mut dues);
            let mut receipt = build_receipt(&ctx, &dues, &lines, surplus, next_seq);
            receipt.id = next_receipt_id;
            let mut entry = build_entry(&ctx, &unit, &receipt);
            entry.id = unmatched_entry.as_deref().and_then(crate::db::parse_id_to_i64).unwrap_or(next_entry_id);
            entry.description = entry_description(req.description.as_deref(), designation.as_ref(), designated_any);
            let touched: Vec<DuesLiability> = lines.iter().map(|l| dues[l.due_index].clone()).collect();
            (receipt, touched, entry)
        };

        // Apply the committed result to the in-memory view.
        let mut inner = self.state.inner.write().await;
        for settled in &settled_dues {
            if let Some(d) = inner.dues.iter_mut().find(|d| crate::auth::same_id(&d.id, &settled.id)) {
                let unit_key = d.unit_id.clone();
                *d = settled.clone();
                d.unit_id = unit_key;
            }
        }
        if receipt.allocated_advance > Decimal::ZERO {
            *inner.advance_payments.entry(unit.id.clone()).or_insert(Decimal::ZERO) += receipt.allocated_advance;
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
        if let Some(existing) = inner.payment_entries.iter_mut().find(|e| unmatched_entry.is_some() && e.id == entry.id) {
            existing.settlement_status = "SETTLED".to_string();
            existing.receipt_id = entry.receipt_id;
            existing.receipt_number = entry.receipt_number.clone();
        } else {
            if unmatched_entry.is_some() {
                // The pending row lives only in the legacy homeowner view.
                entry.external_reference = entry.external_reference.clone().or_else(|| Some(homeowner_id.clone()));
            }
            inner.payment_entries.push(entry);
        }
        if let Some(h) = inner.homeowner_payments.iter_mut().find(|h| h.id == homeowner_id) {
            h.status = match_status;
            h.cleared_debt_amount = cleared;
            h.advance_credit_amount = receipt.allocated_advance;
            h.reference_code = h.reference_code.clone().or_else(|| Some(receipt.receipt_number.clone()));
        } else {
            inner.homeowner_payments.push(crate::models::HomeownerPaymentRecord {
                id: homeowner_id,
                unit_id: unit.id.clone(),
                block_id: unit.block_id.clone(),
                unit_number: unit.unit_number,
                homeowner_name: Some(req.payer_name.clone()),
                amount: payment_amount,
                payment_method: payment_channel,
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

    /// Inter-ledger transfer: Transfer advance balance (Avans) to clear capital dues (Demirbaş)
    pub async fn inter_ledger_transfer(
        &self,
        req: InterLedgerTransferRequest,
    ) -> Result<InterLedgerTransferResponse, String> {
        let site_id = req.site_id.clone().filter(|s| !s.trim().is_empty()).ok_or_else(|| "site_id is required".to_string())?;
        let unit_id = req.unit_id.clone();
        let transfer_amount = req.amount;
        if transfer_amount <= Decimal::ZERO || transfer_amount.scale() > 2 {
            return Err("Virman tutarı 0.00'dan büyük olmalıdır".to_string());
        }

        let (unit, owner_name) = {
            let inner = self.state.inner.read().await;
            let unit = inner
                .units
                .iter()
                .find(|u| crate::auth::same_id(&u.id, &unit_id) && crate::auth::same_id(&u.site_id, &site_id))
                .cloned()
                .ok_or_else(|| format!("Daire bulunamadı: {}", unit_id))?;
            let owner_name = unit
                .owner_user_id
                .as_ref()
                .and_then(|oid| inner.users.iter().find(|u| &u.id == oid).map(|u| u.full_name.clone()))
                .unwrap_or_else(|| "Kat Maliki".to_string());
            (unit, owner_name)
        };
        let now = Utc::now();
        let calc = crate::services::DuesCalculationService::new();
        let ctx = ReceiptContext {
            site_id: site_id.clone(),
            unit_id: unit.id.clone(),
            payer_name: owner_name.clone(),
            payer_role: dues_ledger::DEBTOR_OWNER.to_string(),
            payment_channel: "INTER_LEDGER".to_string(),
            amount: Decimal::ZERO,
            issued_at: now,
            on_behalf_of_owner: false,
            owner_name: None,
            channel_reference: Some("Avans Mahsubu / Virman".to_string()),
            description: None,
            external_reference: None,
        };
        let insufficient = |have: Decimal| {
            format!("Yetersiz avans bakiyesi. Mevcut: ₺{:.2}, Talep Edilen: ₺{:.2}", have, transfer_amount)
        };

        // Only the amount that actually clears debt leaves the advance balance.
        let (receipt, settled, entry, remaining_advance) = if let Some(ref pool) = self.state.pool {
            let site_num = crate::db::require_id("site", &site_id)?;
            let unit_num = crate::db::require_id("unit", &unit.id)?;
            let mut client = pool.get().await.map_err(|e| format!("Database unavailable: {}", e))?;
            let tx = client.transaction().await.map_err(|e| format!("Database unavailable: {}", e))?;
            let db_err = |e: Box<dyn std::error::Error + Send + Sync>| format!("Transfer was not recorded: {}", e);
            if !crate::db::tx_lock_unit(&tx, unit_num, site_num).await.map_err(db_err)? {
                return Err(format!("Daire bulunamadı: {}", unit_id));
            }
            let owner_credit = crate::db::tx_lock_advance(&tx, unit_num, dues_ledger::DEBTOR_OWNER).await.map_err(db_err)?;
            if owner_credit < transfer_amount {
                return Err(insufficient(owner_credit));
            }
            let mut dues: Vec<DuesLiability> = crate::db::tx_load_open_dues(&tx, unit_num)
                .await
                .map_err(db_err)?
                .into_iter()
                .map(|d| calc.calculate_delay_penalty(d, now.date_naive()))
                .collect();
            let candidates = dues_ledger::open_dues_for(&dues, |_| true, dues_ledger::DEBTOR_OWNER);
            let (lines, unused) = dues_ledger::allocate_waterfall(&mut dues, &candidates, transfer_amount);
            let cleared = transfer_amount - unused;
            if cleared <= Decimal::ZERO {
                return Err("Mahsup edilecek açık borç bulunamadı".to_string());
            }
            let seq = crate::db::tx_next_receipt_sequence(&tx, site_num).await.map_err(db_err)?;
            let mut c = ctx;
            c.amount = cleared;
            let mut receipt = build_receipt(&c, &dues, &lines, Decimal::ZERO, seq);
            receipt.legal_statutory_note = Some("Avans bakiyesinden demirbaş/ortak gider borcuna virman işlemi.".to_string());
            receipt.id = crate::db::tx_insert_receipt(&tx, &receipt, site_num, unit_num).await.map_err(db_err)?;
            let mut entry = build_entry(&c, &unit, &receipt);
            entry.description = req.note.clone().or_else(|| Some("Avans bakiyesinden borca virman yapıldı".to_string()));
            entry.id = crate::db::tx_insert_entry(&tx, &entry, site_num, unit_num).await.map_err(db_err)?;
            for line in &lines {
                crate::db::tx_settle_due(&tx, entry.id, &dues[line.due_index], line.settlement.principal, line.settlement.penalty)
                    .await
                    .map_err(db_err)?;
            }
            crate::db::tx_debit_advance(
                &tx,
                unit_num,
                dues_ledger::DEBTOR_OWNER,
                "VIRMAN_DEBIT",
                cleared,
                Some(&receipt.receipt_number),
                Some("Borç mahsubu (virman)"),
            )
            .await
            .map_err(db_err)?;
            tx.commit().await.map_err(|e| format!("Transfer was not recorded: {}", e))?;
            let touched: Vec<DuesLiability> = lines.iter().map(|l| dues[l.due_index].clone()).collect();
            let unit_total_left = {
                let inner = self.state.inner.read().await;
                inner.advance_payments.get(&unit.id).copied().unwrap_or(Decimal::ZERO) - cleared
            };
            (receipt, touched, entry, unit_total_left)
        } else {
            let inner = self.state.inner.read().await;
            let have = inner.advance_payments.get(&unit.id).copied().unwrap_or(Decimal::ZERO);
            if have < transfer_amount {
                return Err(insufficient(have));
            }
            let mut dues: Vec<DuesLiability> = inner
                .dues
                .iter()
                .filter(|d| d.status != DebtStatus::Paid && crate::auth::same_id(&d.unit_id, &unit.id))
                .cloned()
                .collect();
            let seq = inner.payment_receipts.iter().filter(|r| r.site_id == site_id).map(|r| r.sequence_number).max().unwrap_or(0) + 1;
            let rid = inner.payment_receipts.iter().map(|r| r.id).max().unwrap_or(0) + 1;
            let eid = inner.payment_entries.iter().map(|e| e.id).max().unwrap_or(0) + 1;
            drop(inner);
            let candidates = dues_ledger::open_dues_for(&dues, |_| true, dues_ledger::DEBTOR_OWNER);
            let (lines, unused) = dues_ledger::allocate_waterfall(&mut dues, &candidates, transfer_amount);
            let cleared = transfer_amount - unused;
            if cleared <= Decimal::ZERO {
                return Err("Mahsup edilecek açık borç bulunamadı".to_string());
            }
            let mut c = ctx;
            c.amount = cleared;
            let mut receipt = build_receipt(&c, &dues, &lines, Decimal::ZERO, seq);
            receipt.id = rid;
            receipt.legal_statutory_note = Some("Avans bakiyesinden demirbaş/ortak gider borcuna virman işlemi.".to_string());
            let mut entry = build_entry(&c, &unit, &receipt);
            entry.id = eid;
            entry.description = req.note.clone().or_else(|| Some("Avans bakiyesinden borca virman yapıldı".to_string()));
            let touched: Vec<DuesLiability> = lines.iter().map(|l| dues[l.due_index].clone()).collect();
            (receipt, touched, entry, have - cleared)
        };

        let mut inner = self.state.inner.write().await;
        for d in &settled {
            if let Some(m) = inner.dues.iter_mut().find(|x| crate::auth::same_id(&x.id, &d.id)) {
                let key = m.unit_id.clone();
                *m = d.clone();
                m.unit_id = key;
            }
        }
        inner.advance_payments.insert(unit.id.clone(), remaining_advance.max(Decimal::ZERO));
        inner.payment_receipts.push(receipt.clone());
        inner.payment_entries.push(entry);

        Ok(InterLedgerTransferResponse {
            success: true,
            message: format!("₺{:.2} tutarındaki avans bakiyesi başarıyla borca mahsup edildi.", receipt.total_amount),
            receipt_number: receipt.receipt_number.clone(),
            transferred_amount: receipt.total_amount,
            remaining_advance_balance: remaining_advance.max(Decimal::ZERO),
            cleared_capital_due_amount: receipt.allocated_principal + receipt.allocated_penalty,
            verification_hash: receipt.verification_hash,
        })
    }

    /// Retrieve digital receipt by ID or receipt number
    pub async fn get_receipt(&self, site_id: &str, identifier: &str) -> Result<PaymentReceipt, String> {
        let inner = self.state.inner.read().await;

        let num_id = identifier.parse::<i64>().ok();

        let receipt = inner
            .payment_receipts
            .iter()
            .find(|r| {
                if !site_id.is_empty() && r.site_id != site_id && site_id != "all" {
                    return false;
                }
                r.receipt_number == identifier
                    || num_id.map(|n| r.id == n).unwrap_or(false)
            })
            .cloned();

        if let Some(r) = receipt {
            return Ok(r);
        }

        if let Some(ref pool) = self.state.pool {
            if let Ok(client) = pool.get().await {
                let site_id_num = crate::db::require_id("entity", site_id)?;
                let row_res = if let Some(n) = num_id {
                    client.query_opt(
                        "SELECT id, site_id, unit_id, receipt_number, sequence_number, payer_name, payer_role, on_behalf_of_name, on_behalf_of_role, total_amount, payment_channel, channel_reference, allocated_principal, allocated_penalty, allocated_advance, allocation_breakdown::text, is_rent_offset_eligible, legal_statutory_note, verification_hash, issued_at FROM payment_receipts WHERE (site_id = $1 OR $1 = 0) AND (id = $2 OR receipt_number = $3)",
                        &[&site_id_num, &n, &identifier],
                    ).await
                } else {
                    client.query_opt(
                        "SELECT id, site_id, unit_id, receipt_number, sequence_number, payer_name, payer_role, on_behalf_of_name, on_behalf_of_role, total_amount, payment_channel, channel_reference, allocated_principal, allocated_penalty, allocated_advance, allocation_breakdown::text, is_rent_offset_eligible, legal_statutory_note, verification_hash, issued_at FROM payment_receipts WHERE (site_id = $1 OR $1 = 0) AND receipt_number = $2",
                        &[&site_id_num, &identifier],
                    ).await
                };

                if let Ok(Some(row)) = row_res {
                    let breakdown_str: String = row.get(15);
                    return Ok(PaymentReceipt {
                        id: row.get(0),
                        site_id: row.get::<_, i64>(1).to_string(),
                        unit_id: row.get::<_, i64>(2).to_string(),
                        receipt_number: row.get(3),
                        sequence_number: row.get(4),
                        payer_name: row.get(5),
                        payer_role: row.get(6),
                        on_behalf_of_name: row.get(7),
                        on_behalf_of_role: row.get(8),
                        total_amount: row.get(9),
                        payment_channel: row.get(10),
                        channel_reference: row.get(11),
                        allocated_principal: row.get(12),
                        allocated_penalty: row.get(13),
                        allocated_advance: row.get(14),
                        allocation_breakdown: serde_json::from_str(&breakdown_str).unwrap_or_default(),
                        is_rent_offset_eligible: row.get(16),
                        legal_statutory_note: row.get(17),
                        verification_hash: row.get(18),
                        issued_at: row.get(19),
                    });
                }
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
        let transfer_date = req.transfer_date.unwrap_or_else(|| now.date_naive());

        let mut inner = self.state.inner.write().await;

        // Find unit
        let unit_idx = inner
            .units
            .iter()
            .position(|u| u.id == unit_id)
            .ok_or_else(|| format!("Daire bulunamadı: {}", unit_id))?;

        let old_owner_user_id = inner.units[unit_idx].owner_user_id.clone();
        let old_owner_name = old_owner_user_id
            .as_ref()
            .and_then(|oid| inner.users.iter().find(|u| &u.id == oid).map(|u| u.full_name.clone()))
            .unwrap_or_else(|| "Eski Kat Maliki".to_string());

        // Calculate exit balance for old owner (all unpaid debts as of transfer date)
        let old_owner_exit_balance: Decimal = inner
            .dues
            .iter()
            .filter(|d| d.unit_id == unit_id && d.status != DebtStatus::Paid)
            .map(|d| d.total_amount)
            .sum();

        // Register new owner user
        let max_u = inner.users.iter().filter_map(|u| crate::db::parse_id_to_i64(&u.id)).max().unwrap_or(0);
        let new_user_id = (max_u + 1).to_string();
        let new_owner_email = req.new_owner_email.clone().unwrap_or_else(|| {
            format!("owner.{}@sitepulse.local", new_user_id)
        });

        let new_user = User {
            id: new_user_id.clone(),
            site_id: site_id.clone(),
            full_name: req.new_owner_name.clone(),
            email: new_owner_email.clone(),
            phone: req.new_owner_phone.clone().unwrap_or_default(),
            password_hash: Some("ARGON2_TEMP_HASH".to_string()),
            role: Role::HomeOwner,
            must_change_password: true,
            auth_provider: "LOCAL".to_string(),
            google_sub: None,
            avatar_url: None,
            created_at: now,
            person_id: None,
        };

        inner.users.push(new_user.clone());

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

        let history_item = OccupancyHistoryItem {
            id: now.timestamp_millis(),
            unit_id: unit_num_i64,
            person_id: old_person_id,
            person_name: old_owner_name.clone(),
            person_phone: None,
            person_email: None,
            role: "OWNER".to_string(),
            start_date: "2020-01-01".to_string(),
            end_date: Some(transfer_date.to_string()),
            is_active: false,
            exit_balance: old_owner_exit_balance,
            notes: Some(notes.clone()),
            created_at: now,
        };

        inner
            .unit_occupancies
            .entry(unit_id.clone())
            .or_default()
            .push(history_item);

        // Update unit owner
        inner.units[unit_idx].owner_user_id = Some(new_user_id);

        drop(inner);

        if let Some(ref pool) = self.state.pool {
            crate::db::transfer_unit_ownership_db(
                pool,
                &unit_id,
                &new_user,
                transfer_date,
                old_owner_exit_balance,
                req.notes.as_deref(),
            )
            .await.map_err(|e| e.to_string())?;
        }

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
    payer_role: String,
    payment_channel: String,
    amount: Decimal,
    issued_at: DateTime<Utc>,
    on_behalf_of_owner: bool,
    owner_name: Option<String>,
    channel_reference: Option<String>,
    description: Option<String>,
    external_reference: Option<String>,
}

const RENT_OFFSET_NOTE: &str = "634 sayılı KMK Madde 20 & 22 uyarınca ana gayrimenkulün ortak demirbaş/yatırım giderleri bağımsız bölüm malikinin (Kat Maliki) yasal sorumluluğundadır. Kiracı tarafından ödenen bu tutar TBK Madde 314 gereğince kira bedelinden mahsuba uygundur.";

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
                expense_type: d.expense_type.clone(),
                principal_paid: l.settlement.principal,
                penalty_paid: l.settlement.penalty,
            }
        })
        .collect();
    let allocated_principal: Decimal = lines.iter().map(|l| l.settlement.principal).sum();
    let allocated_penalty: Decimal = lines.iter().map(|l| l.settlement.penalty).sum();
    let paid_capital = allocation_breakdown.iter().any(|b| b.expense_type == dues_ledger::EXPENSE_CAPITAL);
    let is_rent_offset_eligible = ctx.on_behalf_of_owner && paid_capital;
    PaymentReceipt {
        id: 0,
        site_id: ctx.site_id.clone(),
        unit_id: ctx.unit_id.clone(),
        verification_hash: PaymentTrackingService::compute_verification_hash(&receipt_number, &ctx.unit_id, ctx.amount, &ctx.issued_at),
        receipt_number,
        sequence_number,
        payer_name: ctx.payer_name.clone(),
        payer_role: ctx.payer_role.clone(),
        on_behalf_of_name: if is_rent_offset_eligible { ctx.owner_name.clone() } else { None },
        on_behalf_of_role: if is_rent_offset_eligible { Some("OWNER".to_string()) } else { None },
        total_amount: ctx.amount,
        payment_channel: ctx.payment_channel.clone(),
        channel_reference: ctx.channel_reference.clone().or_else(|| Some(format!("REF-{}", sequence_number))),
        allocated_principal,
        allocated_penalty,
        allocated_advance: surplus,
        allocation_breakdown,
        is_rent_offset_eligible,
        legal_statutory_note: if is_rent_offset_eligible { Some(RENT_OFFSET_NOTE.to_string()) } else { None },
        issued_at: ctx.issued_at,
    }
}

fn build_entry(ctx: &ReceiptContext, unit: &crate::models::IndependentUnit, receipt: &PaymentReceipt) -> PaymentEntry {
    PaymentEntry {
        id: 0,
        site_id: ctx.site_id.clone(),
        unit_id: ctx.unit_id.clone(),
        unit_label: Some(format!("{} Blok D:{}", unit.block_id, unit.unit_number)),
        payer_name: ctx.payer_name.clone(),
        payer_role: ctx.payer_role.clone(),
        receipt_id: if receipt.id > 0 { Some(receipt.id) } else { None },
        receipt_number: Some(receipt.receipt_number.clone()),
        amount: ctx.amount,
        payment_channel: ctx.payment_channel.clone(),
        settlement_status: "SETTLED".to_string(),
        description: ctx.description.clone(),
        external_reference: ctx.external_reference.clone().or_else(|| receipt.channel_reference.clone()),
        payment_date: ctx.issued_at,
        created_at: Utc::now(),
    }
}

/// Canonical `payment_channel` (the V14 vocabulary) for a client-supplied value.
pub fn normalize_payment_channel(raw: &str) -> Result<String, String> {
    const KNOWN: [&str; 7] = ["VIRTUAL_IBAN", "BANK_STATEMENT", "BANK_TRANSFER", "CREDIT_CARD", "MANUAL_CASH", "INTER_LEDGER", "ONLINE_PAYMENT"];
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
    } else if folded.contains("FAST") || folded.contains("EFT") || folded.contains("HAVALE") || folded.contains("TRANSFER") {
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
fn entry_description(note: Option<&str>, designation: Option<&crate::models::PaymentDesignation>, designated_any: bool) -> Option<String> {
    let note = note.map(str::trim).filter(|n| !n.is_empty());
    let applied = match designation {
        Some(d) if designated_any => Some(format!("Designation (TBK 101): {}", d.describe())),
        Some(d) => Some(format!("Designation (TBK 101) matched no open liability: {}", d.describe())),
        None => None,
    };
    match (note, applied) {
        (Some(n), Some(a)) => Some(format!("{} | {}", n, a)),
        (Some(n), None) => Some(n.to_string()),
        (None, Some(a)) => Some(a),
        (None, None) => None,
    }
}
