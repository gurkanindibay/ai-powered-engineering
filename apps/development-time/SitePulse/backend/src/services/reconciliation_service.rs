use chrono::NaiveDate;
use regex::Regex;
use rust_decimal::Decimal;

use crate::models::{
    BankTransactionItem, DuesLiability, IndependentUnit, ReconciliationMatch, ReconciliationStatus,
    User,
};
use crate::services::dues_calculation_service::DuesCalculationService;
use std::sync::LazyLock;

/// Compiled once; `all_patterns_compile` guarantees it is `Ok`.
static BLOCK_THEN_FLAT_RE: LazyLock<Result<Regex, regex::Error>> = LazyLock::new(|| {
    Regex::new(
        r"(?i)\b([A-Z0-9]+)\s*blok\b.*?\b(?:d[:\.\s-]*|daire[:\.\s-]*|no[:\.\s-]*|k[:\.\s-]*\d+\s+d[:\.\s-]*)(\d+)\b",
    )
});
/// Compiled once; `all_patterns_compile` guarantees it is `Ok`.
static BLOK_PREFIX_FLAT_RE: LazyLock<Result<Regex, regex::Error>> = LazyLock::new(|| {
    Regex::new(r"(?i)\bblok\s*([A-Z0-9]+)\b.*?\b(?:d[:\.\s-]*|daire[:\.\s-]*)(\d+)\b")
});
/// Compiled once; `all_patterns_compile` guarantees it is `Ok`.
static COMPACT_BLOCK_FLAT_RE: LazyLock<Result<Regex, regex::Error>> =
    LazyLock::new(|| Regex::new(r"(?i)\b([A-Z])\s*[-/]\s*(\d+)\b"));
/// Compiled once; `all_patterns_compile` guarantees it is `Ok`.
static FLAT_ONLY_RE: LazyLock<Result<Regex, regex::Error>> =
    LazyLock::new(|| Regex::new(r"(?i)\b(?:d[:\.\s-]*|daire[:\.\s-]*|no[:\.\s-]*)(\d+)\b"));

pub struct ReconciliationService {
    dues_service: DuesCalculationService,
}

impl Default for ReconciliationService {
    fn default() -> Self {
        Self::new()
    }
}

impl ReconciliationService {
    pub fn new() -> Self {
        Self {
            dues_service: DuesCalculationService::new(),
        }
    }

    /// Reconciles parsed bank transactions against site units, resident roster, and outstanding dues.
    pub fn reconcile_transactions(
        &self,
        transactions: &[BankTransactionItem],
        units: &[IndependentUnit],
        users: &[User],
        dues: &[DuesLiability],
        evaluation_date: NaiveDate,
    ) -> Vec<ReconciliationMatch> {
        self.reconcile_transactions_with_site(
            None,
            transactions,
            units,
            users,
            dues,
            evaluation_date,
        )
    }

    pub fn reconcile_transactions_with_site(
        &self,
        site_id: Option<&str>,
        transactions: &[BankTransactionItem],
        units: &[IndependentUnit],
        users: &[User],
        dues: &[DuesLiability],
        evaluation_date: NaiveDate,
    ) -> Vec<ReconciliationMatch> {
        let mut results = Vec::new();

        for txn in transactions {
            let matched = self.match_single_transaction_with_site(
                site_id,
                txn,
                units,
                users,
                dues,
                evaluation_date,
            );
            results.push(matched);
        }

        results
    }

    pub fn match_single_transaction(
        &self,
        txn: &BankTransactionItem,
        units: &[IndependentUnit],
        users: &[User],
        dues: &[DuesLiability],
        evaluation_date: NaiveDate,
    ) -> ReconciliationMatch {
        self.match_single_transaction_with_site(None, txn, units, users, dues, evaluation_date)
    }

