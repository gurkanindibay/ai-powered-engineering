# Epic: Bank Account Integration, Virtual IBAN, Automated Reconciliation & Periodic Dues Accrual

> **Epic ID:** EPIC-07  
> **Module:** `backend-rust`, `flutter-ui`, `flutter-domain`, `mvp_ux_prototype`  
> **Status:** IN PROGRESS (8 / 13 Stories Completed & Verified; STORY-07-09 to 07-13 planned)  
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

### Accrual integrity stories (STORY-07-08 to STORY-07-13)

An accrual and collection gap review (2026-11-17) compared SitePulse with the controls a dues
billing system needs. Collection is largely complete. Accrual lacks a canonical period, atomic
batches, proration, catch-up, corrections, period close, and one late-fee figure across reports.
The stories below specify those controls. Their scenarios are `@pending` until implemented.

Decisions still open for the product owner or counsel are marked **(decide)**.

---

### STORY-07-08: Canonical Billing Period & Atomic Accrual Batch
- **Status:** `COMPLETED` (decision: the due date may fall up to 30 days after the period's month, `DUE_DATE_GRACE_DAYS`)
- **Target Role:** System & Site Manager
- **Gap today:** The period is free text. The duplicate guard and the unique index
  `uq_unit_period_expense` compare that text exactly, so "Ekim 2026", "ekim 2026" and "2026-10" are
  three periods. The due date is not checked against the period. Manual accrual inserts one
  liability at a time: a failure partway leaves some rows in PostgreSQL that the in-memory state never
  receives, and the budget basis is a separate write.
- **Requirements:**
  1. A billing period is identified by a canonical key `YYYY-MM`. The Turkish label ("Ekim 2026") is
     derived from the key for display only. The API accepts the key; a label or another spelling of
     the same month resolves to the same key or is rejected with 400.
  2. Duplicate prevention uses the key: one operational liability per unit, period key and expense
     type, enforced by a unique index on the key.
  3. The due date must fall inside the period's month, or within a configured number of days after
     it **(decide)**. Otherwise the request is rejected with 400 and nothing is written.
  4. Every liability is linked to its `dues_periods` row (`dues_period_id`).
  5. A manual or scheduled accrual of one site is one database transaction: the period row, all
     liabilities and their budget basis commit together or not at all. In-memory state is updated only
     from the committed result.
  6. The response lists every skipped unit with its reason (no tariff, zero share, no budget), and the
     scheduler records the same list where the manager can see it, not only in the server log.
  7. Existing liabilities are migrated to the key; rows whose label cannot be parsed are reported, not
     guessed.
- **Acceptance Criteria:**
  Executable scenarios: [`STORY-07-08-canonical-period-and-atomic-batch.feature`](../features/EPIC-07/STORY-07-08-canonical-period-and-atomic-batch.feature).
- **Implementation Artifacts:**
  - `domain/billing_period.rs` (key, label, due-date rule), `db/dues_repository.rs` (`commit_accrual_batch`, `list_accrual_runs`), `handlers/dues.rs`, `scheduler.rs`, migration `V37` (`period_key` columns, unique indexes, `dues_accrual_runs`, `dues_period_migration_issues` for unparseable or duplicate labels), `GET /api/v1/dues/accrual-runs`
- **Verification & Tests:** `backend/tests/billing_period_tests.rs`, `backend/tests/db_accrual_atomic_tests.rs`

---

### STORY-07-09: Occupancy-Aware Accrual & Proration
- **Status:** `PLANNED`
- **Target Role:** System & Site Manager
- **Gap today:** The debtor (tenant or owner) is decided once, when the liability is created. A unit
  created, moved into or moved out of mid-month is charged the full month to one debtor. Nothing is
  prorated.
- **Requirements:**
  1. Operational dues for a period are split between the occupants of that period by the days each
     one was responsible: the tenant while a lease is active, the owner while the unit is vacant or
     owner-occupied. The split uses the actual number of days in the month and is rounded to kuruş
     half away from zero; the last share absorbs the remainder so the shares add up to the unit's
     monthly amount exactly.
  2. A unit created during a period is charged only from its creation date. Whether this applies or
     the first period is charged in full is a site setting **(decide the default)**.
  3. A move-in, move-out or title transfer recorded after the period was accrued re-splits that
     period's open liability: the shares are re-issued through corrections (STORY-07-11), never by
     editing a liability that has payments.
  4. A share that has already been paid is not reduced below what was paid; any excess is credited to
     that debtor's advance balance.
  5. Whether proration is allowed at all depends on the management plan (yönetim planı) **(verify
     with counsel)**; a site can switch it off, and then the current rule applies (the occupant on the
     accrual date owes the whole month).
- **Acceptance Criteria:**
  Executable scenarios: [`STORY-07-09-occupancy-aware-proration.feature`](../features/EPIC-07/STORY-07-09-occupancy-aware-proration.feature).

---

### STORY-07-10: Accrual Schedule, Catch-Up & Grace Period
- **Status:** `COMPLETED` (Backend API and scheduler; grace period decided as a configurable 0 to 30 days, default 0, still to be verified with counsel; no Flutter screen yet)
- **Target Role:** Site Manager & System
- **Gap today:** The scheduler only accrues the current month, so a month missed while it was off is
  never charged. The due date is fixed to the 15th. Late fees start the day after the due date, with
  no grace period.
- **Requirements:**
  1. Each site configures its accrual day and due day of month (default: accrue on the 1st, due on the
     15th, the current behaviour). A due day beyond the month's last day falls on the last day.
  2. On every run the scheduler accrues every period from the site's first billing period (or its
     go-live date) up to the current one that has not been accrued yet, oldest first. Catch-up never
     goes further back than a configured limit (default 12 months) **(decide)** and reports each period
     it accrued.
  3. A catch-up liability keeps its original period and due date; its late fee follows KMK 20 from that
     due date unless the manager waives it (STORY-07-11).
  4. A site may set a grace period of N days (default 0). No late fee accrues for a payment received
     within the grace period; after it, the fee accrues from the due date as KMK 20 requires
     **(verify with counsel that a grace period is a lawful waiver)**.
  5. Changing the accrual day, due day or grace period affects only periods not yet accrued.
