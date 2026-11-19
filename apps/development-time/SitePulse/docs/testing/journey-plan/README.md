# Site Admin interconnected journeys: test plan (DRAFT for review)

Status: **plan only, nothing is automated.** Every scenario is tagged `@pending`. After review the
files move to `.specify/features/EPIC-13/` (proposed epic `EPIC-13 Site admin journeys`) and get
step definitions in `e2e/steps/epic13_steps.py`. Complements `GUI_TEST_PLAN.md` §12 (per-role
journeys), which walks one role through its own screens but has no shared fixtures or teardown contract.

## 1. Why this plan is shaped this way

Existing e2e tests each build their own little world with SQL "Arrange" helpers
(`Builders.overdue_dues`, `Builders.tenant_debt`) and share one global `reset()` that truncates
everything and restarts the backend. That is why e2e feels hard: every test invents its starting
data, so tests do not compose and the numbers differ everywhere.

This plan replaces that with three ideas:

1. **Named starting states (fixtures F0 to F7).** One data catalogue, defined once below, with fixed
   people, units, tariffs and expected balances. Every scenario says `Given the site is in state F5`
   and never invents data.
2. **Journey chains.** A chain is an ordered list of stages that share one site; the end state of
   one stage is the start state of the next (file `06`). A failure says which stage broke.
3. **Invariant checkpoints.** After every stage of every chain the step
   `Then the ledger invariants hold` runs the same cross-checks (section 4), so a wrong number is
   caught where it first appears, not three stages later.

## 2. Fixed reference data

| Item | Value |
|---|---|
| Clock | **2026-11-19 12:00 Europe/Istanbul**, frozen (needs a test clock, see open question Q1) |
| Site | `e2e-<journey>-<runid>`, one per journey (never shared, see section 5) |
| Block | `A Blok`, units `A-1` to `A-7` |
| Flat tariff | 1500.00 operational per unit per month; `A-6` is larger: 2250.00 |
| Due day | 10th of the month, grace days 0 (grace has its own scenarios) |
| Late fee | KMK 5% per month, pro-rated daily on principal: `principal x 5% x days / 30`, 2 decimals |
| Periods | `Eylül 2026` due 2026-09-10 (70 days late), `Ekim 2026` due 2026-10-10 (40 days late), `Kasım 2026` due 2026-11-10 (9 days late) |
| Late fee per 1500.00 | Eylül 175.00, Ekim 100.00, Kasım 22.50 |
| Late fee per 2250.00 | Eylül 262.50, Ekim 150.00, Kasım 33.75 |
| Proration | on, unless a scenario says otherwise |

All amounts are `Decimal`; no float anywhere in the Arrange or Assert code (AGENTS.md rule 2).

### People and units

| Unit | Owner | Occupant | Notes |
|---|---|---|---|
| A-1 | Ayşe Kaya | Ayşe Kaya (owner-occupied) | pays on time |
| A-2 | Ahmet Yılmaz | tenant Selin Demir | operational debtor is the tenant |
| A-3 | Burak Şahin | vacant | owned, empty |
| A-4 | Ahmet Yılmaz | Ahmet Yılmaz (owner-occupied) | Ahmet owns two units |
| A-5 | Can Öztürk | tenant Deniz Arslan | |
| A-6 | Elif Aydın | Elif Aydın (owner-occupied) | tariff 2250.00 |
| A-7 | none on record | vacant | unassigned unit, used only for corner cases |

## 3. Starting-state catalogue

Expected balances are principal + late fee at the reference clock. `F0` to `F3` answer the
numbered starting points in the request; `F4` to `F7` cover the accrual histories.

| State | Meaning | Data |
|---|---|---|
| **F0 ZERO** | Brand-new site | Site and manager account only. No block, no unit, no person, no period |
| **F1 NO_RESIDENTS** | Structure without people | `A Blok`, units A-1 to A-7 with tariffs, no owner, no occupant, no period |
| **F2 RESIDENTS_NO_PERIOD** | People without billing | F1 plus the owners and occupants of the table above. No period exists |
| **F3 PERIOD_NO_RESIDENTS** | Billing without people | F1 plus period `Ekim 2026` created and accrued while units had no owners and no occupants |
| **F4 SINGLE_PERIOD** | One accrual | F2 plus `Ekim 2026` accrued. Only A-1 paid (on the due date). Debt: A-2 tenant 1600.00, A-3 owner 1600.00, A-4 owner 1600.00, A-5 tenant 1600.00, A-6 owner 2400.00. Outstanding total **8800.00** (principal 8250.00 + fee 550.00) |
| **F5 MULTI_PERIOD** | Three accruals, mixed debt | F2 plus Eylül, Ekim, Kasım accrued. A-1 paid all on time: 0.00. A-2 paid Eylül only: 3122.50 (3000.00 + 122.50). A-3 owes Eylül only (single debt in a previous month): 1675.00. A-4 owes Kasım only (single debt in the current month): 1522.50. A-5 paid nothing: 4797.50 (4500.00 + 297.50). A-6 paid 8000.00 on 2026-09-01, so all three periods are covered and **1250.00 advance** remains. Outstanding total **11117.50** |
| **F6 CHANGING_OCCUPANCY** | Residents arrive and change after accruals | See section 3.1 |
| **F7 CLOSED_HISTORY** | F5 with `Eylül 2026` closed | Eylül is CLOSED; Ekim and Kasım are open |