    fn match_single_transaction_with_site(
        &self,
        site_override: Option<&str>,
        txn: &BankTransactionItem,
        units: &[IndependentUnit],
        users: &[User],
        dues: &[DuesLiability],
        evaluation_date: NaiveDate,
    ) -> ReconciliationMatch {
        let desc = &txn.description;

        // 0. Match by Virtual IBAN (Sanal IBAN)
        let mut matched_by_virtual_iban = false;
        let mut matched_unit: Option<&IndependentUnit> = None;

        for unit in units {
            if let Some(viban) = &unit.virtual_iban {
                let clean_viban = viban.replace(' ', "").to_uppercase();
                let clean_desc = desc.replace(' ', "").to_uppercase();
                let clean_ref = txn
                    .reference_no
                    .as_deref()
                    .unwrap_or("")
                    .replace(' ', "")
                    .to_uppercase();

                if clean_desc.contains(&clean_viban) || clean_ref.contains(&clean_viban) {
                    matched_unit = Some(unit);
                    matched_by_virtual_iban = true;
                    break;
                }
            }
        }

        // 1. If not matched by Virtual IBAN, extract block and flat
        if matched_unit.is_none() {
            let extracted_unit = Self::extract_block_and_flat(desc);
            if let Some((ref blk, unit_no)) = extracted_unit {
                let clean_blk = blk
                    .to_uppercase()
                    .replace("BLOK", "")
                    .replace("BLOCK", "")
                    .replace(['-', '_', ' '], "");
                matched_unit = units.iter().find(|u| {
                    let u_blk = u
                        .block_id
                        .to_uppercase()
                        .replace("BLOK", "")
                        .replace("BLOCK", "")
                        .replace(['-', '_', ' '], "");
                    (u_blk == clean_blk || u.block_id.eq_ignore_ascii_case(blk))
                        && u.unit_number == unit_no
                });
            }

            // If block wasn't extracted but flat was, try matching by flat number alone if unique
            if matched_unit.is_none() {
                if let Some(flat_no) = Self::extract_flat_only(desc) {
                    let candidate_units: Vec<&IndependentUnit> =
                        units.iter().filter(|u| u.unit_number == flat_no).collect();
                    if candidate_units.len() == 1 {
                        matched_unit = Some(candidate_units[0]);
                    }
                }
            }
        }

        // 2. Extract resident name or find resident matching description
        let mut matched_user: Option<&User> = None;
        for user in users {
            if Self::text_contains_name(desc, &user.full_name) {
                matched_user = Some(user);
                break;
            }
        }

        // If unit was found, verify if owner matches
        if let (Some(unit), None) = (matched_unit, matched_user) {
            if let Some(owner_id) = unit.owner_user_id.as_deref() {
                matched_user = users.iter().find(|u| u.id == owner_id);
            }
        }

        // 3. Find outstanding dues for the unit
        let mut matched_due: Option<DuesLiability> = None;
        let mut outstanding_balance: Option<Decimal> = None;
        let mut amount_matches = false;

        let is_already_processed = false;

        if let Some(unit) = matched_unit {
            // Find pending or overdue dues for this unit
            let unit_dues: Vec<&DuesLiability> = dues
                .iter()
                .filter(|d| d.unit_id == unit.id && d.status.is_collectable())
                .collect();

            if let Some(first_due) = unit_dues.first() {
                // Calculate dynamic KMK penalty up to evaluation date
                let evaluated = self
                    .dues_service
                    .calculate_delay_penalty((*first_due).clone(), evaluation_date);
                let balance = evaluated.total_amount;
                outstanding_balance = Some(balance);
                matched_due = Some(evaluated);

                if txn.amount == balance {
                    amount_matches = true;
                }
            } else {
                // No outstanding dues for this unit: match payment as advance payment (Avans Bakiye)
                outstanding_balance = Some(Decimal::ZERO);
            }
        }

        // 4. Calculate Confidence Score & Status
        let mut confidence: u8 = 0;
        let has_unit = matched_unit.is_some();
        let has_name = matched_user.is_some()
            && Self::text_contains_name(desc, &matched_user.unwrap().full_name);
        let is_advance_match = matched_unit.is_some() && matched_due.is_none();

        if is_already_processed {
            confidence = 100;
        } else if matched_by_virtual_iban {
            // Flat-Specific Virtual IBAN allocation is 100% confident by architectural design
            confidence = 100;
        } else if is_advance_match && (has_unit && has_name) {
            confidence = 100;
        } else if is_advance_match && has_unit {
            confidence = 90;
        } else if has_unit && amount_matches {
            // Unit and exact amount match: 100% confidence
            confidence = 100;
        } else if has_unit && has_name && amount_matches {
            confidence = 100;
        } else if has_unit && has_name {
            confidence = 90;
        } else if has_unit {
            confidence = 80;
        } else if has_name {
            confidence = 70;
        }

        let (status, notes) = if is_already_processed {
            (
                ReconciliationStatus::AlreadyProcessed,
                Some("Bu dairenin aidatı daha önce zaten yüklenmiş / ödenmiştir. Mükerrer tahsilat önlendi.".to_string()),
            )
        } else if confidence >= 70 {
            (
                ReconciliationStatus::PendingApproval,
                if is_advance_match {
                    Some(format!(
                        "Aktif aidat borcu bulunmuyor • ₺{} tutarındaki ödeme avans bakiyesi (Avans Bakiye) olarak eşleştirildi.",
                        txn.amount
                    ))
                } else if matched_by_virtual_iban {
                    if txn.amount > outstanding_balance.unwrap_or(Decimal::ZERO) {
                        let surplus = txn.amount - outstanding_balance.unwrap_or(Decimal::ZERO);
                        Some(format!(
                            "100% Match via Virtual IBAN. Settled; ₺{} surplus credited to advance payment.",
                            surplus
                        ))
                    } else {
                        Some("100% Match via Flat-Specific Virtual IBAN (Sanal IBAN). Zero manual narrative entry required.".to_string())
                    }
                } else if amount_matches {
                    Some(
                        "Exact amount matches outstanding dues balance (including KMK penalty)"
                            .to_string(),
                    )
                } else if txn.amount > outstanding_balance.unwrap_or(Decimal::ZERO) {
                    let surplus = txn.amount - outstanding_balance.unwrap_or(Decimal::ZERO);
                    Some(format!(
                        "₺{} aidat borcu kapatılacak, artan ₺{} avans bakiyesine aktarılacak.",
                        outstanding_balance.unwrap_or(Decimal::ZERO),
                        surplus
                    ))
                } else if has_unit {
                    Some("Unit identified from transfer narrative".to_string())
                } else {
                    None
                },
            )
        } else {
            (ReconciliationStatus::Unmatched, None)
        };

        let match_id = format!("MATCH-{}", txn.transaction_id);

        let site_id = site_override
            .map(|s| s.to_string())
            .or_else(|| matched_unit.map(|u| u.site_id.clone()))
            .or_else(|| units.first().map(|u| u.site_id.clone()))
            // Unattributable: no tenant is guessed, so no tenant can see it.
            .unwrap_or_default();

        ReconciliationMatch {
            match_id,
            site_id,
            transaction: txn.clone(),
            matched_unit_id: matched_unit.map(|u| u.id.clone()),
            matched_block: matched_unit.map(|u| u.block_id.clone()),
            matched_unit_number: matched_unit.map(|u| u.unit_number),
            matched_resident_name: matched_user.map(|u| u.full_name.clone()),
            confidence_score: confidence,
            matched_due_id: matched_due.map(|d| d.id),
            outstanding_balance,
            amount_matches_balance: amount_matches,
            status,
            status_code: status.as_str().to_string(),
            notes,
            assigned_unit_id: None,
            assigned_debtor_role: None,
        }
    }

