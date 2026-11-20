# Site Admin interconnected journeys: test plan

This document remains the reference for journey fixtures and invariants. The accepted scenarios
for files 05, 09, and 11 live under `.specify/features/EPIC-13/`; their `@pending` and
`@linked` tags record current automation status. Complements `GUI_TEST_PLAN.md` §12 (per-role
journeys), which walks one role through its own screens but has no shared fixtures or teardown contract.

## 1. Why this plan is shaped this way

Existing e2e tests each build their own little world with SQL "Arrange" helpers
(`Builders.overdue_dues`, `Builders.tenant_debt`) and share one global `reset()` that truncates
everything and restarts the backend. That is why e2e feels hard: every test invents its starting
data, so tests do not compose and the numbers differ everywhere.

This plan replaces that with three ideas:

1. **Named starting states (fixtures F0 to F7).** One data catalogue, defined once below, with fixed
   people, units, tariffs and expected balances. Every scenario says `Given the site is in state F5`
   or declares a small fixture for a single boundary.
2. **Journey chains.** A chain is an ordered list of stages that share one site; the end state of
   one stage is the start state of the next (file `06`). A failure says which stage broke.
3. **Invariant checkpoints.** After every stage of every chain the step
   `Then the ledger invariants hold` runs the same cross-checks (section 4), so a wrong number is
   caught where it first appears, not three stages later.

## 2. Fixed reference data

| Item | Value |
|---|---|
| Clock | **2026-11-19 12:00 Europe/Istanbul**, reference instant (needs a test clock, see Q1) |
| Site | `e2e-<run>-<shard>-<attempt>`, unique to the scenario attempt (see section 5) |
| Block | `A Blok`, units `A-1` to `A-7`; unless a scenario says otherwise, units, ownership and first occupancies exist from 2026-09-01 |
| Flat tariff | 1500.00 operational per unit per month; `A-6` is larger: 2250.00 |
| Due day | 10th of the month, grace days 0 (grace has its own scenarios) |
| Effective due date | Every charge keeps its **period due date** (which month it belongs to, FIFO order) and gets an **effective due date** = the later of the period due date and the date the charge was created. Grace, late fee and aging count from the effective due date (Q9). A charge created by an approved correction counts as created on the approval date |
| Late fee | KMK 5% per month, calculated per segment on outstanding principal: `principal x 5% x days / 30`, rounded to 2 decimals half away from zero |
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
| **F2 RESIDENTS_NO_PERIOD** | People without billing | F1 plus the owners and occupants of the table above, each with an activated resident account and a permanent password (resident sign-in scenarios need it). No period exists |
| **F3 PERIOD_NO_RESIDENTS** | Billing without people | F1 plus period `Ekim 2026` created and accrued while units had no owners and no occupants |
| **F4 SINGLE_PERIOD** | One accrual | F2 plus `Ekim 2026` accrued. Only A-1 paid (on the due date). Debt: A-2 tenant 1600.00, A-3 owner 1600.00, A-4 owner 1600.00, A-5 tenant 1600.00, A-6 owner 2400.00. Outstanding total **8800.00** (principal 8250.00 + fee 550.00) |
| **F5 MULTI_PERIOD** | Three accruals, mixed debt | F2 plus Eylül, Ekim, Kasım accrued. A-1 paid all on time: 0.00. A-2 paid Eylül only: 3122.50 (3000.00 + 122.50). A-3 owes Eylül only (single debt in a previous month): 1675.00. A-4 owes Kasım only (single debt in the current month): 1522.50. A-5 paid nothing: 4797.50 (4500.00 + 297.50). A-6 paid 8000.00 on 2026-09-01, so all three periods are covered and **1250.00 advance** remains. Outstanding total **11117.50** |
| **F6 CHANGING_OCCUPANCY** | Residents arrive and change after accruals | See section 3.1 |
| **F7 CLOSED_HISTORY** | F5 with `Eylül 2026` closed | Eylül is CLOSED; Ekim and Kasım are open |

### F5 payment history

Build each month on the first local day. For each row below, record the listed payment on that
month's due date, except for A-6's 2026-09-01 payment. A dash means no cash payment that month.
Use the responsible debtor and unit on every payment. A-6's October and November settlement
comes from the same advance, with no new payment or receipt for cash.

