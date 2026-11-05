# SitePulse — Database Design Review

> **Scope:** `apps/development-time/SitePulse/backend/db/init/00-*.sql` (authoritative schema), verified against a freshly rebuilt database and cross-checked with the Rust write/read paths in `backend/src` and the business specifications in `.specify/requirements/EPIC-01…10`.
> **Date:** 2026-11-05
> **Status:** Report only — no code or schema changes applied.

---

## 1. Method

1. Rebuilt the schema from scratch (`db/init/00-01 … 00-10`) into an isolated database and dumped columns, constraints, indexes and the FK graph.
2. Traced every table to its Rust write/read sites (`grep INSERT/UPDATE/DELETE/SELECT`).
3. Compared each table against the Gherkin business invariants in EPIC-01…10.
4. Assessed against 1NF/2NF/3NF/BCNF and Codd's practical rules.

All findings below are verified against the actual artifacts, not inferred.

---

## 2. Executive Summary

**25 tables.** The transactional spine (sites → blocks → units → occupancies) is sound after recent work. The **financial/treasury layer has the most serious defects**, and **four tables exist in the schema but have no write path at all**.

| # | Severity | Finding | Business impact |
|---|---|---|---|
| F1 | 🔴 Critical | `payment_receipts` is **never persisted** (0 write sites) — official `#TAH-YYYY-XXXXXX` receipts are memory-only | EPIC-09 STORY-09-04 violated; receipt sequence, `verification_hash`, and `payment_entries.receipt_id` are all decorative |
| F2 | 🔴 Critical | `dues_liabilities.paid_amount` is **overwritten with a single payment amount** (`SET paid_amount = $3`), never accumulated | Partial payments mark a liability `PAID`; amounts silently lost; EPIC-09 FIFO settlement can't be audited |
| F3 | 🔴 Critical | `advance_balances` holds **one balance per unit**, not per owner/tenant sub-ledger | EPIC-09 STORY-09-06 ("virman tenant advance → owner capital dues") is unimplementable without losing whose money was used |
| F4 | 🔴 Critical | Payment→liability allocation (1:N) exists **only as JSONB** in `payment_receipts.allocation_breakdown`; `payment_entries.dues_liability_id` is a single FK | 1NF violation; no RI on allocations; dual-ledger statement (STORY-09-03) cannot be rebuilt relationally |
| F5 | 🟠 High | `units.owner_person_id` / `tenant_person_id` / `occupancy_status` **duplicate** `unit_ownerships` / `unit_occupancies`, written independently in 6+ places | Ownership transfer (STORY-09-07) and move-out (STORY-09-05) can leave contradictory state |
| F6 | 🟠 High | `dues_liabilities.period` is a **free-text Turkish string** ("Eylül 2026") with **no FK** to `dues_periods` | Rename ⇒ orphan liabilities; violates the English-identifier rule; typo ⇒ duplicate accrual |
| F7 | 🟠 High | `debt_aging_snapshots`, `unit_ownerships`, `user_site_roles` have **zero write paths** | STORY-09-03 aging, STORY-09-07 transfer, and multi-site roles are unimplemented |
| F8 | 🟠 High | No **immutability** on `payment_entries` / `payment_receipts` / `collection` history | "Immutable collection ledger" (EPIC-09) is convention only; UPDATE/DELETE unrestricted |
| F9 | 🟠 High | `reconciliation_queue.transaction_id` **not unique**; no `bank_account_id` | Same bank line can be imported twice ⇒ double-credited payments |
| F10 | 🟡 Medium | 15+ enum-like `VARCHAR` columns have **no CHECK**; several `site_id`/`unit_id` pairs are **not composite-FK'd** | Invalid states representable; cross-tenant row pairs possible |
| F11 | 🟡 Medium | `units.house_type` is free text matched to `house_types.type_name` by string | Renaming a tariff silently drops units to default pricing |
| F12 | 🟡 Medium | Persons are **global**, `national_id`/`email` globally unique; no tenant scoping or RLS | Cross-tenant existence leak; GDPR exposure |
| F13 | 🟡 Medium | `units.version` exists for optimistic locking but **is never used** | Concurrent accrual/payment can overwrite |
| F14 | 🟢 Low | No `updated_at`, no soft-delete, no audit columns; no `timezone` on `sites` | Operational traceability gaps |

