# Specification: Payment Ledger Hardening (Per-Debtor Advance, Reversals, Webhook Claims, Issuer Details)

> **Feature ID:** SPEC-006
> **Epic ID:** EPIC-09 (`STORY-09-03`, `STORY-09-04`, EPIC-09 §2.3 virman), EPIC-07 (`STORY-07-03`)
> **Domain:** Treasury & Billing Context — advance ledger, reversals, bank webhook idempotency, receipts
> **Target Roles:** Site Manager, SaaS Admin (site tax details), System (bank webhook, daily jobs)
> **Governance:** KMK Art. 20/22 (dues, tenant paying owner's capital dues), TBK Art. 103 (receipt), TBK Art. 314 (rent offset)
> **Depends on:** SPEC-005 / migration V16 (single ingestion path, append-only ledger)
> **Source analysis:** `docs/database/PAYMENTS_DATABASE_DESIGN_REVIEW.md` §4 (O-1 … O-11), `docs/payments/PAYMENTS_MANAGEMENT_STRUCTURE_REPORT.md` §3.3, §3.4, §3.11
> **Schema:** migration `V17__payment_ledger_hardening.sql`

---

## 1. Context

V16 made the payment ledger append-only, but left eleven design items open. The in-memory model kept one advance total per unit while PostgreSQL keeps one per debtor, so the tenant-surplus → owner-capital transfer failed in DB mode. A settled payment could not be reversed. Webhook claims, idempotency keys and receipts mixed several facts into single columns.

## 2. Requirements

### R1 — Advance balance per debtor (O-1)
- The in-memory advance is `AppStateInner.advance_balances: unit → { owner, tenant }`, loaded per `(unit_id, debtor_type)` and saved per debtor. No re-split heuristic exists.
- A payment surplus is credited to the settling debtor's advance. The receipt records that debtor in `advance_debtor_type` (NULL exactly when `allocated_advance = 0`).
- The automatic advance offset pays each liability only from **its own debtor's** advance.
- `InterLedgerTransferRequest` has `source_debtor` (whose advance is debited) and `target_debtor` (whose liabilities are settled), both `OWNER` by default. `TENANT → OWNER` issues a receipt paid by the tenant on behalf of the owner (rent-offset eligible when capital dues are cleared). The debit is a `VIRMAN_DEBIT` ledger entry on the source debtor, in the same transaction.
- Operational dues accrued for a unit without a tenant are the owner's (`debtor_type = OWNER`), the same rule as the scheduler.

### R2 — Reversal (O-2)
- `POST /api/v1/payments/reverse` `{ receipt, reason }` is staff-only. The operator is taken from the token.
- A reversal:
  - issues a receipt in the reversal series `IAD-YYYY-NNNNNN` (`receipt_type = REVERSAL`, own per-site counter, `reverses_receipt_id` = the original). It copies the original's amounts and allocation lines;
  - appends a contra entry (`entry_type = REVERSAL`, `reverses_entry_id` = the original entry, `settlement_status = REVERSED`, with `reversal_reason` and `recorded_by`);
  - restores `paid_principal` / `paid_penalty` of every liability the payment settled, and recomputes their status;
  - debits the advance the payment credited as a `REFUND` ledger entry. This fails if that advance has already been used;
  - moves the original entry `SETTLED → REVERSED`. The database allows this only once a contra entry exists.
- A receipt is reversed at most once. Asking again returns the first reversal. A reversal receipt and a virman (`INTER_LEDGER`) receipt cannot be reversed in this increment.
- With PostgreSQL the reversal is one transaction. The drift views ignore a reversed entry's allocations and check the reversal against its original.

### R3 — Webhook claims (O-3)
- `processed_bank_webhooks` has a surrogate key plus `site_id`, `site_bank_account_id`, `receipt_id` and `payload_hash`. It is unique on `(scope_key, transaction_id)`, where `scope_key` is the account if known, else the site, else `-`.
- The receiving account/site is resolved from the destination IBAN (a site account, or a unit's virtual IBAN) before processing.
- A redelivery returns `DUPLICATE_IGNORED` with the original receipt number. The same transaction id with different content (amount, IBANs, currency, description) is rejected with `409`.
- When the receiving account is known, the payment idempotency key is `BANK:<account>:<transaction_id>`.
- An unmatched transfer to an IBAN that is no site's account is rejected with `422`. It is never filed under site 1.

### R4 — Idempotency only in `payment_idempotency_keys` (O-4)
- `payment_receipts.channel_reference` holds only the channel's own reference: the bank transaction, the original receipt for a reversal, or NULL.
- The in-memory lookup uses `AppStateInner.payment_idempotency`, loaded from `payment_idempotency_keys`.
- Legacy `IDEMPOTENCY:<key>` references are copied into `payment_idempotency_keys`. Issued receipts are not rewritten.

### R5 — Issuer legal details (O-5)
- `sites.tax_id` (10-digit VKN or 11-digit TCKN, checked by the database and validated on `PUT /api/v1/saas/sites/:id`) and `sites.tax_office`.
- Every new receipt snapshots `issuer_name`, `issuer_address`, `issuer_tax_id` and `issuer_tax_office` at issue time. Pre-V17 receipts keep NULL, because their issuer details at issue time are unknown.

### R6 — Liability status (O-6)
- The paid-derived status is a constraint: `PAID` holds exactly when principal and penalty are fully paid, and `PARTIALLY_PAID` needs a payment (CANCELLED is exempt).
- The time-derived `OVERDUE` is a cache. It is recomputed on read by the code and exposed by `v_dues_effective_status`.

### R7 — Reconciliation queue (O-7)
- `reconciliation_queue.status` uses one English vocabulary: `PENDING_APPROVAL`, `APPROVED`, `UNMATCHED`, `REJECTED`, `ALREADY_PROCESSED`.
- The Turkish `status_code` column is dropped. The API still derives `status_code` for clients.
- The bank account foreign key is `RESTRICT`, so statement history outlives an account change.
- `matched_block`, `matched_unit_number` and `matched_resident_name` are documented as match-time snapshots.

### R8 — Debt aging snapshots (O-8)
- A daily worker writes every site's aging report to `debt_aging_snapshots`. `POST /api/v1/payments/debt-aging/snapshot` does the same on demand.
- Re-running on the same day replaces that day's rows of the site.

### R9 — Decisions recorded (O-9, O-10, O-11)
- **O-9:** the `TAH` and `IAD` sequences are continuous per site and series and never reset yearly. The year in the number is the issue year. A building management's tahsilat makbuzu is not a VUK serial document, and continuity without gaps is the stronger audit property.
- **O-10:** `payment_entries.payer_role` has no default. Every writer sets it.
- **O-11:** `allocation_breakdown` stays as the issued document's snapshot. `v_duplicated_fact_drift` checks collection receipts against their allocation rows. Reversal receipts are checked against their original.

## 3. Acceptance Criteria (Gherkin)

```gherkin
Scenario: A tenant's surplus pays the owner's capital dues
  Given unit 14 is let to Canan and the owner owes a ₺400.00 Asansör installment
  And Canan pays ₺1,600.00 against her ₺1,000.00 operational due
  Then ₺600.00 is credited to the TENANT advance and the capital due stays open
  When the manager transfers ₺400.00 with source_debtor TENANT and target_debtor OWNER
  Then the capital due is PAID, the TENANT advance is ₺200.00
  And the receipt is paid by Canan on behalf of the owner and is rent-offset eligible

Scenario: The owner's advance does not pay the tenant's dues
  Given the OWNER advance is ₺250.00, a ₺200.00 owner capital due and a ₺300.00 tenant due are open
  When the advance offset runs
  Then only the capital due is settled and ₺50.00 OWNER advance remains

Scenario: A bounced payment is reversed
  Given a ₺1,200.00 tenant payment settled a ₺1,000.00 due and credited the rest as advance
  When the manager reverses its receipt with reason "Karşılıksız havale"
  Then an IAD-YYYY-000001 receipt is issued and a REVERSAL contra entry records the reason and the operator
  And the due's paid amounts are back to zero and it is OVERDUE again
  And the advance is debited by a REFUND entry
  And reversing the same receipt again returns the same IAD receipt

Scenario: A reversal is refused when its advance was already used
  Given a payment's surplus was spent by a later virman
  When the payment is reversed
  Then the reversal is rejected and nothing changes

Scenario: A transaction id is claimed per receiving account
  When the bank delivers transaction T to the site account
  Then the claim stores the site, the account, the payload hash and the TAH receipt
  And redelivering T returns DUPLICATE_IGNORED with that receipt
  And delivering T again with another amount is rejected with 409

Scenario: Receipts print the issuer's tax details
  Given the SaaS admin sets the site tax id to 1234567890
  When a payment is recorded
  Then its receipt carries issuer_tax_id 1234567890 and the site's name
  And a tax id "12AB" is rejected
```

## 4. Out of scope
Reversing a virman (rejected; record a correcting transfer instead), refunding an advance without a reversal, re-accruing the KMK 20 penalty for the period between a payment and its reversal (the accrued penalty is kept as accrued), receipt PDF/QR, and a per-year receipt numbering mode.