| Unit | September | October | November |
|---|---:|---:|---:|
| A-1 | 1500.00 | 1500.00 | 1500.00 |
| A-2 | 1500.00 | — | — |
| A-3 | — | Targeted 1500.00 to October | Targeted 1500.00 to November |
| A-4 | 1500.00 | 1500.00 | — |
| A-5 | — | — | — |
| A-6 | 8000.00 on 2026-09-01 | — | — |

Use an explicit liability target for A-3, since generic FIFO would pay September first. If
the supported entry point cannot produce that allocation, use an isolated fixture seed for
those allocations and verify it via the normal read APIs before running any scenario.
For F7, close September at the reference instant after November opens and capture the close
summary. Use the same close date and fee evaluation schedule when comparing to the snapshot.

### 3.1 F6 narrative (the "residents added after accruals" case)

Proration is on. Start with F2 except A-2 is vacant and A-5 remains tenant-occupied. Make
no payments. Build in chronological order, using these local dates. Each accrual runs on the
date of its step, after that step's occupancy change, so the accrual sees the final occupancy
of the month. October and November are therefore accrued after their due dates; the due date
and late fee of those shares count from their effective due date: 2026-10-11 for every October share and
2026-11-15 for every November share (section 2). Oya's re-split November share is due on the
approval date, 2026-11-18; Burak's reduced share keeps 2026-11-15.
A tenant session's end date is exclusive, so the incoming party pays the handover day.

1. 2026-09-01: A-2 vacant, owner Ahmet. `Eylül 2026` accrued: Ahmet owes 1500.00 for A-2.
2. 2026-10-11: tenant Selin Demir moves into A-2. `Ekim 2026` accrued: Ahmet owes 483.87 (10 days),
   Selin owes 1016.13 (21 days). Shares add up to 1500.00.
3. 2026-11-05: A-4 sold, Ahmet Yılmaz to Gül Tanrıverdi (title deed transfer). Ahmet moves out
   of A-4 and Gül moves in as owner-occupant on the same date.
4. 2026-11-15: Selin moves out, tenant Mert Kılıç moves in. `Kasım 2026` accrued: Selin owes 700.00
   (14 days), Mert owes 800.00 (16 days). For A-4, Ahmet owes 200.00 (4 days) and Gül 1300.00
   (26 days), because an owner-occupied sale splits by days (Q10).
5. 2026-11-18: A-3 (vacant so far) gets tenant Oya Çelik with start residing date 2026-11-18.
   `Kasım 2026` already exists, so a split correction is requested and a second manager approves
   it, as in SC-13-05-09. After approval Oya owes 650.00 (13 days) and owner Burak 850.00 (17 days).
   Earlier periods are unchanged. This retroactive split follows Q4.

## 4. Ledger invariants (the reusable checkpoint)

`Then the ledger invariants hold` checks the applicable ledger rows and API read models at the same clock instant. GUI
scenarios also compare the surfaces they visit with the matching API scope. I8 and I10 run at their
explicit restart and isolation checkpoints. Fixtures with no liabilities still assert zero totals
and empty rows.

| # | Invariant |
|---|---|
| I1 | For each collectible liability: outstanding principal plus outstanding fee equals displayed debt; derive each component after credits and valid allocations |
| I2 | Sum of all unit balances = site "total outstanding" on the collection dashboard |
| I3 | Compare dashboard and workspace debt for the same site, unit, debtor and ledger type; reconcile payment history by movement and allocation, including advances and reversals |
| I4 | Each accepted payment is counted once. Allocations and remaining credit reconcile to the payment net of approved refunds and reversals; advances stay scoped to the debtor and unit |
| I5 | For each unit and period, shares sum to the tariff prorated for chargeable days; pre-creation and unassigned days contribute zero. Check original charges before approved corrections |
| I6 | Every liability has exactly one primary debtor. For a tenant's liability the unit owner on the same dates is recorded and shown as jointly liable (KMK m.22), never as a second liability. A cancelled liability has zero outstanding and remains in audit history |
| I7 | Historical debt stays with its original debtor; approved dated corrections preserve the original audit trail and affect only the authorized dates and amounts |
| I8 | Every balance is identical after a backend restart (memory and PostgreSQL agree) |
| I9 | Sum of the amounts shown to a user equals what the API returns, to the kuruş |
| I10 | Site-scoped responses and exports contain only authorized site data; resident financial and private identity data are further scoped to the authorized unit, person and responsibility dates |
| I11 | Every charge's late fee and aging count from its effective due date, never from a day before the charge existed; FIFO allocation follows the period due date |
| I12 | A title transfer moves no existing charge; only charges accrued after its effective date, or an approved seller-pays override, name the buyer or keep the seller |

