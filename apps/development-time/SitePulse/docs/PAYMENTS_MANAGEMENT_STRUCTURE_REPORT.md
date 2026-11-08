# Payments Management — Structural Completeness Report

> **Scope:** SitePulse payments, measured against EPIC-09 (Payment Tracking & Treasury), plus the payment parts of EPIC-07 (webhook / bank statement) and EPIC-08 (occupancy handover).
> **Method:** Static review of migrations V1–V15, `payment_tracking_service.rs`, `dues_ledger.rs`, `db/payment_repository.rs`, `handlers/mod.rs`, `auth.rs`, and the Flutter payment screens. Nothing was executed.
> **Date:** 2026-11-08
> **See also:** [PAYMENTS_REGULATORY_AND_MARKET_EVALUATION.md](PAYMENTS_REGULATORY_AND_MARKET_EVALUATION.md), which covers regulation, the competitor comparison, and the missing and new features.

---

## 0. Remediation status (SPEC-005 / V16 and SPEC-006 / V17, 2026-11-08)

| Finding | Status |
|---|---|
| §3.1 Four allocation engines | ✅ **Fixed.** Webhook, statement confirmation, `/payments/record` and match-all all call `record_and_allocate_payment` (TAH receipt, allocation rows, idempotency). Legacy writers deleted |
| §3.2 No payer identity | ✅ **Fixed** in the schema and on new rows (`payer_person_id`, `occupancy_id`, `on_behalf_of_person_id`). The statement itself (§3.7) is still open |
| §3.3 No reversal; `REFUNDED` vocabulary bug | ✅ **Fixed (SPEC-006 / V17).** `POST /payments/reverse`: `IAD-` reversal receipt, contra entry with reason and operator, un-allocation, advance `REFUND`. Virman reversal deferred |
| §3.4 Advance per debtor / virman | ✅ **Fixed (SPEC-006 / V17).** Per-debtor advance in memory; `source_debtor` / `target_debtor` on the virman (TENANT → OWNER works with PostgreSQL) |
| §3.5 Card payments (payment provider) | ❌ Open |
| §3.6 Debt aging figures | ✅ **Fixed.** Outstanding amounts, penalty as of today, the liability's own debtor |
| §3.7 Cari Hesap Ekstresi | ❌ Open (now buildable on payer identity) |
| §3.8 Ownership transfer atomicity | ❌ Open |
| §3.9 Waterfall / intent | ⚠️ **TBK 101 designation added.** Operational-before-capital tiering and the `MALİK ADINA` keyword are still open |
| §3.10 Stream KPIs / description | ⚠️ The description is now kept. Collection rate and channel KPIs are still open |
| §3.11 Receipt VKN / PDF / QR | ⚠️ **VKN fixed (V17):** `sites.tax_id` plus an issuer snapshot on each receipt. Hash coverage, PDF and QR are still open |
| §3.12 Resident authorization | ❌ Open. Kept staff-only on purpose: a resident must not self-record a settled payment without a real payment provider |

Database design findings and their fixes: [PAYMENTS_DATABASE_DESIGN_REVIEW.md](PAYMENTS_DATABASE_DESIGN_REVIEW.md).

## 1. Verdict

**The payments structure is only partly complete.** One part is well built: the core ledger (receipts, entries, allocations, per-site receipt counter, idempotency keys, an advance ledger split by debtor). The manual-payment path (`record_and_allocate_payment`) uses all of it correctly inside a single transaction.

The rest of the module does not use that ledger. **Four separate allocation engines** apply payments to dues. Only one of them writes receipts, allocation rows and idempotency keys. The structures needed for **reversals/refunds, payer identity, online card payments, and the tenant/owner sub-ledger statement** do not exist. Every EPIC-09 task (`task-15` … `task-19`) is still `UNVERIFIED` in `task-dag.json`.

| Area | Status |
|---|---|
| Core ledger schema (receipts / entries / allocations / counters / idempotency) | ✅ Present, well constrained |
| Single, canonical allocation path used by all channels | ❌ Missing (4 engines) |
| Payer identity (person / occupancy) on payments | ❌ Missing |
| Reversal / refund / correction structure | ❌ Missing |
| Online card / POS payment structure (PSP) | ❌ Missing (UI only) |
| Tenant vs Owner sub-ledger statement (Cari Hesap Ekstresi) | ❌ Missing |
| Debt aging | ⚠️ Present but computes wrong figures |
| Inter-ledger transfer (virman) | ⚠️ Present, but the spec's tenant→owner flow cannot happen |
| Receipt export (PDF / QR) | ⚠️ Stub |
| Ownership transfer financial handover | ⚠️ Present, not atomic |
| Resident-facing payment API | ❌ Resident checkout calls a staff-only route |

