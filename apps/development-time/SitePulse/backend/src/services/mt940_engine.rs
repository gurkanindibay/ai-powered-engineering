use chrono::NaiveDate;
use regex::Regex;
use rust_decimal::Decimal;
use std::str::FromStr;

use crate::models::BankTransactionItem;

pub struct Mt940Engine;

impl Default for Mt940Engine {
    fn default() -> Self {
        Self::new()
    }
}

impl Mt940Engine {
    pub fn new() -> Self {
        Self
    }

    /// Parses a standard SWIFT MT940 statement string into structured BankTransactionItem records.
    pub fn parse(&self, content: &str) -> Result<Vec<BankTransactionItem>, String> {
        let mut transactions: Vec<BankTransactionItem> = Vec::new();
        let lines: Vec<&str> = content.lines().collect();

        let mut current_tag: Option<String> = None;
        let mut current_61: Option<String> = None;
        let mut current_86: Vec<String> = Vec::new();

        // Tag pattern: :TAG:
        let tag_regex = Regex::new(r"^:([0-9]{2}[A-Z]?):(.*)$").map_err(|e| e.to_string())?;

        let mut tx_seq = 0usize;
        let mut finalize_transaction = |t_61: &str, t_86: &[String]| -> Option<BankTransactionItem> {
            tx_seq += 1;
            let parsed_61 = Self::parse_tag_61(t_61)?;
            let narrative = if !t_86.is_empty() {
                t_86.join(" ").trim().to_string()
            } else {
                parsed_61.reference.clone().unwrap_or_else(|| "MT940 Transaction".to_string())
            };

            let fallback_ref = format!("TXN-MT940-{:03}", tx_seq);
            Some(BankTransactionItem {
                transaction_id: parsed_61.reference.clone().unwrap_or(fallback_ref),
                date: parsed_61.date,
                amount: parsed_61.amount,
                currency: "TRY".to_string(),
                description: narrative,
                sender_name: None,
                sender_iban: None,
                reference_no: parsed_61.reference,
            })
        };

        for raw_line in lines {
            let line = raw_line.trim_end();
            if line.is_empty() || line == "-" {
                continue;
            }

            if let Some(caps) = tag_regex.captures(line) {
                let tag = caps.get(1).map_or("", |m| m.as_str()).to_string();
                let rest = caps.get(2).map_or("", |m| m.as_str()).to_string();

                if tag == "61" {
                    // If we already had a transaction in flight, finalize it
                    if let Some(prev_61) = current_61.take() {
                        if let Some(item) = finalize_transaction(&prev_61, &current_86) {
                            transactions.push(item);
                        }
                        current_86.clear();
                    }
                    current_61 = Some(rest);
                    current_tag = Some("61".to_string());
                } else if tag == "86" {
                    current_86.push(rest);
                    current_tag = Some("86".to_string());
                } else {
                    // Another tag (like :62F: or :20:)
                    if let Some(prev_61) = current_61.take() {
                        if let Some(item) = finalize_transaction(&prev_61, &current_86) {
                            transactions.push(item);
                        }
                        current_86.clear();
                    }
                    current_tag = Some(tag);
                }
            } else {
                // Continuation line of multi-line field
                if current_tag.as_deref() == Some("86") {
                    current_86.push(line.to_string());
                }
            }
        }

        // Finalize last transaction if exists
        if let Some(last_61) = current_61.take() {
            if let Some(item) = finalize_transaction(&last_61, &current_86) {
                transactions.push(item);
            }
        }

        Ok(transactions)
    }

    /// Parses a SWIFT MT940 tag :61: statement line.
    /// Standard format: YYMMDD[MMDD]D/C[R]AmountNTypeReference[//BankReference]
    /// Example: "2609150915CR1423,33NTRFNONREF//TXN77889" or "260915CR1423,33NTRF"
    fn parse_tag_61(raw: &str) -> Option<Tag61Parsed> {
        let regex = Regex::new(
            r"^(\d{6})(?:\d{4})?([CD]|RC|RD|CR|DR)([0-9]+,[0-9]{2})([A-Z0-9]{4})?(?:([^/\n]+))?(?://([^\n]+))?",
        ).ok()?;

        let caps = regex.captures(raw.trim())?;

        let date_str = caps.get(1)?.as_str(); // YYMMDD
        let amount_str = caps.get(3)?.as_str(); // 1423,33
        let bank_ref = caps.get(6).or_else(|| caps.get(5)).map(|m| m.as_str().trim().to_string());

        let year: i32 = 2000 + date_str[0..2].parse::<i32>().ok()?;
        let month: u32 = date_str[2..4].parse::<u32>().ok()?;
        let day: u32 = date_str[4..6].parse::<u32>().ok()?;
        let date = NaiveDate::from_ymd_opt(year, month, day)?;

        let decimal_str = amount_str.replace(',', ".");
        let amount = Decimal::from_str(&decimal_str).ok()?;

        Some(Tag61Parsed {
            date,
            amount,
            reference: bank_ref,
        })
    }
}

struct Tag61Parsed {
    date: NaiveDate,
    amount: Decimal,
    reference: Option<String>,
}