## 5. Isolation and teardown contract

Each scenario attempt owns a site and identities keyed by run, shard and attempt, including
outline rows and retries. A lifecycle scenario keeps its own site for all stages. Store any second
site in the same attempt manifest. Preserve screenshots and scenario evidence through the
existing CI shard artifacts.

**Setup.** Use public API builders wherever possible and assert the fixture fingerprint through
read APIs. SQL Arrange uses an exclusive stack and restarts its backend before assertions. For
historical fixtures, use a clock that can advance monotonically before requests and scheduled
jobs. Set the reference time only after fixture construction. Disable unplanned job ticks and
trigger each expected tick explicitly. Read each prepared fixture at the reference instant unless the scenario supplies a different observation date.

**Teardown.** Register cleanup before provisioning and record each created site and identity ID
as soon as it is available. Delete by the manifest IDs on a disposable test database in a
transaction. Keep shared identities and any references from other sites intact. Assert removal
for the recorded IDs and verify that seed data and another active attempt remain unchanged.
Use synthetic data and capture a redacted site snapshot and redacted network evidence on failure.
Cleanup still runs if evidence capture fails. Cleanup can be retried safely after interruption.

Run restart and mutable-clock cases on an exclusive stack, including any SQL teardown that needs
the backend reloaded. Parallel CI workers use separate stacks or a shared stack only for cases
that can run without global mutation. Reclaim a crashed run only after checking its manifest
and confirming the run is inactive. File 07 exercises these boundaries.

## 6. Tags and layers

`@EPIC-13 @STORY-13-xx` on the Feature, `@SC-13-xx-nn` on each Scenario, `@J-nn` journey id,
`@state:F5` the start state, `@chain:<name>` stage of an interconnected chain, `@layer:gui` or
`@layer:backend`, `@depth:n` (section 6.1), `@smoke @core @edge`, `@role_manager` or `@role_resident` (owner or tenant
acting in the resident app), `@pending`, and `@decision` for scenarios
whose expected behaviour needs a product answer first (section 8).

### 6.1 Test depth

`@depth:n` counts the state changes a scenario drives (its `When` steps). Every scenario carries it.

| Depth | Meaning | Where |
|---|---|---|
| 1 | One action on a named starting state | Most of files 01 to 11 |
| 2 | Two linked actions; the second depends on the result of the first | Corrections, retries, reversal, re-split after approval |
| 3 to 5 | A short chain crossing several rules (occupancy, sale, accrual, payment, close) with a checkpoint after each stage | File 12 |
| 6 and more | A full lifecycle on one site | File 06 |

A depth-n chain asserts the ledger invariants after each stage. A failure names the stage, and the
same rules are also covered at depth 1, so the failing rule can be found without rerunning the chain.

Layer rule: GUI scenarios are few and cover what only a screen can show (empty states, the
numbers the admin reads, the full chain). Money rules run at `@layer:backend` against the same
fixtures, because they are faster and are the part that must be exact.

## 7. Corner cases beyond the ones in the request

Covered in files `03`, `04`, `05`:

- Duplicate or zero-amount accrual, accrual with a due day the month does not have (31 in February).
- Same-day move-out and move-in (handover day), move-in on day 1 and on the last day, leap February.
- Tariff that does not divide evenly (1500.01 split 15/15, 1000.00 split in three): shares must add up exactly.
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

## 8. Product decisions and automation prerequisites