    /// Extracts Block and Flat from text.
    /// Handles patterns like:
    /// - "A BLOK D:14"
    /// - "A Blok D.14"
    /// - "A Blok Daire 14"
    /// - "Blok A D:14"
    /// - "A-14"
    pub fn extract_block_and_flat(text: &str) -> Option<(String, i32)> {
        // Pattern 1: [A-Z0-9]+ BLOK D:(\d+) or DAIRE (\d+)
        let re1 = BLOCK_THEN_FLAT_RE.as_ref().ok()?;

        if let Some(caps) = re1.captures(text) {
            let blk = caps.get(1)?.as_str().to_uppercase();
            let flat: i32 = caps.get(2)?.as_str().parse().ok()?;
            return Some((blk, flat));
        }

        // Pattern 2: BLOK [A-Z0-9]+ D:(\d+)
        let re2 = BLOK_PREFIX_FLAT_RE.as_ref().ok()?;

        if let Some(caps) = re2.captures(text) {
            let blk = caps.get(1)?.as_str().to_uppercase();
            let flat: i32 = caps.get(2)?.as_str().parse().ok()?;
            return Some((blk, flat));
        }

        // Pattern 3: Compact format e.g. "A/14" or "A-14"
        let re3 = COMPACT_BLOCK_FLAT_RE.as_ref().ok()?;
        if let Some(caps) = re3.captures(text) {
            let blk = caps.get(1)?.as_str().to_uppercase();
            let flat: i32 = caps.get(2)?.as_str().parse().ok()?;
            return Some((blk, flat));
        }

        None
    }

    /// Extracts standalone flat number if preceded by D:, DAIRE, or NO.
    pub fn extract_flat_only(text: &str) -> Option<i32> {
        let re = FLAT_ONLY_RE.as_ref().ok()?;
        if let Some(caps) = re.captures(text) {
            return caps.get(1)?.as_str().parse().ok();
        }
        None
    }

    /// Case-insensitive and Turkish-normalized name containment check.
    pub fn text_contains_name(haystack: &str, needle: &str) -> bool {
        let norm_haystack = Self::normalize_turkish(haystack);
        let norm_needle = Self::normalize_turkish(needle);

        if norm_needle.is_empty() {
            return false;
        }

        // Check if all words of the name appear in the text
        let needle_words: Vec<&str> = norm_needle.split_whitespace().collect();
        if needle_words.is_empty() {
            return false;
        }

        needle_words.iter().all(|w| norm_haystack.contains(w))
    }

    /// Normalizes Turkish characters to lowercase ASCII equivalents for robust
    /// fuzzy matching. Delegates to the shared [`crate::domain::fold_turkish`],
    /// which also strips the combining dot left by lower-casing `İ`.
    pub fn normalize_turkish(input: &str) -> String {
        crate::domain::fold_turkish(input)
    }
}

#[cfg(test)]
mod pattern_tests {
    use super::*;

    #[test]
    fn all_patterns_compile() {
        for (name, pattern) in [
            ("BLOCK_THEN_FLAT_RE", &*BLOCK_THEN_FLAT_RE),
            ("BLOK_PREFIX_FLAT_RE", &*BLOK_PREFIX_FLAT_RE),
            ("COMPACT_BLOCK_FLAT_RE", &*COMPACT_BLOCK_FLAT_RE),
            ("FLAT_ONLY_RE", &*FLAT_ONLY_RE),
        ] {
            assert!(
                pattern.is_ok(),
                "{name} failed to compile: {:?}",
                pattern.as_ref().err()
            );
        }
    }
}