---

## 2. What exists today

### 2.1 Schema (PostgreSQL)

| Table | Migration | Purpose | Assessment |
|---|---|---|---|
| `payment_receipts` | V5, V9, V14 | Official `TAH-YYYY-NNNNNN` receipt | Good. `CHECK principal+penalty+advance = total`, unique sequence per site, FK `RESTRICT` |
| `payment_entries` | V5, V10, V14 | Canonical inflow ledger | Good shape. Channel, status and role are CHECK-constrained. **No payer person and no occupancy link** |
| `payment_allocations` | V12 | Entry → liability split (principal / penalty) | Good. 1NF, `RESTRICT` |
| `receipt_counters` | V13 | Gap-free per-site sequence | Good |
| `payment_idempotency_keys` | V13 | Retry safety | Good. Only the manual path uses it |
| `advance_balances` (+ `debtor_type`) | V5, V12 | Avans reservoir split TENANT / OWNER | Good in the DB. The in-memory model is not split (see §3.4) |
| `advance_ledger_entries` | V12 | Avans history | Good |
| `debt_aging_snapshots` | V5 | Aging snapshots | **Unused.** No code reads or writes it |
| `dues_liabilities.paid_principal / paid_penalty` | V12 | TBK 100 split | Good |

### 2.2 API

| Route | Handler | Engine used |
|---|---|---|
| `POST /payments/record-manual` | `record_manual_payment` | ✅ Canonical (`record_and_allocate_payment`) |
| `POST /payments/inter-ledger-transfer` | `inter_ledger_transfer` | ✅ Canonical |
| `GET  /payments/receipts/:id` | `get_payment_receipt` | Read |
| `GET  /payments/stream` | `get_payment_stream` | Read (in-memory only) |
| `GET  /payments/debt-aging` | `get_debt_aging_report` | Read (in-memory only) |
| `POST /payments/record` | `record_homeowner_payment` | ❌ Legacy engine #2 |
| `POST /payments/match-all` | `match_all_homeowner_payments` | ❌ Legacy engine #3 |
| `POST /bank/statements/confirm-reconciliation` | `confirm_reconciliation` | ❌ Legacy engine #4 |
| `POST /bank/webhook/incoming-transfer` | `handle_bank_incoming_webhook` | ❌ Legacy engine #4b (single-due + auto-offset) |
| `POST /site-admin/units/:id/transfer-ownership` | `transfer_unit_ownership` | Ownership handover |

---

## 3. Missing or incomplete structure

Findings are ordered by impact.

### 3.1 🔴 No single allocation path. Most channels skip the ledger.

`record_and_allocate_payment` (`payment_tracking_service.rs:305`) is the only path that does all of the following in one DB transaction: lock the unit, load open dues, run the waterfall, take a counter-based receipt number, insert the receipt, entry and `payment_allocations` rows, credit the advance ledger, and store the idempotency key.

The **bank webhook**, **bank statement confirmation**, **resident checkout** (`/payments/record`) and **match-all** each have their own FIFO loop (`handlers/mod.rs:1100`, `~1870`, `2242`, `2480`). They change in-memory state first and only then persist. On these paths:

- **No `TAH-` receipt is issued.** The webhook uses `reconciliation_queue.len()+1` and `/payments/record` uses `RCP-{n}` (`handlers/mod.rs:2355`). STORY-09-04 (every settled payment gets a sequential receipt) is therefore not met for most channels.
- **No `payment_allocations` rows are written.** `save_collection_transaction` (`db/payment_repository.rs:143`) only fills the legacy single `dues_liability_id` column.
- **The data written is wrong.** `payer_name` is set to the transaction *description*, `payer_role` is hardcoded `'OWNER'`, and an unresolved unit falls back to **unit 14 / site 1** (`.or(Some(14))`, `.unwrap_or(1)`).
- The webhook settles **one due** chosen by period text and then runs `apply_advance_payments_offset`. It does not apply the penalty-first waterfall across all dues.
- The in-memory update and the DB write are not atomic. A failure after the mutation leaves memory and DB out of step until restart.

