use chrono::{NaiveDate, Utc};
use regex::Regex;
use rust_decimal::Decimal;
use std::str::FromStr;

use crate::models::{BankStatementFormat, BankTransactionItem};
use crate::services::mt940_engine::Mt940Engine;

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
    pub fn parse_statement(
        &self,
        content: &str,
        format_opt: Option<BankStatementFormat>,
    ) -> Result<Vec<BankTransactionItem>, String> {
        let trimmed = content.trim();
        if trimmed.is_empty() {
            return Ok(Vec::new());
        }

        let format = format_opt.unwrap_or(BankStatementFormat::Auto);

        match format {
            BankStatementFormat::Mt940 => self.mt940_engine.parse(trimmed),
            BankStatementFormat::Excel | BankStatementFormat::Csv => self.parse_tabular_or_lines(trimmed),
            BankStatementFormat::Auto => {
                if trimmed.starts_with(":20:") || (trimmed.contains(":61:") && trimmed.contains(":86:")) {
                    self.mt940_engine.parse(trimmed)
                } else {
                    self.parse_tabular_or_lines(trimmed)
                }
            }
        }
    }

    /// Parses tabular text, CSV, TSV, or single/multi-line Turkish bank transaction statements.
    fn parse_tabular_or_lines(&self, content: &str) -> Result<Vec<BankTransactionItem>, String> {
        let mut transactions = Vec::new();
        let lines: Vec<&str> = content.lines().map(|l| l.trim()).filter(|l| !l.is_empty()).collect();

        for (idx, line) in lines.iter().enumerate() {
            // Skip common table headers
            let lower = line.to_lowercase();
            if (lower.contains("tarih") || lower.contains("date"))
                && (lower.contains("tutar") || lower.contains("amount") || lower.contains("alacak"))
            {
                continue;
            }

            if let Some(item) = self.parse_single_line(line, idx + 1) {
                transactions.push(item);
            }
        }

        Ok(transactions)
    }

    /// Parses a single line representing a transaction.
    /// Handles delimiter separation (; , \t |) or unstructured Turkish bank transfer text like:
    /// "HAVALE - AHMET YILMAZ A BLOK D:14 EYLUL AIDAT - ₺1.423,33"
    fn parse_single_line(&self, line: &str, row_num: usize) -> Option<BankTransactionItem> {
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
                return self.parse_delimited_parts(&parts, row_num);
            }
        }

        // Unstructured free-form line parsing (e.g. "HAVALE - AHMET YILMAZ A BLOK D:14 EYLUL AIDAT - ₺1.423,33")
        self.parse_freeform_line(line, row_num)
    }

    fn parse_delimited_parts(&self, parts: &[&str], row_num: usize) -> Option<BankTransactionItem> {
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
        let date = detected_date.unwrap_or_else(|| Utc::now().date_naive());
        let description = detected_desc.unwrap_or_else(|| format!("Banka İşlemi Satır {}", row_num));
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

    fn parse_freeform_line(&self, line: &str, row_num: usize) -> Option<BankTransactionItem> {
        let amount = Self::extract_amount_from_text(line)?;
        let date = Self::extract_date_from_text(line).unwrap_or_else(|| Utc::now().date_naive());

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
        let re = Regex::new(r"\b(\d{2}[./]\d{2}[./]\d{4}|\d{4}-\d{2}-\d{2})\b").ok()?;
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
        let re = Regex::new(r"₺?\s*([0-9]{1,3}(?:\.[0-9]{3})*,[0-9]{2}|[0-9]+[.,][0-9]{2})\s*(?:TL|TRY)?").ok()?;
        if let Some(caps) = re.captures(text) {
            if let Some(m) = caps.get(1) {
                return Self::extract_amount(m.as_str());
            }
        }
        None
    }
}