- **Acceptance Criteria:**
  Executable scenarios: [`STORY-07-10-accrual-schedule-catch-up-and-grace.feature`](../features/EPIC-07/STORY-07-10-accrual-schedule-catch-up-and-grace.feature).
- **Implementation Artifacts:**
  - `domain/accrual_schedule.rs` (due-day clamp, catch-up plan and limit), `scheduler.rs` (`run_accrual_with_report`), `migrations/V42__accrual_schedule.sql`
  - API: `GET/PUT /api/v1/accrual-schedule` (the caller's site; accrual day, due day, grace days, catch-up limit, go-live date)
  - `services/dues_calculation_service.rs` and `services/late_fee_service.rs` (grace period; `DuesLiability.grace_days` is copied at accrual so later changes touch only new periods)

---

### STORY-07-11: Accrual Corrections (Cancel, Re-issue, Credit Note)
- **Status:** `COMPLETED` (Backend API, ledger and resident statement; requirement 7 waits for STORY-07-12; no Flutter screen yet)
- **Target Role:** Site Manager, Second Approver, Auditor
- **Gap today:** `DebtStatus` has only Pending, Overdue and Paid. The only adjustments are a principal
  write-off and a penalty waiver. A liability with the wrong amount, period or debtor can only be
  written off, which reports a loss instead of a correction.
- **Requirements:**
  1. A manager can request one of three corrections on a liability, with a mandatory reason:
     - **Cancel**: the liability should not exist (wrong unit, wrong period, duplicate).
     - **Re-issue**: replace it with a corrected amount, debtor or due date.
     - **Credit note**: reduce the amount by a stated sum (for example a budget revision).
  2. A correction takes effect only after a second user with ledger rights approves it (four eyes),
     like the existing adjustments. The requester cannot approve their own request.
  3. The original liability is never edited or deleted. A cancel sets it to `CANCELLED` and posts a
     reversing entry; a re-issue cancels it and creates a new liability linked to the original; a
     credit note posts a credit against it.
  4. Amounts already paid on a cancelled or reduced liability move to the debtor's advance balance and
     are then offset against their other open liabilities (STORY-07-05). A receipt is never altered.
  5. A late fee accrued on the cancelled or reduced amount is reversed in proportion.
  6. Every correction appears in the ledger, the resident statement, and an audit list with requester,
     approver, reason and time.
  7. A correction to a closed period is posted in the current open period (STORY-07-12).
- **Acceptance Criteria:**
  Executable scenarios: [`STORY-07-11-accrual-corrections.feature`](../features/EPIC-07/STORY-07-11-accrual-corrections.feature).
- **Implementation Artifacts:**
  - `services/correction_service.rs`, `db/correction_repository.rs`, `migrations/V38__accrual_corrections.sql`
  - API: `GET/POST /api/v1/accrual-corrections` and `POST /api/v1/accrual-corrections/{id}/decide` (the audit list is the GET)
  - `services/accounting_service.rs` (reversing entries), `services/resident_statement.rs` (`corrections`)

---

### STORY-07-12: Billing Period Lifecycle & Close
- **Status:** `PLANNED`
- **Target Role:** Site Manager, Auditor
- **Gap today:** `DuesPeriodStatus` defines `Closed`, but nothing sets or enforces it. The general
  ledger is derived from current data on every read, so a later change rewrites months that were
  already reported to the assembly.
- **Requirements:**
  1. A billing period moves `DRAFT → OPEN → CLOSED`. Accrual creates or opens it; only a manager closes
     it, after a summary (accrued, collected, outstanding, corrections) is shown.
  2. While a period is closed, nothing may change its accrued amounts, its ledger entries or the
     figures reported for it. Payments are still accepted and allocated to its liabilities (debt does
     not stop being collectable); the payment is booked in the period it was received.
  3. Corrections to a closed period's liabilities are booked in the current open period with a
     reference to the closed one (STORY-07-11).
  4. Closing stores a snapshot of the period's figures (per unit and in total). The account report
     and trial balance for a closed period read that snapshot, so they never change after closing.
  5. Reopening a closed period requires a second approver and a reason, and is recorded in the audit
     list.
- **Acceptance Criteria:**
  Executable scenarios: [`STORY-07-12-billing-period-lifecycle-and-close.feature`](../features/EPIC-07/STORY-07-12-billing-period-lifecycle-and-close.feature).

---

### STORY-07-13: One Late-Fee Figure Across Dashboard, Statement & Ledger
- **Status:** `IMPLEMENTED`
- **Target Role:** Site Manager, Auditor, Resident
- **Gap today:** The dashboard, debt aging and resident statement calculate the KMK 20 late fee up to
  today. The general ledger and trial balance use the stored fee, which is updated only when a payment
  or advance offset touches the liability. The reports therefore understate receivables and penalty
  revenue against the dashboard.
- **Requirements:**
  1. A daily job (in the site's time zone) brings the late fee of every open overdue liability up to
     that day and persists it. It is idempotent: a second run on the same day changes nothing.
     Running daily must give the same fee as one evaluation over the whole interval: within a segment
     of unchanged outstanding principal the fee is computed cumulatively from the segment start and
     rounded once, and the day's entry is the difference from the previous total. Rounding each day's
     fee separately would drift (₺2.33 × 16 days = ₺37.28, not ₺37.33).
  2. The ledger books each day's accrued late fee as an entry dated that day, so penalty revenue falls
     in the period it accrued in.
  3. On any date, a unit's outstanding total on the dashboard, its resident statement, the debt aging
     report and the dues receivable in the trial balance agree to the kuruş.
  4. A reconciliation check reports any site where these figures differ, with the liabilities that
     cause it.
- **Acceptance Criteria:**
  Executable scenarios: [`STORY-07-13-late-fee-consistency.feature`](../features/EPIC-07/STORY-07-13-late-fee-consistency.feature).

---

## 3. Harness Verification Gates

To ensure financial and security integrity, all code generated for EPIC-07 passes:
1. **Financial Precision Gate:** Exact `rust_decimal::Decimal` and `Decimal` reconciliation down to ₺0.01 (zero kuruş discrepancy).
2. **Idempotency Gate:** Duplicate webhook deliveries and duplicate accrual requests for the same period are rejected safely with HTTP 200 without double-crediting or duplicate liabilities.
3. **Security Gate:** Plaintext bank credentials must never be written to logs or transmitted unencrypted.
4. **Automated Verification:** 38 Rust tests and 49 Flutter tests running 100% green.
