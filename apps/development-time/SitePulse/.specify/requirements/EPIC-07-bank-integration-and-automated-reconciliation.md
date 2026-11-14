# Epic: Bank Account Integration, Virtual IBAN, Automated Reconciliation & Periodic Dues Accrual

> **Epic ID:** EPIC-07  
> **Module:** `backend-rust`, `flutter-ui`, `flutter-domain`, `mvp_ux_prototype`  
> **Status:** COMPLETED (7 / 7 Stories Completed & Verified)  
> **Target Audience:** `SITE_MANAGER`, `HOME_RESIDENT`, `SAAS_ADMIN`  
> **Governance:** Turkish Condominium Law (634 Sayılı KMK Madde 35-f), TCMB Açık Bankacılık & 6493 Sayılı Kanun  
> **Business Value:** Automates dues collection and ledger reconciliation directly with Turkish banks (*Kuveyt Türk Sandbox, Garanti BBVA, İş Bankası, Yapı Kredi, Akbank*) and licensed FinTech payment facilitators. Eliminates manual bank statement tracking, removes human matching errors via flat-specific Virtual IBANs (Sanal IBAN), provides a zero-permission Excel/MT940 parser for individual developers, manages advance balances (avans bakiye), and autonomously runs periodic monthly dues accrual with strict duplicate prevention.

---

## 1. Epic Overview & Architectural Context

In the Turkish property management ecosystem, **KMK Article 35-f** mandates that all dues and contributions must be collected into an official bank account opened in the name of the residential complex (*Site Yönetimi Potansiyel Vergi Numarası*).

