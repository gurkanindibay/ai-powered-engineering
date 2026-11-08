//! Flat-specific virtual IBAN generation and Turkish IBAN helpers.
//!
//! Validation and formatting delegate to the [`TrIban`] value object in
//! [`crate::domain::iban`]. The generator is a SitePulse-specific identifier
//! strategy, not a bank-issued virtual-account allocation: it has not been
//! provisioned or certified by any bank.

use crate::domain::iban::{self, IbanError, TrIban};

/// Largest unit number that fits the six-digit unit suffix.
pub const MAX_UNIT_NUMBER: i32 = 999_999;

/// Service responsible for generating and validating flat-specific virtual IBANs.
pub struct VirtualIbanService;

impl VirtualIbanService {
    /// Kuveyt Türk Bank Code (Kuveyt Türk Katılım Bankası A.Ş.)
    pub const KUVEYT_TURK_BANK_CODE: &'static str = "00205";

    /// ISO 7064 MOD-97-10 check digits for a 22-digit Turkish BBAN. Non-digit
    /// or wrong-length input is rejected rather than silently skipped.
    pub fn compute_check_digits(bban: &str) -> Result<String, IbanError> {
        iban::check_digits(bban)
    }

    /// True when `iban` is a well-formed Turkish IBAN with valid check digits.
    /// Never panics, whatever the input.
    pub fn validate_tr_iban(iban: &str) -> bool {
        TrIban::parse(iban).is_ok()
    }

    /// Formats a 26-character TR IBAN for display
    /// (e.g. "TR83 0020 5000 0986 3791 600014"). Input that is not a
    /// 26-character ASCII IBAN is returned unchanged.
    pub fn format_for_display(iban: &str) -> String {
        let clean: String = iban.chars().filter(|c| *c != ' ').collect::<String>().to_ascii_uppercase();
        if clean.len() != iban::TR_IBAN_LEN || !clean.is_ascii() {
            return iban.to_string();
        }
        format!(
            "{} {} {} {} {} {}",
            &clean[0..4],
            &clean[4..8],
            &clean[8..12],
            &clean[12..16],
            &clean[16..20],
            &clean[20..26]
        )
    }

