//! Turkish identity and tax numbers: T.C. Kimlik No (11 digits) and Vergi Kimlik
//! No (10 digits), each with its published check-digit rule.
//!
//! Used by vendor registration (SPEC-009 R7), management companies (R13) and
//! payer matching on bank transfer descriptions (R9).

use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum TaxIdError {
    #[error("a tax id has 10 (VKN) or 11 (TCKN) digits")]
    Length,
    #[error("a tax id contains digits only")]
    NotDigits,
    #[error("the check digits of the tax id do not match")]
    Checksum,
}

/// A validated tax identifier.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TaxId {
    /// Vergi Kimlik No of a legal entity or sole trader.
    Vkn(String),
    /// T.C. Kimlik No of a natural person.
    Tckn(String),
}

impl TaxId {
    pub fn parse(raw: &str) -> Result<Self, TaxIdError> {
        let s: String = raw.chars().filter(|c| !c.is_whitespace()).collect();
        if !s.chars().all(|c| c.is_ascii_digit()) {
            return Err(TaxIdError::NotDigits);
        }
        match s.len() {
            10 if is_valid_vkn(&s) => Ok(TaxId::Vkn(s)),
            11 if is_valid_tckn(&s) => Ok(TaxId::Tckn(s)),
            10 | 11 => Err(TaxIdError::Checksum),
            _ => Err(TaxIdError::Length),
        }
    }

    pub fn as_str(&self) -> &str {
        match self {
            TaxId::Vkn(s) | TaxId::Tckn(s) => s,
        }
    }

    /// e-Fatura buyers are VKN holders; a TCKN buyer receives an e-Arşiv invoice.
    pub fn is_legal_entity(&self) -> bool {
        matches!(self, TaxId::Vkn(_))
    }
}

fn digits(s: &str) -> Option<Vec<u32>> {
    s.chars().map(|c| c.to_digit(10)).collect()
}

/// T.C. Kimlik No: 11 digits, the first is not 0; digit 10 is
/// `((d1+d3+d5+d7+d9)*7 - (d2+d4+d6+d8)) mod 10` and digit 11 is the sum of the
/// first ten digits mod 10.
pub fn is_valid_tckn(s: &str) -> bool {
    let Some(d) = digits(s) else { return false };
    if d.len() != 11 || d[0] == 0 {
        return false;
    }
    let odd: u32 = d[0] + d[2] + d[4] + d[6] + d[8];
    let even: u32 = d[1] + d[3] + d[5] + d[7];
    let tenth = (odd * 7 + 10 * 10 - even) % 10;
    let eleventh = d[..10].iter().sum::<u32>() % 10;
    d[9] == tenth && d[10] == eleventh
}

/// Vergi Kimlik No: 10 digits; the last digit is derived from the first nine by
/// the Gelir İdaresi algorithm.
pub fn is_valid_vkn(s: &str) -> bool {
    let Some(d) = digits(s) else { return false };
    if d.len() != 10 {
        return false;
    }
    let mut sum = 0u32;
    for (i, &digit) in d[..9].iter().enumerate() {
        let position = u32::try_from(9 - i).unwrap_or(0);
        let tmp = (digit + position) % 10;
        if tmp == 0 {
            continue;
        }
        let mut v = (tmp * 2u32.pow(position)) % 9;
        if v == 0 {
            v = 9;
        }
        sum += v;
    }
    let check = (10 - sum % 10) % 10;
    d[9] == check
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn valid_tckn_is_accepted_and_altered_digits_are_rejected() {
        assert!(is_valid_tckn("10000000146"));
        assert!(!is_valid_tckn("10000000147"));
        assert!(
            !is_valid_tckn("00000000146"),
            "the first digit is never zero"
        );
        assert!(!is_valid_tckn("1000000014"));
    }

    #[test]
    fn valid_vkn_is_accepted_and_altered_digits_are_rejected() {
        assert!(is_valid_vkn("0010180009"));
        assert!(!is_valid_vkn("0010180006"));
        assert!(!is_valid_vkn("001018000"));
    }

    #[test]
    fn parse_tells_vkn_from_tckn() {
        assert_eq!(
            TaxId::parse("100 000 001 46"),
            Ok(TaxId::Tckn("10000000146".into()))
        );
        assert!(TaxId::parse("0010180009")
            .map(|t| t.is_legal_entity())
            .unwrap_or(false));
        assert_eq!(TaxId::parse("12ab"), Err(TaxIdError::NotDigits));
        assert_eq!(TaxId::parse("123"), Err(TaxIdError::Length));
        assert_eq!(TaxId::parse("10000000147"), Err(TaxIdError::Checksum));
    }
}