---

## 3. Relation Map

```
sites ─┬─< blocks ─┬─< units ─┬─< unit_occupancies ─< occupancy_members
       │           │          ├─< unit_ownerships
       │           │          ├─< dues_liabilities ─< (payment_entries.dues_liability_id)
       │           │          ├─< advance_balances  (1:1)
       │           │          ├─< unit_sender_ibans / unit_payer_names
       │           │          ├─< debt_aging_snapshots
       │           │          └─< payment_receipts ─< payment_entries
       │           ├─< house_types  (⋢ units.house_type — string join only)
       │           └─< dues_periods (⋢ dues_liabilities.period — string join only)
       ├─< site_bank_accounts
       ├─< capital_projects ─┬─< capital_project_installments
       │                     └─< capital_contractor_disbursements
       ├─< user_site_roles >─ users ── persons
       ├─< pending_registrations        (block/unit as free text, by design)
       └─< invitation_tokens >─ units

persons ─< unit_occupancies, unit_ownerships, occupancy_members, users, dues_liabilities.liable_person_id
⋢ = logically related, no enforceable relationship
```

**Two broken "joins" (string-matched only):** `dues_liabilities.period` → `dues_periods.period_name`, and `units.house_type` → `house_types.type_name`. Both are declared as business relationships in the specs and enforced nowhere.

---

## 4. Table-by-Table Review

### 4.1 Tenancy & Identity

#### `sites`
Keys: PK `id`. Unique: `slug`. Children: 12 tables cascade from it.

- ✅ Correct as the tenant root.
- 🔴 **No CHECK on `status`** (its own default is `'ACTIVE'`) or `plan_type` (`'STANDARD'`) — the vocabulary lives only in comments.
- 🟡 `license_end_date` has no relationship to `status`; an expired licence remains `ACTIVE`.
- 🟡 No `timezone`. All accrual code uses `CURRENT_DATE`/`Utc::now()`, so month boundaries are UTC, not site-local — a Turkish site accrues September dues according to UTC. Real business defect for a TR-only product.
- 🟡 `slug` is nullable + UNIQUE: a site can exist without a public identity even though invitations require one.

#### `blocks`
Keys: PK `id`; UNIQUE `(id, site_id)` (added to support the composite FK); UNIQUE `(site_id, block_name)`.

- ✅ Clean. The `(id, site_id)` superkey is redundant but serves the `units` composite FK — justified.
- 🟢 `total_floors` has no CHECK (`>= 1`).

#### `persons`
Keys: PK `id`. Unique: `national_id`, `email`.

- 🟠 **Global, unscoped entity.** `national_id` and `email` are globally UNIQUE across all tenants. In a SaaS where tenants are competitors, inserting a national ID already owned by another site raises a unique-violation that **confirms the person exists elsewhere** — a cross-tenant information leak.
- 🟠 `person_type` is a **global** attribute, but a person can be an owner in site A and a tenant in site B. The correct model is per-site roles (`user_site_roles`), which exists but is unused (F7). So `person_type` is redundant *and* wrong-grained.
- 🟡 Duplicated with `users`: both carry `email` (UNIQUE in each). Two identity tables for one identity.
- 🟡 No `created_at`/`updated_at`.

#### `users`
Keys: PK `id`. Unique: `email`. FKs: `site_id`→sites (CASCADE), `person_id`→persons (SET NULL).

