//! Payer hints in bank transfer descriptions, SPEC-009 R9.
//!
//! Transfers that bypass the unit's virtual IBAN are matched by what the payer
//! wrote: a T.C. Kimlik No (validated by its check digits), a Turkish mobile
//! number, or a block/unit reference ("A BLOK D:14", "A-14", "A/14",
//! "BLOK A DAIRE 14").

use std::sync::LazyLock;

use regex::Regex;

use super::tax_id::is_valid_tckn;
use super::text::fold_turkish;

static ELEVEN_DIGITS: LazyLock<Result<Regex, regex::Error>> =
    LazyLock::new(|| Regex::new(r"(?:^|\D)(\d{11})(?:\D|$)"));
static MOBILE: LazyLock<Result<Regex, regex::Error>> = LazyLock::new(|| {
    Regex::new(r"(?:\+?90|0)?\s*\(?(5\d{2})\)?[\s.-]*(\d{3})[\s.-]*(\d{2})[\s.-]*(\d{2})")
});
static BLOCK_UNIT_1: LazyLock<Result<Regex, regex::Error>> =
    LazyLock::new(|| Regex::new(r"\b([a-z])\s*blok\s*(?:daire|d|no)?\s*[:.]?\s*(\d{1,4})\b"));
static BLOCK_UNIT_2: LazyLock<Result<Regex, regex::Error>> =
    LazyLock::new(|| Regex::new(r"\bblok\s*([a-z])\s*(?:daire|d|no)?\s*[:.]?\s*(\d{1,4})\b"));
static BLOCK_UNIT_3: LazyLock<Result<Regex, regex::Error>> =
    LazyLock::new(|| Regex::new(r"\b([a-z])\s*[-/]\s*(\d{1,4})\b"));

/// Tried in order: "a blok d:14", "blok c daire 21", "c blok daire 3", "a-14", "b/7" (folded text).
static BLOCK_UNIT: [&LazyLock<Result<Regex, regex::Error>>; 3] =
    [&BLOCK_UNIT_1, &BLOCK_UNIT_2, &BLOCK_UNIT_3];

/// What a description reveals about the payer.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PayerHints {
    pub national_id: Option<String>,
    /// `5XXXXXXXXX` (10 digits, no country code or leading zero).
    pub mobile: Option<String>,
    /// Upper-case block letter and unit number.
    pub block_unit: Option<(String, i32)>,
}

impl PayerHints {
    pub fn is_empty(&self) -> bool {
        self.national_id.is_none() && self.mobile.is_none() && self.block_unit.is_none()
    }
}

/// Normalizes a Turkish mobile number to `5XXXXXXXXX`.
pub fn normalize_mobile(raw: &str) -> Option<String> {
    let digits: String = raw.chars().filter(char::is_ascii_digit).collect();
    let tail = digits
        .strip_prefix("90")
        .filter(|r| r.len() == 10)
        .or_else(|| digits.strip_prefix('0').filter(|r| r.len() == 10))
        .unwrap_or(&digits);
    (tail.len() == 10 && tail.starts_with('5')).then(|| tail.to_string())
}

pub fn extract(description: &str) -> PayerHints {
    let folded = fold_turkish(description);
    let mut hints = PayerHints::default();
    if let Ok(re) = ELEVEN_DIGITS.as_ref() {
        hints.national_id = re
            .captures_iter(&folded)
            .filter_map(|c| c.get(1).map(|m| m.as_str().to_string()))
            .find(|s| is_valid_tckn(s));
    }
    if let Ok(re) = MOBILE.as_ref() {
        hints.mobile = re.captures_iter(&folded).find_map(|c| {
            let joined: String = (1..=4)
                .filter_map(|i| c.get(i).map(|m| m.as_str()))
                .collect();
            // An 11-digit national id also contains "5..." runs; skip those.
            (hints
                .national_id
                .as_deref()
                .is_none_or(|n| !n.contains(&joined)))
            .then(|| normalize_mobile(&joined))
            .flatten()
        });
    }
    hints.block_unit = BLOCK_UNIT.iter().find_map(|re| {
        let c = re.as_ref().ok()?.captures(&folded)?;
        let block = c.get(1)?.as_str().to_ascii_uppercase();
        let unit = c.get(2)?.as_str().parse::<i32>().ok()?;
        Some((block, unit))
    });
    hints
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn patterns_compile() {
        assert!(ELEVEN_DIGITS.as_ref().is_ok());
        assert!(MOBILE.as_ref().is_ok());
        assert!(BLOCK_UNIT.iter().all(|r| r.is_ok()));
    }

    #[test]
    fn a_valid_national_id_is_found_and_an_invalid_one_ignored() {
        assert_eq!(
            extract("AIDAT TC 10000000146 EKIM").national_id.as_deref(),
            Some("10000000146")
        );
        assert_eq!(extract("REF 10000000147").national_id, None);
        assert_eq!(extract("IBAN 100000001461").national_id, None);
    }

    #[test]
    fn mobile_numbers_are_normalized() {
        assert_eq!(
            extract("Ödeme 0532 123 45 67").mobile.as_deref(),
            Some("5321234567")
        );
        assert_eq!(
            extract("+90 (535) 111-22-33 aidat").mobile.as_deref(),
            Some("5351112233")
        );
        assert_eq!(
            normalize_mobile("05321234567").as_deref(),
            Some("5321234567")
        );
        assert_eq!(normalize_mobile("4321234567"), None);
    }

    #[test]
    fn block_and_unit_references_are_read() {
        for (text, want) in [
            ("A BLOK D:14 EKIM AIDATI", ("A", 14)),
            ("aidat a-14", ("A", 14)),
            ("B/7 KASIM", ("B", 7)),
            ("BLOK C DAIRE 21", ("C", 21)),
            ("C Blok Daire 3", ("C", 3)),
        ] {
            assert_eq!(
                extract(text).block_unit,
                Some((want.0.to_string(), want.1)),
                "{}",
                text
            );
        }
        assert!(extract("EKIM AIDATI").is_empty());
    }
}
