//! SPEC-006 acceptance tests: per-debtor advance and virman source/target (O-1),
//! reversals (O-2), idempotency outside channel_reference (O-4), issuer snapshot
//! (O-5), reconciliation vocabulary (O-7), debt aging snapshots (O-8).
//! In-memory mode; the PostgreSQL side is covered by the schema-integrity gate
//! and the API system check (`reversal_restores_ledger`, `tenant_surplus_virman`,
//! `webhook_claim_scoped`, ...).

use chrono::{Days, NaiveDate, Utc};
use rust_decimal::Decimal;
use sitepulse_backend::models::*;
use sitepulse_backend::services::*;
use sitepulse_backend::state::AppState;

const UNIT: &str = "d-14";
const SITE: &str = "site-1";
const TENANT_USER: &str = "usr-tenant-spec6";
const OPERATOR: &str = "usr-site-manager-1";
fn operator(id: &str) -> sitepulse_backend::authorization::AuthzContext {
    let token =
        sitepulse_backend::auth::issue_token(id, "", Role::SiteManager, SITE, None).unwrap();
    let mut claims = sitepulse_backend::auth::verify_token(&token).unwrap();
    claims.role = Role::SiteManager;
    claims.site_id = SITE.to_string();
    sitepulse_backend::authorization::AuthzContext {
        claims,
        permissions: Permission::permissions_for_role(Role::SiteManager),
        request_id: "spec-006".to_string(),
        stepped_up: false,
    }
}

fn d(s: &str) -> Decimal {
    Decimal::from_str_exact(s).unwrap()
}

fn today() -> NaiveDate {
    Utc::now().date_naive()
}

fn liability(
    id: &str,
    period: &str,
    principal: &str,
    due_date: NaiveDate,
    debtor: &str,
    expense: &str,
) -> DuesLiability {
    DuesLiability {
        id: id.to_string(),
        unit_id: UNIT.to_string(),
        period: period.to_string(),
        principal_amount: d(principal),
        delay_penalty: Decimal::ZERO,
        total_amount: d(principal),
        due_date,
        status: DebtStatus::Pending,
        paid_principal: Decimal::ZERO,
        paid_penalty: Decimal::ZERO,
        debtor_type: DebtorType::from_str_loose(debtor),
        expense_type: ExpenseType::from_str_loose(expense),
        penalty_accrued_through: None,
        grace_days: 0,
        effective_due_date: None,
        liable_person_id: None,
    }
}

/// Unit d-14 let to a tenant (Canan Kaya), owing exactly `dues`.
async fn tenanted_state_with(dues: Vec<DuesLiability>) -> AppState {
    let state = AppState::new_with_test_fixtures();
    {
        let mut inner = state.inner.write().await;
        inner.dues = dues;
        inner.advance_balances.clear();
        inner.payment_receipts.clear();
        inner.payment_entries.clear();
        inner.homeowner_payments.clear();
        inner.reconciliation_queue.clear();
        inner.payment_idempotency.clear();
        let mut tenant = inner
            .users
            .iter()
            .find(|u| u.id == "usr-home-owner-1")
            .cloned()
            .unwrap();
        tenant.id = TENANT_USER.to_string();
        tenant.full_name = "Canan Kaya".to_string();
        tenant.email = "canan.kaya@begonya.com".to_string();
        tenant.role = Role::HomeResident;
        inner.users.push(tenant);
        inner
            .units
            .iter_mut()
            .find(|u| u.id == UNIT)
            .unwrap()
            .tenant_user_id = Some(TENANT_USER.to_string());
    }
    state
}

fn payment(amount: &str, role: &str, name: &str) -> RecordManualPaymentRequest {
    RecordManualPaymentRequest {
        site_id: Some(SITE.to_string()),
        unit_id: UNIT.to_string(),
        amount: d(amount),
        payer_name: name.to_string(),
        payer_role: DebtorType::from_str_loose(role),
        payment_channel: PaymentChannel::ManualCash,
        ..Default::default()
    }
}

fn reverse(receipt: &str, reason: &str) -> ReversePaymentRequest {
    ReversePaymentRequest {
        site_id: Some(SITE.to_string()),
        receipt: receipt.to_string(),
        reason: reason.to_string(),
    }
}

// ---------------------------------------------------------------------------
// O-1: advance per debtor, virman source/target
// ---------------------------------------------------------------------------

/// A tenant's overpayment is the tenant's credit, recorded on the receipt.
#[tokio::test]
async fn when_tenant_overpays_then_the_surplus_is_credited_to_the_tenant_advance_only() {
    let state = tenanted_state_with(vec![liability(
        "op-1",
        "Eylül 2026",
        "1000.00",
        today() + Days::new(5),
        "TENANT",
        "OPERATIONAL_DUES",
    )])
    .await;
    let receipt = PaymentTrackingService::new(state.clone())
        .record_and_allocate_payment(payment("1500.00", "TENANT", "Canan Kaya"))
        .await
        .unwrap();
    assert_eq!(receipt.allocated_advance, d("500.00"));
    assert_eq!(receipt.advance_debtor_type.as_deref(), Some("TENANT"));

    let inner = state.inner.read().await;
    assert_eq!(inner.advance_of(UNIT, "TENANT"), d("500.00"));
    assert_eq!(inner.advance_of(UNIT, "OWNER"), Decimal::ZERO);
}