### 3.1 F6 narrative (the "residents added after accruals" case)

Proration is on. Built through the API in this order, each step with its own date:

1. 2026-09-01: A-2 vacant, owner Ahmet. `Eylül 2026` accrued: Ahmet owes 1500.00 for A-2.
2. 2026-10-11: tenant Selin Demir moves into A-2. `Ekim 2026` accrued: Ahmet owes 483.87 (10 days),
   Selin owes 1016.13 (21 days). Shares add up to 1500.00.
3. 2026-11-15: Selin moves out, tenant Mert Kılıç moves in. `Kasım 2026` accrued: Selin owes 700.00
   (14 days), Mert owes 800.00 (16 days).
4. 2026-11-05: A-4 sold, Ahmet Yılmaz to Gül Tanrıverdi (title deed transfer).
5. 2026-11-18: A-3 (vacant so far) gets tenant Oya Çelik with start residing date 2026-11-18.
   `Kasım 2026` is re-split: Oya owes 650.00 (13 days), owner Burak 850.00 (17 days). Earlier periods are unchanged.

## 4. Ledger invariants (the reusable checkpoint)

`Then the ledger invariants hold` asserts all of these, through the API and again on screen:

| # | Invariant |
|---|---|
| I1 | For every unit and debtor: principal + late fee - allocated payments = displayed balance |
| I2 | Sum of all unit balances = site "total outstanding" on the collection dashboard |
| I3 | Per-resident dashboard balance = admin unit workspace balance = payment stream total for that person |
| I4 | No payment is allocated twice and no allocation exceeds its payment; unallocated remainder = advance balance |
| I5 | For every period, the shares of every unit add up to its tariff (no kuruş lost or created by proration) |
| I6 | Every liability has exactly one debtor; a cancelled liability has none outstanding |
| I7 | A debtor's old liabilities never move to a new occupant or owner |
| I8 | Every balance is identical after a backend restart (memory and PostgreSQL agree) |
| I9 | Sum of the amounts shown to a user equals what the API returns, to the kuruş |
| I10 | No data of this site is visible to a manager of another site |

## 5. Isolation and teardown contract

Each **journey** owns one site, created through the SaaS API with slug `e2e-<journey>-<runid>`.
There is no shared mutable site, so journeys can run in parallel shards.

**Setup** (fixture `site_in_state("F5")`): create site, apply the state through the public API in the
same order a real admin would (blocks, units, people, periods, accruals, payments). Direct SQL is
allowed only for what the API cannot do (back-dating history in F5, F6). SQL Arrange is always
followed by `restart_backend()` so memory and database agree.

**Teardown** (finalizer, runs on pass, fail and error):

