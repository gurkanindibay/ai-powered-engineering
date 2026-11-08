# Payments Database Design Review

> **Scope:** the payment-related PostgreSQL schema as it stands after replaying V1–V15. Tables: `payment_entries`, `payment_receipts`, `payment_allocations`, `dues_liabilities`, `advance_balances`, `advance_ledger_entries`, `payment_idempotency_keys`, `receipt_counters`, `processed_bank_webhooks`, `debt_aging_snapshots`, `reconciliation_queue`.
> **Method:** replayed every migration into an empty database, dumped columns, constraints, indexes, triggers and views, and read every code path that writes these tables.
> **Fix:** migration **V16 `payment_ledger_integrity.sql`** and the SPEC-005 code changes, verified by the schema-integrity gate (fresh install and upgrade test) and the API system check against a real backend.
> **Related:** [PAYMENTS_MANAGEMENT_STRUCTURE_REPORT.md](PAYMENTS_MANAGEMENT_STRUCTURE_REPORT.md) · [PAYMENTS_REGULATORY_AND_MARKET_EVALUATION.md](PAYMENTS_REGULATORY_AND_MARKET_EVALUATION.md) · `.specify/specs/005-payment-compliance-phase1/spec.md`
> **Date:** 2026-11-08

---

## 1. Verdict

The V9–V15 work left a solid base:
- `NUMERIC(15,2)` everywhere (no floats).
- A relational allocation table.
- A per-site receipt counter.
- Idempotency keys.
- `RESTRICT` foreign keys that protect financial history.
- A drift view, `v_integrity_violations`.

The ledger was still **immutable by convention only**:
- Any statement could update or delete receipts, allocations or advance history.
- A payment could be `SETTLED` with no receipt.
- Two tables recorded the same allocation fact.
- Payments had no link to a person.
- The penalty could not be accrued correctly because the schema had no accrual date.

V16 closes all of these. §4 lists what remains open.

## 2. Strengths (kept)

| Area | Detail |
|---|---|
| Money types | `NUMERIC(15,2)` on every amount. Non-negative CHECKs on principal, penalty, paid amounts and receipt components |
| Receipt arithmetic | `chk_receipt_allocation_sums`: principal + penalty + advance = total |
| Liability arithmetic | `paid_amount = paid_principal + paid_penalty`, each within what is owed |
| Numbering | `receipt_counters` row lock per site, plus unique `(site_id, sequence_number)` and `(site_id, receipt_number)` |
| Retry safety | `payment_idempotency_keys (site_id, idempotency_key)` → receipt |
| History protection | V14 changed ledger foreign keys to `RESTRICT`; sites and units are soft-deleted |
| Advance ledger | `advance_balances` per `(unit, debtor_type)`, with history in `advance_ledger_entries` |
| Drift detection | `v_integrity_violations` and `v_duplicated_fact_drift` |

## 3. Findings fixed in V16

