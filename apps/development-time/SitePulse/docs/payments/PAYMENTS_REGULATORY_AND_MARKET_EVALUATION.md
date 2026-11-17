# Payments Module: Regulatory, Market and Feature Gap Evaluation

> **Companion to:** [PAYMENTS_MANAGEMENT_STRUCTURE_REPORT.md](PAYMENTS_MANAGEMENT_STRUCTURE_REPORT.md), which covers code and schema structure.
> **Scope:** (1) Turkish rules that apply to dues and payment management. (2) How comparable products handle payments. (3) Status of every existing SitePulse payment feature. (4) Missing and new features, with specifications.
> **Date:** 2026-11-08
>
> ⚠️ **This is not legal advice.** The regulatory findings come from secondary sources: law-firm articles, news reports and legal databases (listed in §7). Before any rule is built into the product, confirm it against the official Resmî Gazete text, and have a lawyer or mali müşavir review it. Points that are uncertain are marked **(verify)**.

> **Implementation status reviewed 2026-11-17.** §2.1 reflects the current code and links each implemented capability to its specification. The original evaluation and roadmap record the 2026-11-08 baseline. See the [product owner evaluation](PAYMENTS_PRODUCT_OWNER_EVALUATION.md#implementation-status-2026-11-09) for the Phase 2 and Phase 3 rollout status.

---

## 1. Executive summary

SitePulse's payment module was designed around **one** legal idea: a tenant/owner dual ledger and a 5% delay penalty under KMK 20/22. Turkish dues management is regulated more widely than that, and the rules changed in 2026:

1. **Since 22 May 2026, Law 7579 has changed KMK 35/37.** The genel kurul must approve the operating budget (*işletme projesi*). A manager's interim budget may not rise above the *yeniden değerleme oranı* (revaluation rate). SitePulse has **no işletme projesi at all**: managers type a dues amount per house type, with no cap and no approval. This is the largest compliance gap.
2. **The KVKK principle decision 2026/348** (published in the Resmî Gazete on 31 March 2026) bans posting debtor lists in common areas. Debt notices must go through closed, individual channels. SitePulse has no consent, visibility or notification-channel rules.
3. **The delay penalty is charged on the full principal instead of the unpaid principal.** After a partial payment, the resident is over-charged.
4. **TBK 101 gives the payer the right to choose which debt a payment settles.** SitePulse always auto-allocates FIFO and ignores the payer's choice.
5. **KMK 22 makes the tenant jointly liable with the owner, up to the rent amount.** SitePulse instead splits debts strictly (tenant pays operational dues, owner pays capital dues) and does not store a rent amount, so the cap cannot be applied.

Against the market, SitePulse is **behind on table-stakes features**: expense (gider) management, accounting and the yearly account report, a collections/enforcement workflow, autopay, payment plans, reminders, and real card payments. It is **ahead on** its sanal-IBAN-per-unit design, the explicit dual ledger and the KMK-aware receipt text.

---

## 2. Regulatory evaluation

### 2.1 Requirements versus SitePulse

| # | Rule | What it requires | SitePulse status | Gap severity |
|---|---|---|---|---|
| R1 | **KMK 20: delay penalty** | An owner who pays the share of costs or advances late owes **5% per month, prorated by days late** | Penalty accrues in segments on the unpaid principal. `penalty_accrued_through` prevents double accrual on re-evaluation. [SPEC-005 R3](../../.specify/specs/005-payment-compliance-phase1/spec.md) | ✅ Implemented |
| R2 | **KMK 20: cost-sharing key** | Unless the yönetim planı says otherwise, costs are shared by **arsa payı** (land share). Some cost types are shared equally | Operating budgets allocate dues by land share or equally, with house-type, meter and custom weights also available. Sites without a required budget and sites in the transition window can still accrue from legacy tariffs. [SPEC-007 R5](../../.specify/specs/007-payments-phase2/spec.md), [SPEC-009 R1](../../.specify/specs/009-payments-phase3/spec.md) | 🟠 Legacy tariff fallback |
| R3 | **KMK 37 (as amended by Law 7579, RG 22.05.2026)** | The işletme projesi must be approved by the **kat malikleri genel kurulu**. Without one, the manager prepares an **interim project**, puts it to the assembly within **3 months**, and the amount **may not exceed the revaluation rate** over the existing amount | Operating budgets support assembly approval, an interim budget with a revaluation cap and deadline, and accrual linked to the budget in force. The source of the configured revaluation rate still needs verification. [SPEC-007 R5](../../.specify/specs/007-payments-phase2/spec.md), [SPEC-009 R1](../../.specify/specs/009-payments-phase3/spec.md) | ✅ Workflow implemented |
| R4 | **KMK 37: notification and objection** | The project is served on the owners. Owners may object within **7 days** of notification. A finalized project is an **İİK 68/1 document**, which allows summary enforcement (*ilamsız icra*) | Owner service opens the objection window. Finalization checks service and objections. Collections can produce an evidence pack for liabilities with a recorded legal basis. [SPEC-007 R5](../../.specify/specs/007-payments-phase2/spec.md), [SPEC-009 R8](../../.specify/specs/009-payments-phase3/spec.md) | ✅ Workflow implemented |
| R5 | **KMK 35(d), as amended** | The manager collects advances (*avans*) **until the işletme projesi is approved**, in the first month of the year or as the management plan says | The configurable transition permits legacy tariff accrual and flags liabilities without a budget basis. The product has no dedicated first-month or management-plan advance schedule for this requirement. [SPEC-009 R1](../../.specify/specs/009-payments-phase3/spec.md) | 🟠 Advance schedule open |
| R6 | **KMK 22: tenant joint liability** | The tenant is **jointly and severally** liable with the owner for costs, advances and delay penalties, **capped at the rent amount owed**. Whatever the tenant pays is **deducted from the rent** | Leases supply the rent cap. The joint-exposure view reports eligible owner operational dues and the receipt flow generates a rent-deduction certificate. The receipt citation and legal interpretation still need review. [SPEC-009 R3](../../.specify/specs/009-payments-phase3/spec.md) | ✅ Workflow implemented |
| R7 | **KMK 22/2: legal mortgage** | If the debt cannot be collected, a court-set **kanuni ipotek** (legal mortgage) can be placed on the unit | Collections can prepare a lawyer handover pack. A court-set mortgage has no dedicated record or workflow. [SPEC-009 R8](../../.specify/specs/009-payments-phase3/spec.md) | 🟡 Mortgage tracking open |
| R8 | **KMK 25: transfer of ownership** | An owner who triggers **3 enforcement or court actions within 2 years** can be sued to transfer the unit | Collections flags three recorded enforcement filings within two years on owner cases for a unit. The legal action to transfer ownership remains outside the case workflow. [SPEC-009 R8](../../.specify/specs/009-payments-phase3/spec.md) | 🟡 Filing alert implemented |
| R9 | **TBK 100: partial payment** | A debtor **in default** on interest or costs has a partial payment applied to those first, then to principal | The waterfall applies outstanding penalties before principal on eligible balances. There is no separate check for default on the penalty itself. [SPEC-005 R4](../../.specify/specs/005-payment-compliance-phase1/spec.md) | 🟡 Default edge case open |
| R10 | **TBK 101–102: payer designation** | A debtor with several debts may **say which debt they are paying**. Otherwise the order is: the receipt, then statutory rules (due debts, debts first pursued, earliest due) | Staff can designate liabilities, periods or expense types. Residents can select statement items for card checkout, and bank channels can infer a period from the transfer description. The fallback uses the payment waterfall and due dates, with no priority keyed to which debt was first pursued. [SPEC-005 R4](../../.specify/specs/005-payment-compliance-phase1/spec.md), [SPEC-009 R5](../../.specify/specs/009-payments-phase3/spec.md) | ✅ Designation implemented |
| R11 | **TBK 103–104: receipt** | The payer may demand a receipt | Manual, bank webhook, statement confirmation, match-all and card capture paths issue canonical collection receipts. PDFs include a public QR verification link. [SPEC-005 R1–R2](../../.specify/specs/005-payment-compliance-phase1/spec.md), [SPEC-007 R3–R4](../../.specify/specs/007-payments-phase2/spec.md) | ✅ Implemented |
| R12 | **TBK 147: limitation period (verify)** | Periodic obligations such as dues are commonly treated as becoming time-barred after **5 years** | Resident statements flag older liabilities, and collection cases warn when an open item approaches or passes the modeled five-year date. [SPEC-007 R2](../../.specify/specs/007-payments-phase2/spec.md), [SPEC-009 R8](../../.specify/specs/009-payments-phase3/spec.md) | ✅ Warnings implemented |
| R13 | **Mandatory mediation (verify)** | One source says mediation has been a **pre-condition for lawsuits** in KMK disputes since 01.09.2023 (6325 s. K. m.18/B) | Collection cases record a mediation stage and prepare a lawyer handover pack. The workflow does not submit cases to an external court or mediation system. [SPEC-009 R8](../../.specify/specs/009-payments-phase3/spec.md) | 🟡 Internal case stage implemented |
| R14 | **KVKK 6698 and Kurul decision 2026/348** (RG 31.03.2026) | Posting name, unit, debt amount or days late in common areas is **unlawful** (no lawful basis under m.5, breaches the security duty under m.12). Debt notices must go through **closed, person-specific channels** | Versioned notices, acknowledgements, channel consent, personal-channel rules, scoped exports, access logs and retention controls are available. Production notification delivery still needs providers. [SPEC-009 R2 and R4](../../.specify/specs/009-payments-phase3/spec.md) | ✅ Controls implemented |
| R15 | **6493 Payment Services Law** | Payment services (accepting card payments, moving funds on others' behalf) require a **TCMB licence**. Unlicensed activity is a criminal offence (m.28: 1–3 years imprisonment) | Card checkout uses a provider-hosted page and signed callbacks. Card processing is sandbox-only, and production acceptance still requires a licensed provider integration and merchant contract. [SPEC-007 R4](../../.specify/specs/007-payments-phase2/spec.md), [SPEC-009 R6 and R9](../../.specify/specs/009-payments-phase3/spec.md) | 🟠 Production provider open |
| R15b | **KMK 35: hesap verme (verify)** | The manager keeps the books and **accounts to the genel kurul**. A denetçi (auditor) reviews them. A karar defteri (decisions book) is required. Sources disagree on whether a notarized işletme defteri is mandatory | The expense ledger, yearly account report, auditor role and numbered assembly decisions are available. [SPEC-009 R7 and R12](../../.specify/specs/009-payments-phase3/spec.md) | ✅ Workflow implemented |
| R16 | **Tax / e-documents (verify)** | A kat malikleri kurulu is generally not a taxpayer, so dues receipts are not e-Arşiv invoices. A **professional management company** invoicing its fee does need e-Fatura/e-Arşiv. Interest income on site funds is taxed through withholding | Management-company fees support sandbox e-Fatura and e-Arşiv issuance. Production issuance needs an authorised integrator. Withholding on site-fund interest is outside this workflow. [SPEC-009 R13](../../.specify/specs/009-payments-phase3/spec.md) | 🟡 Production integration open |

EPIC-07 specifies six open accrual stories.

- Canonical billing periods and atomic batches. [STORY-07-08](../../.specify/features/EPIC-07/STORY-07-08-canonical-period-and-atomic-batch.feature)
- Occupant changes and proration within a period. [STORY-07-09](../../.specify/features/EPIC-07/STORY-07-09-occupancy-aware-proration.feature)
- Scheduling, catch-up and grace periods. [STORY-07-10](../../.specify/features/EPIC-07/STORY-07-10-accrual-schedule-catch-up-and-grace.feature)
- Cancellations, reissues and credit notes. [STORY-07-11](../../.specify/features/EPIC-07/STORY-07-11-accrual-corrections.feature)
- Billing-period lifecycle and close. [STORY-07-12](../../.specify/features/EPIC-07/STORY-07-12-billing-period-lifecycle-and-close.feature)
- Consistent late fees across the dashboard, statement and ledger. [STORY-07-13](../../.specify/features/EPIC-07/STORY-07-13-late-fee-consistency.feature)

### 2.2 What the 2026 KMK amendment means for the product

Law **7579** (adopted by TBMM on 29.04.2026, published in RG 33261 on 22.05.2026, effective the same day) changed KMK 35(1)(d), KMK 37 and KMK 70. The product needs these changes:

- **Interim-project cap.** Any increase over the previous işletme projesi must be checked against that year's **revaluation rate** (VUK mükerrer 298; one source gives **25.49% for 2026** as an example, **verify**). Amounts above the cap need a genel kurul decision.
- **Three-month clock.** An interim project must reach the genel kurul within 3 months. The system should track this deadline and warn the manager.
- **Approval makes debts enforceable.** Only dues backed by an approved, finalized işletme projesi or a kurul decision on operating costs qualify as an İİK 68/1 document. Each dues liability should therefore point to the budget or decision it comes from.
- **Toplu yapı plan changes.** Changing the management plan in a toplu yapı (multi-building complex) now needs a 2/3 majority instead of 4/5. This affects the allocation key (R2) if the plan is changed.

### 2.3 Compliance by EPIC-09 story

| Story | Regulatory soundness |
|---|---|
| 09-01 Payment stream | OK in principle. Needs KVKK access control and an audit log of who viewed what |
| 09-02 FIFO waterfall | **Needs TBK 101 designation and penalty-base correction** |
| 09-03 Aging and statement | Must not be exportable as a public "debtor list" (KVKK 2026/348). Add the 5-year limitation flag |
| 09-04 Receipts | Must cover all channels (TBK 103). "Official / legally compliant" wording needs mali müşavir review |
| 09-05 Move-out | OK. Under KMK 22 the tenant remains jointly liable only up to rent owed, so the frozen balance should be kept with its cap |
| 09-06 Tenant pays capital dues | Correct in direction. Fix the TBK 314 citation (verify) and add the rent cap |
| 09-07 Ownership transfer | OK in principle. Pre-transfer debts stay with the old owner. Note: under KMK, unpaid common charges can also attach to the unit itself (legal mortgage), so the new owner should be warned of open items |

---

## 3. Market evaluation

### 3.1 Products compared

- **Apsiyon (Turkey, market leader).** Integrates with Turkish banks and automatically matches incoming transfers to residents by **TCKN, block/unit or phone**. No-credential setup is available for Yapı Kredi, Ziraat, Şekerbank and Kuveyt Türk. Offers sanal POS card payments with **installments**, **card-on-file autopay**, automatic receipts built on a **standard chart of accounts**, and dues distribution **by owner, tenant, building or unit type**. Also has meter/heat-share billing, scheduled **SMS/email** notices, a resident app, POS hardware, and starting **icra** on overdue accounts.
- **Konsiyon / Dijiyon (Turkey).** Market **lawyer assignment** and handing the debt schedule over to the lawyer for enforcement.
- **International HOA tools (Buildium, AppFolio, Vantaca, CINC, PayHOA, ManageHOA).** Typical features: **ACH autopay** and card, **configurable automated late fees** (one-time to compounding), **payment reminders**, **payment plans**, **waivers and write-offs**, **NSF/returned-payment handling**, a per-unit ledger, **bank reconciliation tied to accrual accounting**, budgets, delinquency notices, collections escalation, violations and fines, and an owner portal.

### 3.2 Feature matrix

✅ = has · ⚠️ = partial or buggy · ❌ = missing · (src) = claimed by vendor material, not independently verified

| Capability | SitePulse | Apsiyon | Intl HOA tools |
|---|---|---|---|
| Per-unit sanal IBAN | ✅ | ❌/n.a. (bank-account matching instead) | ❌ |
| Bank statement import (Excel/MT940) | ✅ | ✅ (live bank feed) | ✅ |
| Live bank feed / auto-match (TCKN, phone) | ⚠️ (Kuveyt Türk sandbox, name/IBAN match) | ✅ (src) | ✅ |
| Webhook real-time settlement | ⚠️ (bypasses the canonical ledger) | ✅ (src) | ✅ |
| Card payment (sanal POS) | ❌ (UI only) | ✅ with installments (src) | ✅ |
| Autopay / card on file | ❌ | ✅ (src) | ✅ ACH autopay |
| Dual ledger tenant/owner | ✅ (unique strength) | ✅ distribute by owner/tenant (src) | ⚠️ (owner-centric) |
| Late penalty automation | ⚠️ (wrong base) | ? | ✅ configurable |
| Payment designation by payer | ❌ | ? | ⚠️ |
| Sequential receipts | ⚠️ (one channel) | ✅ automatic (src) | ✅ |
| Receipt PDF | ❌ (stub) | ✅ | ✅ |
| Reversal / refund / NSF | ❌ | ? | ✅ |
| Waivers / write-offs | ❌ | ? | ✅ |
| Payment plans / restructuring | ❌ | ? | ✅ |
| Reminders (SMS/email/push) | ❌ (backend) | ✅ scheduled (src) | ✅ |
| Debt aging | ⚠️ (wrong figures) | ✅ | ✅ |
| Collections → lawyer → icra | ❌ | ✅ icra start (src) | ✅ |
| İşletme projesi / budget | ❌ | ? | ✅ budgets |
| Expense (gider) and vendor payments | ❌ (capital disbursements only) | ✅ income/expense (src) | ✅ AP |
| Chart of accounts / GL | ❌ | ✅ (src) | ✅ accrual GL |
| Yearly account report for genel kurul | ❌ | ✅ reports (src) | ✅ |
| Meter / consumption billing | ❌ | ✅ (src) | ⚠️ |
| Capital projects / installments | ✅ (EPIC-10) | ? | ✅ special assessments |
| KVKK consent / notice | ❌ | ✅ notice and e-message consent (src) | n.a. |

**Reading the matrix:** SitePulse's differentiators (sanal IBAN, explicit dual ledger, capital-project installments, KMK-aware receipts) are real. It lacks the **accounting and collections spine** that every competitor treats as basic.

---

## 4. Existing feature evaluation

| # | Feature | Where | Works? | Detail |
|---|---|---|---|---|
| E1 | Manual payment with waterfall and receipt | `POST /payments/record-manual` | ✅ Works | The only fully correct path. Atomic, idempotent, issues a `TAH-` receipt |
| E2 | Resident checkout ("Hemen Öde") | `payment_checkout_dialog.dart` → `/payments/record` | ❌ Broken | The route is staff-only (403). No PSP behind it. Collects raw card fields in the UI, which is a PCI concern |
| E3 | Sanal IBAN webhook settlement | `/bank/webhook/incoming-transfer` | ⚠️ Partial | HMAC check and replay protection are good. It settles one due, issues no `TAH-` receipt and writes no allocation rows |
| E4 | Bank statement parse and reconciliation | `/bank/statements/*` | ⚠️ Partial | Parsing and matching work. Confirmation uses a separate allocation engine. Payer is stored as the description |
| E5 | Match-all homeowner payments | `/payments/match-all` | ⚠️ Legacy | A duplicate engine. Should be removed |
| E6 | Advance balance and auto-offset | `apply_advance_payments_offset` | ⚠️ | Works in memory. The DB split by debtor is lost on reload |
| E7 | Inter-ledger transfer (virman) | `/payments/inter-ledger-transfer` | ⚠️ | Works only for the owner's own advance. Tenant → owner fails in DB mode |
| E8 | Delay penalty (KMK 20) | `calculate_delay_penalty` | ⚠️ | Rate and daily proration are correct. **The base is wrong** (full principal) |
| E9 | Payment stream / filtering | `/payments/stream` | ⚠️ | In-memory only. No collection rate or channel KPIs. Synthesizes fake rows |
| E10 | Debt aging | `/payments/debt-aging` | ⚠️ | Wrong outstanding amounts and wrong debtor attribution |
| E11 | Receipt view | `/payments/receipts/:id` | ✅ / ⚠️ | View works, with correct resident scoping. The PDF button is a stub |
| E12 | Move-out exit balance | `site_admin_service.rs` | ✅ | Correct split (tenant gets operational dues only) |
| E13 | Ownership transfer | `/site-admin/units/:id/transfer-ownership` | ⚠️ | Not atomic. Exit balance includes the tenant's dues |
| E14 | Capital projects and installments (EPIC-10) | `capital_project_service.rs` | ✅ | Uses `BY_LAND_SHARE` / `EQUAL_PER_UNIT`, the right idea, but for operating dues too |
| E15 | Monthly dues accrual | `/dues/accrue-period` | ⚠️ | Fixed amount per house type. Not tied to an approved budget or land share (R2, R3) |
| E16 | Remembered sender IBANs / payer names | `unit_sender_ibans`, `unit_payer_names` | ✅ | A good matching aid |

---

## 5. Missing features and new features

**Priority key:** **P0** = legal or financial correctness, needed before production · **P1** = market parity · **P2** = differentiation.

### P0: compliance and correctness

#### F1. İşletme Projesi (Operating Budget) and Approval Lifecycle
- **Why:** R2, R3, R4, R5 and Law 7579. Without it, dues have no legal basis and cannot be enforced through İİK 68.
- **Scope:**
  - Budget per site and fiscal year, with expense-category lines (personnel, cleaning, energy, maintenance, insurance, management fee, reserve) and each line's **allocation key**: `LAND_SHARE` (default), `EQUAL` (legally equal-share costs), `HOUSE_TYPE`, `METER`, or `CUSTOM` per the yönetim planı.
  - Computes each unit's yearly and monthly **avans**.
  - **States:** `DRAFT → INTERIM (manager) → SERVED → OBJECTION_WINDOW (7 days) → APPROVED_BY_ASSEMBLY / FINAL`, plus `REJECTED`.
  - **Interim cap:** checks the increase against a stored `revaluation_rates(year, rate)` table and blocks it, or demands a kurul decision reference, when the cap is exceeded.
  - **3-month deadline** tracking with reminders to the manager.
  - **Service record** for each owner: method (signature, registered mail, e-notification) and date, so that the objection window can be computed.
  - **Objection** records: who, when, reason, outcome.
- **Data:** `operating_budgets`, `operating_budget_lines`, `operating_budget_unit_shares`, `budget_service_records`, `budget_objections`, `assembly_decisions`, `revaluation_rates`. Add `dues_liabilities.operating_budget_id` and `assembly_decision_id` (the legal basis of each liability).
- **Change:** `accrue_monthly_dues` generates liabilities **only from a FINAL or INTERIM budget**, never from a free-typed amount.

#### F2. Delay penalty correction and policy
- **Why:** R1, R9.
- **Scope:** Penalty = outstanding principal × 5% × days ÷ 30, accrued in **segments** between partial payments: the base drops after each payment. Store a penalty accrual ledger (`penalty_accruals`: from, to, base, amount) so that every figure is explainable in court. Optional grace days (only if the yönetim planı allows; verify). **Penalty waiver** requires a reason, an approver and an audit entry.

#### F3. Payer designation of allocation (TBK 101)
- **Why:** R10.
- **Scope:** `RecordManualPaymentRequest`, the webhook and statement confirmation accept an optional `designation`: specific due IDs, a period ("2026-10"), an expense type, or `PRINCIPAL_FIRST`. The resident app lets the payer choose which debt to pay. The statement parser extracts periods from the description. Designation is stored on the payment entry and printed on the receipt. With no designation, the statutory default order applies (TBK 102, approximated by FIFO by due date).

#### F4. One ingestion path, receipts for every channel, and reversal
- **Why:** R11, plus structure report §3.1 and §3.3.
- **Scope:** Every channel goes through `record_and_allocate_payment`. Add a reversal/refund receipt type with contra entries and un-allocation, plus NSF and returned-transfer handling.

#### F5. KMK 22 tenant joint liability with rent cap
- **Why:** R6.
- **Scope:**
  - Add `unit_occupancies.monthly_rent` and `lease_start` / `lease_end`.
  - Show the tenant's **joint exposure** (owner debts that can be claimed from the tenant, up to unpaid rent).
  - Generate a **rent-deduction certificate** (*kira mahsup belgesi*) for every tenant payment that settles owner liabilities.
  - Keep the dual ledger as the *internal* attribution, but stop asserting that tenants are never liable for owner items.
  - Fix the legal citation on the receipt (verify KMK 22 versus TBK 314).

#### F6. KVKK compliance for financial data
- **Why:** R14 and Kurul decision 2026/348.
- **Scope:**
  - Privacy-notice (*aydınlatma metni*) acknowledgement and consent records per person.
  - Notification channel rules: debt notices go only to the person (push, SMS, e-mail), never to group channels.
  - No "debtor list" export with names visible. Aggregated or masked reports only, outside staff.
  - Access audit log for who viewed or exported financial data.
  - Retention policy for IBANs, names and statements.

#### F7. Licensed payment-provider integration (design constraint)
- **Why:** R15.
- **Scope:** Integrate a TCMB-licensed provider or the bank's sanal POS, with settlement **directly into the site's own bank account** (`site_bank_accounts`). SitePulse stores only tokens and references: no card number or CVV ever reaches SitePulse servers or the Flutter form (hosted page or SDK, 3-D Secure).
- **Data:** `payment_intents` (provider, provider_ref, amount, state `CREATED / AUTHORIZED / CAPTURED / FAILED / REFUNDED`, fee, 3ds_status), plus a signed provider webhook that **feeds F4's single ingestion path**.

### P1: market parity

#### F8. Expense (gider) and vendor payment management
Vendors, incoming invoices (with an attached PDF), expense categories that match the F1 budget lines, approval workflow (manager → denetçi for thresholds), outgoing payments with bank references, and **budget vs actual** per line. Today only capital contractor disbursements exist.

#### F9. Site accounting and the yearly account report
A simple chart of accounts (bank, cash, receivables by debtor, advances, reserve, income, expense), double-entry postings generated automatically from F4 and F8, daily **bank balance reconciliation** (ledger vs bank), period close, and exports: işletme defteri style, Excel, PDF. The **yearly account report** for the genel kurul (*hesap verme*) and a read-only **denetçi** role (R15b).

#### F10. Delinquency and collections workflow
- **Reminder schedule:** e.g. D+3 push, D+10 SMS, D+30 written warning, D+45 notarial notice template (*ihtarname*). Personal channels only (F6).
- **Payment plans (yapılandırma):** an installment schedule tied to the open debts, with a broken-plan trigger.
- **Escalation states:** `REMINDED → NOTICE_SENT → MEDIATION (verify) → LAWYER_ASSIGNED → ICRA_FILED → COLLECTED / WRITTEN_OFF`. Stores lawyer, icra dairesi, file number, fees and costs.
- **Document pack:** the F1 budget, kurul decision, service proof, statement and penalty breakdown, i.e. everything for İİK 68.
- **Counters and flags:** a **KMK 25** counter (3 actions in 2 years) and a **5-year limitation** warning (R12).

#### F11. Autopay and installments
Card-on-file through the F7 provider token. Monthly auto-charge on the due date. Card installments where the provider supports them. Bank standing orders (*otomatik ödeme talimatı*) where the site's bank supports them.

#### F12. Bank integration expansion
Multi-bank statement feeds (bank corporate APIs with the site's credentials, see R15), plus matching by **TCKN / phone / block-unit**, as Apsiyon does. Configurable matching rules. Tolerance handling for partial or over-payments. Daily automatic reconciliation of the ledger against the bank (feeds F9).

#### F13. Resident financial self-service
My statement (tenant or owner view), all receipts as PDF with a QR verification link, choosing which debt to pay (F3), requesting a virman, raising a dispute or objection (including F1 budget objections), and payment-plan requests (F10).

### P2: differentiation

| ID | Feature | Detail |
|---|---|---|
| F14 | Meter / consumption billing | Heat-share meters, water sub-meters. The `METER` allocation key in F1. Import readings from CSV or API |
| F15 | Reserve fund and treasury | A reserve (*yedek akçe*) balance with its own target in the budget. Conservative placement only. One source reports manager liability for putting dues money into investment funds (verify). Interest-income tracking for tax |
| F16 | Professional management company mode | A multi-site portfolio, management-fee invoicing through a GİB e-Fatura/e-Arşiv integrator (R16), and profitability per site |
| F17 | Collection analytics | Collection rate trend, days-sales-outstanding (DSO), forecast cash flow from F1 and F10, early-warning scoring for at-risk units |
| F18 | Digital decisions book (*karar defteri*) and assembly | Meeting agendas, attendance and votes. Decisions linked to budgets and dues as the legal basis for F1 and F10. Majority calculation by land share or unit count, including the new 2/3 rule for toplu yapı |

### 5.1 Suggested roadmap

| Phase | Features | Outcome |
|---|---|---|
| **1. Make it correct** | F4 (single ingestion), F2, F3, structure-report fixes | Every payment is legally allocated, receipted and reversible |
| **2. Make it lawful** | F1, F5, F6, F7 design | Dues have a legal basis (Law 7579). KVKK-safe. Ready for a payment provider |
| **3. Reach parity** | F8, F9, F10, F11, F12, F13 | Comparable to Apsiyon-class tools |
| **4. Differentiate** | F14 – F18 | Professional-manager and analytics edge |

Each phase needs EPIC/STORY entries in `.specify/requirements/`, matching task-DAG nodes, and regression fixtures in `backend/tests/financial_fixtures.rs`, run through the full gate with PostgreSQL.

---

## 6. Open questions for legal and accounting review

1. Exact wording of Law 7579 changes to KMK 35/37/70, and the official revaluation rate for each year.
2. Whether F1 interim projects need a kurul decision for **any** increase above the cap, or only an additional assembly within the 3 months.
3. The correct statutory basis for the tenant rent-offset note (KMK 22 vs TBK 314).
4. Whether the 5-year limitation applies to dues and delay penalties, and how Yargıtay currently treats it.
5. Whether the mandatory-mediation rule for KMK disputes (from 01.09.2023) applies to collection claims in our flow.
6. Whether reading site bank accounts through a third-party aggregator requires an account-information-service licence under 6493.
7. Whether site dues receipts can be called "official", and the e-document duties of professional management companies.

---

## 7. Sources

**Regulation**
- [7579 sayılı Kanun ile KMK değişikliği (REO)](https://www.reo.org.tr/haberdetay/2026-kat-mulkiyeti-kanunu-degisikligi-ile-aidat-artislarina-sinirlama-bugun-yururluge-girdi)
- [Amendments to the Condominium Law (Legal500 / Mondaq)](https://www.legal500.com/intelligence/turkey/real-estate-and-construction/amendments-to-the-condominium-law-operating-plan-advances-and-management-plan)
- [7579 sayılı Kanun özeti (Alomaliye)](https://www.alomaliye.com/2026/05/25/7579-sayili-kanun-ozeti/amp/)
- [7579 sayılı Kanun ve site aidatı (Hukukçular Evi)](https://hukukcularevi.com/hukuk-gundemi/7579-sayili-kanun-kat-mulkiyeti-site-aidati/)
- [KMK konsolide metin 22.05.2026 (Alomaliye)](https://www.alomaliye.com/wp-content/uploads/2002/10/634-sk-22-05-2026.doc)
- [Site aidatlarında keyfi zam dönemi bitti (Memurlar.net)](https://www.memurlar.net/haber/1168079/kanun-degisti-site-aidatlarinda-keyfi-zam-donemi-bitti.html)
- [KMK değişikliği taslağı (Dünya)](https://www.dunya.com/gundem/kat-mulkiyeti-kanunu-degisiyor-site-yonetimleri-yetkilendirilecek-aidat-zamlarina-sinir-geliyor-haberi-798045)
- [Aidat borcu: icra, faiz ve sorumluluk (Hukukçular Evi)](https://hukukcularevi.com/aidat-borcu-odenmezse-icra-takibi-ve-faiz/)
- [Aidat gecikme tazminatı hesaplama (İmer)](https://imer.av.tr/gayrimenkul-hukuku/aidat-gecikme-tazminati-hesaplama)
- [Kat mülkiyetinde kiracıların hak ve borçları (Mıhcı)](https://mihci.av.tr/?p=20261)
- [Kiracı aidat borcunu ödemezse (FFK Partner)](https://www.ffkpartnerhukuk.com.tr/kiraci-aidat-borcunu-odemezse-ne-olur-2026-guncel-rehber/)
- [İşletme projesine itiraz (Av. Saim İncekaş)](https://av-saimincekas.com/kat-mulkiyeti/isletme-projesine-itiraz/)
- [İşletme projesinin tebliği (Av. Saim İncekaş)](https://av-saimincekas.com/kat-mulkiyeti/isletme-projesinin-tebligi/)
- [KMK işletme projesi, genel kurul, toplu yapı (Hukukçular Evi)](https://hukukcularevi.com/makale-kat-mulkiyeti-isletme-projesi-genel-kurul-toplu-yapi/)
- [TBK m.100 kısmen ödeme](https://av-saimincekas.com/kanun/turk-borclar-kanunu/madde-100-tbk/)
- [TBK m.101 mahsup](https://av-saimincekas.com/kanun/turk-borclar-kanunu/madde-101-tbk/)
- [Kısmi ödeme ifa ve kira borcu (Hukukçular Evi)](https://hukukcularevi.com/kismi-odeme-ifa-ve-kira-borcunun-sona-ermesi/)
- [KVKK 2026/348 ilke kararı (Alomaliye)](https://www.alomaliye.com/2026/03/31/kvkkdan-apartman-ve-siteler-icin-kritik-karar-borc-listelerini-ortak-alanlara-asmak-hukuka-aykiri/)
- [KVKK ilke kararı (Erdem & Erdem)](https://www.erdem-erdem.av.tr/bilgi-bankasi/toplu-yapilarda-kisisel-veri-iceren-borc-bilgilerinin-ortak-alanlarda-paylasilmasina-iliskin-kisisel-verileri-koruma-kurulu-ilke-karari-yayimlandi)
- [KVKK borç listesi kararı (CNBC-e)](https://www.cnbce.com/haberler/kvkkdan-apartmanlardaki-borc-listesi-icin-kritik-karar-h27543)
- [6493 sayılı Kanun (Alomaliye)](https://alomaliye.com/2013/06/27/odeme-ve-menkul-kiymet-mutabakat-sistemleri-6493-sayili/)
- [TCMB Ödeme Kuruluşları](https://www.tcmb.gov.tr/wps/wcm/connect/TR/TCMB%20TR/Main%20Menu/Temel%20Faaliyetler/Odeme%20Hizmetleri/Odeme%20Kuruluslari)
- [6493 izinsiz faaliyet suçu (Hukuki Haber)](https://www.hukukihaber.net/6493-sayili-kanun-kapsaminda-izinsiz-faaliyette-bulunma-sucunda-odeme-hizmeti)
- [Ödeme ve e-para kuruluşları: TCMB lisans (Hukukçular Evi)](https://hukukcularevi.com/danismanlik/odeme-elektronik-para-kuruluslari-tcmb-lisans/)
- [Apartman yönetimi KMK 34–42 (Hukukçular Evi)](https://hukukcularevi.com/apartman-yonetimi-kmk-34-42-yonetici-hesap-denetici/)
- [Aidat parasını fona yatıran yönetici sorumluluğu (Hukukçular Evi)](https://hukukcularevi.com/site-apartman-yonetimi-aidat-parasini-fona-yatirdi-yonetici-sorumlulugu-kmk-35-38/)
- [Apartman yönetimi muhasebesi (Emlak Kulisi)](https://emlakkulisi.com/apartman-yonetimi-muhasebesi-nasil-tutulur/268392)
- [Apartman yönetiminin faiz gelirleri (Alomaliye)](https://www.alomaliye.com/2004/06/16/apartman-yonetiminin-elde-ettigi-faizlerin-vergilendirilmesi/)

**Market**
- [Apsiyon all solutions](https://www.apsiyon.com/en/all-solutions)
- [Apsiyon online bank integration](https://www.apsiyon.com/en/online-bank-integration)
- [Apsiyon banka entegrasyonu (destek)](https://destek.apsiyon.com/tr/support/solutions/articles/65000139530-apsiyon-banka-entegrasyonu)
- [Apsiyon / Siyonet (Webrazzi, 2017)](https://webrazzi.com/2017/05/29/apsiyon-siyonet-site-yonetimi/)
- [Konsiyon aidat takip sistemi](https://konsiyon.com/aidat-takip-sistemi)
- [Dijiyon yazılım çözümleri](https://dijiyon.com/yazilim-cozumleri)
- [Best payment software for property management 2026 (ManageCasa)](https://managecasa.com/articles/best-payment-software-for-property-management)
- [Best HOA accounting software 2026 (Gitnux)](https://gitnux.org/best/homeowners-association-accounting-software/)
- [PayHOA financial features](https://www.payhoa.com/features/financial/)
- [BuildingLink HOA dues collection](https://www.buildinglink.io/features/hoa-dues-collection-software)
- [CINC Systems (Capterra)](https://capterra.com/p/143799/CINC-Systems/)
