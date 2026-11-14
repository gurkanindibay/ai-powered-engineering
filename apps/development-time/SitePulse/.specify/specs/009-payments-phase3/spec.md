# Specification: Payments Phase 3 (Compliance Gates, Collections, Accounting, Governance)

> **Feature ID:** SPEC-009
> **Epic ID:** EPIC-11 (`.specify/requirements/EPIC-11-payments-phase3.md`)
> **Domain:** Treasury, Accounting, Collections and Governance contexts
> **Target Roles:** Home Owner, Home Resident (tenant), Site Manager, Auditor (denetçi, read-only), SaaS Admin, management company staff, lawyer (token access)
> **Governance:** KMK 20/22/25/30/35/37 (Law 7579), İİK 68/1, TBK 147/1, 6698 KVKK and Decision 2026/348, 6493, VUK (e-Arşiv). Items marked **(verify)** follow `docs/payments/PAYMENTS_PRODUCT_OWNER_EVALUATION.md` and need counsel before production use.
> **Depends on:** SPEC-005, SPEC-006, SPEC-007 (V16–V18)
> **Source analysis:** `docs/payments/PAYMENTS_PRODUCT_OWNER_EVALUATION.md` §3–§4 (F-01 … F-17, §3.3 hygiene)
> **Schema:** migration `V20__payments_phase3.sql`

---

## 1. Context

SPEC-007 closed the PSP checkout, the core işletme projesi lifecycle, the resident statement and the receipt PDF. The product-owner evaluation still lists missing gates (KVKK, KMK 22), parity features (notifications and dunning, autopay, expenses and GL, collections, payment plans, multi-bank matching) and differentiators (heat-share, decisions book, portfolio, analytics). SPEC-009 implements all of them on one persistence port.

### 1.1 Architecture

* **Pure rules** live in `src/domain/` (`kvkk`, `dunning`, `installments`, `double_entry`, `heat_share`, `assembly_vote`, `collection_metrics`, `joint_liability`, `payer_match`, `limitation`, `allocation_keys`) with unit tests, no I/O.
* **Persistence port** `db::finance_store::FinanceStore`: services never branch on the pool. In memory, ids come from the collection; with PostgreSQL every record is written through the generic `Record` mapping (`db::finance_records`) before it is applied to memory. The book is loaded at boot (`load_finance_book`).
* **State:** `AppStateInner::finance` (`FinanceBook`) holds every SPEC-009 aggregate.
* **Services:** one per feature under `src/services/` with typed `thiserror` errors (`FinanceError`).
* **Handlers:** `src/handlers/payments_phase3.rs`, routes under `/api/v1/{kvkk,notifications,dunning,leases,resident-requests,autopay,accounting,collections,payment-plans,adjustments,bank-matching,heat-share,assembly,portfolio,analytics}`.

## 2. Requirements