    /// Generates a flat-specific virtual IBAN under a parent site account.
    ///
    /// Layout: 5-digit bank code + reserve `0` + 10-digit site/block prefix +
    /// 6-digit unit suffix, then MOD-97 check digits.
    ///
    /// The output for a given input is a stored identifier and must never
    /// change. Known limits of the prefix, kept for compatibility and covered by
    /// tests: the block hash is a byte sum, so anagram block ids (`AB`/`BA`)
    /// share a prefix, and different sites can collide modulo 10^10. Uniqueness
    /// must therefore be enforced where identifiers are stored.
    ///
    /// Rejects bank codes that are not 1–5 digits and unit numbers outside
    /// `1..=MAX_UNIT_NUMBER` (previously negative numbers were folded onto their
    /// absolute value and large numbers were truncated, silently colliding).
    pub fn generate_virtual_iban(
        bank_code: &str,
        site_id: &str,
        block_id: &str,
        unit_number: i32,
    ) -> Result<String, IbanError> {
        let bank_code = iban::normalize_bank_code(bank_code)?;
        if !(1..=MAX_UNIT_NUMBER).contains(&unit_number) {
            return Err(IbanError::InvalidBban);
        }

        // Deterministic 10-digit site prefix (seed "0009863791" is the
        // Kuveyt Türk branch root used for site-1, Begonya Sitesi).
        let site_hash = site_id
            .bytes()
            .fold(9863791u64, |acc, b| acc.wrapping_mul(31).wrapping_add(u64::from(b)));
        let block_hash = block_id
            .bytes()
            .fold(0u64, |acc, b| acc.wrapping_add(u64::from(b)));
        // `wrapping_add` keeps the release-build result for every input while
        // removing the debug-build overflow panic of the former plain `+`.
        let site_prefix = format!("{:010}", site_hash.wrapping_add(block_hash) % 10_000_000_000);

        let bban = format!("{bank_code}0{site_prefix}{unit_number:06}");
        Ok(TrIban::from_bban(&bban)?.into_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_validates_generated_virtual_iban() {
        let iban = VirtualIbanService::generate_virtual_iban("00205", "site-1", "A", 14).unwrap();
        assert_eq!(iban.len(), 26);
        assert!(iban.starts_with("TR"));
        assert!(iban.contains("00205"));
        assert!(VirtualIbanService::validate_tr_iban(&iban));
    }

    #[test]
    fn test_unique_virtual_ibans_for_different_flats() {
        let iban_14 = VirtualIbanService::generate_virtual_iban("00205", "site-1", "A", 14).unwrap();
        let iban_15 = VirtualIbanService::generate_virtual_iban("00205", "site-1", "A", 15).unwrap();
        let iban_b14 = VirtualIbanService::generate_virtual_iban("00205", "site-1", "B", 14).unwrap();

        assert_ne!(iban_14, iban_15);
        assert_ne!(iban_14, iban_b14);
        assert!(VirtualIbanService::validate_tr_iban(&iban_14));
        assert!(VirtualIbanService::validate_tr_iban(&iban_15));
        assert!(VirtualIbanService::validate_tr_iban(&iban_b14));
    }

    #[test]
    fn test_format_for_display() {
        let iban = "TR830020500009863791600014";
        let formatted = VirtualIbanService::format_for_display(iban);
        assert_eq!(formatted, "TR83 0020 5000 0986 3791 600014");
    }

    #[test]
    fn generated_identifiers_are_stable() {
        // Seeded unit d-14 and webhook fixtures depend on this exact value.
        assert_eq!(
            VirtualIbanService::generate_virtual_iban("00205", "site-1", "A", 14).unwrap(),
            "TR410020504213991067000014"
        );
    }

    #[test]
    fn generator_rejects_invalid_input_and_never_overflows() {
        assert!(VirtualIbanService::generate_virtual_iban("002050", "site-1", "A", 14).is_err());
        assert!(VirtualIbanService::generate_virtual_iban("2O5", "site-1", "A", 14).is_err());
        assert!(VirtualIbanService::generate_virtual_iban("00205", "site-1", "A", -14).is_err());
        assert!(VirtualIbanService::generate_virtual_iban("00205", "site-1", "A", 0).is_err());
        assert!(VirtualIbanService::generate_virtual_iban("00205", "site-1", "A", 1_000_000).is_err());
        // Long ids drive the wrapping site hash near u64::MAX; adding the block
        // hash used to overflow and panic in debug builds.
        let long_site = "z".repeat(512);
        for block in ["", "A", &"\u{ff}".repeat(64)] {
            let iban = VirtualIbanService::generate_virtual_iban("00205", &long_site, block, 7).unwrap();
            assert!(VirtualIbanService::validate_tr_iban(&iban));
        }
    }

    #[test]
    fn documented_prefix_collisions_are_real() {
        let ab = VirtualIbanService::generate_virtual_iban("00205", "site-1", "AB", 1).unwrap();
        let ba = VirtualIbanService::generate_virtual_iban("00205", "site-1", "BA", 1).unwrap();
        assert_eq!(ab, ba, "anagram block ids share a prefix; storage must enforce uniqueness");
    }

    #[test]
    fn validation_never_panics_on_multibyte_input() {
        assert!(!VirtualIbanService::validate_tr_iban("TRé0020504213991067000014"));
        assert!(!VirtualIbanService::validate_tr_iban("TR\u{0130}020504213991067000014"));
        assert_eq!(VirtualIbanService::format_for_display("TRé0020504213991067000014"), "TRé0020504213991067000014");
        assert!(VirtualIbanService::compute_check_digits("00205042139910670000AB").is_err());
    }
}