| ID | Severity | Finding (before) | Fix |
|---|---|---|---|
| **P-06** | 🔴 Critical | **No immutability enforcement.** `payment_receipts`, `payment_allocations`, `advance_ledger_entries` and `payment_idempotency_keys` could be updated or deleted. `save_payment_receipt` used `ON CONFLICT … DO UPDATE` and rewrote issued receipts on every full sync. `update_homeowner_payment_match` rewrote entry statuses freely, including to a value the CHECK rejects | **Append-only triggers** on the four tables. `trg_payment_entries_guard` freezes amount, site, unit, channel, date, reference and creation time, and allows only `UNMATCHED/PENDING → SETTLED` (which must set the receipt) and `SETTLED → REVERSED`. The receipt sync is now `ON CONFLICT DO NOTHING`. The legacy status writer was removed. A **transaction-scoped** switch (`SET LOCAL sitepulse.allow_ledger_purge = 'on'`) exists only for the non-production purge, which is now a single transaction with child tables deleted first (it previously failed halfway on V14's `RESTRICT` keys and logged the error) |
| **P-03** | 🔴 Critical | A `SETTLED` entry needed no receipt. The legacy writers (`save_collection_transaction`, `save_homeowner_payment`) inserted settled rows without receipts, with `payer_name` set to the bank description, `payer_role` hardcoded to `OWNER`, and a fallback to **unit 14 / site 1** when the unit could not be resolved | `chk_payment_entries_settled_has_receipt`. Old rows are flagged `legacy_unreceipted` rather than given invented receipts. The legacy writers were deleted, and every channel now goes through the transactional path (SPEC-005 R1) |
| **P-05** | 🟠 High | **Duplicated fact:** `payment_entries.dues_liability_id` (a single due) and `payment_allocations` (multiple dues) both described the allocation and could disagree | Rows that had only the legacy link were copied into `payment_allocations` (capped at the due's principal), then the column was **dropped**. The sync loader was updated |
| **P-01** | 🟠 High | No record of the date up to which `delay_penalty` was accrued, so a correct KMK 20 accrual after partial payments was impossible. The code charged the penalty on the **full** principal | `dues_liabilities.penalty_accrued_through` plus `chk_dues_penalty_accrued_after_due`. Open legacy penalties are frozen at the migration date, so they are never over-charged. The code now accrues the penalty in segments on the **unpaid** principal |
| **P-02** | 🟠 High | Payers were identified only by a typed name. Tenant/owner statements and correct attribution after a move-out or sale were impossible | `payment_entries.payer_person_id`, `payment_entries.occupancy_id`, `payment_receipts.payer_person_id` and `payment_receipts.on_behalf_of_person_id`, all foreign keys with indexes. The resolver `sp_unit_party_at(unit, role, date)` reads the ownership/occupancy history and falls back to the unit's current owner/tenant columns. Existing rows were backfilled, and new rows are filled by the insert SQL |
| **P-04** | 🟡 Medium | One receipt could be referenced by several entries. One entry could hold several allocation rows for the same due. `payment_entries.receipt_id` was `ON DELETE SET NULL` | Unique index `uq_payment_entries_receipt`. Duplicate allocation lines merged and made unique with `uq_payment_allocation_line`. The receipt foreign key is now `RESTRICT` |
| **P-07** | 🟡 Medium | `payment_entries.payment_date` and `payment_receipts.issued_at` were nullable although they define ledger order | Backfilled and set `NOT NULL` |
| **P-08** | 🟡 Medium | `ADJUSTMENT` advance entries had no sign (counted as 0 in the drift view). Heuristic re-splits of the advance balance were recorded as `PAYMENT_SURPLUS` even though no payment backed them | New `ADJUSTMENT_CREDIT` / `ADJUSTMENT_DEBIT` types. `save_advance_balance` now records an unexplained increase as `ADJUSTMENT_CREDIT`. The drift view also flags allocations exceeding their entry, and entries whose amount differs from their receipt |
| **P-09** | 🟢 Low | Lookups by external reference and for the unmatched queue scanned the whole table | `idx_payment_entries_external_ref`, `idx_payment_entries_unmatched` (partial), `idx_advance_ledger_reference` |

### Code defects found while verifying against PostgreSQL

Running the real backend on a throwaway database exposed problems that the in-memory tests cannot see:

| Defect | Fix |
|---|---|
| An **unmatched** webhook transfer was kept only in memory, while its `transaction_id` was already claimed in `processed_bank_webhooks`. After a restart the money was gone from the system, and the bank's retry was ignored as a duplicate | The unmatched queue item is now persisted before the response |
| A claimed webhook whose processing failed stayed claimed forever | The claim is released on failure (`release_bank_webhook_transaction`). The payment itself is idempotent on `BANK:<transaction_id>` |
| One SQL parameter (`payer_role`) was used both as a `VARCHAR` column and as a `TEXT` function argument, so PostgreSQL rejected every payment with "inconsistent types deduced for parameter" | Explicit `::text` casts. Covered by the API system check |
| `save_payment_entry` / `save_payment_allocation` were unused writers able to bypass the transactional path | Deleted |

## 4. Open items (not changed in V16)

| ID | Severity | Item | Recommendation |
|---|---|---|---|
| O-1 | 🟠 | The in-memory model keeps **one advance total per unit**, while the database splits by debtor. Inter-ledger transfer (virman) debits only the OWNER bucket, so the tenant-surplus → owner-capital flow fails in DB mode | Make the in-memory model per debtor. Add `source_debtor` / `target_debtor` to the virman request (next increment) |
| O-2 | 🟠 | No reversal linkage. The trigger allows `SETTLED → REVERSED`, but there is no `reverses_entry_id`, reversal receipt type or un-allocation | Reversal design (regulatory report F4): contra entries plus a reversal receipt series |
| O-3 | 🟡 | `processed_bank_webhooks` is keyed only by `transaction_id`: no site, bank account, receipt link or payload hash. Two banks could reuse the same id | Key it by `(site_bank_account_id, transaction_id)`, and store the receipt id and a payload hash |
| O-4 | 🟡 | `payment_receipts.channel_reference` has several meanings (`IDEMPOTENCY:<key>`, `REF-n`, a virman note). The in-memory idempotency lookup depends on it | Keep idempotency in `payment_idempotency_keys` (in memory too). Use `channel_reference` only for the bank or channel reference |
| O-5 | 🟡 | Receipts carry no snapshot of the issuer's legal details (site name, address, tax id), and `sites` has no tax id column | Add `sites.tax_id`, plus issuer snapshot columns on `payment_receipts` (needed for STORY-09-04) |
| O-6 | 🟡 | `dues_liabilities.status` stores time-derived states (`OVERDUE`) and paid-derived states (`PARTIALLY_PAID`) that drift from the clock and from the paid amounts | Treat them as a cache recomputed on read, or derive them in a view |
| O-7 | 🟡 | `reconciliation_queue`: status vocabulary in two casings; `site_bank_account_id … ON DELETE CASCADE` deletes statement history together with a bank account; denormalized `matched_*` columns | One vocabulary; change to `RESTRICT`; keep `matched_*` only as a snapshot |
| O-8 | 🟢 | `debt_aging_snapshots` is never written or read | Populate it from a nightly job (regulatory report F17), or drop it |
| O-9 | 🟢 | The receipt sequence is per site and never resets yearly, although the receipt number contains the year | Decide the legal requirement and document it (regulatory report §6) |
| O-10 | 🟢 | `payment_entries.payer_role` defaults to `'TENANT'`, which hides missing data | Remove the default once every writer sets it (all canonical writers now do) |
| O-11 | 🟢 | `payment_receipts.allocation_breakdown` (JSONB) duplicates `payment_allocations` | Intentional: it is the snapshot of the issued document. `v_duplicated_fact_drift` already checks it against the relational rows |

## 5. Verification

| Gate | Result |
|---|---|
| `scripts/schema_integrity_check.py` (fresh install + V7→V16 upgrade, 52 checks) | ✅ 52/52 pass, including 9 new V16 negative cases and 3 positive cases. The upgraded schema equals a fresh install, and every constraint is validated |
| `scripts/api_system_check.py` (real backend, throwaway database, 12 checks) | ✅ 12/12 pass, including the new `match_all_settles_in_place`, `payer_identity_recorded`, `site_purge_is_atomic` and `ledger_integrity_clean` |
| Manual SQL smoke test of the triggers (12 cases) | ✅ Every forbidden update/delete/transition rejected; the purge switch works for one transaction only |

V16 was **not** applied to the shared development database (`sitepulse`), because that database is also used by the `master` checkout. Its legacy writers insert `SETTLED` rows without receipts, which V16 now rejects. It will be applied when this branch is merged and the stack is restarted.
