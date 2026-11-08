use chrono::{NaiveDate, Utc};
use regex::Regex;
use rust_decimal::Decimal;
use std::str::FromStr;

use crate::models::{BankStatementFormat, BankTransactionItem, SkippedStatementEntry};
use crate::services::mt940_engine::Mt940Engine;
use std::sync::LazyLock;

/// Compiled once; `all_patterns_compile` guarantees it is `Ok`.
static DATE_IN_TEXT_RE: LazyLock<Result<Regex, regex::Error>> =
    LazyLock::new(|| Regex::new(r"\b(\d{2}[./]\d{2}[./]\d{4}|\d{4}-\d{2}-\d{2})\b"));
/// Compiled once; `all_patterns_compile` guarantees it is `Ok`.
static AMOUNT_IN_TEXT_RE: LazyLock<Result<Regex, regex::Error>> = LazyLock::new(|| {
    Regex::new(r"₺?\s*([0-9]{1,3}(?:\.[0-9]{3})*,[0-9]{2}|[0-9]+[.,][0-9]{2})\s*(?:TL|TRY)?")
});

/// Result of parsing a statement: imported transactions plus every entry that
/// was skipped and why.
#[derive(Debug, Clone, Default)]
pub struct ParseReport {
    pub transactions: Vec<BankTransactionItem>,
    pub skipped: Vec<SkippedStatementEntry>,
}

pub struct BankStatementParser {
    mt940_engine: Mt940Engine,
}

impl Default for BankStatementParser {
    fn default() -> Self {
        Self::new()
    }
}

impl BankStatementParser {
    pub fn new() -> Self {
        Self {
            mt940_engine: Mt940Engine::new(),
        }
    }

    /// Automatically detects statement format or respects specified format, parsing rows into transactions.
    /// Rows without a date are dated today; use [`Self::parse_statement_report`]
    /// to choose the fallback date and to see which rows were skipped.
    pub fn parse_statement(
        &self,
        content: &str,
        format_opt: Option<BankStatementFormat>,
    ) -> Result<Vec<BankTransactionItem>, String> {
        self.parse_statement_report(content, format_opt, Utc::now().date_naive())
            .map(|report| report.transactions)
    }

    /// Parses a statement and reports every entry that was not imported.
    ///
    /// `fallback_date` is used for rows that carry no recognizable date, so the
    /// result is deterministic for a given input and import context.
    ///
    /// Limits: `Excel` content is read as delimited text (binary `.xlsx` is not
    /// decoded), delimited rows are split without CSV quote handling, and
    /// currency is assumed to be TRY.
    pub fn parse_statement_report(
        &self,
        content: &str,
        format_opt: Option<BankStatementFormat>,
        fallback_date: NaiveDate,
    ) -> Result<ParseReport, String> {
        let trimmed = content.trim();
        if trimmed.is_empty() {
            return Ok(ParseReport::default());
        }

        let format = format_opt.unwrap_or(BankStatementFormat::Auto);
        let is_mt940 = match format {
            BankStatementFormat::Mt940 => true,
            BankStatementFormat::Excel | BankStatementFormat::Csv => false,
            BankStatementFormat::Auto => {
                trimmed.starts_with(":20:")
                    || (trimmed.contains(":61:") && trimmed.contains(":86:"))
            }
        };

        if is_mt940 {
            let (transactions, skipped) = self.mt940_engine.parse_report(trimmed)?;
            Ok(ParseReport {
                transactions,
                skipped,
            })
        } else {
            Ok(self.parse_tabular_or_lines(trimmed, fallback_date))
        }
    }

    /// Parses tabular text, CSV, TSV, or single/multi-line Turkish bank transaction statements.
    fn parse_tabular_or_lines(&self, content: &str, fallback_date: NaiveDate) -> ParseReport {
        let mut report = ParseReport::default();

        for (idx, raw_line) in content.lines().enumerate() {
            let line = raw_line.trim();
            if line.is_empty() {
                continue;
            }
            // Skip common table headers
            let lower = line.to_lowercase();
            if (lower.contains("tarih") || lower.contains("date"))
                && (lower.contains("tutar") || lower.contains("amount") || lower.contains("alacak"))
            {
                continue;
            }

            match self.parse_single_line(line, idx + 1, fallback_date) {
                Some(item) => report.transactions.push(item),
                None => report.skipped.push(SkippedStatementEntry {
                    line_number: idx + 1,
                    reason: "No transaction amount could be recognized on this line.".to_string(),
                    content: line.to_string(),
                }),
            }
        }

        report
    }

    /// Parses a single line representing a transaction.
    /// Handles delimiter separation (; , \t |) or unstructured Turkish bank transfer text like:
    /// "HAVALE - AHMET YILMAZ A BLOK D:14 EYLUL AIDAT - ₺1.423,33"
    fn parse_single_line(
        &self,
        line: &str,
        row_num: usize,
        fallback_date: NaiveDate,
    ) -> Option<BankTransactionItem> {
        // Detect delimiter if present
        let delimiter = if line.contains('\t') {
            Some('\t')
        } else if line.contains(';') {
            Some(';')
        } else if line.contains('|') {
            Some('|')
        } else if line.contains(',') && line.matches(',').count() >= 2 {
            // Only if multiple commas and not just decimal comma
            Some(',')
        } else {
            None
        };

        if let Some(delim) = delimiter {
            let parts: Vec<&str> = line.split(delim).map(|p| p.trim()).collect();
            if parts.len() >= 2 {
                return self.parse_delimited_parts(&parts, row_num, fallback_date);
            }
        }

        // Unstructured free-form line parsing (e.g. "HAVALE - AHMET YILMAZ A BLOK D:14 EYLUL AIDAT - ₺1.423,33")
        self.parse_freeform_line(line, row_num, fallback_date)
    }

