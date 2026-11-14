# Epic: Payments Phase 3 (Compliance Gates, Collections, Accounting and Governance)

> **Epic ID:** EPIC-11
> **Module:** `backend-rust`, `flutter-ui`, `flutter-domain`, `postgres-db`
> **Specification:** [SPEC-009](../specs/009-payments-phase3/spec.md), migration `V20__payments_phase3.sql`
> **Source:** [docs/PAYMENTS_PRODUCT_OWNER_EVALUATION.md](../../docs/PAYMENTS_PRODUCT_OWNER_EVALUATION.md) §3–§4 (F-01 … F-17)
> **Status:** IMPLEMENTED (sandbox providers; items marked *verify* need counsel before production)
> **Target Audience:** `SITE_MANAGER`, `AUDITOR`, `HOME_OWNER`, `HOME_RESIDENT`, `SAAS_ADMIN`, management-company members, lawyers (token)
> **Invariants:** `rust_decimal` / `Decimal` money and `NUMERIC(15,2)` columns; every split through `domain::apportion`; four-eyes on every waiver, write-off, payment plan and invoice approval; debt notices only on personal channels (KVKK 2026/348); no card data in SitePulse (6493).

## 1. Why
SPEC-007 closed card checkout, the core işletme projesi and the resident statement. The product-owner evaluation still found the platform missing its KVKK and KMK 22 gates, the parity features every competitor sells (reminders, autopay, an expense ledger and the yearly account report, collections and payment plans) and the differentiators (heat-share, a decisions book, a management-company console, analytics).

## 2. User stories

| Story | As a … | I want … | So that … | Acceptance (tests) |
|---|---|---|---|---|
| STORY-11-01 | manager | to split budget lines by house type, meter or custom weights and run a 90-day transition | dues of every site rest on a lawful key (F-01) | `when_a_budget_line_uses_house_type_or_meter_keys…`, `…in_transition…` |
| STORY-11-02 | resident | to read the privacy notice, acknowledge it and choose my message channels | my financial data is handled under KVKK (F-03) | `when_a_privacy_notice_is_published…`, `…masked…`, `…retention…` |
| STORY-11-03 | manager | to see how much of an owner's debt I may claim from the tenant, capped at the unpaid rent | collection letters respect KMK 22 (F-04) | `…claimable_up_to_the_unpaid_rent`, `…rent_certificate…` |
| STORY-11-04 | manager | a dunning schedule that sends each step once, never to a group channel | debtors are reminded lawfully and consistently (F-05) | `when_dunning_runs…`, `…opts_out_of_sms…`, `…group_channel…` |
| STORY-11-05 | resident | to choose which debts I pay, dispute an item and request a virman | I control how my money is applied (F-06) | `…virman…`, `when_a_dispute_is_resolved…`, Flutter `selecting open items…` |
| STORY-11-06 | resident | to save my card at the provider and pay automatically | I never miss a due date (F-07) | `when_autopay_runs…`, `when_a_card_is_declined…` |
| STORY-11-07 | manager / auditor | vendors, approved invoices, a balanced ledger, budget vs actual and the yearly account report | I can account to the assembly from one tool (F-08, F-16) | `…four_eyes…`, `…trial_balance_balances…`, API `finance_desk_over_http` |
| STORY-11-08 | manager | a collection case workflow with an evidence pack and a lawyer link | debts reach enforcement with their legal basis (F-09) | `…enforcement…lawyer…`, `…kmk25…` |
| STORY-11-09 | manager | payer hints (TCKN, phone, block/unit) and a daily bank reconciliation | transfers outside the virtual IBAN are matched (F-10) | `…bypasses_the_virtual_iban…`, `…daily_reconciliation…` |
| STORY-11-10 | manager | payment plans and four-eyes waivers and write-offs | hardship cases are handled transparently (F-11) | `…waiver…`, `…plan_is_kept…` |
| STORY-11-11 | manager | heating costs split by meter readings and area | central-heating sites bill fairly (F-13) | `…heating_period…` |
| STORY-11-12 | manager | meetings, quorum, votes and a numbered decisions book | decisions approve budgets with evidence (F-14) | `…assembly_accepts_a_budget_item…` |
| STORY-11-13 | management company | a portfolio summary and monthly e-Arşiv / e-Fatura fee invoices | I run many sites from one console (F-15) | `…management_company_invoices…` |
| STORY-11-14 | manager | collection rate, on-time rate, DSO, channel shares, a forecast and at-risk units | I can see and act on collection trends (F-17) | `…analytics_are_computed…` |

## 2a. Story details and executable acceptance

### STORY-11-01: Allocation keys and the 90-day transition
- **As a:** manager  
- **I want to:** to split budget lines by house type, meter or custom weights and run a 90-day transition  
- **So that:** dues of every site rest on a lawful key (F-01)