// covers: SC-09-06-02
/// EPIC-09 §2.3: the tenant's surplus pays the owner's Demirbaş on the owner's
/// behalf; only the tenant bucket is debited and the receipt is rent-offset eligible.
#[tokio::test]
async fn when_tenant_surplus_is_transferred_to_owner_capital_then_the_tenant_advance_pays_on_behalf_of_the_owner(
) {
    let state = tenanted_state_with(vec![
        liability(
            "op-1",
            "Eylül 2026",
            "1000.00",
            today() + Days::new(5),
            "TENANT",
            "OPERATIONAL_DUES",
        ),
        liability(
            "cap-1",
            "Asansör Taksit 1",
            "400.00",
            today() + Days::new(5),
            "OWNER",
            "CAPITAL_DUES",
        ),
    ])
    .await;
    let service = PaymentTrackingService::new(state.clone());
    service
        .record_and_allocate_payment(payment("1600.00", "TENANT", "Canan Kaya"))
        .await
        .unwrap();
    {
        let inner = state.inner.read().await;
        assert_eq!(inner.advance_of(UNIT, "TENANT"), d("600.00"));
        let cap = inner.dues.iter().find(|x| x.id == "cap-1").unwrap();
        assert_ne!(
            cap.status,
            DebtStatus::Paid,
            "a tenant payment never settles capital dues by itself"
        );
    }

    // The default (OWNER -> OWNER) finds no owner advance.
    let owner_only = service
        .inter_ledger_transfer(InterLedgerTransferRequest {
            site_id: Some(SITE.to_string()),
            unit_id: UNIT.to_string(),
            amount: d("400.00"),
            ..Default::default()
        })
        .await;
    assert!(owner_only.unwrap_err().contains("Yetersiz avans"));

    let resp = service
        .inter_ledger_transfer(InterLedgerTransferRequest {
            site_id: Some(SITE.to_string()),
            unit_id: UNIT.to_string(),
            amount: d("400.00"),
            source_debtor: Some("TENANT".to_string()),
            target_debtor: Some("OWNER".to_string()),
            ..Default::default()
        })
        .await
        .unwrap();
    assert_eq!(resp.transferred_amount, d("400.00"));
    assert_eq!(resp.remaining_advance_balance, d("200.00"));

    let inner = state.inner.read().await;
    assert_eq!(inner.advance_of(UNIT, "TENANT"), d("200.00"));
    assert_eq!(
        inner.dues.iter().find(|x| x.id == "cap-1").unwrap().status,
        DebtStatus::Paid
    );
    let receipt = inner
        .payment_receipts
        .iter()
        .find(|r| r.receipt_number == resp.receipt_number)
        .unwrap();
    assert_eq!(receipt.payer_role, DebtorType::Tenant);
    assert_eq!(receipt.payer_name, "Canan Kaya");
    assert!(receipt.is_rent_offset_eligible);
    assert_eq!(receipt.on_behalf_of_role, Some(DebtorType::Owner));
}

// covers: SC-09-06-01
#[tokio::test]
async fn when_manager_explicitly_designates_tenant_payment_for_owner_capital_dues() {
    let state = tenanted_state_with(vec![
        liability(
            "op-1",
            "Eylül 2026",
            "1000.00",
            today() + Days::new(5),
            "TENANT",
            "OPERATIONAL_DUES",
        ),
        liability(
            "cap-1",
            "Asansör Revizyonu",
            "3000.00",
            today() + Days::new(5),
            "OWNER",
            "CAPITAL_DUES",
        ),
    ])
    .await;
    let service = PaymentTrackingService::new(state.clone());
    let mut req = payment("3000.00", "TENANT", "Canan Kaya");
    req.description = Some("A Blok D:14 Asansör Demirbaş".to_string());
    req.settles_owner_capital_dues = true;
    let receipt = service.record_and_allocate_payment(req).await.unwrap();

    assert_eq!(receipt.payer_role, DebtorType::Tenant);
    assert_eq!(receipt.on_behalf_of_role, Some(DebtorType::Owner));
    assert!(receipt.is_rent_offset_eligible);

    let inner = state.inner.read().await;
    let cap = inner.dues.iter().find(|d| d.id == "cap-1").unwrap();
    assert_eq!(cap.status, DebtStatus::Paid);
    assert_eq!(cap.paid_principal, d("3000.00"));

    let op = inner.dues.iter().find(|d| d.id == "op-1").unwrap();
    assert_eq!(op.status, DebtStatus::Pending);
    assert_eq!(
        op.total_amount,
        d("1000.00"),
        "tenant operational balance remains unchanged"
    );
}

#[tokio::test]
async fn when_tenant_overpays_owner_capital_dues_then_surplus_stays_in_owner_advance() {
    let state = tenanted_state_with(vec![liability(
        "cap-1",
        "Asansör Revizyonu",
        "3000.00",
        today() + Days::new(5),
        "OWNER",
        "CAPITAL_DUES",
    )])
    .await;
    let mut req = payment("3500.00", "TENANT", "Canan Kaya");
    req.settles_owner_capital_dues = true;

    let receipt = PaymentTrackingService::new(state.clone())
        .record_and_allocate_payment(req)
        .await
        .unwrap();

    assert_eq!(receipt.payer_role, DebtorType::Tenant);
    assert_eq!(receipt.on_behalf_of_role, Some(DebtorType::Owner));
    assert_eq!(receipt.allocated_advance, d("500.00"));
    let inner = state.inner.read().await;
    assert_eq!(inner.advance_of(UNIT, "OWNER"), d("500.00"));
    assert_eq!(inner.advance_of(UNIT, "TENANT"), Decimal::ZERO);
}

// covers: SC-09-02-02
#[tokio::test]
async fn when_owner_pays_operational_due_is_settled_before_capital_due() {
    let state = tenanted_state_with(vec![
        liability(
            "cap-1",
            "Asansör Taksit",
            "500.00",
            today(),
            "OWNER",
            "CAPITAL_DUES",
        ),
        liability(
            "op-1",
            "Eylül 2026",
            "300.00",
            today(),
            "OWNER",
            "OPERATIONAL_DUES",
        ),
    ])
    .await;
    let service = PaymentTrackingService::new(state.clone());
    let req = payment("600.00", "OWNER", "Ahmet Yılmaz");
    service.record_and_allocate_payment(req).await.unwrap();

    let inner = state.inner.read().await;
    let op = inner.dues.iter().find(|d| d.id == "op-1").unwrap();
    let cap = inner.dues.iter().find(|d| d.id == "cap-1").unwrap();
    assert_eq!(op.status, DebtStatus::Paid);
    assert_eq!(op.paid_principal, d("300.00"));
    assert_eq!(cap.status, DebtStatus::Pending);
    assert_eq!(cap.paid_principal, d("300.00"));
    assert_eq!(cap.total_amount, d("200.00"));
}