1. Delete everything keyed by this `site_id` in foreign-key order, inside one transaction
   (liabilities, allocations, payments, occupancies, units, blocks, tenants' persons, site users, site).
2. Delete persons and users created only for this journey (matched by the `e2e-` email domain).
3. Assert the site and its rows are gone: zero rows per table for the `site_id`, no user with
   the `@e2e.test` domain, and the checksum of the shared seed tables (system seed, SaaS admin)
   is unchanged.
4. Restart the backend once at the end of a shard so in-memory state matches the database.
5. On failure, before deleting, capture a SQL dump of the site and the network log as artifacts
   (CI artifact `e2e-shard-N`), so a failed journey stays debuggable.

File `07` tests this contract itself, so a leaking fixture fails a named scenario instead of
silently poisoning later journeys.

## 6. Tags and layers

`@EPIC-13 @STORY-13-xx` on the Feature, `@SC-13-xx-nn` on each Scenario, `@J-nn` journey id,
`@state:F5` the start state, `@chain:<name>` stage of an interconnected chain, `@layer:gui` or
`@layer:backend`, `@smoke @core @edge`, `@role_manager`, `@pending`, and `@decision` for scenarios
whose expected behaviour needs a product answer first (section 8).

Layer rule: GUI scenarios are few and cover what only a screen can show (empty states, the
numbers the admin reads, the full chain). Money rules run at `@layer:backend` against the same
fixtures, because they are faster and are the part that must be exact.

## 7. Corner cases beyond the ones in the request

Covered in files `03`, `04`, `05`:

- Duplicate or zero-amount accrual, accrual with a due day the month does not have (31 in February).
- Same-day move-out and move-in (handover day), move-in on day 1 and on the last day, leap February.
- Tariff that does not divide evenly (333.33 over 3 days): shares must add up exactly.
- Payment of exactly the debt, one kuruş short, overpayment, zero and negative payment.
- Same bank transaction id sent twice (idempotency), transfer to an unknown virtual IBAN, transfer
  that names a unit of another site.
- One person who owns two units, or owns one and rents another.
- Duplicate person (same national id) on move-in, then merge.
- Move-out with debt, with advance, twice, and move-in on an occupied unit.
- Accrual correction after a partial payment (cancel, credit note, re-issue) and four-eyes rule.
- Closed period: no new accrual, no new liability, late fee stops or continues as specified.
- Grace boundary: payment on the last grace day and one day after.
- Two admins accrue at the same time; two webhooks for one unit at the same time.
- Resident or other-site manager attempting an admin action (403, no data leak).
- Backend restart in the middle of a journey (invariant I8).
- Excel import with a bad row among good rows.
- Month boundary at midnight Europe/Istanbul (UTC differs from local date).

## 8. Open questions (need your answer before automation)

| # | Question | Plan assumption |
|---|---|---|
| Q1 | Can the backend run on a frozen clock? | **Decided:** add an e2e-only fixed-time setting to the backend (to be built first, README section 10) |
| Q2 | Accrual on a unit with no owner: skip or reject? | **Decided:** accrual succeeds; units without owner are reported in a separate list (SC-13-01-08) |
| Q3 | Accrual on a vacant owned unit: owner is the debtor? | Yes, owner owes (matches the existing proration story) |
| Q4 | Adding a resident after accruals: any retroactive charge? | **Decided:** charges start at the primary resident's start residing date; a past date re-splits periods already accrued (I7 still holds for older debtors). SC-13-01-10, 13-01-14, 13-03-04 |
| Q5 | Does the late fee keep growing on a closed period? | **Decided:** yes until paid; closing blocks new accruals only |
| Q6 | Is the 5% / 30-day late-fee rule the only one (no cap, no compounding)? | Yes, as in STORY-01-02 |
| Q7 | Is deleting a site allowed in the API, or is teardown SQL only? | SQL only, test-support code, never an API |
| Q8 | One site per journey costs a backend restart per SQL Arrange. Accept, or add a "reload state" endpoint behind the e2e flag? | Accept first, optimise if the suite is too slow |

## 9. Files

| File | Journeys |
|---|---|
| [01-starting-states.feature](01-starting-states.feature) | J-01 to J-06: F0 to F3, what an admin sees and can do from each |
| [02-accrual-histories.feature](02-accrual-histories.feature) | J-07 to J-09: F4, F5, F7: single and multiple periods, single debts, closing |
| [03-occupancy-changes.feature](03-occupancy-changes.feature) | J-10: F6: residents added late, tenant and owner changes |
| [04-payments-and-allocation.feature](04-payments-and-allocation.feature) | J-11: paying, advance, idempotency, FIFO across periods |
| [05-corner-cases.feature](05-corner-cases.feature) | J-12: the edge list of section 7 |
| [06-lifecycle-chain.feature](06-lifecycle-chain.feature) | J-13: one site from zero to a closed period, with invariant checkpoints |
| [07-teardown-and-isolation.feature](07-teardown-and-isolation.feature) | J-14: setup, teardown and isolation contract |

## 10. Proposed delivery order after review

1. Test support: frozen clock (Q1), `site_in_state()` fixture, `ledger_invariants()` helper, teardown finalizer (file 07 first).
2. F0 to F3 (file 01), the smallest data and the simplest asserts.
3. F4, F5 (file 02) and the payment rules (file 04), backend layer.
4. F6 (file 03), then corner cases (file 05).
5. The GUI chain (file 06) last, reusing everything above.
6. Move to `.specify/features/EPIC-13/`, run `feature_traceability.py check`, link the PR to the CI `e2e-test-report`.
