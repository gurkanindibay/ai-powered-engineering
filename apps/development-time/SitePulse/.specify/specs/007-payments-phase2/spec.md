# Specification: Payments Phase 2 (Virman Reversal, Resident Statement, Receipt PDF, Card Payments, İşletme Projesi)

> **Feature ID:** SPEC-007
> **Epic ID:** EPIC-09 (`STORY-09-03` statement, `STORY-09-04` receipts, §2.3 virman), EPIC-01 (card checkout), EPIC-02 (budget), EPIC-10 (`STORY-10-04` virman dialog)
> **Domain:** Treasury & Billing Context
> **Target Roles:** Home Owner, Home Resident (tenant), Site Manager, SaaS Admin (revaluation rates), licensed payment provider (webhook)
> **Governance:** KMK 20 (penalty), KMK 35/37 as amended by Law 7579 (RG 22.05.2026, işletme projesi), İİK 68/1, TBK 147/1 (5-year limitation), 6493 (payment services), KVKK (no payer data on public verification)
> **Depends on:** SPEC-005 / V16, SPEC-006 / V17
> **Source analysis:** `docs/payments/PAYMENTS_REGULATORY_AND_MARKET_EVALUATION.md` F1, F4, F7, E2, E10, E11; SPEC-006 §4 (deferred virman reversal, receipt PDF)
> **Schema:** migration `V18__payments_phase2.sql`

---

## 1. Context

SPEC-005/006 left five items open: a virman could not be reversed, residents had no statement with debt aging, the receipt PDF button was a stub, the card checkout collected raw card fields and called a staff-only route, and there was no işletme projesi, so dues had no approved legal basis (non-compliant with KMK 37 since 22.05.2026).

## 2. Requirements

### R1 — Virman reversal
- `POST /api/v1/payments/reverse` accepts an `INTER_LEDGER` receipt. The reversal reopens the liabilities the virman settled and credits the spent amount back to the source debtor's advance as a `VIRMAN_REVERSAL` advance ledger entry, in the same transaction. It issues an `IAD-` receipt; `restored_advance` reports the amount. A virman is reversed at most once.
- The manager's receipt viewer has an "İptal / iade" action (reason required) for `TAH-` receipts, collections and virmans alike.
- The virman dialog lists the site's real units with their current advance balances (`advance_balance` on the home-owner list), never fixed sample units.

### R2 — Resident statement (hesap ekstresi)
- `GET /api/v1/residents/:unit_id/statement` returns, per debtor, the open items aged into current / 1–30 / 31–60 / 61–90 / 90+ days, principal, KMK 20 penalty accrued to date, advance balance, each item's operating budget (legal basis) and a 5-year limitation flag (TBK 147/1), plus the unit's receipts (with a reversed flag).
- A resident sees only their own debtor (owner or tenant) and receipts; site staff see both. Another site's manager gets 403.
- The resident home has a "Hesap Ekstresi" entry; the manager's resident cards have `btn_statement_<unit>`.

### R3 — Receipt PDF and verification
- `GET /api/v1/payments/receipts/:id/pdf` renders the stored receipt (issuer, VKN, payer, allocation lines, legal note) as an A4 PDF with embedded subset DejaVu Sans (Turkish glyphs) and a QR code. Resident scoping is the same as for the JSON receipt.
- The QR code points to the public `GET /api/v1/public/receipts/verify?no=&h=`, which confirms number, type, date, amount, issuer and reversal status, and discloses no payer or unit (KVKK).

### R4 — Card payments through a licensed provider (6493)
- `POST /api/v1/residents/:unit_id/payment-intents` opens a `payment_intent` (provider reference, state `CREATED → AUTHORIZED → CAPTURED | FAILED`, `CAPTURED → REFUNDED`) and returns the provider's hosted checkout URL. A resident may only pay their own debtor's debts. SitePulse never receives card data.
- `POST /api/v1/payments/provider/webhook` is public and authenticated by `X-Provider-Signature` (hex HMAC-SHA256 of the body with `SITEPULSE_PAYMENT_WEBHOOK_SECRET`). A capture is recorded through `record_and_allocate_payment` (channel `CREDIT_CARD`, idempotency key `PSP:<provider>:<ref>`); repeated notifications return the same receipt; an amount mismatch is 409.
- Reversing a card receipt refunds the intent at the provider and marks it `REFUNDED`.
- Only the `SANDBOX` provider exists in this build: a simulated hosted page (3-D Secure approve/decline, no card fields), disabled in production. A real provider is a new `PaymentProvider` selected with `SITEPULSE_PAYMENT_PROVIDER`.
- The Flutter checkout opens the hosted page in a new tab and follows the intent until it is captured or failed.

### R5 — İşletme projesi
- Budgets per site and fiscal year with expense lines (category, yearly amount, allocation key `LAND_SHARE` or `EQUAL`) and per-unit yearly/monthly shares split to the kuruş (largest remainder).
- Lifecycle: `DRAFT → INTERIM` (manager) or `DRAFT/INTERIM → APPROVED` (assembly decision reference and date) `→ FINAL`; `REJECTED`; a budget coming into force supersedes the year's previous one (`SUPERSEDED`). At most one budget is in force per site and year.
- Interim cap: the increase over the baseline (previous budget, or the current tariffs' yearly run-rate for a site's first budget) may not exceed that year's `revaluation_rates` rate; above it, or without a recorded rate, only the assembly can approve. An interim budget carries its 3-month deadline.
- Service on each owner (method, date) opens the 7-day objection window; objections are recorded and resolved. `FINAL` needs every unit served, the window closed and no open or upheld objection.
- `accrue-period` and the monthly scheduler accrue operational dues from the unit's monthly share of the budget in force and set `dues_liabilities.operating_budget_id`. A typed amount is refused (409) while a budget is in force or when the site requires one (`sites.require_operating_budget`); without a budget and without the requirement, the legacy tariff is used and the response carries a KMK 37 warning.
- The debtor of operational dues is read from PostgreSQL occupancy (`units.tenant_person_id`), and liabilities are inserted through the identity column (no explicit ids).
- Revaluation rates: list for staff, set by the SaaS admin. The 2026 seed (25.49%) must be verified against the published communiqué.

## 3. Acceptance
- Rust: `tests/payments_phase2_tests.rs` (15 tests) and `payment_ledger_hardening_tests::when_a_virman_receipt_is_reversed_then_the_dues_reopen_and_the_source_advance_is_restored`.
- System (PostgreSQL): `virman_reversal_restores_advance`, `resident_statement_scoped`, `receipt_pdf_and_verification`, `card_payment_via_provider`, `budget_accrual_legal_basis`, `ledger_integrity_clean` (with the new `budget_shares_vs_lines` and `captured_intent_without_receipt` checks).
- GUI: `e2e/tests/test_spec007_payments_phase2.py`, `test_epic09_receipts.py::test_tenant_statement_lists_operational_items_only`, the STORY-10-04 virman tests, and the accrual debtor tests in `test_epic08_occupancy.py`.

## 4. Out of scope
Real provider integrations (bank sanal POS, iyzico/PayTR etc.), card-on-file/autopay and installments, `METER`/`CUSTOM`/`HOUSE_TYPE` allocation keys, a digital decision book (karar defteri) beyond the decision reference, budget-vs-actual (needs the expense module F8), and refund of a card payment's provider fee.