This epic solves the operational bottleneck of manually matching bank transfers ("A Blok D:14 Aidat", "Mehmet Bey aidat ödemesi") and automating monthly recurring liabilities through three unified tiers:

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                        BANK RECONCILIATION & ACCRUAL ARCHITECTURE                      │
├─────────────────────────┬───────────────────────────────┬──────────────────────────────┤
│ Tier / Solution         │ Technical Mechanism           │ Developer / Site Pre-req     │
├─────────────────────────┼───────────────────────────────┼──────────────────────────────┤
│ Tier 1: Sanal IBAN      │ Dedicated IBAN per flat       │ Site Manager bank agreement  │
│ Tier 2: FAST / Karekod  │ Instant payment & UX copy     │ Mobile Banking / Webhook API │
│ Tier 3: Zero-Approval   │ Excel / CSV / MT940 Ingestion │ 0 Permissions, instant start │
│ Tier 4: Auto-Accrual    │ Embedded Tokio Batch Worker   │ Zero manual effort scheduler │
└─────────────────────────┴───────────────────────────────┴──────────────────────────────┘
```

---

## 2. User Stories & Acceptance Criteria

### STORY-07-01: Flat-Specific Virtual IBAN (Sanal IBAN) Allocation
- **Status:** `COMPLETED` (Verified with Kuveyt Türk Sandbox, ISO 7064 MOD-97-10 check digits & E2E suite)
- **Target Role:** Site Manager & System
- **Description:** Automatically provision and bind a unique Virtual IBAN sub-account to each apartment (`bagimsiz_bolum_id`) under the site's primary commercial collection account.
- **Acceptance Criteria:**
  Executable scenarios: [`STORY-07-01-virtual-iban-allocation.feature`](../features/EPIC-07/STORY-07-01-virtual-iban-allocation.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).
- **Implementation Artifacts:**
  - `virtual_iban_service.rs`, `kuveyt_turk_service.rs`, `models/mod.rs`, `handlers/mod.rs`
- **Verification & Tests:**
  - `when_unit_created_then_generates_unique_sanal_iban`
  - `when_querying_resident_dashboard_then_includes_allocated_virtual_iban`
  - `scripts/test-virtual-iban-e2e.sh`

---

### STORY-07-02: Zero-Approval Bank Statement (Excel / CSV / MT940) Parser
- **Status:** `COMPLETED` (Verified with integration & UI test suite)
- **Target Role:** Site Manager (Individual Developer Friendly)
- **Description:** Allow site managers to upload monthly Excel, CSV, or SWIFT MT940 statements exported from any Turkish bank internet branch. An intelligent regex/NLP matcher parses transfer descriptions, extracts block/flat identifiers and resident names, and proposes batch dues clearances.
- **Acceptance Criteria:**
  Executable scenarios: [`STORY-07-02-bank-statement-parser.feature`](../features/EPIC-07/STORY-07-02-bank-statement-parser.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).
- **Implementation Artifacts:**
  - `bank_statement_parser.rs`, `mt940_engine.rs`, `reconciliation_service.rs`
- **Verification & Tests:**
  - `when_parsing_turkish_bank_excel_then_matches_flat_and_amount`
  - `when_parsing_mt940_statement_then_extracts_transactions_and_matches_due`

---

### STORY-07-03: Real-Time Bank Webhook & Payment Notification Listener
- **Status:** `COMPLETED` (Verified with live Sandbox webhook, instant dues clearance & Idempotency Gate)
- **Target Role:** System / Bank Integration
- **Description:** Provide a secure REST webhook endpoint accepting real-time incoming transfer notifications from participating banks (Kuveyt Türk, Garanti BBVA, Yapı Kredi, Akbank) with idempotency keys and automatic settlement to prevent duplicate booking.
- **Acceptance Criteria:**
  Executable scenarios: [`STORY-07-03-bank-webhook-listener.feature`](../features/EPIC-07/STORY-07-03-bank-webhook-listener.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).
- **Implementation Artifacts:**
  - `handlers/mod.rs` (`handle_bank_incoming_webhook`), `reconciliation_service.rs`
- **Verification & Tests:**
  - `when_bank_webhook_delivers_virtual_iban_payment_then_clears_dues_and_generates_receipt`
  - `when_statement_contains_virtual_iban_then_matches_flat_with_100_percent_confidence`
  - `scripts/test-virtual-iban-e2e.sh`

---

### STORY-07-04: User-Friendly Virtual IBAN & FAST Payment Resident Experience
- **Status:** `COMPLETED` (Verified in Flutter & Prototype)
- **Target Role:** Home Resident
- **Description:** Replace technical banking jargon with clean, user-friendly Turkish fintech terminology on the mobile Resident Dashboard and Payment Checkout dialog ("Sanal IBAN ile FAST Transfer"), offering 1-tap clipboard copying, clear sender explanation instructions, and instant payment guidance.
- **Acceptance Criteria:**
  Executable scenarios: [`STORY-07-04-resident-fast-payment.feature`](../features/EPIC-07/STORY-07-04-resident-fast-payment.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).
- **Implementation Artifacts:**
  - `payment_checkout_dialog.dart`, `hero_balance_card.dart`, `mvp_ux_prototype.html`
- **Verification & Tests:**
  - Widget tests in `widget_test.dart` and `dashboard_controller_test.dart`

---

### STORY-07-05: Advance Payment Allocation, Dynamic Surplus Balance & Auto-Offset
- **Status:** `COMPLETED` (Verified in Rust Backend, Flutter & E2E)
- **Target Role:** Home Resident & Site Manager
- **Description:** When a resident transfers an amount greater than their outstanding debt (or makes early payments when no debt exists), credit the surplus as an Advance Payment (`advance_payment` / Avans Bakiye). Dynamically render `+₺{amount}` in emerald green on the resident's Hero Balance Card (*"Mevcut Avans Bakiyesi (Alacak)"*) instead of "₺0 ödenecek tutar", record credit movements in the transaction ledger, and automatically deduct future dues using FIFO.
- **Acceptance Criteria:**
  Executable scenarios: [`STORY-07-05-advance-payment-allocation.feature`](../features/EPIC-07/STORY-07-05-advance-payment-allocation.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).
- **Implementation Artifacts:**
  - `handlers/mod.rs` (`apply_advance_payments_offset`), `models/mod.rs`, `hero_balance_card.dart`
- **Verification & Tests:**
  - `when_excess_or_multiple_payments_delivered_then_credited_as_advance_payment`
  - `when_new_dues_period_accrued_and_resident_has_advance_payment_then_automatically_offsets_debt`

---

### STORY-07-06: Site Bank Account Configuration & Statement Format Enforcement
- **Status:** `COMPLETED` (Verified in Rust Backend & Flutter UI)
- **Target Role:** Site Manager
- **Description:** Provide a site banking administration endpoint and UI allowing site managers to configure their official bank account (Kuveyt Türk, Garanti BBVA, İş Bankası, Yapı Kredi, Akbank) and automatically enforce the active statement format (Excel, CSV, MT940). Reject incompatible statement formats during upload.
- **Acceptance Criteria:**
  Executable scenarios: [`STORY-07-06-site-bank-account-configuration.feature`](../features/EPIC-07/STORY-07-06-site-bank-account-configuration.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).
- **Implementation Artifacts:**
  - `handlers/mod.rs` (`configure_site_bank_account`), `models/mod.rs`, `dues_management_view.dart`
- **Verification & Tests:**
  - `when_site_manager_configures_bank_account_then_format_is_automatically_set_by_bank`
  - `when_parsing_bank_statement_then_enforces_active_bank_format_and_permits_new_format_after_change`

---

### STORY-07-07: Monthly Dues Periodic Accrual & Duplicate Prevention (Tokio Batch Scheduler & Manager UI Action)
- **Status:** `COMPLETED` (Verified in Tokio Backend, Flutter UI & Integration Suite)
- **Target Role:** System & Site Manager
- **Description:** Automate periodic monthly dues accrual across all sites via an embedded Tokio background scheduler (batch job) and empower site managers to manually trigger period accrual from the Aidat Yönetimi view ("Toplu Aidat Tahakkuku"). Enforce a strict duplicate accrual prevention guard (`prevent duplicate accrual`): if dues for a site and period (e.g. `Ekim 2026`) have already been accrued, reject duplicate liability creation, return `already_accrued: true` with an informative warning, and automatically offset any available resident advance balances (`advance_payment`) via FIFO.
- **Acceptance Criteria:**
  Executable scenarios: [`STORY-07-07-monthly-dues-accrual.feature`](../features/EPIC-07/STORY-07-07-monthly-dues-accrual.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).
- **Implementation Artifacts:**
  - `scheduler.rs`, `backend/src/main.rs`, `handlers/mod.rs` (`accrue_monthly_dues`), `dues_management_view.dart`, `dashboard_controller.dart`
- **Verification & Tests:**
  - `when_dues_period_already_accrued_then_duplicate_accrual_is_prevented`
  - `when_scheduler_batch_runs_then_accrues_and_prevents_duplicate_accrual`
  - `DuesManagementView opens Toplu Aidat Tahakkuku confirmation dialog with duplicate prevention note` (Flutter widget test)

---

## 3. Harness Verification Gates

To ensure financial and security integrity, all code generated for EPIC-07 passes:
1. **Financial Precision Gate:** Exact `rust_decimal::Decimal` and `Decimal` reconciliation down to ₺0.01 (zero kuruş discrepancy).
2. **Idempotency Gate:** Duplicate webhook deliveries and duplicate accrual requests for the same period are rejected safely with HTTP 200 without double-crediting or duplicate liabilities.
3. **Security Gate:** Plaintext bank credentials must never be written to logs or transmitted unencrypted.
4. **Automated Verification:** 38 Rust tests and 49 Flutter tests running 100% green.