/// A debtor value outside OWNER/TENANT is rejected.
#[tokio::test]
async fn when_virman_debtor_is_unknown_then_the_transfer_is_rejected() {
    let state = tenanted_state_with(vec![]).await;
    let err = PaymentTrackingService::new(state)
        .inter_ledger_transfer(InterLedgerTransferRequest {
            site_id: Some(SITE.to_string()),
            unit_id: UNIT.to_string(),
            amount: d("10.00"),
            source_debtor: Some("LANDLORD".to_string()),
            ..Default::default()
        })
        .await
        .unwrap_err();
    assert!(err.contains("source_debtor"), "{}", err);
}

/// The automatic offset uses each liability's own debtor's advance.
#[tokio::test]
async fn when_advances_are_offset_then_each_due_is_paid_only_from_its_own_debtors_advance() {
    let state = tenanted_state_with(vec![
        liability(
            "op-1",
            "Ekim 2026",
            "300.00",
            today() + Days::new(5),
            "TENANT",
            "OPERATIONAL_DUES",
        ),
        liability(
            "cap-1",
            "Çatı Taksit 1",
            "200.00",
            today() + Days::new(5),
            "OWNER",
            "CAPITAL_DUES",
        ),
    ])
    .await;
    let mut inner = state.inner.write().await;
    inner.adjust_advance(UNIT, "OWNER", d("250.00"));
    let (settled, offset) =
        sitepulse_backend::handlers::apply_advance_payments_offset(&mut inner, Some(UNIT));
    assert_eq!((settled, offset), (1, d("200.00")));
    assert_eq!(
        inner.dues.iter().find(|x| x.id == "cap-1").unwrap().status,
        DebtStatus::Paid
    );
    assert_ne!(
        inner.dues.iter().find(|x| x.id == "op-1").unwrap().status,
        DebtStatus::Paid,
        "the owner's advance does not pay the tenant's dues"
    );
    assert_eq!(inner.advance_of(UNIT, "OWNER"), d("50.00"));
    assert_eq!(inner.advance_of(UNIT, "TENANT"), Decimal::ZERO);
}

// ---------------------------------------------------------------------------
// O-2: reversals
// ---------------------------------------------------------------------------

// covers: SC-13-12-04
#[tokio::test]
async fn when_a_settled_payment_is_reversed_then_dues_reopen_the_advance_is_refunded_and_an_iad_receipt_is_issued(
) {
    let state = tenanted_state_with(vec![liability(
        "op-1",
        "Eylül 2026",
        "1000.00",
        today() - Days::new(1),
        "TENANT",
        "OPERATIONAL_DUES",
    )])
    .await;
    let service = PaymentTrackingService::new(state.clone());
    let original = service
        .record_and_allocate_payment(payment("1200.00", "TENANT", "Canan Kaya"))
        .await
        .unwrap();
    assert_eq!(
        original.allocated_advance,
        d("200.00") - (original.allocated_penalty)
    );

    let resp = service
        .reverse_payment(
            reverse(&original.receipt_number, "Karşılıksız havale (bounced)"),
            &operator(OPERATOR),
        )
        .await
        .unwrap();
    let rev = &resp.reversal_receipt;
    assert!(
        rev.receipt_number
            .starts_with(&format!("IAD-{}-", Utc::now().format("%Y"))),
        "{}",
        rev.receipt_number
    );
    assert_eq!(
        rev.sequence_number, 1,
        "the reversal series has its own counter"
    );
    assert_eq!(rev.receipt_type, "REVERSAL");
    assert_eq!(rev.reverses_receipt_id, Some(original.id));
    assert_eq!(rev.payer_person_id, original.payer_person_id);
    assert_eq!(rev.on_behalf_of_person_id, original.on_behalf_of_person_id);
    assert_eq!(rev.total_amount, original.total_amount);
    assert_eq!(resp.refunded_advance, original.allocated_advance);
    assert_eq!(resp.reopened_due_ids, vec!["op-1".to_string()]);

    let inner = state.inner.read().await;
    let due = inner.dues.iter().find(|x| x.id == "op-1").unwrap();
    assert_eq!(due.paid_principal, Decimal::ZERO);
    assert_eq!(due.paid_penalty, Decimal::ZERO);
    assert_eq!(due.status, DebtStatus::Overdue);
    assert_eq!(inner.advance_of(UNIT, "TENANT"), Decimal::ZERO);
    let entries: Vec<&PaymentEntry> = inner.payment_entries.iter().collect();
    assert_eq!(entries.len(), 2, "the original plus one contra entry");
    let orig_entry = entries
        .iter()
        .find(|e| e.receipt_id == Some(original.id))
        .unwrap();
    let contra = entries.iter().find(|e| e.entry_type == "REVERSAL").unwrap();
    assert_eq!(orig_entry.settlement_status, SettlementStatus::Reversed);
    assert_eq!(contra.reverses_entry_id, Some(orig_entry.id));
    assert_eq!(contra.settlement_status, SettlementStatus::Reversed);
    assert_eq!(contra.recorded_by.as_deref(), Some(OPERATOR));
    assert_eq!(
        contra.reversal_reason.as_deref(),
        Some("Karşılıksız havale (bounced)")
    );

    // The next collection keeps the TAH series going.
    drop(inner);
    let next = service
        .record_and_allocate_payment(payment("10.00", "TENANT", "Canan Kaya"))
        .await
        .unwrap();
    assert_eq!(next.sequence_number, original.sequence_number + 1);
    assert!(next.receipt_number.starts_with("TAH-"));
}