- 🟠 `site_id` + `role` **duplicate** `user_site_roles`. A `SAAS_ADMIN` has `site_id = NULL` and no row in `user_site_roles` — so two systems disagree about entitlements.
- 🟠 `users.email` duplicates `persons.email`; nothing keeps them equal.
- 🟡 `chk_users_role` excludes `PROPERTY_OWNER`, which the EPIC-08 glossary names as a valid term — terminology drift between spec and schema.
- 🟡 `auth_provider` (`'LOCAL'`) unrestricted; `google_sub` unique-when-present (good).

#### `user_site_roles`
- 🔴 **Dead table** (F7): 0 INSERT/UPDATE/DELETE in Rust. The multi-site role model is specified (EPIC-03) but every query still filters `users.site_id`.
- 🟡 `uq_user_site_role (user_id, site_id, role)` allows one person to hold SITE_MANAGER **and** HOME_OWNER on the same site — probably intended, worth confirming.

#### `pending_registrations`
Keys: PK `request_id`. FK: `site_id`→sites (CASCADE).

- ✅ Correctly *not* FK-bound to units — the unit may not exist yet.
- 🟠 **No CHECK on `status`** (`'PENDING'` default, values `PENDING/APPROVED/REJECTED` used in code).
- 🟠 **No UNIQUE on `(site_id, block, unit_no, email)`** — the same applicant can submit unlimited duplicate requests; nothing prevents it.
- 🟡 `block` and `unit_no` are free text/int rather than a reference to the block name; acceptable for pre-registration, but means no typo defence.

#### `invitation_tokens`
Keys: PK `token`. FKs: `site_id`→sites (CASCADE), `unit_id`→units (CASCADE).

- 🟠 **No `consumed_at` / `used_by`** — a token stays valid for its full 7 days regardless of use (EPIC-04 describes a reusable *link*, so this is a spec-level question, but it means invitations cannot be revoked once used).
- 🟠 **No CHECK on `token_type`** (`'UNIT'` is only a default).
- 🟡 `building`, `unit_number` (both VARCHAR) duplicate `units.block_id`/`units.unit_number` — denormalized snapshot; becomes stale if the unit is renumbered.
- 🟡 No index on `unit_id` for cascade/cleanup.

### 4.2 Physical Property

#### `units`
Keys: PK `id`; UNIQUE `(block_id, unit_number)`; composite FK `(block_id, site_id)`→`blocks(id, site_id)`; UNIQUE `virtual_iban` when present.

- ✅ The composite FK is the strongest integrity feature in the schema — `site_id` can no longer contradict the block's site.
- 🔴 **Three denormalized duplicates of state that lives elsewhere (F5):**
  - `owner_person_id` ⟷ `unit_ownerships` (active rows)
  - `tenant_person_id` ⟷ `unit_occupancies` (active TENANT row)
  - `occupancy_status` ⟷ `unit_occupancies` (existence + type)
  These are updated in 6+ hand-written `UPDATE units …` statements. Nothing prevents `occupancy_status = 'VACANT'` while an active occupancy row exists, or an owner differing from `unit_ownerships`.
- 🟠 `house_type VARCHAR(50)` — **no FK to `house_types`** (F11). Pricing resolves the tariff by string match, so a rename silently re-prices or de-prices units.
- 🟠 `version` exists but **is never read or incremented** (F13) — a vestigial optimistic-lock column.
- 🟡 `owner_person_id`/`tenant_person_id` FKs have no ON DELETE rule (default NO ACTION) — person deletion fails with an opaque error.
- 🟡 `unit_number INT` while the UI/domain speaks "A Blok D:14"; the composite `(block_id, unit_number)` is correct.

#### `unit_occupancies`
Keys: PK `id`. UNIQUE `(unit_id) WHERE is_active` — one active session. CHECKs on dates and type.

- ✅ The single best-normalized table: temporal history, correct active-row invariant, `exit_balance` supports STORY-09-05.
- 🟡 `exit_balance` default `0.00` is nullable — a distinction between "no exit settlement" and "settled at zero" is impossible.
- 🟡 `person_id` is `ON DELETE RESTRICT` (good) but the corresponding `units.tenant_person_id` is not, so the two disagree on deletion semantics.