    fn parse_delimited_parts(
        &self,
        parts: &[&str],
        row_num: usize,
        fallback_date: NaiveDate,
    ) -> Option<BankTransactionItem> {
        let mut detected_date: Option<NaiveDate> = None;
        let mut detected_amount: Option<Decimal> = None;
        let mut detected_desc: Option<String> = None;
        let mut detected_ref: Option<String> = None;

        for part in parts {
            if detected_date.is_none() {
                if let Some(d) = Self::extract_date(part) {
                    detected_date = Some(d);
                    continue;
                }
            }

            if detected_amount.is_none() {
                if let Some(a) = Self::extract_amount(part) {
                    detected_amount = Some(a);
                    continue;
                }
            }

            if part.starts_with("TXN-") || part.starts_with("DEC-") || part.starts_with("REF-") {
                detected_ref = Some(part.to_string());
                continue;
            }

            if part.len() > 3 {
                if let Some(ref existing) = detected_desc {
                    detected_desc = Some(format!("{} {}", existing, part));
                } else {
                    detected_desc = Some(part.to_string());
                }
            }
        }

        let amount = detected_amount?;
        let date = detected_date.unwrap_or(fallback_date);
        let description =
            detected_desc.unwrap_or_else(|| format!("Banka İşlemi Satır {}", row_num));
        let txn_id = detected_ref.unwrap_or_else(|| format!("TXN-EXCEL-{:03}", row_num));

        Some(BankTransactionItem {
            transaction_id: txn_id,
            date,
            amount,
            currency: "TRY".to_string(),
            description,
            sender_name: None,
            sender_iban: None,
            reference_no: None,
        })
    }

    fn parse_freeform_line(
        &self,
        line: &str,
        row_num: usize,
        fallback_date: NaiveDate,
    ) -> Option<BankTransactionItem> {
        let amount = Self::extract_amount_from_text(line)?;
        let date = Self::extract_date_from_text(line).unwrap_or(fallback_date);

        // Clean amount and currency tokens from description
        let description = line.to_string();
        let txn_id = format!("TXN-ROW-{:03}", row_num);

        Some(BankTransactionItem {
            transaction_id: txn_id,
            date,
            amount,
            currency: "TRY".to_string(),
            description: description.trim().to_string(),
            sender_name: None,
            sender_iban: None,
            reference_no: None,
        })
    }

    /// Extracts date from a single token (e.g. "15.09.2026", "2026-09-15", "15/09/2026").
    pub fn extract_date(token: &str) -> Option<NaiveDate> {
        let clean = token.trim();
        // dd.mm.yyyy
        if let Ok(d) = NaiveDate::parse_from_str(clean, "%d.%m.%Y") {
            return Some(d);
        }
        // yyyy-mm-dd
        if let Ok(d) = NaiveDate::parse_from_str(clean, "%Y-%m-%d") {
            return Some(d);
        }
        // dd/mm/yyyy
        if let Ok(d) = NaiveDate::parse_from_str(clean, "%d/%m/%Y") {
            return Some(d);
        }
        None
    }

    /// Searches text for date pattern.
    pub fn extract_date_from_text(text: &str) -> Option<NaiveDate> {
        let re = DATE_IN_TEXT_RE.as_ref().ok()?;
        if let Some(m) = re.find(text) {
            return Self::extract_date(m.as_str());
        }
        None
    }

    /// Extracts decimal amount from a single token (e.g. "₺1.423,33", "1.423,33", "1423.33").
    pub fn extract_amount(token: &str) -> Option<Decimal> {
        let mut cleaned = token
            .replace('₺', "")
            .replace("TL", "")
            .replace("TRY", "")
            .replace(['$', '€'], "")
            .trim()
            .to_string();

        if cleaned.is_empty() {
            return None;
        }

        // Turkish format: "1.423,33" -> dot is thousand separator, comma is decimal
        if cleaned.contains('.') && cleaned.contains(',') {
            cleaned = cleaned.replace('.', "").replace(',', ".");
        } else if cleaned.contains(',') {
            // "1423,33" -> replace comma with dot
            cleaned = cleaned.replace(',', ".");
        }

        Decimal::from_str(&cleaned).ok()
    }

    /// Searches text for currency amounts like "₺1.423,33", "1.423,33 TL", "1423.33".
    pub fn extract_amount_from_text(text: &str) -> Option<Decimal> {
        // Pattern: Optional ₺, digits, optional dots/commas, 2 decimal digits, optional TL/TRY
        let re = AMOUNT_IN_TEXT_RE.as_ref().ok()?;
        if let Some(caps) = re.captures(text) {
            if let Some(m) = caps.get(1) {
                return Self::extract_amount(m.as_str());
            }
        }
        None
    }
}

#[cfg(test)]
mod pattern_tests {
    use super::*;

    #[test]
    fn all_patterns_compile() {
        for (name, pattern) in [
            ("DATE_IN_TEXT_RE", &*DATE_IN_TEXT_RE),
            ("AMOUNT_IN_TEXT_RE", &*AMOUNT_IN_TEXT_RE),
        ] {
            assert!(
                pattern.is_ok(),
                "{name} failed to compile: {:?}",
                pattern.as_ref().err()
            );
        }
    }
}