| # | Question | Plan assumption |
|---|---|---|
| Q1 | Can the backend run on a controllable local clock? | **Decided:** add an e2e-only clock that can advance through fixture dates, with deterministic job ticks (to be built first, README section 10) |
| Q2 | Accrual on a unit with no owner: skip or reject? | **Decided:** accrual succeeds; units without owner are reported in a separate list (SC-13-01-08) |
| Q3 | Accrual on a vacant owned unit: owner is the debtor? | Yes, owner owes (matches the existing proration story) |
| Q4 | Adding a resident after accruals: any retroactive charge? | **Decided:** charges start at the primary resident's start residing date. Days nobody was billed for become a supplementary charge that refers to the original month: in that period while it is OPEN, otherwise in the current open period, with the closed snapshot unchanged (as Q5). Days already billed to someone go through the split correction with a second approver (SC-13-05-09). Either way the new charge's effective due date is its creation or approval date. SC-13-01-10, SC-13-01-14, SC-13-03-04, SC-13-12-03 |
| Q5 | Does the late fee keep growing on a closed period? | **Decided:** yes until paid. The live liability can change; payments, fees and corrections are booked in the open period and the closed snapshot remains fixed (STORY-07-12) |
| Q6 | Is the 5% / 30-day late-fee rule the only one (no cap, no compounding)? | Yes, as in STORY-01-02 |
| Q7 | Is deleting a site allowed in the API, or is teardown SQL only? | SQL only, test-support code, never an API |
| Q8 | One site per journey costs a backend restart per SQL Arrange. Accept, or add a "reload state" endpoint behind the e2e flag? | Use an exclusive test stack when setup requires a restart. |
| Q9 | Who owes days around a tenant's stay, and what happens to a departing tenant's debt? | **Decided.** Days before the tenant's start residing date and after their release belong to the owner, also in late accruals and re-splits. Departure goes through a check-out that shows the tenant's open debt (exit settlement). That debt stays on the tenant as primary debtor and the owner stays jointly liable for it (section 8.1). If the tenant left without telling the manager, the manager records the move-out with its real date; days after it are re-split to the owner and the tenant's earlier debt is still collectable from the owner. **Due date, decided:** a share created after the period due date gets the effective due date of section 2, so nobody owes a fee for days before the share existed. This replaces SC-07-10-03's rule that catch-up liabilities keep their period's due date (section 8.2). SC-13-01-14, SC-13-03-02, SC-13-03-17, SC-13-05-06, SC-13-05-17, SC-13-05-18 |
| Q10 | A sale in the middle of the month: who owes that month? | **Decided.** Operational dues follow the occupant: a tenant-occupied unit whose tenant does not change is not split; an owner-occupied unit is split by days between seller and buyer. Fixed-asset (capital) installments go to the owner on record when each installment is accrued. Debt accrued before the sale stays with the seller. At transfer the manager sees a sale clearance statement (open debt, advance, installments not yet accrued). If the sale contract says the seller pays the remaining installments, the manager records a seller-pays override that takes effect only after a second approver. SC-13-03-05, SC-13-03-16, SC-13-03-18, SC-13-03-19, SC-13-12-02 |
| Q11 | A transfer to the unit's virtual IBAN with no payer identity, on a unit with several open debtors (F6 A-2): whose debt does it pay? | **Decided:** it is not matched automatically. It goes to the reconciliation queue as UNMATCHED and the manager assigns it to a debtor. SC-13-04-15 |

### 8.1 Legal basis for debt responsibility (Q9, Q10)

Summary of Law No. 634 (Kat Mülkiyeti Kanunu, KMK) as published on mevzuat.gov.tr, for test design only. This is
not legal advice. Confirm with a lawyer before the product rule ships.

- **The owner is the primary debtor.** KMK m.20 obliges every owner to pay their share of common
  expenses and advances. An owner who does not pay in full owes a late fee of 5% per month.
- **A tenant is jointly and severally liable with the owner.** KMK m.22/1 makes anyone who uses the unit
  continuously (by lease, right of residence or otherwise) liable jointly and severally with the owner for the
  owner's expense share, advance and late fee. A tenant's liability is capped at the rent they owe, and what
  they pay is deducted from that rent.
- **Consequence for SitePulse:** whatever the tenant leaves unpaid, the management can always collect from
  the owner, with or without a check-out. Notice only changes when the tenant's responsibility ends. SitePulse
  does not hold the rent, so it cannot apply the tenant's cap. It should keep billing the tenant as primary
  debtor and show the owner as jointly liable. It should not move or duplicate the liability.
- **Unit lien.** If the debt still cannot be collected, a court-determined debt can be registered as a statutory
  mortgage (kanuni ipotek) on the unit in favour of the other owners (KMK m.22/2). Old debt does not move to
  a buyer automatically; it can follow the unit only through that registered lien.
- **Between owner and tenant**, the lease decides who bears the dues. Usage-related costs such as heating,
  lighting and water fall on the tenant (TBK m.341). Structural repairs and fixed-asset costs generally stay
  with the owner (TBK m.303 and Yargıtay case law). The management's claim under KMK m.22 does not change.

### 8.2 Changes these decisions need in existing specs and code

The plan is pending, so nothing below is changed yet. Each item has its own issue and must land before the matching scenarios can pass.

