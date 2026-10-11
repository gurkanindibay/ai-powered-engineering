/// Service responsible for generating and validating Flat-Specific Virtual IBANs (Sanal IBAN)
/// compliant with Turkish Banking Regulation (BDDK / TCMB) and ISO 13616 / ISO 7064 MOD-97-10.
pub struct VirtualIbanService;

impl VirtualIbanService {
    /// Kuveyt Türk Bank Code (Kuveyt Türk Katılım Bankası A.Ş.)
    pub const KUVEYT_TURK_BANK_CODE: &'static str = "00205";

    /// Calculates ISO 7064 MOD-97-10 check digits for a given Turkish BBAN.
    ///
    /// BBAN structure: 5-digit Bank Code + 1-digit Reserve ("0") + 16-digit Account/Sub-Account Number.
    /// Total BBAN length: 22 digits.
    pub fn compute_check_digits(bban: &str) -> String {
        // Rearrange for calculation: BBAN + "TR00" -> BBAN + "292700"
        let rearranged = format!("{}292700", bban);

        let mut remainder: u64 = 0;
        for ch in rearranged.chars() {
            if let Some(digit) = ch.to_digit(10) {
                remainder = (remainder * 10 + digit as u64) % 97;
            }
        }

        let check_num = 98 - remainder;
        format!("{:02}", check_num)
    }

    /// Verifies if a given Turkish IBAN is valid according to ISO 7064 MOD-97-10.
    #[allow(dead_code)]
    pub fn validate_tr_iban(iban: &str) -> bool {
        let clean = iban.replace(' ', "").to_uppercase();
        if clean.len() != 26 || !clean.starts_with("TR") {
            return false;
        }

        // Move first 4 characters to end: IBAN[4..] + IBAN[0..4]
        // "TR" -> "2927"
        let check_digits = &clean[2..4];
        let bban = &clean[4..];
        let check_string = format!("{}2927{}", bban, check_digits);

        let mut remainder: u64 = 0;
        for ch in check_string.chars() {
            if let Some(digit) = ch.to_digit(10) {
                remainder = (remainder * 10 + digit as u64) % 97;
            } else {
                return false;
            }
        }

        remainder == 1
    }

    /// Formats a 26-character TR IBAN with 4-character grouping for display (e.g. "TR83 0020 5000 ...").
    pub fn format_for_display(iban: &str) -> String {
        let clean = iban.replace(' ', "").to_uppercase();
        if clean.len() != 26 {
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

    /// Generates a flat-specific Virtual IBAN under a parent site commercial account for Kuveyt Türk.
    ///
    /// Rules:
    /// - Bank code: 5 digits (e.g. "00205" for Kuveyt Türk)
    /// - Reserve: 1 digit ("0")
    /// - Site Account Prefix: derived from the site master account or site index (10 digits)
    /// - Unit Suffix: zero-padded unit number (6 digits, e.g. unit 14 -> "000014")
    /// - Calculated Check Digits: 2 digits (MOD 97)
    pub fn generate_virtual_iban(
        bank_code: &str,
        site_id: &str,
        block_id: &str,
        unit_number: i32,
    ) -> String {
        let clean_bank_code = format!("{:0>5}", bank_code.trim());
        let reserve = "0";

        // Generate deterministic 10-digit site prefix
        // For site-1 (Begonya Sitesi), use Kuveyt Türk account branch root "0009863791"
        let site_hash = site_id
            .bytes()
            .fold(9863791u64, |acc, b| (acc.wrapping_mul(31)).wrapping_add(b as u64));
        let block_hash = block_id
            .bytes()
            .fold(0u64, |acc, b| acc.wrapping_add(b as u64));
        let site_prefix = format!("{:010}", (site_hash + block_hash) % 10000000000);

        // Unit suffix (6 digits)
        let unit_suffix = format!("{:06}", unit_number.abs() % 1000000);

        // 16-digit sub-account
        let account_number = format!("{}{}", &site_prefix[0..10], unit_suffix);

        // 22-digit BBAN
        let bban = format!("{}{}{}", clean_bank_code, reserve, account_number);

        // Check digits
        let check_digits = Self::compute_check_digits(&bban);

        format!("TR{}{}", check_digits, bban)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_validates_generated_virtual_iban() {
        let iban = VirtualIbanService::generate_virtual_iban("00205", "site-1", "A", 14);
        assert_eq!(iban.len(), 26);
        assert!(iban.starts_with("TR"));
        assert!(iban.contains("00205"));
        assert!(VirtualIbanService::validate_tr_iban(&iban));
    }

    #[test]
    fn test_unique_virtual_ibans_for_different_flats() {
        let iban_14 = VirtualIbanService::generate_virtual_iban("00205", "site-1", "A", 14);
        let iban_15 = VirtualIbanService::generate_virtual_iban("00205", "site-1", "A", 15);
        let iban_b14 = VirtualIbanService::generate_virtual_iban("00205", "site-1", "B", 14);

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
}
