# Specification: Virtual IBAN Settlement, Advance Payment Allocation & Periodic Dues Accrual

> **Feature ID:** SPEC-004  
> **Epic ID:** EPIC-07 (`STORY-07-01`, `STORY-07-03`, `STORY-07-04`, `STORY-07-05`, `STORY-07-06`, `STORY-07-07`)  
> **Domain:** Automated Virtual IBAN Settlement, Resident Advance Balance, and Periodic Dues Accrual  
> **Target Roles:** Home Resident (Site Sakini), Site Manager (Site Yöneticisi), SaaS Admin  
> **Governance:** Turkish Condominium Law (KMK Madde 35-f), High-Precision Decimal Invariants, TCMB FAST / Açık Bankacılık  

---

## 1. Context & Business Value

In property management, collecting dues through generic bank transfers leads to manual tracking errors and delayed bookkeeping. This specification formalizes the end-to-end automation of the residential financial lifecycle:

1. **Flat-Specific Virtual IBAN (Sanal IBAN)**: Each apartment unit is allocated a unique, ISO 7064 MOD-97-10 validated 26-character Turkish Virtual IBAN (`TR410020504213991067000014`) tied to the site's primary commercial account.
2. **Real-Time Settlement & Zero Human Intervention**: Incoming FAST and EFT transfers received via bank webhooks (`POST /api/v1/bank/webhook/incoming-transfer`) immediately identify the flat with 100% confidence, transition dues liabilities to `PAID`, issue digital receipts, and enforce strict HMAC verification and idempotency (`DUPLICATE_IGNORED`).
3. **Advance Payment Allocation (Avans Bakiye)**: Any transfer amount exceeding the flat's outstanding debt (or paid in advance before dues accrue) is credited to `advance_payment`. The resident's Hero Balance Card dynamically displays `+₺{amount}` in emerald green (*"Mevcut Avans Bakiyesi (Alacak)"*) instead of "0 ödenecek tutar", and transaction movements clearly reflect advance funding.
4. **Site Bank Configuration & Format Enforcement**: Site managers configure their official bank account (Kuveyt Türk, Garanti BBVA, İş Bankası, Yapı Kredi, Akbank) and the system automatically enforces matching statement formats (Excel, CSV, MT940).
5. **Periodic Monthly Dues Accrual with Duplicate Prevention**:
   - **Embedded Tokio Background Scheduler**: Runs a recurring batch worker that automatically creates monthly dues liabilities (e.g. `Ekim 2026`) across all sites.
   - **Site Manager UI Action ("Toplu Aidat Tahakkuku")**: Empowers site managers in the Aidat Yönetimi view to trigger and preview period accrual.
   - **Duplicate Accrual Guard (`prevent duplicate accrual`)**: If debts for a site and period have already been accrued, duplicate creation is strictly rejected, returning `already_accrued: true` and an informative notice without modifying existing debts.
   - **Automatic Advance Offset**: Automatically deducts newly accrued liabilities from available resident advance balances (`advance_payment`) via FIFO.

---

## 2. Technical Architecture & Artifacts

### 2.1 Backend Artifacts (Rust / Axum / Tokio)
- `virtual_iban_service.rs`: ISO 7064 MOD-97-10 check digit calculation and 26-character TR Virtual IBAN generation.
- `kuveyt_turk_service.rs`: Kuveyt Türk Sandbox integration and certificate validation.
- `scheduler.rs`: Embedded Tokio background scheduler executing `run_periodic_accrual_for_all_sites` every interval.
- `handlers/mod.rs`:
  - `handle_bank_incoming_webhook`: Webhook endpoint with idempotency guard.
  - `accrue_monthly_dues`: Monthly period accrual handler with duplicate accrual prevention.
  - `apply_advance_payments_offset`: FIFO advance balance deduction against unpaid liabilities.
  - `configure_site_bank_account`: Bank account configuration and statement format auto-binding.
- `models/mod.rs`: High-precision `rust_decimal::Decimal` structs (`AccrueDuesPeriodRequest`, `AccrueDuesPeriodResponse`, `BankIncomingWebhookRequest`, `BankIncomingWebhookResponse`).

### 2.2 Frontend Artifacts (Flutter UI & Mobile Web)
- `payment_checkout_dialog.dart`: User-friendly FAST payment option (*"Sanal IBAN ile FAST Transfer"*), 1-tap clipboard copy, and instructions.
- `hero_balance_card.dart`: Dynamic dual-state rendering (Overdue debt in crimson vs. positive advance balance in emerald green).
- `dues_management_view.dart`: Dedicated **"Toplu Aidat Tahakkuku"** action button, confirmation dialog, and duplicate prevention alerts.
- `dashboard_controller.dart`: Reactive controller managing `accrueMonthlyDues`, dynamic `availableDuesMonths`, and instant resident balance synchronization.

---

## 3. Acceptance Criteria (Gherkin)

```gherkin
Scenario: Automated virtual IBAN allocation and resident dashboard display
  Given unit "A Blok D:14" in site "Begonya Sitesi" is registered
  When virtual IBAN is generated
  Then format is valid TR IBAN "TR410020504213991067000014"
  And resident sees the Sanal IBAN on their mobile dashboard with 1-tap copy

Scenario: Real-time webhook incoming transfer settlement and receipt emission
  Given outstanding dues liability of ₺1400.00 for unit "d-14"
  When bank webhook delivers transfer of ₺2860.67 to virtual IBAN "TR410020504213991067000014"
  Then dues liability transitions to "PAID"
  And remaining ₺1460.67 is credited to "advance_payment"
  And Hero Balance Card displays "+₺1.460,67" in emerald green
  And subsequent duplicate webhook with same transaction ID returns "DUPLICATE_IGNORED"

Scenario: Monthly dues accrual with duplicate prevention guard
  Given a new period arrives: "Ekim 2026"
  When monthly dues accrual is executed for site "site-1"
  Then 12 dues liabilities of ₺1400.00 each are created
  And unit "d-14" with advance balance ₺1460.67 is auto-settled to PAID with remaining advance ₺60.67
  And when monthly accrual is executed a second time for "Ekim 2026"
  Then newly accrued unit count is 0
  And response flags "already_accrued: true"
  And message contains "Mükerrer tahakkuk engellendi"
  And no duplicate liabilities are added
```

---

## 4. Verification & Testing Evidence

- `cargo test`: 38/38 unit and integration tests passing.
- `flutter test`: 49/49 widget and unit tests passing.
- Harness gates: Financial Precision Gate, Idempotency Gate, and Invariant Guard Gate verified.
