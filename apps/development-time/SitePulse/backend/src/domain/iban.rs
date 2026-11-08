//! Validated Turkish IBAN value object (ISO 13616, ISO 7064 MOD-97-10).
//!
//! Structure: `TR` + 2 check digits + 5-digit bank code + 1 reserve digit +
//! 16-digit account number = 26 ASCII characters. Every slice below happens
//! only after the input is proven to be ASCII, so no input can panic.

use std::fmt;

use thiserror::Error;

pub const TR_IBAN_LEN: usize = 26;
pub const TR_BBAN_LEN: usize = 22;
pub const TR_BANK_CODE_LEN: usize = 5;

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum IbanError {
    #[error("Invalid IBAN. IBANs may contain only letters, digits and spaces.")]
    InvalidCharacters,
    #[error("Invalid IBAN. Turkish IBANs must start with 'TR' and be 26 characters long.")]
    NotTurkish,
    #[error("Invalid IBAN. The check digits do not match (mistyped IBAN?).")]
    Checksum,
    #[error("Invalid BBAN. A Turkish BBAN is exactly 22 digits.")]
    InvalidBban,
    #[error("Invalid bank code. A Turkish bank code is 1 to 5 digits.")]
    InvalidBankCode,
}

/// A Turkish IBAN whose format and check digits have been verified. Stored in
/// compact upper-case form (no spaces).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct TrIban(String);

impl TrIban {
    /// Parses user input, ignoring whitespace and letter case.
    pub fn parse(input: &str) -> Result<Self, IbanError> {
        let compact: String = input.chars().filter(|c| !c.is_whitespace()).collect();
        if !compact.chars().all(|c| c.is_ascii_alphanumeric()) {
            return Err(IbanError::InvalidCharacters);
        }
        let compact = compact.to_ascii_uppercase();
        if compact.len() != TR_IBAN_LEN || !compact.starts_with("TR") {
            return Err(IbanError::NotTurkish);
        }
        // ASCII-only from here on, so byte offsets are character offsets.
        if !compact[2..].bytes().all(|b| b.is_ascii_digit()) {
            return Err(IbanError::InvalidCharacters);
        }
        let rearranged = format!("{}2927{}", &compact[4..], &compact[2..4]);
        if mod97(&rearranged) != 1 {
            return Err(IbanError::Checksum);
        }
        Ok(Self(compact))
    }

