//! Canonical fingerprints and HMAC signatures.
//!
//! The canonical strings below are **persisted contracts**: webhook payload
//! hashes are stored for redelivery detection and receipt hashes are printed on
//! receipts. Never change a canonical form in place; add a new versioned
//! function and migrate callers deliberately. The golden-hash tests pin every
//! version.
//!
//! Amounts are rendered with `{:.2}` (two decimal places). Callers pass amounts
//! that are already at money scale, so the formatting never has to round.

use chrono::{DateTime, Utc};
use hmac::digest::KeyInit;
use hmac::{Hmac, Mac};
use rust_decimal::Decimal;
use sha2::{Digest, Sha256};

/// Fields that define one incoming bank transfer.
#[derive(Debug, Clone, Copy)]
pub struct TransferFields<'a> {
    pub transaction_id: &'a str,
    pub amount: Decimal,
    /// `None` means the provider omitted it; TRY is assumed.
    pub currency: Option<&'a str>,
    pub virtual_iban: &'a str,
    pub sender_iban: Option<&'a str>,
    pub description: Option<&'a str>,
}

/// Fields printed on, and verified from, a payment receipt.
#[derive(Debug, Clone, Copy)]
pub struct ReceiptFields<'a> {
    pub receipt_number: &'a str,
    pub unit_id: &'a str,
    pub total_amount: Decimal,
    pub issued_at: &'a DateTime<Utc>,
}

/// Canonical form v1 of a bank transfer:
/// `txn_id|amount(2dp)|CURRENCY|VIRTUALIBAN|SENDERIBAN|description`, where IBANs
/// are upper-cased with spaces removed and text fields are trimmed.
pub fn transfer_canonical_v1(fields: &TransferFields<'_>) -> String {
    let compact_upper = |s: Option<&str>| s.unwrap_or("").replace(' ', "").to_uppercase();
    format!(
        "{}|{:.2}|{}|{}|{}|{}",
        fields.transaction_id.trim(),
        fields.amount,
        fields.currency.unwrap_or("TRY").trim().to_uppercase(),
        compact_upper(Some(fields.virtual_iban)),
        compact_upper(fields.sender_iban),
        fields.description.unwrap_or("").trim(),
    )
}

/// SHA-256 (lower-case hex) of [`transfer_canonical_v1`]. Distinguishes a
/// redelivery from a transaction id reused for a different transfer.
pub fn transfer_hash_v1(fields: &TransferFields<'_>) -> String {
    sha256_hex(transfer_canonical_v1(fields).as_bytes())
}

/// Canonical form v1 of a receipt: `sitepulse:receipt:unit:amount(2dp):issued_at(RFC 3339)`.
pub fn receipt_canonical_v1(fields: &ReceiptFields<'_>) -> String {
    format!(
        "sitepulse:{}:{}:{:.2}:{}",
        fields.receipt_number,
        fields.unit_id,
        fields.total_amount,
        fields.issued_at.to_rfc3339()
    )
}

/// SHA-256 (lower-case hex) of [`receipt_canonical_v1`].
pub fn receipt_hash_v1(fields: &ReceiptFields<'_>) -> String {
    sha256_hex(receipt_canonical_v1(fields).as_bytes())
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

/// `hex(HMAC-SHA256(secret, body))`.
pub fn hmac_sha256_hex(secret: &[u8], body: &[u8]) -> String {
    hex::encode(hmac_sha256(secret, body))
}

/// Verifies `hex(HMAC-SHA256(secret, body))` in constant time. Accepts an
/// optional `sha256=` prefix. An empty secret never verifies, so a missing
/// configuration cannot turn into "accept everything".
pub fn verify_hmac_sha256_hex(secret: &[u8], body: &[u8], signature_hex: &str) -> bool {
    if secret.is_empty() {
        return false;
    }
    let Ok(signature) = hex::decode(signature_hex.trim().trim_start_matches("sha256=")) else {
        return false;
    };
    let Ok(mut mac) = <Hmac<Sha256> as KeyInit>::new_from_slice(secret) else {
        return false;
    };
    mac.update(body);
    mac.verify_slice(&signature).is_ok()
}

fn hmac_sha256(secret: &[u8], body: &[u8]) -> Vec<u8> {
    match <Hmac<Sha256> as KeyInit>::new_from_slice(secret) {
        Ok(mut mac) => {
            mac.update(body);
            mac.finalize().into_bytes().to_vec()
        }
        // HMAC-SHA256 accepts keys of any length, so this branch is unreachable;
        // an empty tag can never verify against a real signature.
        Err(_) => Vec::new(),
    }
}

/// One allocation line covered by a v2 receipt hash.
#[derive(Debug, Clone, Copy)]
pub struct AllocationLine<'a> {
    pub due_id: &'a str,
    pub principal: Decimal,
    pub penalty: Decimal,
}

/// Fields of a v2 receipt hash: v1 plus the payer and every allocation line, so
/// a receipt whose payer or allocation was altered no longer verifies.
#[derive(Debug, Clone, Copy)]
pub struct ReceiptFieldsV2<'a> {
    pub base: ReceiptFields<'a>,
    pub payer_name: &'a str,
    pub payer_role: &'a str,
    pub allocations: &'a [AllocationLine<'a>],
}