#### `unit_ownerships`
Keys: PK `id`. UNIQUE `(unit_id, person_id) WHERE is_active`. CHECK share ∈ (0,100].

- 🔴 **Dead table** (F7): 0 writes. EPIC-09 STORY-09-07 (title-deed transfer, historical freezing) has no implementation path; only the one-time backfill in `00-07` ever populated it.
- 🟠 **Σ share_percentage per unit is not constrained to 100** — 3 co-owners at 50% each is representable. A `CONSTRAINT … NOT VALID` summary table or a deferred trigger is required for share accounting.
- 🟡 Duplicates `units.owner_person_id` for the "current owner" case (F5).

#### `occupancy_members`
Keys: PK `id`. UNIQUE `(occupancy_id, person_id) WHERE person_id IS NOT NULL`. FKs: occupancy (CASCADE), person (SET NULL), user (SET NULL).

- ✅ Correctly scoped to the occupancy session (STORY-08-02). The recent consolidation removed the duplicate `unit_members` table and its fake `resident_id`.
- 🟠 `full_name`/`phone`/`email` remain as fallbacks for people with no `persons` row — legitimate, but this means **no unique identity for those members**: two "Ali Kaya" rows on one occupancy are allowed (the unique index only covers `person_id`).
- 🟡 `relationship` is free text (`NOT NULL`) with no vocabulary.
- 🟡 `is_emergency_contact` has no invariant (ideally ≤1 per occupancy).

#### `house_types`
Keys: PK `id`. UNIQUE `(site_id, type_name)`.

- ✅ Correct shape as a per-site tariff catalogue, and it *is* used for pricing.
- 🟠 No link from `units.house_type` (F11).
- 🟡 `dues_amount` has no CHECK (`>= 0`).

### 4.3 Billing & Treasury

#### `dues_periods`
Keys: PK `id`. UNIQUE `(site_id, period_name)`. FK `site_id`→sites.

- 🟠 **Orphaned from the actual billing data (F6).** `dues_liabilities` stores `period VARCHAR(50)` — a hand-built Turkish string (`"Eylül 2026"`) — and never references `dues_periods.id`. The table is a UI list, not a relational dimension.
- 🟠 **No CHECK on `status`** (`'ACTIVE'`).
- 🟡 `period_name` is localized human text used as a natural key — fragile.

#### `dues_liabilities` — *the core financial fact table*
Keys: PK `id`. FKs: `unit_id`→units, `liable_person_id`→persons, `occupancy_id`→unit_occupancies, `capital_project_id`→capital_projects. Unique: periodic `(unit_id, period, expense_type) WHERE capital_project_id IS NULL`; capital `(unit_id, capital_project_id, installment_number)`.

Good: CHECKs on status/expense/debtor types, non-negative principal/penalty/paid, and `paid_amount <= principal + delay_penalty`.

Flaws:

- 🔴 **`paid_amount` is semantically double-booked (F2).** It is written as `SET paid_amount = $3` with *the amount of the current payment*, in three call sites — one of which passes `Decimal::ZERO`. The table is designed for a running total; the code writes "last payment". Consequences:
  - a ₺100 partial payment on a ₺1.400 liability sets `status='PAID'`, `paid_amount=100`;
  - `chk_dues_paid_within_owed` passes, so the DB cannot detect the business error;
  - `PARTIALLY_PAID` exists in the status CHECK but is never set.
  This is simultaneously a **normalization defect (two sources of truth: `paid_amount` vs Σ`payment_entries`) and a business-logic defect**.