    /// Builds an IBAN from a 22-digit Turkish BBAN by computing its check digits.
    pub fn from_bban(bban: &str) -> Result<Self, IbanError> {
        let digits = check_digits(bban)?;
        Ok(Self(format!("TR{digits}{bban}")))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// The 5-digit bank (EFT) code, e.g. `00205` for Kuveyt Türk.
    pub fn bank_code(&self) -> &str {
        &self.0[4..4 + TR_BANK_CODE_LEN]
    }

    /// SitePulse display form: five groups of four and a final group of six,
    /// e.g. `TR41 0020 5042 1399 1067 000014` (the API's established layout).
    pub fn grouped(&self) -> String {
        let s = &self.0;
        format!(
            "{} {} {} {} {} {}",
            &s[0..4],
            &s[4..8],
            &s[8..12],
            &s[12..16],
            &s[16..20],
            &s[20..26]
        )
    }

    pub fn into_string(self) -> String {
        self.0
    }
}

impl fmt::Display for TrIban {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// ISO 7064 MOD-97-10 check digits for a 22-digit Turkish BBAN. Rejects any
/// non-digit or wrong-length input instead of skipping characters.
pub fn check_digits(bban: &str) -> Result<String, IbanError> {
    if bban.len() != TR_BBAN_LEN || !bban.bytes().all(|b| b.is_ascii_digit()) {
        return Err(IbanError::InvalidBban);
    }
    // BBAN + "TR00", with T=29 and R=27.
    let remainder = mod97(&format!("{bban}292700"));
    Ok(format!("{:02}", 98 - remainder))
}

/// Left-pads a 1–5 digit bank code to five digits.
pub fn normalize_bank_code(code: &str) -> Result<String, IbanError> {
    let code = code.trim();
    if code.is_empty() || code.len() > TR_BANK_CODE_LEN || !code.bytes().all(|b| b.is_ascii_digit())
    {
        return Err(IbanError::InvalidBankCode);
    }
    Ok(format!("{code:0>5}"))
}

/// Remainder of a decimal digit string modulo 97. Callers guarantee ASCII digits.
fn mod97(digits: &str) -> u32 {
    digits
        .bytes()
        .fold(0u32, |acc, b| (acc * 10 + u32::from(b - b'0')) % 97)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Independently published example IBANs (not produced by this module).
    const PUBLISHED_VALID: [&str; 2] = [
        "TR330006100519786457841326",
        "TR32 0010 0099 9990 1234 5678 90",
    ];

    #[test]
    fn accepts_published_examples_in_any_spacing_and_case() {
        for iban in PUBLISHED_VALID {
            let parsed = TrIban::parse(iban).unwrap();
            assert_eq!(parsed.as_str().len(), TR_IBAN_LEN);
            assert_eq!(TrIban::parse(&iban.to_lowercase()).unwrap(), parsed);
        }
        assert_eq!(
            TrIban::parse(PUBLISHED_VALID[0]).unwrap().bank_code(),
            "00061"
        );
    }

    #[test]
    fn rejects_bad_checksum_and_structure() {
        assert_eq!(
            TrIban::parse("TR340006100519786457841326"),
            Err(IbanError::Checksum)
        );
        assert_eq!(
            TrIban::parse("DE89370400440532013000"),
            Err(IbanError::NotTurkish)
        );
        assert_eq!(TrIban::parse("TR123"), Err(IbanError::NotTurkish));
        assert_eq!(
            TrIban::parse("TR33000610051978645784132X"),
            Err(IbanError::InvalidCharacters)
        );
        assert_eq!(
            TrIban::parse("TR33-0006-1005"),
            Err(IbanError::InvalidCharacters)
        );
    }

    #[test]
    fn multibyte_input_never_panics() {
        // 26 bytes but not 26 ASCII characters; would split a char if sliced.
        for input in [
            "TRé0006100519786457841326",
            "TR\u{0130}0006100519786457841326",
            "ŞŞŞŞŞŞŞŞŞŞŞŞŞ",
            "€€€€€€€€",
        ] {
            assert!(TrIban::parse(input).is_err(), "{input}");
        }
    }

    #[test]
    fn check_digits_round_trip_and_reject_non_digits() {
        let parsed = TrIban::parse(PUBLISHED_VALID[0]).unwrap();
        let bban = &parsed.as_str()[4..];
        assert_eq!(check_digits(bban).unwrap(), "33");
        assert_eq!(TrIban::from_bban(bban).unwrap(), parsed);
        assert_eq!(
            check_digits("00061005197864578413AB"),
            Err(IbanError::InvalidBban)
        );
        assert_eq!(check_digits("123"), Err(IbanError::InvalidBban));
    }

    #[test]
    fn groups_for_display() {
        let parsed = TrIban::parse("TR330006100519786457841326").unwrap();
        assert_eq!(parsed.grouped(), "TR33 0006 1005 1978 6457 841326");
    }

    #[test]
    fn normalizes_bank_codes() {
        assert_eq!(normalize_bank_code("205").unwrap(), "00205");
        assert_eq!(normalize_bank_code("00205").unwrap(), "00205");
        assert_eq!(
            normalize_bank_code("002050"),
            Err(IbanError::InvalidBankCode)
        );
        assert_eq!(normalize_bank_code("2O5"), Err(IbanError::InvalidBankCode));
        assert_eq!(normalize_bank_code(""), Err(IbanError::InvalidBankCode));
    }
}
