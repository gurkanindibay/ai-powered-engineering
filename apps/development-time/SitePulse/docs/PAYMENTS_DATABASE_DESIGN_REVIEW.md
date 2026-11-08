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

## 4. Open items after V16 — status after V17 (SPEC-006)

V17 `payment_ledger_hardening.sql` and the SPEC-006 code changes (`.specify/specs/006-payment-ledger-hardening/spec.md`, `task-27`) address the items below.

| ID | Severity | Item (after V16) | Status after V17 |
|---|---|---|---|
| O-1 | 🟠 | The in-memory model kept **one advance total per unit**, while the database splits by debtor. The virman debited only the OWNER bucket, so the tenant-surplus → owner-capital flow failed in DB mode | ✅ **Fixed.** `AppStateInner.advance_balances` is `unit → {owner, tenant}`, loaded and saved per `(unit_id, debtor_type)`. The re-split heuristic in `save_advance_balance` is gone, together with the unused ledger-bypassing writers. The automatic offset pays each liability only from its own debtor's advance. `InterLedgerTransferRequest.source_debtor` / `target_debtor` (default OWNER) make `TENANT → OWNER` a single transaction: tenant payer, on behalf of the owner, rent-offset eligible, with a `VIRMAN_DEBIT` on the TENANT bucket. Receipts record `advance_debtor_type`, checked so that it is set exactly when `allocated_advance > 0`. **Found while fixing it:** `accrue_monthly_dues` and unit provisioning typed an owner-occupied unit's operational dues as `TENANT`. They now use the scheduler's rule: TENANT only when the unit is let |
| O-2 | 🟠 | No reversal linkage or un-allocation | ✅ **Fixed.** `POST /api/v1/payments/reverse` (staff, reason required, operator taken from the token) runs as one transaction. It issues an `IAD-YYYY-NNNNNN` receipt (`receipt_type = REVERSAL`, own `receipt_counters` row, `reverses_receipt_id`, unique). It appends a contra entry (`entry_type = REVERSAL`, `reverses_entry_id` unique, `reversal_reason`, `recorded_by`, all immutable). It restores `paid_principal` / `paid_penalty` and recomputes the status, debits the credited advance as `REFUND` (refused if that advance was already spent), then moves the original `SETTLED → REVERSED`. The guard now allows that transition only once a contra entry exists. The drift views ignore a reversed entry's allocations and check each reversal against its original. A repeated request returns the first reversal. **Deferred:** reversing a virman is refused (record a correcting transfer instead). The KMK 20 penalty for the days between a payment and its reversal is not re-accrued: the penalty stays as accrued, on the principal outstanding at the time |
| O-3 | 🟡 | `processed_bank_webhooks` keyed only by `transaction_id` | ✅ **Fixed.** Surrogate key, plus `site_id`, `site_bank_account_id`, `receipt_id` and `payload_hash` (SHA-256 of transaction id, amount, currency, IBANs and description), all `RESTRICT` foreign keys. The table is unique on `(scope_key, transaction_id)`, where `scope_key` = account, else site, else `-`. Pre-V17 claims are backfilled with their site and the site's active account, so retries of old transactions are still recognised. A redelivery returns the original TAH number. The same id with different content is `409`. The payment key becomes `BANK:<account>:<txn>` when the account is known. **Found while fixing it:** an unmatched transfer was persisted with `save_reconciliation_match`, which requires a unit, so every unmatched webhook failed in DB mode. An unknown destination also fell back to site 1. Unmatched transfers are now stored under the receiving site and account, and a destination IBAN that is no site's account is `422` |
| O-4 | 🟡 | `channel_reference` overloaded with `IDEMPOTENCY:<key>`, `REF-n` and the virman note | ✅ **Fixed** for new rows. `channel_reference` holds the bank/channel reference, or the original receipt number on a reversal, otherwise NULL. Idempotency is looked up in `payment_idempotency_keys` and its in-memory mirror `AppStateInner.payment_idempotency`. Legacy `IDEMPOTENCY:` references were copied into `payment_idempotency_keys`. Issued receipts were not rewritten, so old rows keep their old text. No CHECK forbids the prefix, because legacy rows would fail validation |
| O-5 | 🟡 | No issuer legal details on receipts; no `sites.tax_id` | ✅ **Fixed.** `sites.tax_id` (CHECK `^[0-9]{10,11}$`, validated by `PUT /api/v1/saas/sites/:id`) and `sites.tax_office`. Receipts snapshot `issuer_name`, `issuer_address`, `issuer_tax_id` and `issuer_tax_office` in the insert statement itself. Pre-V17 receipts keep NULL rather than invented values. **Found while fixing it:** every SaaS site update rewrote the site's blocks (`DELETE FROM blocks`), which PostgreSQL rejects once units reference them. Blocks are now rewritten only when the request names them. **Still open (STORY-09-04):** the verification hash does not yet cover the issuer or the allocation lines, and there is no PDF/QR |
| O-6 | 🟡 | `dues_liabilities.status` stored time-derived and paid-derived states | ⚠️ **Partly fixed.** The paid-derived states are now a constraint (`chk_dues_paid_status_consistent`): `PAID` holds exactly when the liability is fully paid, and `PARTIALLY_PAID` needs a payment. Existing rows were normalised. The time-derived `OVERDUE` stays a cache: the code recomputes it on read (`calculate_delay_penalty`) and `v_dues_effective_status` derives it in SQL. The stored value is not dropped, because the Flutter views and the legacy endpoints still read it |
| O-7 | 🟡 | `reconciliation_queue`: two status casings, `ON DELETE CASCADE` bank account, denormalised `matched_*` | ✅ **Fixed.** One English vocabulary (`PENDING_APPROVAL`, `APPROVED`, `UNMATCHED`, `REJECTED`, `ALREADY_PROCESSED`), with legacy PascalCase rows translated. The duplicated Turkish `status_code` column is dropped; the API still derives `status_code` for clients. The bank-account FK is `RESTRICT`. `matched_block` / `matched_unit_number` / `matched_resident_name` are documented (column comments) as match-time snapshots; `matched_unit_id` / `matched_due_id` remain the facts |
| O-8 | 🟢 | `debt_aging_snapshots` never written | ✅ **Fixed.** A daily worker (`scheduler::start_debt_aging_snapshot_worker`) and `POST /api/v1/payments/debt-aging/snapshot` write each site's aging report. A same-day re-run replaces that day's rows of the site. Nothing reads the history yet (trend UI, regulatory report F17) |
| O-9 | 🟢 | Receipt sequence never resets yearly although the number carries the year | 📝 **Decided (documentation only).** Sequences are continuous per site and series (`TAH`, `IAD`) and never reset. The year in the number is the issue year. A building management's tahsilat makbuzu is not a VUK serial document, and a gap-free running sequence is the stronger audit property. Recorded in SPEC-006 R9. Revisit if a site becomes subject to e-Arşiv/e-SMM numbering |
| O-10 | 🟢 | `payment_entries.payer_role` defaulted to `'TENANT'` | ✅ **Fixed.** Default dropped (NOT NULL kept). Every writer sets the role. The schema gate's older negative cases were updated to pass a role, so they still test what they claim |
| O-11 | 🟢 | `allocation_breakdown` (JSONB) duplicates `payment_allocations` | 📝 **Kept by design (documentation only).** It is the snapshot of the issued document. `v_duplicated_fact_drift` checks collection receipts against their allocation rows. Reversal receipts have no allocation rows of their own and are checked against their original in `v_integrity_violations` |