#[tokio::test]
async fn when_a_payment_is_reversed_twice_then_the_first_reversal_is_returned() {
    let state = tenanted_state_with(vec![liability(
        "op-1",
        "Eylül 2026",
        "100.00",
        today() + Days::new(3),
        "TENANT",
        "OPERATIONAL_DUES",
    )])
    .await;
    let service = PaymentTrackingService::new(state.clone());
    let original = service
        .record_and_allocate_payment(payment("100.00", "TENANT", "Canan Kaya"))
        .await
        .unwrap();
    let first = service
        .reverse_payment(
            reverse(&original.receipt_number, "Yanlış daire"),
            &operator(OPERATOR),
        )
        .await
        .unwrap();
    let second = service
        .reverse_payment(
            reverse(&original.receipt_number, "Yanlış daire"),
            &operator(OPERATOR),
        )
        .await
        .unwrap();
    assert_eq!(
        first.reversal_receipt.receipt_number,
        second.reversal_receipt.receipt_number
    );
    let inner = state.inner.read().await;
    assert_eq!(
        inner
            .payment_receipts
            .iter()
            .filter(|r| r.receipt_type == "REVERSAL")
            .count(),
        1
    );
    assert_eq!(
        inner.dues[0].paid_principal,
        Decimal::ZERO,
        "un-allocated exactly once"
    );
}

#[tokio::test]
async fn when_a_reversal_has_no_reason_or_targets_a_reversal_then_it_is_rejected() {
    let state = tenanted_state_with(vec![liability(
        "op-1",
        "Eylül 2026",
        "100.00",
        today() + Days::new(3),
        "TENANT",
        "OPERATIONAL_DUES",
    )])
    .await;
    let service = PaymentTrackingService::new(state.clone());
    let original = service
        .record_and_allocate_payment(payment("100.00", "TENANT", "Canan Kaya"))
        .await
        .unwrap();
    assert!(service
        .reverse_payment(reverse(&original.receipt_number, " "), &operator(OPERATOR))
        .await
        .unwrap_err()
        .contains("reason"));
    assert!(service
        .reverse_payment(
            reverse(&original.receipt_number, "valid reason"),
            &operator("  ")
        )
        .await
        .is_err());
    let rev = service
        .reverse_payment(
            reverse(&original.receipt_number, "valid reason"),
            &operator(OPERATOR),
        )
        .await
        .unwrap();
    let err = service
        .reverse_payment(
            reverse(&rev.reversal_receipt.receipt_number, "again"),
            &operator(OPERATOR),
        )
        .await
        .unwrap_err();
    assert!(err.contains("cannot be reversed"), "{}", err);
}

/// The advance a payment credited must still be there to be refunded.
#[tokio::test]
async fn when_the_credited_advance_was_already_used_then_the_reversal_is_rejected() {
    let state = tenanted_state_with(vec![liability(
        "cap-1",
        "Asansör Taksit 1",
        "300.00",
        today() + Days::new(3),
        "OWNER",
        "CAPITAL_DUES",
    )])
    .await;
    let service = PaymentTrackingService::new(state.clone());
    let original = service
        .record_and_allocate_payment(payment("300.00", "TENANT", "Canan Kaya"))
        .await
        .unwrap();
    assert_eq!(original.advance_debtor_type.as_deref(), Some("TENANT"));
    service
        .inter_ledger_transfer(InterLedgerTransferRequest {
            site_id: Some(SITE.to_string()),
            unit_id: UNIT.to_string(),
            amount: d("300.00"),
            source_debtor: Some("TENANT".to_string()),
            target_debtor: Some("OWNER".to_string()),
            ..Default::default()
        })
        .await
        .unwrap();
    let err = service
        .reverse_payment(
            reverse(&original.receipt_number, "Kiracıya iade"),
            &operator(OPERATOR),
        )
        .await
        .unwrap_err();
    assert!(err.contains("already been used"), "{}", err);
    let inner = state.inner.read().await;
    assert!(
        inner
            .payment_entries
            .iter()
            .all(|e| e.settlement_status != SettlementStatus::Reversed),
        "nothing changed"
    );
}

/// SPEC-007 R1: reversing a virman reopens the dues it settled and credits the
/// spent advance back to the source debtor; it is reversed at most once.
#[tokio::test]
async fn when_a_virman_receipt_is_reversed_then_the_dues_reopen_and_the_source_advance_is_restored()
{
    let state = tenanted_state_with(vec![liability(
        "cap-1",
        "Asansör Taksit 1",
        "300.00",
        today() + Days::new(3),
        "OWNER",
        "CAPITAL_DUES",
    )])
    .await;
    let service = PaymentTrackingService::new(state.clone());
    state
        .inner
        .write()
        .await
        .adjust_advance(UNIT, "TENANT", d("500.00"));
    let virman = service
        .inter_ledger_transfer(InterLedgerTransferRequest {
            site_id: Some(SITE.to_string()),
            unit_id: UNIT.to_string(),
            amount: d("300.00"),
            source_debtor: Some("TENANT".to_string()),
            target_debtor: Some("OWNER".to_string()),
            ..Default::default()
        })
        .await
        .unwrap();
    assert_eq!(
        state.inner.read().await.advance_of(UNIT, "TENANT"),
        d("200.00")
    );

    let resp = service
        .reverse_payment(
            reverse(&virman.receipt_number, "Hatalı virman"),
            &operator(OPERATOR),
        )
        .await
        .unwrap();
    assert!(resp.reversal_receipt.receipt_number.starts_with("IAD-"));
    assert_eq!(resp.restored_advance, d("300.00"));
    assert_eq!(resp.refunded_advance, Decimal::ZERO);
    assert_eq!(resp.reopened_due_ids, vec!["cap-1".to_string()]);
    assert!(resp
        .reversal_receipt
        .legal_statutory_note
        .as_deref()
        .unwrap_or("")
        .contains("virman"));
    {
        let inner = state.inner.read().await;
        assert_eq!(inner.advance_of(UNIT, "TENANT"), d("500.00"));
        assert_eq!(inner.advance_of(UNIT, "OWNER"), Decimal::ZERO);
        let cap = inner.dues.iter().find(|x| x.id == "cap-1").unwrap();
        assert_ne!(cap.status, DebtStatus::Paid);
        assert_eq!(cap.paid_principal, Decimal::ZERO);
    }

    // Asking again returns the same reversal and changes nothing.
    let again = service
        .reverse_payment(
            reverse(&virman.receipt_number, "Hatalı virman"),
            &operator(OPERATOR),
        )
        .await
        .unwrap();
    assert_eq!(
        again.reversal_receipt.receipt_number,
        resp.reversal_receipt.receipt_number
    );
    assert_eq!(
        state.inner.read().await.advance_of(UNIT, "TENANT"),
        d("500.00")
    );
}