**Missing structure:** one `PaymentIngestionService` (or similar) that every channel calls. Channels would differ only in the channel code and the external reference (webhook `transaction_id`, statement `match_id`, idempotency key). The four legacy loops would be deleted.

### 3.2 🔴 Payments have no payer identity (person / occupancy)

`payment_entries` and `payment_receipts` store only `payer_name VARCHAR` and `payer_role`. Nothing links a payment to `persons.id` or to `unit_occupancies.id`. The data model already has these concepts: `dues_liabilities.liable_person_id` and `occupancy_id`.

Consequences:
- STORY-09-03 (*tenant sub-ledger includes "payments made by Canan" only*) cannot be built reliably. A free-text name is the only key.
- STORY-09-05 (*past receipts remain attributed to Zeynep after move-out*) relies on name strings.
- Debt aging guesses the debtor from the unit's *current* tenant instead of from the liability (§3.6).

**Missing columns:** `payer_person_id`, `on_behalf_of_person_id` and `occupancy_id` on `payment_entries` and `payment_receipts`, as FKs with an index.

### 3.3 🔴 No reversal, refund or correction mechanism

The ledger is supposed to be immutable, but there is no way to correct it:
- No `reverses_entry_id` / `reversal_of_receipt_id` column, and no reversal/credit-note receipt type.
- No endpoint or service to reverse a payment, un-allocate it (decrement `paid_principal/paid_penalty`, restore status), or refund an advance.
- **The status vocabularies disagree.** V5 documents `REFUNDED`. V14 constrains `settlement_status IN ('SETTLED','UNMATCHED','PENDING','REVERSED')`. Yet `update_homeowner_payment_match` (`db/payment_repository.rs:265`) writes `'REFUNDED'`, which **violates the CHECK** and makes the update fail.
- `advance_ledger_entries.entry_type` allows `'REFUND'`, but nothing produces it.

**Missing structure:** reversal entries (negative or contra) linked to the original, a reversal receipt (e.g. `IAD-YYYY-NNNNNN`), a service that un-allocates, and an approval/audit trail (who reversed it, and why).

### 3.4 🟠 Advance balance is modeled differently in the DB and in memory, which breaks virman

- In the DB, `advance_balances` is keyed `(unit_id, debtor_type)`. In memory, `advance_payments` is a `HashMap<unit_id, Decimal>`, and on load it is **summed over both debtors** (`db/sync.rs:~680`). `save_advance_balance` then re-splits the total with a heuristic: owner first, the rest to tenant.
- A tenant overpayment is credited to the **TENANT** advance (`credit_debtor = settling_role`). `inter_ledger_transfer` locks and debits only the **OWNER** advance (`payment_tracking_service.rs:542`). The headline EPIC-09 §2.3 flow, *tenant surplus → owner's Demirbaş*, therefore fails with "insufficient advance" in DB mode. The in-memory path uses the unsplit total and succeeds, so tests can pass while production fails.
- The request has no source/target debtor fields, so a TENANT→OWNER transfer cannot be expressed.

**Missing structure:** a per-debtor advance model in memory, and `source_debtor` / `target_debtor` on `InterLedgerTransferRequest`, recorded in `advance_ledger_entries`.

### 3.5 🟠 No online card / POS payment structure

`payment_checkout_dialog.dart` collects card holder and card number, then posts to `/payments/record`. There is no payment-provider integration and no `payment_intents` / `card_transactions` table (provider id, auth / capture / fail state, 3-D Secure, callback signature, fee). The `CREDIT_CARD` / `ONLINE_PAYMENT` channel values exist only as enum strings. Channel 3 of STORY-09-01 is not implemented.

### 3.6 🟠 Debt aging computes the wrong numbers

`get_debt_aging_report` (`payment_tracking_service.rs:203`):
- It uses `due.principal_amount` and `due.delay_penalty`. It should use **outstanding** amounts (`principal − paid_principal`, `penalty − paid_penalty`). Partially paid dues are overstated.
- It assigns the debtor from `unit.tenant_user_id.is_some()`. It should use `due.debtor_type`, so a tenanted unit's CAPITAL_DUES (owed by the owner) are reported as TENANT debt.
- It reads only in-memory state, and the `debt_aging_snapshots` table goes unused. There is no history or trend.

### 3.7 🟠 No Cari Hesap Ekstresi (sub-ledger statement)