### Remaining open items (next increments)
- Reversing a virman; a stand-alone advance refund (without reversing a payment).
- Re-accruing the KMK 20 penalty for the days a later-reversed payment was counted as paid.
- Receipt verification hash covering the issuer and the allocation lines; PDF/QR (STORY-09-04).
- Dropping the stored `OVERDUE` once every reader uses the effective status.
- A trend view over `debt_aging_snapshots`.

## 5. Verification

| Gate | V16 | V17 (SPEC-006) |
|---|---|---|
| `scripts/schema_integrity_check.py` (fresh install + V7→latest upgrade) | ✅ 52/52 | ✅ 74/74: 14 new V17 negative cases (each checked to fail on its intended constraint), 4 positive cases and 4 upgrade assertions. The upgraded schema equals a fresh install, and every constraint is validated |
| `scripts/api_system_check.py` (real backend, throwaway database) | ✅ 12/12 | ✅ 17/17, adding `tenant_surplus_virman`, `reversal_restores_ledger`, `webhook_claim_scoped`, `issuer_snapshot_on_receipt` and `debt_aging_snapshot_persisted` |
| `cargo test` (backend) | — | ✅ all pass, including the 16 tests in `tests/payment_ledger_hardening_tests.rs` (the Kuveyt Türk key test no longer depends on local key files since SPEC-007) |

V16 was **not** applied to the shared development database (`sitepulse`), because that database is also used by the `master` checkout. Its legacy writers insert `SETTLED` rows without receipts, which V16 now rejects. V16 and V17 will be applied when this branch is merged and the stack is restarted.