### R1 (F-01 remainder): budget allocation keys, decisions and transition mode
- Budget lines accept `HOUSE_TYPE` (weight = the unit's house-type tariff in kuruş), `METER` and `CUSTOM` (explicit non-negative integer `unit_weights`, which must cover every unit and sum above zero), next to `LAND_SHARE` and `EQUAL`. Shares are split with `domain::apportion`.
- `approve` accepts an `assembly_decision_id` of a recorded decision (R12); its number and date become the budget's decision reference.
- `PUT /operating-budgets/policy` accepts `transition_days` (1–90). During transition a site that requires a budget may still accrue the legacy tariff; every such liability is listed as "no legal basis" in `GET /operating-budgets/compliance`, and the response warns the manager.
- The daily job notifies staff about interim budgets whose 3-month deadline is 14 days away or past.

### R2 (F-03): KVKK financial-data controls
- Privacy notices per site (versioned), acknowledgements per user, and channel consents per user (`EMAIL`, `SMS`, `PUSH`, `WHATSAPP`).
- Channel policy (`domain::kvkk`): debt notices go only to personal channels (`EMAIL`, `SMS`, `PUSH`, `WHATSAPP` direct, `LETTER`). `GROUP_CHAT`, `NOTICE_BOARD` and `WHATSAPP_GROUP` are always refused and the refusal is logged.
- `GET /kvkk/debtor-export`: site staff get named rows; the auditor and residents get masked names (`A*** Y***`) and unit-level amounts only. Every call writes an access-log row.
- Financial access log: who viewed or exported the statement, the receipt PDF, the debtor export, the GL, the account report or an evidence pack.
- Retention policy per data category, with a review endpoint that counts records past retention and purges access-log and notification rows that are past it.

### R3 (F-04, verify): KMK 22 tenant joint liability with rent cap
- Leases per unit (tenant name, monthly rent, start, end, rent paid through).
- `GET /leases/joint-exposure`: per tenanted unit, the owner's open operational dues claimable from the tenant, capped at the unpaid rent (unpaid months up to today plus the next instalment). Capital dues are excluded. The internal dual ledger is unchanged.
- `GET /payments/receipts/:id/rent-deduction-certificate`: a PDF certificate for receipts where a tenant paid owner items (rent offset).
- New receipts cite "KMK 22 / TBK 314 kira bedelinden mahsup (verify)" instead of a bare TBK reference.

### R4 (F-05): notification infrastructure and dunning
- `NotificationService` delivers through a `NotificationChannel` sender (`LOG` sandbox; real senders plug in by environment). Every send, block or failure is a row in the delivery log, deduplicated by key.
- Dunning policy per site (default D+3 push, D+10 SMS, D+30 written warning by e-mail, D+45 ihtarname letter). `POST /dunning/run` is idempotent per liability and step. Liabilities that are disputed, in an active payment plan or in a collection case past `NOTICE_SENT` are skipped. The scheduler runs it daily.
- `GET /dunning/notice-letter/:due_id`: an ihtarname draft PDF for a liability.

### R5 (F-06 remainder): resident self-service
- The statement page lets the resident pick the items to pay; the card intent carries the TBK 101 designation.
- Virman requests: the source debtor (tenant or owner) asks staff to move their advance to the other ledger. Staff approve (this runs `inter_ledger_transfer`) or reject.
- Disputes: a resident disputes a liability with a reason. Staff accept or reject it. An open dispute pauses dunning on that item.

### R6 (F-07): autopay and instalments
- Saved cards are provider tokens with brand, last 4 digits and expiry (no PAN). The sandbox issues a token when a hosted payment is captured with `save_card`.
- Autopay mandates per unit and debtor, with an optional per-charge limit. The daily run charges open due items through the provider. A capture goes through the single ingestion path (`AUTOPAY:<mandate>:<due>:<attempt>` idempotency). A decline is logged and notified and retried on D+2 and D+5. An expired card suspends the mandate. A declined charge never marks a due as paid.
- Card intents accept `installments` (1, 2, 3, 6, 9, 12) when the provider supports them.

### R7 (F-08, F-16): expenses, general ledger, account report, reserve fund
- Vendors (VKN 10 digits or TCKN 11 digits, valid IBAN), incoming invoices (category from the budget vocabulary, net, VAT, total, document reference), approval thresholds (up to `manager_limit` needs one approver; above it the auditor must approve as well), four-eyes (approver ≠ creator), and partial payments.
- The general ledger is derived from the source documents, so it cannot drift: accruals, penalties, waivers, receipts, reversals, advance use, invoices, invoice payments, capital disbursements, and manual journal entries (which must balance). Chart of accounts: see `domain::double_entry::CHART` (simplified Tekdüzen, verify).
- `GET /accounting/trial-balance` (always balances), `/accounting/journal`, `/accounting/budget-vs-actual` (by budget category), `/accounting/account-report?year=` (hesap verme, JSON or PDF), and `/accounting/reserve-fund` (target from the budget's `RESERVE` lines; balance of account 549).
- The `AUDITOR` role is read-only on accounting, collections and analytics, and approves invoices above the threshold.

### R8 (F-09): collections and legal handover
- Cases per debtor and unit move through `REMINDED → NOTICE_SENT → MEDIATION (verify) → LAWYER_ASSIGNED → ICRA_FILED → COLLECTED | WRITTEN_OFF`. Every transition is an event.
- Evidence pack (JSON and PDF): budget and decision, service record, statement, receipts and a daily penalty breakdown. It is built only when every liability in the case has a legal basis (operating budget, or a capital project decision).
- KMK 25 counter: three `ICRA_FILED` events against the same owner within 2 years raises a flag. TBK 147/1: items past or within 6 months of the 5-year limitation are warned (verify).
- Lawyer access: a one-time token (stored as a digest) gives read-only access to the pack through `/api/v1/public/collection-cases/pack`. Every access is logged.

### R9 (F-10): multi-bank feeds and payer matching
- `domain::payer_match` extracts a TCKN (with its checksum), a Turkish mobile number and a block/unit reference from a transfer description. `POST /bank-matching/suggest` ranks candidate units for transfers that bypass the virtual IBAN.
- Bank feed connections per site keep a credential *reference*, never the secret. The `SANDBOX` feed and the statement-file feed fetch through the `BankFeed` port.
- `POST /bank-matching/daily-reconciliation`: the bank's closing balance and lines for a day are compared with the ledger's bank movements. The run stores the differences.

### R10 (F-11): payment plans, waivers, write-offs
- A plan over open debts is split into equal instalments with `domain::apportion` (the remainder goes to the earliest instalments). Progress counts payments on the covered debts after the plan opened. An instalment overdue past the grace days makes the plan `BROKEN`, notifies the debtor and resumes dunning. A completed plan may waive the penalty accrued during it.
- Adjustments: `PENALTY_WAIVER` or `PRINCIPAL_WRITE_OFF`, with a reason, a requester and an approver who must be a different person. An approved adjustment lowers what is owed on the liability (it cannot exceed the outstanding amount). The adjustment row is the audit record.

### R11 (F-13, verify): heat-share billing
- Heating periods with a total cost and a consumption share (default 70%, verify). The fixed share is split by area weights (default land share), and the consumption share by meter readings. Approval accrues one `OPERATIONAL_DUES` liability per unit (`Isınma <period>`) for the occupant.

### R12 (F-14): decisions book and assembly
- Meetings with agenda items, attendance (owner or proxy), votes per unit, and tally rules in `domain::assembly_vote`: `SIMPLE` (more than half of the present votes by count), `TWO_THIRDS` and `FOUR_FIFTHS` (of all units by count and land share), `UNANIMOUS`. The quorum is a count-and-land-share majority on the first call; any attendance counts on the second call (KMK 30, verify).
- Closing an agenda item records a numbered decision in the site's decisions book (karar defteri). A decision can approve a budget (R1).

### R13 (F-15): management-company portfolio and fee invoicing
- Companies, their sites (monthly fee, VAT rate), and members. `GET /portfolio/:company/summary` shows per site: units, receivables, this month's collection rate, overdue items, open cases and pending invoices. Access is limited to SaaS admins and company members.
- Monthly fee invoices are issued through the `EInvoiceIntegrator` port (`SANDBOX` returns a GİB-style UUID): e-Arşiv for individuals, e-Fatura for registered buyers (verify).

### R14 (F-17): collection analytics
- `GET /analytics/collections`: per month, the on-time collection rate, DSO (amount-weighted days from due date to settlement), digital share, zero-touch share by channel, a 6-month cash-flow forecast (budget shares × trailing collection rate, minus budget expenses and approved unpaid invoices), and at-risk units scored LOW, MEDIUM or HIGH.

### R15: hygiene (§3.3)
- The payment stream reports this month's collection rate and the share per channel.
- `receipt_hash_v2` also covers the payer and the allocation breakdown for new receipts; verification accepts v1 for older receipts.

## 3. Acceptance
- Domain unit tests in each `src/domain/*.rs` module (tax id, KVKK channel rule, dunning steps, instalments, double entry, heat share, assembly vote, collection metrics, KMK 22 rent cap, payer hints, limitation).
- `tests/payments_phase3_tests.rs`: 28 in-memory scenarios covering R1–R15, including two-site isolation and the daily job. Dates are the site's local date (Europe/Istanbul), the same date every service uses.
- PostgreSQL: the schema-integrity gate replays V20. `tests/finance_store_pg_tests.rs` (opt-in with `SITEPULSE_PG_TESTS=1` and a scratch `DB_NAME`) writes every SPEC-009 record through the services and reloads the book from the database. `api_system_check.py` check `finance_desk_over_http`: balanced ledger, dunning, analytics, staff export, four-eyes on invoices, site isolation, forged lawyer token, clean `v_finance_integrity_violations`.
- Flutter: `test/payments_phase3_test.dart` (models, designation total, the shared `showSpTextPrompt` page, the finance desk and its read-only auditor view, designated payment).

### 3.1 Client
- Manager: **Finans Masası** (cockpit tile `cockpit_finance_hub`): expenses and approvals, ledger and the yearly account report PDF, collection cases with the evidence pack, payment plans, waiver and write-off approvals, resident requests, the decisions book, analytics and the KVKK access log.
- Auditor (`AUDITOR`): `/auditor/home` shows the same desk read-only (expense approval allowed).
- Resident: under the statement, choose the items to pay (TBK 101 designation) and optionally save the card, dispute an item, request a virman; the **Otomatik Ödeme** and **Gizlilik ve İzinler** pages.

### 3.2 Fixes found while implementing
- "Is this date in the future?" checks for assembly decisions and service dates compared a site-local date with the UTC date and refused today's Istanbul evening decisions. They now use the site's local date (`finance_common::site_today`).
- Receipt timestamps are turned into dates in the site's time zone (`finance_common::local_date`) for plans, reconciliation, analytics and the ledger.

## 4. Out of scope
Real SMS, push or e-mail vendors, real bank corporate APIs, real e-invoice integrators and real PSP tokenization (all behind ports with sandbox implementations). UYAP submission (lawyer handover only). e-Tebligat.
