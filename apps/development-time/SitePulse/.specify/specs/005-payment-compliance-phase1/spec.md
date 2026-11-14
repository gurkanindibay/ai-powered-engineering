# Specification: Payment Compliance — Phase 1 (Single Ingestion, Penalty Base, Payer Designation)

> **Feature ID:** SPEC-005
> **Epic ID:** EPIC-09 (remediates `STORY-09-01`, `STORY-09-02`, `STORY-09-03`, `STORY-09-04`), EPIC-07 (`STORY-07-03`, `STORY-07-05`)
> **Domain:** Treasury & Billing Context — payment ingestion and allocation
> **Target Roles:** Site Manager, System (bank webhook), Resident (indirectly: receipts)
> **Governance:** KMK Art. 20 (delay penalty), TBK Art. 100 (partial payment), TBK Art. 101–102 (payer designation), TBK Art. 103 (right to a receipt)
> **Source analysis:** `docs/payments/PAYMENTS_MANAGEMENT_STRUCTURE_REPORT.md` §3.1, §3.3, §3.6 and `docs/payments/PAYMENTS_REGULATORY_AND_MARKET_EVALUATION.md` F2, F3, F4

---

## 1. Context

Before this spec, four separate allocation loops settled dues: the bank webhook, bank statement confirmation, the staff "record homeowner payment" endpoint, and match-all. Only `PaymentTrackingService::record_and_allocate_payment` issued `TAH-` receipts, wrote `payment_allocations`, and was atomic and idempotent. The delay penalty was charged on the full principal even after partial payments. Payers could not choose which debt a payment settles.

## 2. Requirements

### R1 — Single ingestion path
Every channel that settles dues MUST call `record_and_allocate_payment`:

| Channel | `payment_channel` | Idempotency key |
|---|---|---|
| Bank webhook, virtual IBAN match | `VIRTUAL_IBAN` | `BANK:<transaction_id>` |
| Bank webhook, main-account match | `BANK_TRANSFER` | `BANK:<transaction_id>` |
| Bank statement confirmation | `BANK_STATEMENT` | `STMT:<transaction_id or match_id>` |
| Staff-recorded payment (`/payments/record`) | mapped from `payment_method` | `HOP:<reference_code>` when given |
| Match-all of an `UNMATCHED` ledger entry | the entry's channel | `HOP:<entry id>` |

Consequences, for every channel:
- A sequential `TAH-YYYY-NNNNNN` receipt is issued.
- One `payment_allocations` row is written per liability touched.
- The surplus is credited to the advance ledger of the settling debtor.
- With PostgreSQL, the whole payment is one transaction.

Retrying the same channel event returns the first receipt and changes nothing.

### R2 — Match-all does not duplicate the ledger
When match-all settles an `UNMATCHED` `payment_entries` row, that row becomes the settled entry: status `SETTLED`, its `receipt_id` is set, and its allocations attach to it. No second entry is inserted.

### R3 — Penalty base is the unpaid principal (KMK 20)
- The penalty accrues **in segments**: `outstanding_principal × 5% × days / 30`, for each period between evaluations or payments.
- `dues_liabilities.penalty_accrued_through` records the date up to which `delay_penalty` has been accrued.
- An evaluation adds only the segment from `max(due_date, penalty_accrued_through)` to the evaluation date. Repeating an evaluation on the same date adds nothing.
- A liability without `penalty_accrued_through` (legacy rows) keeps the previous single-segment rule from the due date, using the outstanding principal, and is never below the stored penalty.
- Each segment is rounded to 2 decimals (`MidpointAwayFromZero`).
- The automatic advance offset evaluates the penalty before settling, so each segment uses the correct base.

### R4 — Payer designation (TBK 101–102)
- `RecordManualPaymentRequest.designation` may name `due_ids`, `periods` and/or an `expense_type`.
- The designated liabilities that the payer may settle are allocated first, with the TBK 100 waterfall: penalty first, then principal.
- Any remainder goes to the payer's other open liabilities, oldest due date first (TBK 102 default order), and then to the advance ledger.
- With no explicit designation, bank channels derive one from the description, matching a liability's `period` text case-insensitively. This keeps the old webhook behaviour ("Eylül 2026 aidatı").
- The designation is recorded in the payment entry's description.

### R5 — Data-quality fixes
- A payment that cannot resolve its unit MUST fail. It may not fall back to unit 14 / site 1.
- A settlement status written by the legacy match endpoint MUST be in the V14 vocabulary (`SETTLED`, `UNMATCHED`, `PENDING`, `REVERSED`).
- The debt aging report uses **outstanding** principal and penalty, and takes the debtor from the liability's `debtor_type`.

## 3. Acceptance Criteria (Gherkin)

```gherkin
Scenario: Penalty accrues only on the unpaid principal after a partial payment
  Given a ₺1,000.00 operational due, due 2026-09-01
  And ₺600.00 of principal is paid on 2026-09-16 (penalty accrued to that date: ₺25.00)
  When the liability is evaluated on 2026-10-01
  Then the delay penalty is ₺25.00 + ₺400.00 × 5% × 15 / 30 = ₺35.00
  And re-evaluating on 2026-10-01 leaves it at ₺35.00

Scenario: Payer designates a specific due
  Given unit 14 owes "Ağustos 2026" and "Eylül 2026" operational dues
  When a ₺1,400.00 payment designates period "Eylül 2026"
  Then "Eylül 2026" is settled and "Ağustos 2026" stays open

Scenario: Bank webhook issues a canonical receipt
  When the bank webhook delivers a matched transfer
  Then a TAH-YYYY-NNNNNN receipt is issued for it
  And the response receipt_id is that receipt number
  And re-delivering the same transaction_id returns DUPLICATE_IGNORED without a second receipt

Scenario: Statement confirmation issues a canonical receipt
  When the manager confirms a matched statement line
  Then a TAH- receipt is issued and the matched due is settled through the waterfall

Scenario: Match-all settles a pending entry without duplicating it
  Given an UNMATCHED payment entry for unit 14
  When match-all runs
  Then the entry count is unchanged and that entry is SETTLED with a receipt

Scenario: Debt aging uses outstanding amounts and the liability's debtor
  Given a partially paid tenant due and an owner capital due on a tenanted unit
  When the aging report is computed
  Then the tenant row shows only the unpaid remainder
  And the capital due appears under the OWNER row
```

## 4. Out of scope (next increments)
Reversals and refunds, tenant→owner virman source/target, receipt PDF/QR, an atomic ownership transfer, the işletme projesi (operating budget), and card payments through a licensed provider. See `docs/payments/PAYMENTS_REGULATORY_AND_MARKET_EVALUATION.md` §5.