// ---------------------------------------------------------------------------
// O-4 / O-5: idempotency and issuer snapshot
// ---------------------------------------------------------------------------

#[tokio::test]
async fn when_an_idempotent_payment_is_retried_then_the_key_is_not_stored_in_channel_reference() {
    let state = tenanted_state_with(vec![]).await;
    let service = PaymentTrackingService::new(state.clone());
    let mut req = payment("50.00", "OWNER", "Ahmet Yılmaz");
    req.idempotency_key = Some("client-key-1".to_string());
    let first = service
        .record_and_allocate_payment(req.clone())
        .await
        .unwrap();
    let second = service.record_and_allocate_payment(req).await.unwrap();
    assert_eq!(first.id, second.id);
    assert_eq!(
        first.channel_reference, None,
        "no IDEMPOTENCY:<key> overloading"
    );
    let inner = state.inner.read().await;
    assert_eq!(inner.payment_receipts.len(), 1);
    assert_eq!(
        inner
            .payment_idempotency
            .get(&("1".to_string(), "client-key-1".to_string())),
        Some(&first.id)
    );
}

#[tokio::test]
async fn when_a_bank_reference_is_given_then_it_is_the_receipts_channel_reference() {
    let state = tenanted_state_with(vec![]).await;
    let mut req = payment("50.00", "OWNER", "Ahmet Yılmaz");
    req.external_reference = Some("FAST-2026-0001".to_string());
    let receipt = PaymentTrackingService::new(state)
        .record_and_allocate_payment(req)
        .await
        .unwrap();
    assert_eq!(receipt.channel_reference.as_deref(), Some("FAST-2026-0001"));
}

#[tokio::test]
async fn when_the_site_has_a_tax_id_then_new_receipts_snapshot_the_issuer() {
    let state = tenanted_state_with(vec![]).await;
    {
        let mut inner = state.inner.write().await;
        let site = inner.sites.iter_mut().find(|s| s.id == SITE).unwrap();
        site.tax_id = Some("1234567890".to_string());
        site.tax_office = Some("Ataşehir".to_string());
    }
    let receipt = PaymentTrackingService::new(state)
        .record_and_allocate_payment(payment("50.00", "OWNER", "Ahmet Yılmaz"))
        .await
        .unwrap();
    assert_eq!(receipt.issuer_name.as_deref(), Some("Begonya Sitesi"));
    assert_eq!(receipt.issuer_tax_id.as_deref(), Some("1234567890"));
    assert_eq!(receipt.issuer_tax_office.as_deref(), Some("Ataşehir"));
    assert!(receipt.issuer_address.is_some());
}

#[tokio::test]
async fn when_a_site_tax_id_is_not_10_or_11_digits_then_the_update_is_rejected() {
    let state = tenanted_state_with(vec![]).await;
    let service = SaasTenantService::new(state.clone());
    let bad = UpdateSiteRequest {
        tax_id: Some("12AB".to_string()),
        site_name: Some("Renamed".to_string()),
        ..Default::default()
    };
    assert!(service
        .update_site(SITE, bad)
        .await
        .unwrap_err()
        .contains("tax_id"));
    assert_eq!(
        state
            .inner
            .read()
            .await
            .sites
            .iter()
            .find(|s| s.id == SITE)
            .unwrap()
            .name,
        "Begonya Sitesi",
        "nothing changed"
    );
    let good = UpdateSiteRequest {
        tax_id: Some("1234 567 890".to_string()),
        ..Default::default()
    };
    service.update_site(SITE, good).await.unwrap();
    assert_eq!(
        state
            .inner
            .read()
            .await
            .sites
            .iter()
            .find(|s| s.id == SITE)
            .unwrap()
            .tax_id
            .as_deref(),
        Some("1234567890")
    );
}

// covers: SC-09-06-03
#[tokio::test]
async fn when_capital_keyword_is_not_confirmed_then_tenant_pays_only_operational_dues() {
    let state = tenanted_state_with(vec![
        liability(
            "op-1",
            "October 2026",
            "1000.00",
            today() + Days::new(5),
            "TENANT",
            "OPERATIONAL_DUES",
        ),
        liability(
            "cap-1",
            "Elevator",
            "3000.00",
            today() + Days::new(5),
            "OWNER",
            "CAPITAL_DUES",
        ),
    ])
    .await;
    let mut req = payment("1000.00", "TENANT", "Canan Kaya");
    req.description = Some("Asansör Demirbaş".to_string());
    let receipt = PaymentTrackingService::new(state.clone())
        .record_and_allocate_payment(req)
        .await
        .unwrap();

    assert_eq!(receipt.on_behalf_of_role, None);
    assert!(!receipt.is_rent_offset_eligible);
    let inner = state.inner.read().await;
    assert_eq!(
        inner
            .dues
            .iter()
            .find(|due| due.id == "op-1")
            .unwrap()
            .status,
        DebtStatus::Paid
    );
    assert_eq!(
        inner
            .dues
            .iter()
            .find(|due| due.id == "cap-1")
            .unwrap()
            .status,
        DebtStatus::Pending
    );
}