Executable scenarios: [`STORY-11-01-allocation-keys-and-transition.feature`](../features/EPIC-11/STORY-11-01-allocation-keys-and-transition.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

### STORY-11-02: Privacy notice, channel consents and retention
- **As a:** resident  
- **I want to:** to read the privacy notice, acknowledge it and choose my message channels  
- **So that:** my financial data is handled under KVKK (F-03)

Executable scenarios: [`STORY-11-02-kvkk-privacy-and-retention.feature`](../features/EPIC-11/STORY-11-02-kvkk-privacy-and-retention.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

### STORY-11-03: KMK 22 tenant claim cap and rent certificate
- **As a:** manager  
- **I want to:** to see how much of an owner's debt I may claim from the tenant, capped at the unpaid rent  
- **So that:** collection letters respect KMK 22 (F-04)

Executable scenarios: [`STORY-11-03-kmk22-tenant-claim.feature`](../features/EPIC-11/STORY-11-03-kmk22-tenant-claim.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

### STORY-11-04: Dunning schedule and lawful channels
- **As a:** manager  
- **I want to:** a dunning schedule that sends each step once, never to a group channel  
- **So that:** debtors are reminded lawfully and consistently (F-05)

Executable scenarios: [`STORY-11-04-dunning-schedule.feature`](../features/EPIC-11/STORY-11-04-dunning-schedule.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

### STORY-11-05: Selecting debts, disputes and virman requests
- **As a:** resident  
- **I want to:** to choose which debts I pay, dispute an item and request a virman  
- **So that:** I control how my money is applied (F-06)

Executable scenarios: [`STORY-11-05-resident-payment-control.feature`](../features/EPIC-11/STORY-11-05-resident-payment-control.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

### STORY-11-06: Saved card and automatic payment
- **As a:** resident  
- **I want to:** to save my card at the provider and pay automatically  
- **So that:** I never miss a due date (F-07)

Executable scenarios: [`STORY-11-06-autopay.feature`](../features/EPIC-11/STORY-11-06-autopay.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

### STORY-11-07: Vendors, invoices, ledger and yearly account report
- **As a:** manager / auditor  
- **I want to:** vendors, approved invoices, a balanced ledger, budget vs actual and the yearly account report  
- **So that:** I can account to the assembly from one tool (F-08, F-16)

Executable scenarios: [`STORY-11-07-finance-desk.feature`](../features/EPIC-11/STORY-11-07-finance-desk.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

### STORY-11-08: Collection case workflow, evidence pack and lawyer link
- **As a:** manager  
- **I want to:** a collection case workflow with an evidence pack and a lawyer link  
- **So that:** debts reach enforcement with their legal basis (F-09)

Executable scenarios: [`STORY-11-08-collection-cases.feature`](../features/EPIC-11/STORY-11-08-collection-cases.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

### STORY-11-09: Payer hints and daily bank reconciliation
- **As a:** manager  
- **I want to:** payer hints (TCKN, phone, block/unit) and a daily bank reconciliation  
- **So that:** transfers outside the virtual IBAN are matched (F-10)

Executable scenarios: [`STORY-11-09-payer-hints-and-reconciliation.feature`](../features/EPIC-11/STORY-11-09-payer-hints-and-reconciliation.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

### STORY-11-10: Payment plans, waivers and write-offs
- **As a:** manager  
- **I want to:** payment plans and four-eyes waivers and write-offs  
- **So that:** hardship cases are handled transparently (F-11)

Executable scenarios: [`STORY-11-10-payment-plans-and-waivers.feature`](../features/EPIC-11/STORY-11-10-payment-plans-and-waivers.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

### STORY-11-11: Heating costs split by meter readings and area
- **As a:** manager  
- **I want to:** heating costs split by meter readings and area  
- **So that:** central-heating sites bill fairly (F-13)

Executable scenarios: [`STORY-11-11-heating-cost-split.feature`](../features/EPIC-11/STORY-11-11-heating-cost-split.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

### STORY-11-12: Meetings, quorum, votes and decisions book
- **As a:** manager  
- **I want to:** meetings, quorum, votes and a numbered decisions book  
- **So that:** decisions approve budgets with evidence (F-14)

Executable scenarios: [`STORY-11-12-assembly-decisions-book.feature`](../features/EPIC-11/STORY-11-12-assembly-decisions-book.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

### STORY-11-13: Portfolio summary and fee invoices
- **As a:** management company  
- **I want to:** a portfolio summary and monthly e-Arşiv / e-Fatura fee invoices  
- **So that:** I run many sites from one console (F-15)

Executable scenarios: [`STORY-11-13-management-company-console.feature`](../features/EPIC-11/STORY-11-13-management-company-console.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

### STORY-11-14: Collection analytics and at-risk units
- **As a:** manager  
- **I want to:** collection rate, on-time rate, DSO, channel shares, a forecast and at-risk units  
- **So that:** I can see and act on collection trends (F-17)

Executable scenarios: [`STORY-11-14-collection-analytics.feature`](../features/EPIC-11/STORY-11-14-collection-analytics.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

## 3. Verification
- Rust: `tests/payments_phase3_tests.rs` (28 scenarios), domain unit tests, `tests/finance_store_pg_tests.rs` (opt-in PostgreSQL round trip of every record).
- System: `scripts/api_system_check.py` check `finance_desk_over_http`; `schema_integrity_check.py` replays V20.
- Flutter: `test/payments_phase3_test.dart`.
