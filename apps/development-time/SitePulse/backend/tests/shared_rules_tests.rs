//! Call-site regression tests for rules consolidated into `domain`:
//! Turkish folding in reconciliation and slugs, and email identity matching.

use chrono::Utc;
use sitepulse_backend::models::*;
use sitepulse_backend::services::{to_slug, AuthService, ReconciliationService};
use sitepulse_backend::state::AppState;

#[test]
fn when_slugging_dotted_capital_i_then_no_stray_hyphen_is_produced() {
    // Previously "i-stanbul-evleri": lower-casing İ leaves U+0307, which became '-'.
    assert_eq!(to_slug("İstanbul Evleri"), "istanbul-evleri");
    assert_eq!(to_slug("Yıldız Park Evleri"), "yildiz-park-evleri");
    assert_eq!(to_slug("   "), "site");
}

#[test]
fn when_matching_upper_case_bank_narrative_then_dotted_i_names_match() {
    // Bank narratives arrive upper-cased; "İREM KOÇ" must match "irem koç".
    assert!(ReconciliationService::text_contains_name(
        "HAVALE İREM KOÇ EKİM AİDAT",
        "İrem Koç"
    ));
    assert!(ReconciliationService::text_contains_name(
        "HAVALE IREM KOC",
        "İrem Koç"
    ));
    assert_eq!(
        ReconciliationService::normalize_turkish("İSTANBUL"),
        "istanbul"
    );
}

#[tokio::test]
async fn when_stored_email_has_surrounding_whitespace_then_login_still_finds_user() {
    let state = AppState::new();
    let password = "Correct-Horse-9!";
    {
        let mut inner = state.inner.write().await;
        inner.users.push(User {
            id: "usr-ws".to_string(),
            site_id: "site-1".to_string(),
            full_name: "Whitespace User".to_string(),
            email: "  Mixed.Case@Example.COM ".to_string(),
            phone: String::new(),
            password_hash: Some(sitepulse_backend::auth::hash_password(password)),
            role: Role::HomeOwner,
            must_change_password: false,
            auth_provider: AuthProvider::Local,
            google_sub: None,
            avatar_url: None,
            created_at: Utc::now(),
            person_id: None,
        });
    }
    let service = AuthService::new(state);
    let res = service
        .authenticate_with_password(PasswordLoginRequest {
            email: "mixed.case@example.com".to_string(),
            password: password.to_string(),
        })
        .await;
    assert!(
        res.is_ok(),
        "stored value must be normalized like the input: {:?}",
        res.err()
    );
}

#[test]
fn when_mt940_contains_debits_and_reversals_then_only_credits_are_imported_and_rest_reported() {
    use sitepulse_backend::services::BankStatementParser;
    let content =
        ":20:STMT\n:25:TR120006200000000000001001\n:28C:00001/001\n:60F:C260901TRY50000,00\n\
:61:2609150915C1423,33NTRFNONREF//TXN-CREDIT\n:86:HAVALE A BLOK D:14 EYLUL AIDAT\n\
:61:2609160916D9000,00NTRFNONREF//TXN-DEBIT\n:86:ASANSOR BAKIM ODEMESI\n\
:61:2609170917RC100,00NTRFNONREF//TXN-REVERSAL\n:86:IADE\n\
:61:GARBAGE\n:86:BOZUK SATIR\n:62F:C260930TRY42423,33\n-";
    let report = BankStatementParser::new()
        .parse_statement_report(
            content,
            Some(BankStatementFormat::Mt940),
            chrono::NaiveDate::from_ymd_opt(2026, 9, 30).unwrap(),
        )
        .unwrap();
    let ids: Vec<&str> = report
        .transactions
        .iter()
        .map(|t| t.transaction_id.as_str())
        .collect();
    assert_eq!(
        ids,
        vec!["TXN-CREDIT"],
        "an outgoing debit must never become an incoming payment"
    );
    let reasons: Vec<&str> = report.skipped.iter().map(|s| s.reason.as_str()).collect();
    assert_eq!(report.skipped.len(), 3, "{reasons:?}");
    assert!(reasons[0].starts_with("Debit entry"));
    assert!(reasons[1].starts_with("Reversal entry"));
    assert!(reasons[2].starts_with("Unrecognized"));
    assert_eq!(report.skipped[0].line_number, 7);
}

#[test]
fn when_tabular_rows_lack_amount_or_date_then_rows_are_reported_and_fallback_date_is_used() {
    use sitepulse_backend::services::BankStatementParser;
    let fallback = chrono::NaiveDate::from_ymd_opt(2026, 1, 2).unwrap();
    let content = "Tarih;Açıklama;Tutar\nAHMET YILMAZ A BLOK D:14;1.423,33\nAÇIKLAMASIZ SATIR\n";
    let report = BankStatementParser::new()
        .parse_statement_report(content, Some(BankStatementFormat::Csv), fallback)
        .unwrap();
    assert_eq!(report.transactions.len(), 1);
    assert_eq!(report.transactions[0].date, fallback);
    assert_eq!(report.skipped.len(), 1);
    assert_eq!(report.skipped[0].line_number, 3);
}