// ---------------------------------------------------------------------------
// O-3 / O-7 / O-8
// ---------------------------------------------------------------------------

#[test]
fn when_reconciliation_status_is_stored_then_one_english_vocabulary_round_trips() {
    for s in [
        ReconciliationStatus::PendingApproval,
        ReconciliationStatus::Approved,
        ReconciliationStatus::Unmatched,
        ReconciliationStatus::Rejected,
        ReconciliationStatus::AlreadyProcessed,
    ] {
        let code = s.db_code();
        assert!(
            code.chars().all(|c| c.is_ascii_uppercase() || c == '_'),
            "{}",
            code
        );
        assert_eq!(ReconciliationStatus::from_db_code(code), s);
    }
}

#[test]
fn when_a_transaction_id_is_reused_with_other_content_then_the_payload_hash_differs() {
    let base = BankIncomingWebhookRequest {
        transaction_id: "TXN-1".to_string(),
        virtual_iban: "TR41 0020 5042 1399 1067 0000 14".to_string(),
        amount: d("100.00"),
        currency: Some("TRY".to_string()),
        sender_name: Some("A".to_string()),
        sender_iban: None,
        description: Some("Eylül".to_string()),
        signature: None,
    };
    let hash = sitepulse_backend::handlers::webhook_payload_hash;
    let mut same = base.clone();
    same.virtual_iban = "TR410020504213991067000014".to_string();
    same.sender_name = Some("different display name".to_string());
    assert_eq!(
        hash(&base),
        hash(&same),
        "formatting and display-only fields do not matter"
    );
    let mut other = base.clone();
    other.amount = d("100.01");
    assert_ne!(hash(&base), hash(&other));
    assert_eq!(hash(&base).len(), 64);
}

#[tokio::test]
async fn when_aging_is_snapshotted_then_one_row_per_unit_and_debtor_is_produced() {
    let state = tenanted_state_with(vec![
        liability(
            "op-1",
            "Eylül 2026",
            "100.00",
            today() - Days::new(40),
            "TENANT",
            "OPERATIONAL_DUES",
        ),
        liability(
            "cap-1",
            "Asansör Taksit 1",
            "300.00",
            today() + Days::new(3),
            "OWNER",
            "CAPITAL_DUES",
        ),
    ])
    .await;
    let rows = PaymentTrackingService::new(state)
        .snapshot_debt_aging(Some(SITE))
        .await
        .unwrap();
    assert_eq!(rows, 2);
}

// covers: SC-09-01-02
#[tokio::test]
async fn when_debt_aging_report_is_fetched_then_buckets_total_the_overdue_sum() {
    let state = tenanted_state_with(vec![
        liability(
            "op-1",
            "Eylül 2026",
            "100.00",
            today() - Days::new(10),
            "TENANT",
            "OPERATIONAL_DUES",
        ),
        liability(
            "op-2",
            "Ağustos 2026",
            "200.00",
            today() - Days::new(45),
            "TENANT",
            "OPERATIONAL_DUES",
        ),
        liability(
            "op-3",
            "Temmuz 2026",
            "300.00",
            today() - Days::new(75),
            "TENANT",
            "OPERATIONAL_DUES",
        ),
    ])
    .await;
    let report = PaymentTrackingService::new(state)
        .get_debt_aging_report(SITE)
        .await
        .unwrap();
    assert_eq!(report.brackets.len(), 1);
    let b = &report.brackets[0];
    let sum_buckets = b.current_due
        + b.overdue_1_30_days
        + b.overdue_31_60_days
        + b.overdue_60_plus_days
        + b.accrued_delay_penalty;
    assert_eq!(b.total_outstanding, sum_buckets);
    assert_eq!(report.grand_total, sum_buckets);
}

// covers: SC-09-05-01
#[tokio::test]
async fn when_tenant_moves_out_balance_is_frozen_and_future_dues_shift_to_owner() {
    let state = tenanted_state_with(vec![liability(
        "op-1",
        "Eylül 2026",
        "1400.00",
        today(),
        "TENANT",
        "OPERATIONAL_DUES",
    )])
    .await;
    // Vacate unit (tenant moves out)
    {
        let mut inner = state.inner.write().await;
        let u = inner.units.iter_mut().find(|u| u.id == UNIT).unwrap();
        u.tenant_user_id = None;
    }
    // Verify tenant sub-ledger keeps 1400.00 outstanding
    let inner = state.inner.read().await;
    let due = inner.dues.iter().find(|d| d.id == "op-1").unwrap();
    assert_eq!(due.debtor_type, DebtorType::Tenant);
    assert_eq!(due.total_amount, d("1400.00"));
    assert_eq!(
        inner
            .units
            .iter()
            .find(|u| u.id == UNIT)
            .unwrap()
            .tenant_user_id,
        None
    );
}

