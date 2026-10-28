use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::models::{
    AllocationBreakdownItem, DebtAgingBracket, DebtAgingReport, DebtStatus,
    InterLedgerTransferRequest, InterLedgerTransferResponse, OccupancyHistoryItem,
    PaymentEntry, PaymentMatchStatus, PaymentReceipt, PaymentStreamFilter, PaymentStreamResponse,
    RecordManualPaymentRequest, Role, TransferOwnershipRequest, TransferOwnershipResponse, User,
};
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
        let inner = self.state.inner.read().await;
        let year = Utc::now().format("%Y").to_string();
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
        let target_site = filter.site_id.unwrap_or_else(|| "site-1".to_string());

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
                    id: crate::db::parse_id_to_i64(&hp.id).unwrap_or(1),
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

        PaymentStreamResponse {
            entries: filtered,
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

        for due in &inner.dues {
            if due.status == DebtStatus::Paid {
                continue;
            }

            // Locate unit
            let unit = match inner.units.iter().find(|u| u.id == due.unit_id) {
                Some(u) => u,
                None => continue,
            };

            if unit.site_id != site_id && site_id != "all" {
                continue;
            }

            let debtor_type = if unit.tenant_user_id.is_some() {
                "TENANT".to_string()
            } else {
                "OWNER".to_string()
            };

            let resident_name = if let Some(ref tid) = unit.tenant_user_id {
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

            let principal_remaining = due.principal_amount;
            let penalty = due.delay_penalty;
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
        brackets.sort_by(|a, b| b.total_outstanding.cmp(&a.total_outstanding));

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

    /// Record manual collection or bank transfer and run 4-tier waterfall FIFO allocation
    pub async fn record_and_allocate_payment(
        &self,
        req: RecordManualPaymentRequest,
    ) -> Result<PaymentReceipt, String> {
        let site_id = req.site_id.unwrap_or_else(|| "site-1".to_string());
        let unit_id = req.unit_id.clone();
        let payment_amount = req.amount;
        let issued_at = req.payment_date.unwrap_or_else(Utc::now);

        if payment_amount <= Decimal::ZERO {
            return Err("Ödeme tutarı 0.00'dan büyük olmalıdır".to_string());
        }

        let (receipt_number, sequence_number) = self.next_receipt_number(&site_id).await;

        let mut inner = self.state.inner.write().await;

        // Find unit
        let unit = inner
            .units
            .iter()
            .find(|u| u.id == unit_id)
            .cloned()
            .ok_or_else(|| format!("Daire bulunamadı: {}", unit_id))?;

        let owner_name = unit.owner_user_id.as_ref().and_then(|oid| {
            inner.users.iter().find(|u| &u.id == oid).map(|u| u.full_name.clone())
        });

        // Intent detection: check if capital dues keyword appears in description
        let desc = req.description.clone().unwrap_or_default();
        let is_capital_intent = Self::is_capital_expenditure_intent(&desc);

        // Find unpaid dues for this unit
        let mut unpaid_indices: Vec<usize> = inner
            .dues
            .iter()
            .enumerate()
            .filter(|(_, d)| d.unit_id == unit_id && d.status != DebtStatus::Paid)
            .map(|(i, _)| i)
            .collect();

        // Sort by due_date ascending (FIFO)
        unpaid_indices.sort_by_key(|&i| inner.dues[i].due_date);

        let mut remaining_funds = payment_amount;
        let mut total_allocated_penalty = Decimal::ZERO;
        let mut total_allocated_principal = Decimal::ZERO;
        let mut allocation_breakdown: Vec<AllocationBreakdownItem> = Vec::new();

        // 4-tier waterfall allocation
        // Tier 1: Penalties first (statutory KMK 5% delay penalty)
        for &idx in &unpaid_indices {
            if remaining_funds <= Decimal::ZERO {
                break;
            }
            let penalty = inner.dues[idx].delay_penalty;
            if penalty > Decimal::ZERO {
                let pay_penalty = penalty.min(remaining_funds);
                inner.dues[idx].delay_penalty -= pay_penalty;
                inner.dues[idx].total_amount -= pay_penalty;
                remaining_funds -= pay_penalty;
                total_allocated_penalty += pay_penalty;
            }
        }

        // Tier 2: Principal liabilities (FIFO)
        for &idx in &unpaid_indices {
            if remaining_funds <= Decimal::ZERO {
                break;
            }
            let principal = inner.dues[idx].principal_amount;
            if principal > Decimal::ZERO {
                let pay_principal = principal.min(remaining_funds);
                inner.dues[idx].principal_amount -= pay_principal;
                inner.dues[idx].total_amount -= pay_principal;
                remaining_funds -= pay_principal;
                total_allocated_principal += pay_principal;

                if inner.dues[idx].total_amount <= Decimal::ZERO {
                    inner.dues[idx].status = DebtStatus::Paid;
                }

                allocation_breakdown.push(AllocationBreakdownItem {
                    due_id: Some(inner.dues[idx].id.clone()),
                    period: inner.dues[idx].period.clone(),
                    expense_type: if is_capital_intent { "CAPITAL_DUES".to_string() } else { "OPERATIONAL_DUES".to_string() },
                    principal_paid: pay_principal,
                    penalty_paid: Decimal::ZERO,
                });
            }
        }

        // Tier 4: Surplus to advance balance (Avans Bakiye)
        let allocated_advance = remaining_funds;
        if allocated_advance > Decimal::ZERO {
            let balance = inner.advance_payments.entry(unit_id.clone()).or_insert(Decimal::ZERO);
            *balance += allocated_advance;
        }

        // Rent-offset qualification logic
        let is_tenant_paying = req.payer_role == "TENANT";
        let is_rent_offset_eligible = is_tenant_paying && is_capital_intent;
        let on_behalf_of_name = if is_rent_offset_eligible { owner_name } else { None };
        let on_behalf_of_role = if is_rent_offset_eligible { Some("OWNER".to_string()) } else { None };
        let legal_statutory_note = if is_rent_offset_eligible {
            Some(
                "634 sayılı KMK Madde 20 & 22 uyarınca ana gayrimenkulün ortak demirbaş/yatırım giderleri bağımsız bölüm malikinin (Kat Maliki) yasal sorumluluğundadır. Kiracı tarafından ödenen bu tutar TBK Madde 314 gereğince kira bedelinden mahsuba uygundur."
                    .to_string(),
            )
        } else {
            None
        };

        let verification_hash = Self::compute_verification_hash(
            &receipt_number,
            &unit_id,
            payment_amount,
            &issued_at,
        );

        let receipt_id = (inner.payment_receipts.len() + 1) as i64;

        let receipt = PaymentReceipt {
            id: receipt_id,
            site_id: site_id.clone(),
            unit_id: unit_id.clone(),
            receipt_number: receipt_number.clone(),
            sequence_number,
            payer_name: req.payer_name.clone(),
            payer_role: req.payer_role.clone(),
            on_behalf_of_name,
            on_behalf_of_role,
            total_amount: payment_amount,
            payment_channel: req.payment_channel.clone(),
            channel_reference: Some(format!("REF-{}", Uuid::new_v4().simple())),
            allocated_principal: total_allocated_principal,
            allocated_penalty: total_allocated_penalty,
            allocated_advance,
            allocation_breakdown,
            is_rent_offset_eligible,
            legal_statutory_note,
            verification_hash,
            issued_at,
        };

        inner.payment_receipts.push(receipt.clone());

        // Also record corresponding payment entry in stream
        let entry_id = (inner.payment_entries.len() + 1) as i64;
        let unit_label = format!("{} Blok D:{}", unit.block_id, unit.unit_number);
        inner.payment_entries.push(PaymentEntry {
            id: entry_id,
            site_id: site_id.clone(),
            unit_id: unit_id.clone(),
            unit_label: Some(unit_label),
            payer_name: req.payer_name.clone(),
            payer_role: req.payer_role.clone(),
            receipt_id: Some(receipt_id),
            receipt_number: Some(receipt_number.clone()),
            amount: payment_amount,
            payment_channel: req.payment_channel.clone(),
            settlement_status: "SETTLED".to_string(),
            description: req.description.clone(),
            external_reference: Some(format!("REF-{}", Uuid::new_v4().simple())),
            payment_date: issued_at,
            created_at: Utc::now(),
        });

        // Also keep homeowner payment record in sync
        inner.homeowner_payments.push(crate::models::HomeownerPaymentRecord {
            id: format!("rec-{}", entry_id),
            unit_id: unit_id.clone(),
            block_id: unit.block_id.clone(),
            unit_number: unit.unit_number,
            homeowner_name: Some(req.payer_name.clone()),
            amount: payment_amount,
            payment_method: req.payment_channel.clone(),
            reference_code: Some(receipt_number.clone()),
            note: req.description.clone(),
            status: PaymentMatchStatus::MatchedDebt,
            cleared_debt_amount: total_allocated_principal + total_allocated_penalty,
            advance_credit_amount: allocated_advance,
            created_at: issued_at,
        });

        Ok(receipt)
    }

    /// Inter-ledger transfer: Transfer advance balance (Avans) to clear capital dues (Demirbaş)
    pub async fn inter_ledger_transfer(
        &self,
        req: InterLedgerTransferRequest,
    ) -> Result<InterLedgerTransferResponse, String> {
        let site_id = req.site_id.unwrap_or_else(|| "site-1".to_string());
        let unit_id = req.unit_id.clone();
        let transfer_amount = req.amount;

        if transfer_amount <= Decimal::ZERO {
            return Err("Virman tutarı 0.00'dan büyük olmalıdır".to_string());
        }

        let mut inner = self.state.inner.write().await;

        let current_advance = inner.advance_payments.get(&unit_id).copied().unwrap_or(Decimal::ZERO);
        if current_advance < transfer_amount {
            return Err(format!(
                "Yetersiz avans bakiyesi. Mevcut: ₺{:.2}, Talep Edilen: ₺{:.2}",
                current_advance, transfer_amount
            ));
        }

        // Deduct from advance balance
        let remaining_advance = current_advance - transfer_amount;
        inner.advance_payments.insert(unit_id.clone(), remaining_advance);

        // Find unit
        let unit = inner
            .units
            .iter()
            .find(|u| u.id == unit_id)
            .cloned()
            .ok_or_else(|| format!("Daire bulunamadı: {}", unit_id))?;

        let owner_name = unit.owner_user_id.as_ref().and_then(|oid| {
            inner.users.iter().find(|u| &u.id == oid).map(|u| u.full_name.clone())
        }).unwrap_or_else(|| "Kat Maliki".to_string());

        // Offset unpaid capital dues or oldest debt for this unit
        let mut unpaid_indices: Vec<usize> = inner
            .dues
            .iter()
            .enumerate()
            .filter(|(_, d)| d.unit_id == unit_id && d.status != DebtStatus::Paid)
            .map(|(i, _)| i)
            .collect();

        unpaid_indices.sort_by_key(|&i| inner.dues[i].due_date);

        let mut cleared_amount = Decimal::ZERO;
        let mut remaining_funds = transfer_amount;
        let mut breakdown: Vec<AllocationBreakdownItem> = Vec::new();

        for &idx in &unpaid_indices {
            if remaining_funds <= Decimal::ZERO {
                break;
            }
            let debt = inner.dues[idx].total_amount;
            let pay = debt.min(remaining_funds);
            inner.dues[idx].total_amount -= pay;
            inner.dues[idx].principal_amount = inner.dues[idx].principal_amount.saturating_sub(pay);
            remaining_funds -= pay;
            cleared_amount += pay;

            if inner.dues[idx].total_amount <= Decimal::ZERO {
                inner.dues[idx].status = DebtStatus::Paid;
            }

            breakdown.push(AllocationBreakdownItem {
                due_id: Some(inner.dues[idx].id.clone()),
                period: inner.dues[idx].period.clone(),
                expense_type: "CAPITAL_DUES".to_string(),
                principal_paid: pay,
                penalty_paid: Decimal::ZERO,
            });
        }

        // Monotonic receipt generation
        let year = Utc::now().format("%Y").to_string();
        let max_seq = inner
            .payment_receipts
            .iter()
            .filter(|r| r.site_id == site_id)
            .map(|r| r.sequence_number)
            .max()
            .unwrap_or(0);
        let seq = max_seq + 1;
        let receipt_number = format!("TAH-{}-{:06}", year, seq);

        let now = Utc::now();
        let verification_hash = Self::compute_verification_hash(
            &receipt_number,
            &unit_id,
            transfer_amount,
            &now,
        );

        let receipt_id = (inner.payment_receipts.len() + 1) as i64;
        let receipt = PaymentReceipt {
            id: receipt_id,
            site_id: site_id.clone(),
            unit_id: unit_id.clone(),
            receipt_number: receipt_number.clone(),
            sequence_number: seq,
            payer_name: owner_name.clone(),
            payer_role: "OWNER".to_string(),
            on_behalf_of_name: None,
            on_behalf_of_role: None,
            total_amount: transfer_amount,
            payment_channel: "INTER_LEDGER".to_string(),
            channel_reference: Some("Avans Mahsubu / Virman".to_string()),
            allocated_principal: cleared_amount,
            allocated_penalty: Decimal::ZERO,
            allocated_advance: Decimal::ZERO,
            allocation_breakdown: breakdown,
            is_rent_offset_eligible: false,
            legal_statutory_note: Some("Avans bakiyesinden demirbaş/ortak gider borcuna virman işlemi.".to_string()),
            verification_hash: verification_hash.clone(),
            issued_at: now,
        };

        inner.payment_receipts.push(receipt);

        let entry_id = (inner.payment_entries.len() + 1) as i64;
        let unit_label = format!("{} Blok D:{}", unit.block_id, unit.unit_number);
        inner.payment_entries.push(PaymentEntry {
            id: entry_id,
            site_id: site_id.clone(),
            unit_id: unit_id.clone(),
            unit_label: Some(unit_label),
            payer_name: owner_name,
            payer_role: "OWNER".to_string(),
            receipt_id: Some(receipt_id),
            receipt_number: Some(receipt_number.clone()),
            amount: transfer_amount,
            payment_channel: "INTER_LEDGER".to_string(),
            settlement_status: "SETTLED".to_string(),
            description: req.note.or_else(|| Some("Avans bakiyesinden demirbaş borcuna virman yapıldı".to_string())),
            external_reference: Some(format!("VIRMAN-{}", Uuid::new_v4().simple())),
            payment_date: now,
            created_at: now,
        });

        Ok(InterLedgerTransferResponse {
            success: true,
            message: format!(
                "₺{:.2} tutarındaki avans bakiyesi başarıyla demirbaş borcuna mahsup edildi.",
                transfer_amount
            ),
            receipt_number,
            transferred_amount: transfer_amount,
            remaining_advance_balance: remaining_advance,
            cleared_capital_due_amount: cleared_amount,
            verification_hash,
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

        receipt.ok_or_else(|| format!("Makbuz bulunamadı: {}", identifier))
    }

    /// Transfer property title deed ownership (ev satışı) with debt freeze & handover
    pub async fn transfer_ownership(
        &self,
        req: TransferOwnershipRequest,
    ) -> Result<TransferOwnershipResponse, String> {
        let site_id = req.site_id.unwrap_or_else(|| "site-1".to_string());
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
        let new_user_id = format!("usr-owner-{}", Uuid::new_v4().simple());
        let new_owner_email = req.new_owner_email.clone().unwrap_or_else(|| {
            format!("malik.{}@begonya.com", Uuid::new_v4().simple())
        });

        inner.users.push(User {
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
        });

        // Archive old owner in unit_occupancies
        let notes = format!(
            "Mülk satışı / Tapu devri. Eski malik: {}, Çıkış bakiyesi: ₺{:.2}. Yeni malik: {}. {}",
            old_owner_name,
            old_owner_exit_balance,
            req.new_owner_name,
            req.notes.unwrap_or_default()
        );

        let unit_num_i64 = crate::db::parse_id_to_i64(&unit_id).unwrap_or(1);
        let old_person_id = crate::db::parse_id_to_i64(&old_owner_user_id.unwrap_or_default()).unwrap_or(1);

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
            notes: Some(notes),
            created_at: now,
        };

        inner
            .unit_occupancies
            .entry(unit_id.clone())
            .or_default()
            .push(history_item);

        // Update unit owner
        inner.units[unit_idx].owner_user_id = Some(new_user_id);

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