/// Canonical form v2 of a receipt:
/// `sitepulse:v2:<v1 fields>:<payer role>:<payer name>:<due=principal/penalty;...>`.
/// The payer name is trimmed; allocation lines keep the receipt's order.
pub fn receipt_canonical_v2(fields: &ReceiptFieldsV2<'_>) -> String {
    let lines: Vec<String> = fields
        .allocations
        .iter()
        .map(|a| format!("{}={:.2}/{:.2}", a.due_id, a.principal, a.penalty))
        .collect();
    format!(
        "sitepulse:v2:{}:{}:{:.2}:{}:{}:{}:{}",
        fields.base.receipt_number,
        fields.base.unit_id,
        fields.base.total_amount,
        fields.base.issued_at.to_rfc3339(),
        fields.payer_role,
        fields.payer_name.trim(),
        lines.join(";")
    )
}

/// SHA-256 (lower-case hex) of [`receipt_canonical_v2`]. Same length as v1, so
/// stored and printed codes of both versions verify by equality.
pub fn receipt_hash_v2(fields: &ReceiptFieldsV2<'_>) -> String {
    sha256_hex(receipt_canonical_v2(fields).as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn d(s: &str) -> Decimal {
        Decimal::from_str_exact(s).unwrap()
    }

    #[test]
    fn transfer_v1_golden() {
        let fields = TransferFields {
            transaction_id: " TXN-1 ",
            amount: d("1400.00"),
            currency: None,
            virtual_iban: "TR41 0020 5042 1399 1067 0000 14",
            sender_iban: Some("tr99 0006 2000 0000 0000 9999 88"),
            description: Some(" Ekim 2026 aidat "),
        };
        assert_eq!(
            transfer_canonical_v1(&fields),
            "TXN-1|1400.00|TRY|TR410020504213991067000014|TR990006200000000000999988|Ekim 2026 aidat"
        );
        assert_eq!(
            transfer_hash_v1(&fields),
            sha256_hex(transfer_canonical_v1(&fields).as_bytes())
        );
        assert_eq!(
            transfer_hash_v1(&fields),
            "bd1a0e0f4be7e30a8dca62eb4915458862dabc83b2fd26f9f3a708902745bd86",
            "transfer v1 is a persisted contract; add a v2 instead of changing it"
        );
    }

    #[test]
    fn receipt_v1_golden() {
        let issued_at = Utc.with_ymd_and_hms(2026, 10, 5, 9, 30, 0).unwrap();
        let fields = ReceiptFields {
            receipt_number: "RCP-2026-000001",
            unit_id: "d-14",
            total_amount: d("1400.00"),
            issued_at: &issued_at,
        };
        assert_eq!(
            receipt_canonical_v1(&fields),
            "sitepulse:RCP-2026-000001:d-14:1400.00:2026-10-05T09:30:00+00:00"
        );
        assert_eq!(
            receipt_hash_v1(&fields),
            "89e2bcc34f62a816a36aaef3aa01803ef20a38a0fdd3a30f580df9da8d9b1dc1",
            "receipt v1 is a persisted contract; add a v2 instead of changing it"
        );
    }

    #[test]
    fn hmac_round_trip_and_rejections() {
        let body = br#"{"transaction_id":"TXN-1"}"#;
        let sig = hmac_sha256_hex(b"secret", body);
        assert!(verify_hmac_sha256_hex(b"secret", body, &sig));
        assert!(verify_hmac_sha256_hex(
            b"secret",
            body,
            &format!("sha256={sig}")
        ));
        assert!(!verify_hmac_sha256_hex(b"wrong", body, &sig));
        assert!(!verify_hmac_sha256_hex(b"secret", b"tampered", &sig));
        assert!(!verify_hmac_sha256_hex(b"secret", body, "not-hex"));
        assert!(!verify_hmac_sha256_hex(
            b"",
            body,
            &hmac_sha256_hex(b"", body)
        ));
    }

    #[test]
    fn receipt_hash_v2_is_a_persisted_contract() {
        let issued = chrono::DateTime::parse_from_rfc3339("2027-01-15T10:30:00+00:00")
            .map(|d| d.with_timezone(&Utc))
            .unwrap_or_default();
        let lines = [AllocationLine {
            due_id: "42",
            principal: Decimal::new(150000, 2),
            penalty: Decimal::new(7500, 2),
        }];
        let fields = ReceiptFieldsV2 {
            base: ReceiptFields {
                receipt_number: "TAH-2027-000001",
                unit_id: "14",
                total_amount: Decimal::new(157500, 2),
                issued_at: &issued,
            },
            payer_name: " Ayşe Yılmaz ",
            payer_role: "OWNER",
            allocations: &lines,
        };
        assert_eq!(
            receipt_canonical_v2(&fields),
            "sitepulse:v2:TAH-2027-000001:14:1575.00:2027-01-15T10:30:00+00:00:OWNER:Ayşe Yılmaz:42=1500.00/75.00"
        );
        assert_eq!(receipt_hash_v2(&fields).len(), 64);
        assert_eq!(
            receipt_hash_v2(&fields),
            "2f9cadb362efbab5f06eab01ec6144c748c890988ea9edd1febfe05cdc0ad015",
            "persisted contract: receipt_hash_v2 must never change"
        );
    }
}
