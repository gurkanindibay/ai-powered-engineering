//! Visual review helper for receipt PDF rendering (SPEC-007 R3).
//!
//! Generates a sample payment receipt PDF to the path specified in `$SITEPULSE_SAMPLE_PDF`
//! (or defaults to `sample_receipt.pdf` in the current directory if unset):
//!
//! ```bash
//! SITEPULSE_SAMPLE_PDF=/tmp/receipt.pdf cargo run --example sample_receipt_pdf
//! ```

use chrono::{Days, NaiveDate, Utc};
use rust_decimal::Decimal;
use sitepulse_backend::models::*;
use sitepulse_backend::services::receipt_document;
use sitepulse_backend::services::*;
use sitepulse_backend::state::AppState;
use std::path::PathBuf;

const SITE: &str = "site-1";

fn d(s: &str) -> Decimal {
    Decimal::from_str_exact(s).expect("valid decimal literal")
}

fn today() -> NaiveDate {
    Utc::now().date_naive()
}

async fn site_with_two_units() -> AppState {
    let state = AppState::new_with_test_fixtures();
    {
        let mut inner = state.inner.write().await;
        inner.dues.clear();
        inner.advance_balances.clear();
        inner.payment_receipts.clear();
        inner.payment_entries.clear();
        inner.payment_idempotency.clear();
        let mut second = inner
            .units
            .iter()
            .find(|u| u.id == "d-14")
            .cloned()
            .expect("unit d-14 exists");
        second.id = "d-15".to_string();
        second.unit_number = 15;
        second.land_share = 12;
        second.house_type = Some("2+1".to_string());
        second.virtual_iban = None;
        inner.units.push(second);
    }
    state
}

async fn owner_owing(amount: &str) -> AppState {
    let state = site_with_two_units().await;
    state.inner.write().await.dues.push(DuesLiability {
        id: "op-1".to_string(),
        unit_id: "d-14".to_string(),
        period: "Kasım 2026".to_string(),
        principal_amount: d(amount),
        delay_penalty: Decimal::ZERO,
        total_amount: d(amount),
        due_date: today() + Days::new(5),
        status: DebtStatus::Pending,
        paid_principal: Decimal::ZERO,
        paid_penalty: Decimal::ZERO,
        debtor_type: DebtorType::Owner,
        expense_type: ExpenseType::OperationalDues,
        penalty_accrued_through: None,
        grace_days: 0,
        effective_due_date: None,
        liable_person_id: None,
    });
    state
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let target_path = std::env::var("SITEPULSE_SAMPLE_PDF")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("sample_receipt.pdf"));

    let state = owner_owing("1800.00").await;
    {
        let mut inner = state.inner.write().await;
        let site = inner
            .sites
            .iter_mut()
            .find(|s| s.id == SITE)
            .expect("site exists");
        site.tax_id = Some("1234567890".into());
        site.tax_office = Some("Kadıköy".into());
    }
    let receipt = PaymentTrackingService::new(state)
        .record_and_allocate_payment(RecordManualPaymentRequest {
            site_id: Some(SITE.into()),
            unit_id: "d-14".into(),
            amount: d("2000.00"),
            payer_name: "Şükrü Işıkoğlu".into(),
            payer_role: DebtorType::Owner,
            payment_channel: PaymentChannel::CreditCard,
            ..Default::default()
        })
        .await
        .map_err(|e| format!("failed to record payment: {e:?}"))?;

    let pdf = receipt_document::render_receipt_pdf(&receipt, "A Blok D:14")
        .map_err(|e| format!("failed to render pdf: {e:?}"))?;

    std::fs::write(&target_path, pdf)?;
    println!("Sample receipt PDF written to {}", target_path.display());
    Ok(())
}