| Rule | Existing behaviour to change | Issue |
|---|---|---|
| Effective due date (Q9) | SC-07-10-03 says each catch-up liability keeps its period's due date; `dues_calculation_service.rs` counts the fee from `due_date`. Add an effective due date and use it for grace, fee and aging | [#206](https://github.com/gurkanindibay/ai-powered-engineering/issues/206) |
| Jointly liable owner (Q9) | Liabilities have one debtor; add the jointly liable owner per date range and show it on the owner statement, without the tenant's receipts or contacts | [#207](https://github.com/gurkanindibay/ai-powered-engineering/issues/207) |
| Unmatched multi-debtor transfer (Q11) | Webhook matching by virtual IBAN must stop when the unit has more than one open debtor | [#208](https://github.com/gurkanindibay/ai-powered-engineering/issues/208) |
| Sale clearance and seller-pays override (Q10) | New screen in the title transfer flow and a four-eyes request like the advance transfer of SC-08-05-03 | [#209](https://github.com/gurkanindibay/ai-powered-engineering/issues/209) |
| Supplementary charge (Q4) | Back-dated start dates on unbilled days must post a charge in the open period that refers to the original month | [#210](https://github.com/gurkanindibay/ai-powered-engineering/issues/210) |

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
| [08-screen-and-session-states.feature](08-screen-and-session-states.feature) | J-15: first login, loading, errors, retry, search, session expiry and stale forms |
| [09-financial-state-transitions.feature](09-financial-state-transitions.feature) | J-16: targeting, partial and backdated payments, post-close changes, reconciliation and dual ledger |
| [10-tenant-data-isolation.feature](10-tenant-data-isolation.feature) | J-17: cross-site reads, exports and mutations, private tenant statements and receipts, former occupants and session races |
| [11-state-machines.feature](11-state-machines.feature) | J-18: every liability, period, reconciliation and unit occupancy status: entry, allowed commands and refused commands |
| [12-multi-depth-chains.feature](12-multi-depth-chains.feature) | J-19: depth 3 to 5 chains that combine sale, departure, back-dating, catch-up and capital rules with a checkpoint per stage |

## 10. Coverage map

Use this map with the [GUI catalogue](../GUI_TEST_PLAN.md) and the existing
[Gherkin acceptance criteria](../../../.specify/features/README.md). Track each new
scenario as pending until its user-visible outcome or backend invariant runs in CI.

| State family | Covered in this draft | Existing suites to include in an app-wide run |
|---|---|---|
| Session and permissions | Fresh provisioning, expiry, session switch, site and resident isolation (file 10) | EPIC-03, EPIC-06 and the five per-role journeys |
| Screen data | Empty, populated, zero matches, loading, request failure, retry, stale action | GUI catalogue for remaining surfaces and resident offline cache |
| People and units | Unowned, vacant, owner- and tenant-occupied, replacement, transfer and rollback | EPIC-04, EPIC-08 and EPIC-12 for invitation decisions, dependents and the full allowed-command matrix |
| Billing and treasury | Every `DebtStatus`, `DuesPeriodStatus` (including DRAFT) and `ReconciliationStatus` value (file 11), closed and reopened periods, payment reversal, dual ledger | EPIC-07 and EPIC-09 for individual commands and receipts, EPIC-10 for project and disbursement states |
| Other manager workflows | Covered through their dedicated suites in an app-wide run | EPIC-02 for announcements and reminders; EPIC-11 for its finance workflows where available |
| Test infrastructure | Partial setup, failure evidence, retry, parallel ownership, restart and crashed run | CI shard entry points and existing test report |

## 11. Proposed delivery order after review

1. Test support: controllable clock with deterministic scheduler ticks (Q1), `site_in_state()` fixture, `ledger_invariants()` helper, teardown finalizer (file 07 first).
2. F0 to F3 (file 01), then the backend isolation cases that use the established fixtures (file 10).
3. F4, F5 (file 02) and the payment rules (file 04), backend layer.
4. F6 (file 03) after the section 8.2 changes, then the state machines, ledger transitions and corner cases (files 11, 09 and 05).
5. The multi-depth chains (file 12), once their depth-1 rules pass.
6. Add the isolated GUI recovery and session cases (files 08 and 10), then the GUI chain (file 06).
7. Move to `.specify/features/EPIC-13/`, run `feature_traceability.py check`, link the PR to the CI `e2e-test-report`.