- 🟠 **No `site_id`.** Every other financial table carries it; here tenant scoping requires `units → blocks → sites`. Inconsistent scoping strategy and no RLS anchor.
- 🟠 **`period` has no FK** (F6).
- 🟠 **Three overlapping debtor representations**: `debtor_type` (OWNER/TENANT), `liable_person_id` (nullable), `occupancy_id` (nullable). Nothing enforces that a `TENANT` liability points at the tenant of that occupancy, or that `liable_person_id` matches. EPIC-08's central invariant ("charged to debtor TENANT (Selin Demir)") is unenforced.
- 🟡 `payment_date` (singular) coexists with `payment_entries` history — redundant and misleading for multi-part payments.
- 🟡 `status` is derivable from `paid_amount` vs `principal + penalty` and due date. Keeping both allows contradiction (`PENDING` with `paid_amount = full`).
- 🟡 No `updated_at`; `version` unused.

#### `payment_entries` — *unified ledger*
Keys: PK `id`. FKs: site, unit, dues_liability (SET NULL), receipt (SET NULL). CHECK `amount > 0`.

- ✅ Good consolidation (three legacy ledgers → one), correct decimal type, correct FK coverage.
- 🔴 **Cannot represent allocation (F4).** A payment routinely settles N liabilities (Tier 1 penalty → Tier 2 oldest operational → Tier 3 capital → Tier 4 surplus). `dues_liability_id` is a single nullable FK, so the truth lives in `payment_receipts.allocation_breakdown` JSONB. A proper `payment_allocations(payment_entry_id, dues_liability_id, amount_principal, amount_penalty)` table is the normalized form.
- 🔴 **No sub-ledger attribution (F3).** The dual-ledger model needs to know *whose* account was credited (`OWNER` vs `TENANT` sub-account). `payer_role` records who paid; it does not record the beneficiary. STORY-09-06 (tenant pays owner's capital dues) cannot be reported correctly.
- 🟠 `settlement_status` duplicates information derivable from allocation state (`UNMATCHED` ≡ no allocations).
- 🟠 **No CHECK on `payment_channel` / `payer_role` / `settlement_status`.**
- 🟠 **No unique constraint on `external_reference`** — re-importing a bank statement double-credits (F9, with `reconciliation_queue`).
- 🟠 **Not immutable (F8)** — no trigger/rule prevents UPDATE/DELETE, contradicting "immutable collection ledger".
- 🟡 `payment_date` and `created_at` are both defaulted to `now()`; back-dated imports lose the original posting time unless the caller sets it.

#### `payment_receipts`
- 🔴 **Never written (F1).** 0 INSERT sites. The whole table — `receipt_number`, `sequence_number` (with its unique index), `verification_hash`, `allocation_breakdown`, `legal_statutory_note` — is dead weight in production.
- 🔴 **`payment_entries.receipt_id` therefore always points at nothing** (or is NULL) — an FK to a permanently empty table.
- 🟠 `chk_receipt_allocation_sums` is a strong invariant that is never exercised.
- 🟠 **No self-referential integrity for `sequence_number` gap-freeness** — uniqueness is enforced, monotonic contiguity is not (requires a counter table or advisory-lock sequence per site).
- 🟠 **No CHECK on `payer_role` / `on_behalf_of_role` / `payment_channel`.**
- 🟡 `total_amount >= 0` permits a zero-value receipt.

#### `advance_balances`
Keys: PK `unit_id` (1:1 with units).

- 🔴 **Single balance per unit — dual-ledger violation (F3).** EPIC-09 requires separate Tenant and Owner advance reservoirs; here a tenant's overpayment and an owner's surplus are the same number.
- 🔴 **No history.** Balance is mutable in place (`ON CONFLICT DO UPDATE`); there is no ledger of credits/debits, so "Avansı Demirbaşa Aktar" (virman) has no audit trail — contrary to the epic's explicit audit requirement.
- 🟡 `balance >= 0` CHECK is good but the invariant is only maintainable if consumption is transactional.

#### `debt_aging_snapshots`
- 🔴 **Dead table (F7)**: 0 writes. STORY-09-03 (aging buckets) is unimplemented at persistence level; the UI derives aging in memory.
- 🟠 **`site_id` + `unit_id` can disagree** — no composite FK to `units(id, site_id)` (the pattern already used for `blocks`).
- 🟠 **All six amounts are fully derivable** from `dues_liabilities` + `due_date`. This is a deliberate materialized snapshot, but there is no job producing it and no staleness marker beyond `as_of_date`.
- 🟡 `debtor_type` has no CHECK.

#### `collection_transactions` — *removed*
Confirmed absent after consolidation. ✅ EPIC-08 STORY-08-03 still references it by name in its Gherkin ("zero records deleted from … collection_transactions") — the **specification is now out of date** relative to the schema.

### 4.4 Reconciliation & Ingestion

#### `reconciliation_queue`
Keys: PK `match_id`. FKs: `matched_unit_id`→units (SET NULL), `matched_due_id`→dues_liabilities (SET NULL).

- 🟠 **`transaction_id` is not unique** (F9). Importing the same statement twice creates two matches for one real bank line; approving both double-credits the unit. Idempotency must come from the schema, not the parser.
- 🟠 **No `bank_account_id`.** When a site switches banks (allowed via `site_bank_accounts.is_active`), nothing records which account a line came from — reconciliation history becomes unattributable.
- 🟠 **No import batch concept** (`statement_imports` with file hash, bank, period). Re-upload detection has no anchor.
- 🟠 **Mutable staging that is not linked to its outcome.** Approved rows stay in the queue *and* produce a `payment_entries` row; nothing ties the two, so the queue can be re-approved.
- 🟡 `matched_block`/`matched_unit_number`/`matched_resident_name` duplicate the resolved unit (denormalized snapshot) — acceptable for an audit of the *proposal*, but only if the row is immutable afterwards; it is not.
- 🟡 `status`, `status_code`, `currency` have no CHECK, and status vocabulary mixes English and Turkish in the reader (`"ONAYLANDI"`, `"ESLESTIRILEMEDI"`).

#### `unit_sender_ibans` / `unit_payer_names`
Keys: PK `sender_iban`; `id` + UNIQUE `(unit_id, payer_name)`. FK `unit_id`→units (CASCADE).

- ✅ Correct: these are the fuzzy-matching heuristics for statement ingestion, and they are properly unit-scoped.
- 🟠 `sender_iban` is globally PK: **the same IBAN cannot be remembered for two units** (e.g. one payer paying two flats). Business-plausible case, currently impossible.
- 🟡 `sender_iban` has no IBAN format CHECK (unlike `site_bank_accounts.iban`).

#### `site_bank_accounts`
- ✅ Correct partial-unique "one active account per site"; IBAN and statement-format CHECKs present.
- 🟠 **`iban` is not UNIQUE** — two sites can claim the same IBAN, which would break statement attribution.
- 🟡 `configured_by` has no ON DELETE rule while `users` rows can be deleted.
- 🟡 No `bank_statement_imports` companion (see F9).

### 4.5 Capital Expenditure

#### `capital_projects`
Keys: PK `id`. FK `site_id`→sites (CASCADE).

- 🟠 **No CHECK on `category`, `status`, or `allocation_basis`** — all three are closed vocabularies documented only in comments.
- 🟠 `contract_amount` is not reconciled with `total_budget` and is nullable; nothing ties disbursement total to contract.
- 🟡 `target_completion_date` can precede `target_start_date`.
- 🟡 `contractor_iban`/`recipient_iban` have no IBAN format CHECK (unlike `site_bank_accounts`).

#### `capital_project_installments`
Keys: PK `id`. UNIQUE `(project_id, installment_number)`. CHECKs on budget/percentage.

- 🟠 **`total_installments` is repeated on every row** — a 3NF violation (it depends on `project_id`, not on the installment key). Changing the schedule means updating N rows, and inconsistent rows are representable.
- 🟠 **Σ `percentage` per project is not constrained to 100**, nor Σ `installment_budget` to `capital_projects.total_budget`. EPIC-10's budget-allocation wizard assumes both.
- 🟡 `is_accrued`/`accrued_at` are duplicated by the existence of the corresponding `dues_liabilities` rows (`capital_project_id`, `installment_number`) — two sources of accrual truth.

#### `capital_contractor_disbursements`
- ✅ Correctly project-scoped and append-only in intent.
- 🟠 `disbursement_method` unrestricted; `recipient_iban` unvalidated.
- 🟡 `invoice_number` not unique (duplicate contractor invoices allowed).

---

## 5. Normalization Assessment

| Form | Verdict | Evidence |
|---|---|---|
**1NF** | ❌ | `payment_receipts.allocation_breakdown` JSONB stores a repeating group of allocations with due-ids as strings. |
**2NF** | ⚠️ | `capital_project_installments.total_installments` depends on `project_id`, not the full key. `dues_liabilities.status` depends on `paid_amount` (non-key derived). |
**3NF** | ❌ | `units.owner_person_id` / `tenant_person_id` / `occupancy_status` are transitively derived from `unit_ownerships` / `unit_occupancies`. `dues_liabilities.paid_amount` duplicates Σ`payment_entries`. |
**BCNF** | ⚠️ | `dues_periods.period_name` and `house_types.type_name` act as natural keys used by string join rather than FK. |
**Domain-key** | ⚠️ | `reconciliation_queue.transaction_id` should be a business key (unique); it isn't. |
**Referential** | ✅/⚠️ | 40 FKs, all correct; but 2 logical relations (`period`, `house_type`) and 3 composite pairs (`site_id`+`unit_id` in payment/receipt/aging tables) are unenforced. |

**Verdict:** the *registry* half is ~3NF. The *treasury* half is not, because allocation (a genuine associative entity) is modelled as JSON and the debtor sub-ledger is modelled as a scalar balance.

---

## 6. Business Scenario Conformance

| Story | Schema support | Verdict |
|---|---|---|
STORY-08-01 dual-ledger separation | `expense_type`, `debtor_type` present | ✅ structure; ⚠️ debtor not enforced |
STORY-08-02 household scoping | `occupancy_members` | ✅ |
STORY-08-03 move-out, zero data loss | `unit_occupancies.exit_balance` | ✅ (spec names the removed `collection_transactions`) |
STORY-08-04 move-in audit trail | `unit_occupancies` history | ✅ |
STORY-09-01 payment stream | `payment_entries` | ✅ |
STORY-09-02 FIFO waterfall | `payment_entries` + JSONB allocation | ❌ allocation not relational; `paid_amount` not accumulated |
STORY-09-03 aging + sub-ledger | `debt_aging_snapshots` (dead), no sub-ledger dimension | ❌ |
STORY-09-04 receipt `#TAH-…` | `payment_receipts` (never written) | ❌ |
STORY-09-05 move-out settlement | `exit_balance` | ⚠️ no frozen sub-ledger |
STORY-09-06 tenant pays owner capital dues | `is_rent_offset_eligible`, `on_behalf_of_*` | ❌ no beneficiary/ sub-ledger columns |
STORY-09-07 ownership transfer | `unit_ownerships` (dead) | ❌ |
STORY-10-02 installment accrual | `capital_project_installments` | ⚠️ no Σ=100% invariant, duplicated `total_installments` |
STORY-10-04 inter-ledger virman | `advance_balances` (single scalar) | ❌ no per-ledger balance or transfer log |
STORY-07-01 virtual IBAN | `units.virtual_iban` UNIQUE | ✅ |
STORY-07 reconciliation | `reconciliation_queue` | ⚠️ no idempotency, no bank-account linkage |
STORY-03-01 tenant isolation | app-level `site_id` filters only | ⚠️ no RLS; `persons` global |
STORY-04 invitations | `invitation_tokens` | ⚠️ no consumption/revocation |

---

## 7. Cross-Cutting Defects

1. **Currency is implicit.** No monetary column carries a currency; `SYSTEM_CURRENCY='TRY'` is a config row. A second currency would require a schema change.
2. **Immutability is aspirational.** EPIC-09 calls the ledger immutable; no rule, trigger or permission enforces append-only on `payment_entries` / `payment_receipts`.
3. **Enum drift.** 9 columns have CHECK-constrained vocabularies; ~15 equivalent ones don't. The set is arbitrary rather than systematic.
4. **Timestamp coverage.** `updated_at` exists only on `site_bank_accounts`; `persons`, `units`, `dues_liabilities`, `capital_*` lack it.
5. **Soft delete absent.** Deleting a unit cascades through payments, occupancies and receipts — destroying the audit trail EPIC-08 STORY-08-03 promises to preserve.
6. **No tenant RLS.** Isolation is entirely application-enforced; one missing `WHERE site_id` exposes another tenant's data.
7. **Localized data in storage.** `"Eylül 2026"` periods and Turkish `status` strings (`"ONAYLANDI"`) appear in columns and are compared literally, violating the workspace English-identifier rule at the *data* level.
8. **Optimistic locking is vestigial.** `units.version` and `dues_liabilities.version` exist but are never used in any UPDATE.

---

## 8. Recommended Remediation Order (not implemented)

**P0 — correctness of money**
1. Persist `payment_receipts`; make `payment_entries.receipt_id` meaningful. Enforce gap-free sequence per site.
2. Introduce `payment_allocations (payment_entry_id, dues_liability_id, principal_amount, penalty_amount)`; drop reliance on JSONB.
3. Change `paid_amount` semantics to an accumulated value maintained by allocation, or remove it and derive from allocations.
4. Add `ledger_owner`/`beneficiary_person_id` to allocations so dual-ledger statements are derivable.

**P1 — model completion**
5. Split `advance_balances` into `(unit_id, ledger_scope)` with an append-only `advance_ledger_entries` history.
6. `dues_liabilities.period_id` → `dues_periods(id)`; migrate free-text periods.
7. `units.house_type_id` → `house_types(id)`.
8. Give `unit_ownerships` and `debt_aging_snapshots` real write paths, or drop them.
9. Retire `users.site_id`/`users.role` in favour of `user_site_roles`.

**P2 — integrity hardening**
10. Composite FKs `(site_id, unit_id)` → `units(id, site_id)` on payment, receipt and aging tables.
11. Unique `reconciliation_queue(site_id, transaction_id)`; add `bank_account_id` and a `statement_imports` batch table.
12. Complete CHECK coverage for all enum columns; add `UNIQUE(iban)` on `site_bank_accounts`.
13. Enforce Σ`share_percentage` = 100 and Σ`installment.percentage` = 100 / Σ`budget` = `total_budget`.
14. Remove `units.owner_person_id`/`tenant_person_id`/`occupancy_status` or make them trigger-maintained projections.

**P3 — operational**
15. Append-only enforcement (trigger or REVOKE) on the ledger tables.
16. `updated_at` + soft-delete columns; `sites.timezone`.
17. Row-level security keyed on `site_id`.
18. Update EPIC-08/EPIC-09 documents where they reference removed tables or unimplemented behaviour.

---

## 9. What is already sound

- Every monetary column is `NUMERIC(15,2)`; no float anywhere.
- 40 foreign keys, all with deliberate ON DELETE semantics; the `units→blocks(id,site_id)` composite FK is exemplary.
- Single-active-row invariants are correctly expressed as partial unique indexes (`uq_unit_active_occupancy`, `uq_unit_active_owner`, `uq_site_active_bank`, `uq_unit_active_owner`).
- Household members are now correctly scoped to an occupancy session with real identity FKs.
- The ledger consolidation removed three overlapping tables and two phantom references.
- All schema sources (`db/init`, `migrations/`, Rust bootstrap) are generated from one file and verified byte-identical.