STORY-09-03 requires a printable, debtor-specific statement: dues, payments, penalties and a running balance, for TENANT or OWNER. No endpoint, service or UI provides one. Without §3.2 it cannot be built correctly.

### 3.8 🟠 Ownership transfer is not atomic, and its financial split is wrong

`transfer_ownership` (`payment_tracking_service.rs:716`):
- It mutates in-memory state (new user, owner swap, history) **before** the DB call. `save_user` runs outside the DB transaction. A DB failure leaves memory changed.
- `old_owner_exit_balance` sums **all** unpaid unit dues, including the tenant's operational dues. EPIC-09 STORY-09-07 limits it to the owner's liabilities.
- Existing dues keep their `liable_person_id`, and nothing freezes or re-stamps them per transfer date. "Frozen to the old owner" is only a note.
- It creates the new user with `password_hash = "ARGON2_TEMP_HASH"`, a placeholder that is not a real hash. The history row has a hard-coded `start_date: "2020-01-01"`.

### 3.9 🟡 Gaps in the waterfall and in intent detection

- `allocate_waterfall` (`dues_ledger.rs`) does penalties first, then principal FIFO by date. Operational and capital dues are mixed by date. The spec's Tier 2 (operational) → Tier 3 (capital, owner only) ordering is not enforced for an OWNER payer.
- `is_capital_expenditure_intent` lacks the spec keyword **`MALİK ADINA`** and includes `KAZAN`, which is broad.
- No structure lets a manager steer an allocation (target a specific due or period). There is no `allocation_override` on the request.

### 3.10 🟡 Payment stream (STORY-09-01) is incomplete

- It reads only in-memory `payment_entries`. When that list is empty it **synthesizes** entries from `homeowner_payments`, using the requested `site_id` and a hardcoded `payer_role: "OWNER"` (`payment_tracking_service.rs:~87`).
- The response has no **collection rate** and no **channel distribution**, both required by the acceptance criteria.
- `build_entry` sets `description: None`, so the description of a manual payment is lost from the stream.

### 3.11 🟡 Receipts lack legal fields and export

- The receipt has no **site tax ID (VKN)** field or snapshot, although STORY-09-04 requires one.
- `verification_hash` covers only number, unit, amount and time. It does not cover the allocation breakdown or the payer, so those can change without the hash changing. No QR payload exists.
- The "Paylaş / PDF" button (`payment_tracking_page.dart:424`) only shows a snackbar. No PDF is produced.
- The counter is per site and never resets per year, while the number includes the year (`TAH-2027-000143` follows `TAH-2026-000142`). Decide whether that is intended and document it.

### 3.12 🟡 Authorization and resident flows

- `/api/v1/payments/record` falls under `Access::SiteStaff` (`auth.rs:254`), but the **resident** checkout posts to it (`dashboard_controller.dart:4151`). Against the real backend, a resident's payment gets 403.
- No resident-scoped endpoints exist for *my payments*, *my statement* or *my advance → owner's Demirbaş* (EPIC-09 §2.3 "Kiracı Mobil Uygulaması Üzerinden").

---

## 4. Recommended remediation order

1. **One ingestion path (§3.1).** Route the webhook, statement confirmation, resident checkout and match-all through `record_and_allocate_payment`, then delete the legacy loops. Most receipt, allocation and idempotency gaps close with this step.
2. **Payer identity columns (§3.2).** Migration V16: `payer_person_id`, `on_behalf_of_person_id`, `occupancy_id`, plus a backfill where possible.
3. **Reversal model (§3.3).** Contra entries, reversal receipts, an un-allocate service, and fixing the `REFUNDED`/`REVERSED` vocabulary.
4. **Per-debtor advance plus a virman request with source/target (§3.4).**
5. **Fix aging (§3.6), then build the Cari Hesap Ekstresi endpoint and UI (§3.7).**
6. **Make ownership transfer one transaction with an owner-only exit balance (§3.8).**
7. **Fix resident authorization, then add resident payment endpoints (§3.12).**
8. **Receipt VKN / hash / QR / PDF (§3.11), stream KPIs (§3.10), waterfall tiers (§3.9).**
9. **PSP / card integration (§3.5).** This is a separate design decision: provider choice, PCI scope.

For each step, add regression tests to `backend/tests/financial_fixtures.rs` / `integration_tests.rs`. Run the full gate (`scripts/run_tests.py`) with PostgreSQL. Several defects (§3.4) appear only in DB mode, so in-memory tests alone will not catch them.