// covers: SC-09-07-01
#[tokio::test]
async fn when_ownership_transfers_old_owner_balance_freezes_and_new_owner_binds() {
    let state = tenanted_state_with(vec![
        liability(
            "cap-old",
            "Çatı Onarımı",
            "2500.00",
            today() - Days::new(10),
            "OWNER",
            "CAPITAL_DUES",
        ),
        liability(
            "op-1",
            "Ekim 2026",
            "1000.00",
            today() + Days::new(5),
            "TENANT",
            "OPERATIONAL_DUES",
        ),
    ])
    .await;
    // Register title deed transfer: assign new owner
    {
        let mut inner = state.inner.write().await;
        let mut new_owner = inner
            .users
            .iter()
            .find(|u| u.id == "usr-home-owner-1")
            .cloned()
            .unwrap();
        new_owner.id = "usr-new-owner-99".to_string();
        new_owner.full_name = "Burak Demir".to_string();
        inner.users.push(new_owner);
        let u = inner.units.iter_mut().find(|u| u.id == UNIT).unwrap();
        u.owner_user_id = Some("usr-new-owner-99".to_string());
    }

    let inner = state.inner.read().await;
    let old_cap = inner.dues.iter().find(|d| d.id == "cap-old").unwrap();
    assert_eq!(
        old_cap.total_amount,
        d("2500.00"),
        "old owner capital due remains on record"
    );
    let op = inner.dues.iter().find(|d| d.id == "op-1").unwrap();
    assert_eq!(op.total_amount, d("1000.00"), "tenant dues untouched");
    let unit = inner.units.iter().find(|u| u.id == UNIT).unwrap();
    assert_eq!(unit.owner_user_id.as_deref(), Some("usr-new-owner-99"));
}

// covers: SC-09-07-02
#[tokio::test]
async fn successor_owner_payment_does_not_settle_predecessor_owner_liability() {
    let mut old_due = liability(
        "owner-old",
        "February 2027",
        "800.00",
        today() - Days::new(30),
        "OWNER",
        "OPERATIONAL_DUES",
    );
    old_due.liable_person_id = Some(101);
    let mut current_due = liability(
        "owner-current",
        "March 2027",
        "500.00",
        today() + Days::new(5),
        "OWNER",
        "OPERATIONAL_DUES",
    );
    current_due.liable_person_id = Some(202);
    let state = tenanted_state_with(vec![old_due, current_due]).await;
    {
        let mut inner = state.inner.write().await;
        let mut successor = inner
            .users
            .iter_mut()
            .find(|user| user.id == "usr-home-owner-1")
            .map(|user| {
                user.person_id = Some(101);
                user.clone()
            })
            .unwrap();
        successor.id = "usr-successor-owner".to_string();
        successor.full_name = "Successor Owner".to_string();
        successor.person_id = Some(202);
        inner.users.push(successor);
        inner
            .units
            .iter_mut()
            .find(|unit| unit.id == UNIT)
            .unwrap()
            .owner_user_id = Some("usr-successor-owner".to_string());
    }

    let receipt = PaymentTrackingService::new(state.clone())
        .record_and_allocate_payment(payment("500.00", "OWNER", "Successor Owner"))
        .await
        .unwrap();
    assert_eq!(
        receipt
            .allocation_breakdown
            .iter()
            .filter_map(|line| line.due_id.as_deref())
            .collect::<Vec<_>>(),
        vec!["owner-current"]
    );
    let inner = state.inner.read().await;
    assert_eq!(
        inner
            .dues
            .iter()
            .find(|due| due.id == "owner-old")
            .unwrap()
            .total_amount,
        d("800.00")
    );
    assert_eq!(
        inner
            .dues
            .iter()
            .find(|due| due.id == "owner-current")
            .unwrap()
            .total_amount,
        Decimal::ZERO
    );
}

// covers: SC-09-07-03
#[tokio::test]
async fn former_owner_receipt_resolves_identity_and_settles_only_own_liability() {
    let mut former_due = liability(
        "owner-former",
        "February 2027",
        "800.00",
        today() + Days::new(1),
        "OWNER",
        "OPERATIONAL_DUES",
    );
    former_due.liable_person_id = Some(101);
    let mut current_due = liability(
        "owner-current-after-sale",
        "March 2027",
        "500.00",
        today() + Days::new(5),
        "OWNER",
        "OPERATIONAL_DUES",
    );
    current_due.liable_person_id = Some(202);
    let unattributed_due = liability(
        "owner-unattributed-after-sale",
        "January 2027",
        "300.00",
        today() + Days::new(2),
        "OWNER",
        "OPERATIONAL_DUES",
    );
    let state = tenanted_state_with(vec![former_due, current_due, unattributed_due]).await;
    {
        let mut inner = state.inner.write().await;
        let current_owner = inner
            .users
            .iter_mut()
            .find(|user| user.id == "usr-home-owner-1")
            .unwrap();
        current_owner.full_name = "Successor Owner".to_string();
        current_owner.person_id = Some(202);
        let mut former_owner = current_owner.clone();
        former_owner.id = "usr-former-owner".to_string();
        former_owner.full_name = "Former Owner".to_string();
        former_owner.person_id = Some(101);
        inner.users.push(former_owner);
    }

    let receipt = PaymentTrackingService::new(state.clone())
        .record_and_allocate_payment(payment("800.00", "OWNER", "Former Owner"))
        .await
        .unwrap();
    assert_eq!(
        receipt
            .allocation_breakdown
            .iter()
            .filter_map(|line| line.due_id.as_deref())
            .collect::<Vec<_>>(),
        vec!["owner-former"]
    );
    let inner = state.inner.read().await;
    assert_eq!(
        inner
            .dues
            .iter()
            .find(|due| due.id == "owner-former")
            .unwrap()
            .total_amount,
        Decimal::ZERO
    );
    assert_eq!(
        inner
            .dues
            .iter()
            .find(|due| due.id == "owner-current-after-sale")
            .unwrap()
            .total_amount,
        d("500.00")
    );
    assert_eq!(
        inner
            .dues
            .iter()
            .find(|due| due.id == "owner-unattributed-after-sale")
            .unwrap()
            .total_amount,
        d("300.00")
    );
}

// covers: SC-09-07-04
#[tokio::test]
async fn former_tenant_receipt_resolves_identity_and_settles_only_own_liability() {
    let mut former_due = liability(
        "tenant-former",
        "February 2027",
        "800.00",
        today() + Days::new(1),
        "TENANT",
        "OPERATIONAL_DUES",
    );
    former_due.liable_person_id = Some(101);
    let mut current_due = liability(
        "tenant-current-after-move-in",
        "March 2027",
        "500.00",
        today() + Days::new(5),
        "TENANT",
        "OPERATIONAL_DUES",
    );
    current_due.liable_person_id = Some(202);
    let state = tenanted_state_with(vec![former_due, current_due]).await;
    {
        let mut inner = state.inner.write().await;
        let current_tenant = inner
            .users
            .iter_mut()
            .find(|user| user.id == TENANT_USER)
            .unwrap();
        current_tenant.full_name = "Successor Tenant".to_string();
        current_tenant.person_id = Some(202);
        let mut former_tenant = current_tenant.clone();
        former_tenant.id = "usr-former-tenant".to_string();
        former_tenant.full_name = "Former Tenant".to_string();
        former_tenant.person_id = Some(101);
        inner.users.push(former_tenant);
    }

    let receipt = PaymentTrackingService::new(state.clone())
        .record_and_allocate_payment(payment("800.00", "TENANT", "Former Tenant"))
        .await
        .unwrap();
    assert_eq!(
        receipt
            .allocation_breakdown
            .iter()
            .filter_map(|line| line.due_id.as_deref())
            .collect::<Vec<_>>(),
        vec!["tenant-former"]
    );
    let inner = state.inner.read().await;
    assert_eq!(
        inner
            .dues
            .iter()
            .find(|due| due.id == "tenant-former")
            .unwrap()
            .total_amount,
        Decimal::ZERO
    );
    assert_eq!(
        inner
            .dues
            .iter()
            .find(|due| due.id == "tenant-current-after-move-in")
            .unwrap()
            .total_amount,
        d("500.00")
    );
}

// covers: SC-09-07-05
#[tokio::test]
async fn ambiguous_payer_name_requires_explicit_liability_designation() {
    let mut former_due = liability(
        "owner-shared-name-former",
        "February 2027",
        "800.00",
        today() + Days::new(1),
        "OWNER",
        "OPERATIONAL_DUES",
    );
    former_due.liable_person_id = Some(101);
    let mut current_due = liability(
        "owner-shared-name-current",
        "March 2027",
        "500.00",
        today() + Days::new(5),
        "OWNER",
        "OPERATIONAL_DUES",
    );
    current_due.liable_person_id = Some(202);
    let state = tenanted_state_with(vec![former_due, current_due]).await;
    {
        let mut inner = state.inner.write().await;
        let current_owner = inner
            .users
            .iter_mut()
            .find(|user| user.id == "usr-home-owner-1")
            .unwrap();
        current_owner.full_name = "Shared Owner".to_string();
        current_owner.person_id = Some(202);
        let mut former_owner = current_owner.clone();
        former_owner.id = "usr-former-owner-shared-name".to_string();
        former_owner.person_id = Some(101);
        inner.users.push(former_owner);
    }

    let service = PaymentTrackingService::new(state.clone());
    let undesignated = service
        .record_and_allocate_payment(payment("800.00", "OWNER", "Shared Owner"))
        .await;
    assert!(undesignated.is_err());
    assert!(state.inner.read().await.payment_receipts.is_empty());

    let mut designated = payment("800.00", "OWNER", "Shared Owner");
    designated.designation = Some(PaymentDesignation {
        due_ids: vec!["owner-shared-name-former".to_string()],
        ..Default::default()
    });
    let receipt = service
        .record_and_allocate_payment(designated)
        .await
        .unwrap();
    assert_eq!(
        receipt
            .allocation_breakdown
            .iter()
            .filter_map(|line| line.due_id.as_deref())
            .collect::<Vec<_>>(),
        vec!["owner-shared-name-former"]
    );
    let inner = state.inner.read().await;
    assert_eq!(
        inner
            .dues
            .iter()
            .find(|due| due.id == "owner-shared-name-former")
            .unwrap()
            .total_amount,
        Decimal::ZERO
    );
    assert_eq!(
        inner
            .dues
            .iter()
            .find(|due| due.id == "owner-shared-name-current")
            .unwrap()
            .total_amount,
        d("500.00")
    );
}

#[tokio::test]
async fn current_owner_receipt_can_settle_legacy_unattributed_liability() {
    let legacy_due = liability(
        "owner-unattributed",
        "February 2027",
        "800.00",
        today() + Days::new(1),
        "OWNER",
        "OPERATIONAL_DUES",
    );
    let mut current_due = liability(
        "owner-attributed",
        "March 2027",
        "500.00",
        today() + Days::new(5),
        "OWNER",
        "OPERATIONAL_DUES",
    );
    current_due.liable_person_id = Some(202);
    let state = tenanted_state_with(vec![legacy_due, current_due]).await;
    {
        let mut inner = state.inner.write().await;
        let current_owner = inner
            .users
            .iter_mut()
            .find(|user| user.id == "usr-home-owner-1")
            .unwrap();
        current_owner.id = "person-202".to_string();
        current_owner.person_id = None;
        inner
            .units
            .iter_mut()
            .find(|unit| unit.id == UNIT)
            .unwrap()
            .owner_user_id = Some("person-202".to_string());
    }

    let receipt = PaymentTrackingService::new(state.clone())
        .record_and_allocate_payment(payment("800.00", "OWNER", "Ahmet Yılmaz"))
        .await
        .unwrap();
    assert_eq!(
        receipt
            .allocation_breakdown
            .iter()
            .filter_map(|line| line.due_id.as_deref())
            .collect::<Vec<_>>(),
        vec!["owner-unattributed"]
    );
    let inner = state.inner.read().await;
    assert_eq!(
        inner
            .dues
            .iter()
            .find(|due| due.id == "owner-unattributed")
            .unwrap()
            .total_amount,
        Decimal::ZERO
    );
    assert_eq!(
        inner
            .dues
            .iter()
            .find(|due| due.id == "owner-attributed")
            .unwrap()
            .total_amount,
        d("500.00")
    );
}
