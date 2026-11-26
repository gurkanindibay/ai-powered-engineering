# SitePulse PM Manual Testing Playbook

**Status:** Active companion to [TEST_STRATEGY.md](TEST_STRATEGY.md) · **Owner:** SitePulse maintainers · **Verified against:** `1a57b5cb` (2026-11-25)

## 1. What this playbook is for

[TEST_STRATEGY.md](TEST_STRATEGY.md) is the single source of truth for how SitePulse is tested: which layer proves which claim, which lane runs it, and what counts as evidence. This playbook is the **manual and exploratory lane** of that strategy. It does not redefine the strategy; it tells a Product Manager how to exercise the product by hand on a reproducible state and how to hand a defect back to engineering with evidence attached.

Two rules keep the manual lane honest:

1. **A manual session is never evidence that a scenario passes.** The evidence of record is a named test that runs in CI and asserts the rule (strategy principle 1). A green manual walkthrough tells you the build is usable; a red one produces a bug report.
2. **A manual session starts from a named preset, not from whatever happens to be in the database.** Expected totals, unit balances, personas and checklists come from `pm_scenarios`, the same catalogue the automated E2E seeder uses, so a cheat sheet cannot drift from the suite.

Everything below is produced by [pm_workbench.py](../../scripts/pm_workbench.py) and its Workbench Web UI ([pm_workbench_web.py](../../scripts/pm_workbench_web.py), [pm_workbench_ui.html](../../scripts/pm_workbench_ui.html)). If a number on this page disagrees with the running cheat sheet, the cheat sheet is right and this page is stale — regenerate it with the procedure in §13.

## 2. Prerequisites

| Requirement | Why | Check |
| --- | --- | --- |
| Python 3.11 or newer | Runs the CLI, the Web UI and the seeder | `python3 --version` |
| Docker, or the project's `scripts/dev-db-up.sh` | Local PostgreSQL for the seeded presets | `docker info` |
| Rust toolchain | `up` builds and starts the backend on `:8080` with the `e2e` feature | `cargo --version` |
| Flutter SDK with a web target | `up` builds and starts the web client on `:9090` | `flutter --version` |
| Free ports `8080`, `9090`, `9095` | Backend API, Flutter Web, Workbench Web UI | `ss -ltn \| grep -E ':(8080\|9090\|9095)'` |

Every command in this playbook runs from `apps/development-time/SitePulse`. The tool refuses to start when `APP_ENV` or `ENVIRONMENT` is `production`, and the Web UI binds to loopback only unless you pass `--allow-remote`.

## 3. Quick start

```bash
cd apps/development-time/SitePulse
python3 scripts/pm_workbench.py up          # PostgreSQL + backend :8080 + Flutter Web :9090 + Workbench UI :9095
open http://localhost:9095                  # or paste it into a browser
```

Then, in the browser:

1. **Scenario gallery** → click **Prepare F5**. The button seeds a fresh site, pins the simulated clock to `2026-11-19` and makes the scenario active. The first prepare also recompiles nothing; expect 20–60 s against a warm stack.
2. **Active scenario cheat sheet** → read the site name and id, the simulated clock, the expected site totals, the unit-by-unit balances, the persona roster and the PM checklist. These are the numbers you test against.
3. **Persona Quick-Launch Panel** → click **Launch** on a persona to sign in to the Flutter client in a new tab as that person. The panel also has **Copy** buttons for the e-mail and password if you prefer the normal login screen.
4. Work through the pack checklist in §5, then **Verify Ledger Health** (§7).
5. If anything is wrong, **Export Bug Bundle** (§9) before you reset or move on.
6. Stop everything when you are done:

```bash
python3 scripts/pm_workbench.py down        # add --stop-db to stop the PostgreSQL containers too
```

`up` accepts `--skip-db` (PostgreSQL already running), `--skip-flutter` (UI only, no Flutter build), `--skip-ui` (CLI only), `--backend-release`, `--api-port`, `--web-port`, `--ui-port`, `--timeout` (health-check seconds), `--no-wait` and `--json`. `status` reports which processes are live and whether the backend and UI answer their health checks.

### Starting late or recovering

```bash
python3 scripts/pm_workbench.py status              # pidfile ~/.sitepulse/workbench.pid, health of :8080 and :9095
python3 scripts/pm_workbench.py serve               # only the Web UI, against an already-running backend
python3 scripts/pm_workbench.py seed F5 --json      # reseed from the terminal, no browser needed
python3 scripts/pm_workbench.py clock get           # current simulated date and time
```

The Web UI remembers the last prepared scenario in `~/.sitepulse/workbench-active.json`, so restarting the UI shows the same cheat sheet. The database, not the file, holds the scenario; **Reset Current Scenario** re-provisions the preset exactly as it was first prepared.

## 4. Reading the cheat sheet

| Field | What it means | How to use it |
| --- | --- | --- |
| Site name and id | `SitePulse PM Test <preset> <suffix>` (F10_GOVERNANCE uses `Begonya Sitesi`) | The id is what the site-scoped ledger checks and the CLI take |
| Simulated clock | The pinned Europe/Istanbul reference date | Compare every "days overdue" or "late fee" figure against this date, not today's date |
| Expected site totals | Blocks, units, people, accounts, periods, liabilities, receipts, overdue and advance in TRY | Exact-match assertions; `total_overdue` / `total_advance` are the dashboard figures |
| Unit-by-unit balances | Per unit `amount_due`, `advance_balance`, paid/overdue and, in capital presets, `capital_due` | The unit directory and the unit workspace must show these to the kuruş |
| Personas | Manager plus residents, each with role, unit, e-mail and password | Quick-launch or log in manually; passwords are dev-only and never exported |
| PM checklist | The two to six rules this preset exists to exercise | The actual test script; §5 repeats them per pack |

Every value is a decimal string, never a float. `1.522,50` in the product is `1522.50` here; the same amount must appear in both.

## 5. The six complexity packs

The gallery groups the presets into six packs. Prepare one preset at a time. Preparing another preset seeds a fresh site and makes it the active one; the previous site stays in the database but is no longer what the cheat sheet describes, so export the bug bundle first if you still need its evidence. Each subsection lists the reference clock, the expected site totals, the unit balances and the PM checklist exactly as the seeder reports them.

### Pack A — Onboarding (`F0`–`F3`)

What it proves: a site can grow from nothing to a ready-to-accrue period without inventing money.

| Preset | Label | Clock | Blocks | Units | People | Accounts | Periods | Overdue | Advance |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `F0` | Empty site | 2026-09-01 | 0 | 0 | 0 | 0 | 0 | 0.00 | 0.00 |
| `F1` | Structure only | 2026-09-01 | 1 | 7 | 0 | 0 | 0 | 0.00 | 0.00 |
| `F2` | Residents invited | 2026-09-01 | 1 | 7 | 7 | 7 | 0 | 0.00 | 0.00 |
| `F3` | Period opened, no residents | 2026-10-01 | 1 | 7 | 0 | 0 | 1 | 0.00 | 0.00 |

Unit balances are `0.00` due and `0.00` advance for every unit in all four presets; `F0` has no units at all. The structure is one block with seven units (`A-1` … `A-7`; `A-6` is the large flat).

- `F0` checklist
  - [ ] Verify clean site creation with no initial blocks or units
  - [ ] Test initial site wizard and block creation workflow
- `F1` checklist
  - [ ] Verify 7 units created in A Blok with assigned tariffs and land shares
  - [ ] Test resident invitation and vacancy assignment
- `F2` checklist
  - [ ] Verify resident accounts and credentials activated for 7 personas
  - [ ] Test resident login and profile navigation
- `F3` checklist
  - [ ] Verify period `Ekim 2026` created in OPEN status without prior residents
  - [ ] Test tariff calculation and accrual preview on unassigned units

### Pack B — Core dues and late fees (`F4`, `F5`, `F7`)

What it proves: accrual, payment allocation, advance balance, late fees and period closing agree with each other to the kuruş.

| Preset | Label | Clock | Periods | Liabilities | Receipts | Overdue | Advance |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `F4` | Single period with overdue dues | 2026-11-19 | 1 | 6 | 1 | 8,800.00 | 0.00 |
| `F5` | Three periods, advance balance | 2026-11-19 | 3 | 18 | 9 | 4,567.50 | 1,250.00 |
| `F7` | Closed historical period | 2026-11-19 | 3 | 18 | 9 | 4,567.50 | 1,250.00 |

**`F4` unit balances** — one open period, `Ekim 2026`:

| Unit | Type | Due | Advance | State |
| --- | --- | --- | --- | --- |
| `A-1` | Flat | 0.00 | 0.00 | Paid in full, receipt `TAH-2026-000001` |
| `A-2` | Flat | 1,600.00 | 0.00 | Overdue |
| `A-3` | Flat | 1,600.00 | 0.00 | Overdue |
| `A-4` | Flat | 1,600.00 | 0.00 | Overdue |
| `A-5` | Flat | 1,600.00 | 0.00 | Overdue |
| `A-6` | Large flat | 2,400.00 | 0.00 | Overdue |
| `A-7` | Flat | 0.00 | 0.00 | Paid / nothing owed |

**`F5` and `F7` unit balances** — three periods, `Eylül`, `Ekim` and `Kasım 2026`:

| Unit | Type | Due | Advance | State |
| --- | --- | --- | --- | --- |
| `A-1` | Flat | 0.00 | 0.00 | Paid |
| `A-2` | Flat | 1,522.50 | 0.00 | Overdue |
| `A-3` | Flat | 0.00 | 0.00 | Paid |
| `A-4` | Flat | 1,522.50 | 0.00 | Overdue |
| `A-5` | Flat | 1,522.50 | 0.00 | Overdue |
| `A-6` | Large flat | 0.00 | 1,250.00 | Paid, holds an operational advance |
| `A-7` | Flat | 0.00 | 0.00 | Paid |

`F7` is `F5` with `Eylül 2026` closed: the historical period becomes an immutable snapshot while `Ekim` and `Kasım 2026` stay active.

- `F4` checklist
  - [ ] Verify single period `Ekim 2026` with ₺8,800.00 total overdue
  - [ ] Verify A-1 paid in full (₺1,500.00) with verified receipt `TAH-2026-000001`
  - [ ] Test delay penalty calculation across overdue units
- `F5` checklist
  - [ ] Verify multi-period accruals (`Eylül`, `Ekim`, `Kasım 2026`) with ₺4,567.50 overdue
  - [ ] Verify unit A-6 holding ₺1,250.00 operational advance balance
  - [ ] Test FIFO allocation and advance balance utilization
- `F7` checklist
  - [ ] Verify historical period `Eylül 2026` is CLOSED with immutable snapshot
  - [ ] Verify `Ekim` and `Kasım 2026` remain ACTIVE
  - [ ] Test period re-open request and audit trail

### Pack C — Occupancy, sales and splits (`F6`)

What it proves: a unit whose occupants change over time keeps every month's liability with the right debtor, including a multi-debtor unit and a pro-rata split that needs a second approver.

| Metric | Value |
| --- | --- |
| Reference clock | 2026-11-19 |
| Periods | 3 (`Eylül`, `Ekim`, `Kasım 2026`) |
| People | 10 (owners, tenants and former occupants) |
| Liabilities / receipts | 23 / 0 |
| Overdue | 9,750.00 |

| Unit | Type | Due | Advance | State |
| --- | --- | --- | --- | --- |
| `A-1` | Flat | 1,500.00 | 0.00 | Overdue |
| `A-2` | Flat | 1,500.00 | 0.00 | Overdue, multi-debtor |
| `A-3` | Flat | 1,500.00 | 0.00 | Overdue |
| `A-4` | Flat | 1,500.00 | 0.00 | Overdue |
| `A-5` | Flat | 1,500.00 | 0.00 | Overdue |
| `A-6` | Large flat | 2,250.00 | 0.00 | Overdue |
| `A-7` | Flat | 0.00 | 0.00 | Paid / nothing owed |

Unit `A-2` carries three debtors over the three periods: owner Ahmet Yılmaz, former tenant Selin Demir and tenant Mert Kılıç.

- `F6` checklist
  - [ ] Verify changing occupancy lifecycle across three periods
  - [ ] Verify multi-debtor status on unit A-2 (Ahmet Yılmaz, Selin Demir, Mert Kılıç)
  - [ ] Test pro-rata dues split approval workflow with four-eyes reviewer

### Pack D — Capital expenditure (`F8_CAPITAL`)

What it proves: a capital project accrues installments to owners, keeps capital debt separate from operational dues, and can be funded by moving an operational advance across ledgers.

| Metric | Value |
| --- | --- |
| Reference clock | 2026-11-19 |
| Periods | 3 |
| Liabilities / receipts | 25 / 9 |
| Operational overdue / advance | 4,567.50 / 1,250.00 |
| Capital projects | 1 (`Exterior Facade Insulation`, budget 105,000.00) |
| Capital installments | 3, first accrued 35,000.00 (5,000.00 per unit × 7) |

Unit balances are the `F5` operational balances plus `capital_due = 5,000.00` on every unit:

| Unit | Operational due | Advance | Capital due |
| --- | --- | --- | --- |
| `A-1` | 0.00 | 0.00 | 5,000.00 |
| `A-2` | 1,522.50 | 0.00 | 5,000.00 |
| `A-3` | 0.00 | 0.00 | 5,000.00 |
| `A-4` | 1,522.50 | 0.00 | 5,000.00 |
| `A-5` | 1,522.50 | 0.00 | 5,000.00 |
| `A-6` | 0.00 | 1,250.00 | 5,000.00 |
| `A-7` | 0.00 | 0.00 | 5,000.00 |

- `F8_CAPITAL` checklist
  - [ ] Verify capital project `Exterior Facade Insulation` with ₺105,000.00 total budget
  - [ ] Verify 1st installment accrued (₺35,000.00) across 7 units (₺5,000.00 per unit)
  - [ ] Verify unit A-6 holds ₺1,250.00 operational advance ready for inter-ledger virman
  - [ ] Verify contractor `Özkan Yalıtım İnşaat A.Ş.` record ready for milestone disbursement
  - [ ] Test inter-ledger virman from operational advance to capital debt

### Pack E — Reconciliation and import (`F9_RECON`)

What it proves: a bank statement finds the right unit through its virtual IBAN, an ambiguous multi-debtor transfer lands in the unmatched queue instead of guessing, a duplicate transaction is idempotent, and a person import reports its bad rows.

| Metric | Value |
| --- | --- |
| Reference clock | 2026-11-19 |
| Periods | 3 |
| People | 11 (including one duplicate candidate) |
| Liabilities / receipts | 23 / 0 |
| Overdue | 9,750.00 |
| Virtual IBANs assigned | 7 |
| Duplicate candidates | 1 |

Unit balances are the `F6` balances: `A-1` … `A-5` at 1,500.00, `A-6` at 2,250.00, `A-7` paid. This is the preset to pair with the companion files in §8.

- `F9_RECON` checklist
  - [ ] Verify deterministic Virtual IBANs (TR…) assigned to all 7 units
  - [ ] Verify multi-debtor history on unit A-2 (owner Ahmet, former tenant Selin, tenant Mert)
  - [ ] Test bank statement import and automated reconciliation matching via Virtual IBAN
  - [ ] Identify duplicate candidate person in directory matching phone `+90 532 111 22 33`
  - [ ] Execute person-card merge into canonical record and verify historical ledger preservation

### Pack F — Governance and multi-site (`F10_GOVERNANCE`)

What it proves: a second site cannot leak into the first, severe arrears and a payment plan follow their own rules, and governance artefacts (heating cost split, general assembly) exist on a realistic state.

| Metric | Value |
| --- | --- |
| Reference clock | 2026-11-19 |
| Sites | 2 (`Begonya Sitesi` and `Kardelen Rezidans`) |
| Periods | 4 |
| Liabilities / receipts | 8 / 0 |
| Overdue | 11,600.00 |
| Severe arrears units | 1 |
| Active payment plans | 1 |
| Heat cost periods | 1 |
| Scheduled meetings | 1 |

| Unit | Type | Due | Advance | State |
| --- | --- | --- | --- | --- |
| `A-1` | Flat | 1,500.00 | 0.00 | Overdue |
| `A-2` | Flat | 3,350.00 | 0.00 | Overdue, includes 1,850.00 severe arrears from `Haziran 2026` |
| `A-3` | Flat | 1,500.00 | 0.00 | Overdue |
| `A-4` | Flat | 1,500.00 | 0.00 | Overdue, 3-installment payment plan |
| `A-5` | Flat | 1,500.00 | 0.00 | Overdue |
| `A-6` | Large flat | 2,250.00 | 0.00 | Overdue |
| `A-7` | Flat | 0.00 | 0.00 | Paid / nothing owed |

- `F10_GOVERNANCE` checklist
  - [ ] Verify multi-site tenant isolation between Begonya Sitesi and Kardelen Rezidans
  - [ ] Verify unit A-2 has severe >90-day arrears from Haziran 2026 (₺1,850.00 overdue)
  - [ ] Test legal dunning notice generation and collection case creation for severe arrears
  - [ ] Verify active 3-installment payment plan on unit A-4 with four-eyes approvals
  - [ ] Inspect heating meter readings and verify 70/30 consumption cost distribution
  - [ ] Review scheduled General Assembly meeting and agenda items for voting

## 6. Time Machine — testing time without waiting

The **Time Machine** bar moves the simulated Europe/Istanbul clock. Nothing is scheduled for later in the product; every due date, late fee, aging bucket and reminder reads this one clock, so moving it is how a manual session reaches next month.

| Control | What it does | When to use it |
| --- | --- | --- |
| `+1 Day` / `+10 Days` | Advances exactly 1 or 10 days (`advance_to`) | Walk an overdue unit across a boundary one day at a time |
| `Jump to Due Day (10th)` | Sets the 10th of this month, or of the next month if today is the 10th or later | Check the due-day transition and the first day a charge is overdue |
| `Jump to Month End` | Sets the last day of this month, or of the next month if already at month end | Check month-end accrual and aging |
| Custom date + `Set Date` | Sets any `YYYY-MM-DD` date | A specific date from a bug report or a calendar edge case (28–31, February) |
| `Run Scheduler Tick` | Runs the date-driven jobs (accruals, late fees, aging, reminders) at the current simulated time | After moving the clock: the tick is what materializes the jobs |

The bar reads the clock through `GET /api/clock` and writes through `POST /api/clock`; the CLI wraps the same backend endpoints:

```bash
python3 scripts/pm_workbench.py clock get
python3 scripts/pm_workbench.py clock advance 2026-11-29
python3 scripts/pm_workbench.py clock tick
python3 scripts/pm_workbench.py clock clear      # back to the real wall clock, not to the preset date
```

To return to the preset's reference date, prepare the preset again, or `python3 scripts/pm_workbench.py clock set 2026-11-19`.

**What to check after a jump.** The displayed amounts must still equal the API to the kuruş (invariant I9), a late fee must never start before the charge's effective due date (I11), and **Verify Ledger Health** must stay green. A late fee that appears at the old due date, or a total that changes only on one screen, is a defect worth a bundle.

## 7. Verify Ledger Health

Every prepared scenario can be checked against the twelve journey invariants. Click **Verify Ledger Health** in the active scenario, or run the same checks from a terminal:

```bash
python3 scripts/pm_ledger_health.py check --site-id <site id>          # scorecard
python3 scripts/pm_ledger_health.py check --site-id <site id> --json   # machine-readable
```

Five invariants run site-scoped SQL in PostgreSQL. The other seven need a GUI journey, a restart or a second approver, so they are reported as `MANUAL` together with the automated suite that covers them. **A `MANUAL` row is not a pass.**

| ID | Invariant | Checked by |
| --- | --- | --- |
| I1 | Debt components add up to the booked payment | SQL (paid amount = principal + fee, cancelled charges carry no money, allocations reconcile) |
| I2 | Site total equals the sum of unit balances | `MANUAL` — `e2e/tests/test_journey_accruals_payments.py` |
| I3 | Dashboard and workspace agree on the same debt | `MANUAL` — `e2e/tests/test_journey_financial_transitions.py` |
| I4 | Each payment is counted once and advances stay with their debtor | SQL (reversal links the settled original, advance balance equals its ledger net) |
| I5 | Period shares add up to the prorated tariff | `MANUAL` — `e2e/tests/test_journey_accrual_corner_cases.py` |
| I6 | Every collectible charge names one primary debtor | SQL (liable person present, occupancy belongs to the same unit) |
| I7 | Historical debt stays with its original debtor | `MANUAL` — `e2e/tests/test_journey_liability_changes.py` |
| I8 | Balances survive a backend restart | `MANUAL` — `e2e/tests/test_journey_fixtures.py` |
| I9 | Displayed amounts equal the API to the kuruş | `MANUAL` — `e2e/tests/test_journey_starting_states_gui.py` |
| I10 | Every financial row stays inside its own site | SQL (reconciliation queue, bank account and matched unit share one site) |
| I11 | Late fees and aging start at the effective due date | SQL (effective due date, late-fee segment start) |
| I12 | A title transfer moves no existing charge | `MANUAL` — `e2e/tests/test_journey_occupancy_changes.py` |

A red row names the failing ids and the remediation in the card. The card also lists every site-scoped row of `v_integrity_violations`, the same view the E2E teardown asserts is empty. On a freshly prepared preset, five `PASS`, seven `MANUAL` and zero violations is the expected result; anything else is either a real ledger drift or a stale seed, and a reset tells you which.

## 8. Companion test files

The **Companion test files** section produces files from the *active* scenario, so the virtual IBANs and unit numbers match the site under test. Pair them with `F9_RECON` for reconciliation and import work.

| File | Endpoint | Contents |
| --- | --- | --- |
| Bank statement (CSV) | `GET /api/companion/bank-statement?format=csv` | Four transactions: exact `A-1` payment of 1,500.00 (`TXN-20261115-001`), ambiguous `A-2` multi-debtor transfer of 800.00 (`TXN-20261115-002`, expected to land in the UNMATCHED queue), a duplicate of `TXN-20261115-001`, and an unknown virtual IBAN for 500.00 |
| Bank statement (MT940) | `GET /api/companion/bank-statement?format=mt940` | The same site's IBANs in SWIFT MT940 (`:20:`, `:25:`, `:28C:`, `:60F:`, `:61:`, `:86:`, `:62F:`) |
| Resident import (Excel `.xlsx`) | `GET /api/companion/resident-import.xlsx` | Header plus seven rows: five valid residents, one deliberately malformed row (`XYZ` block, `invalid-email`, `-5` land share, `not-a-number` dues), and one row that repeats the first resident's e-mail and the duplicate-candidate phone |

Expected outcomes:

1. **Exact match** — `TXN-20261115-001` settles unit `A-1` for 1,500.00 and produces a receipt; the ledger moves to paid.
2. **Ambiguous multi-debtor** — the `A-2` transfer is **not** auto-matched. It appears in the reconciliation queue as UNMATCHED (journey question Q11), and a manager must choose the debtor.
3. **Duplicate transaction id** — re-importing `TXN-20261115-001` must not create a second payment; the row is rejected as a duplicate. The site total is unchanged.
4. **Unknown virtual IBAN** — the 500.00 row stays unmatched and cannot be attached to any unit's ledger.
5. **Partial import** — the Excel import reports the malformed row and the duplicate e-mail, imports the valid rows, and leaves the rejected rows out of the directory. Nothing is half-written: a failed row must not create a person without a unit.

These files are generated, never hand-edited, and contain test data only.

## 9. Export Bug Bundle

When something is wrong, click **Export Bug Bundle** before resetting the scenario. The bundle is a Markdown file with:

- the preset, simulated clock, site name and id;
- the persona roster with e-mail addresses — **passwords are never exported**;
- the full ledger-health scorecard, including `MANUAL` rows and any `v_integrity_violations`;
- the pack checklist with its items;
- the correlated backend 4xx/5xx request fields (`request_id`, `trace_id`, `method`, `path`, `status`, `latency_ms`), de-duplicated by `request_id`;
- any notes you typed into the box.

Redaction is mandatory and applies to every exported value: e-mails, IBANs, Turkish id numbers, bearer tokens, passwords and API keys are masked before they reach the file, and free-text log messages (which may carry payer names) are dropped rather than parsed. The card offers **Copy to clipboard** and **Download .md**.

From a terminal, without the UI:

```bash
python3 scripts/pm_ledger_health.py bundle \
  --site-id <site id> --preset F5 --preset-label "Three periods, advance balance" \
  --site-name "<name from the cheat sheet>" --clock 2026-11-19 \
  --notes "A-6 advance shows 1,250.00 but the ledger card is empty" \
  --output /tmp/f5-bug.md
```

Attach the file to the issue and say which preset, which unit and which checklist item failed. The `request_id` values in the bundle are what support needs to find the same request in the server logs.

## 10. Personas you can sign in as

Every preset seeds a manager plus the reference residents. The cheat sheet in the browser is authoritative for the e-mail addresses and passwords of the scenario that is active; the table below records who exists and which unit each person covers, so you know which persona to use for a given check.

| Persona | Role | Unit | Present in |
| --- | --- | --- | --- |
| Site Manager (`Journey Manager`) | `SITE_MANAGER` | — | every preset, including `F0` and `F1` |
| Ayşe Kaya | `HOME_OWNER` | `A-1` | `F2`, `F4`–`F10_GOVERNANCE` |
| Selin Demir | `HOME_RESIDENT` (former tenant in `F6`) | `A-2` | `F2`, `F4`–`F10_GOVERNANCE` |
| Burak Şahin | `HOME_OWNER` | `A-3` | `F2`, `F4`–`F10_GOVERNANCE` |
| Ahmet Yılmaz | `HOME_OWNER` | `A-4` | `F2`, `F4`–`F10_GOVERNANCE` |
| Can Öztürk | `HOME_OWNER` | `A-5` | `F2`, `F4`–`F10_GOVERNANCE` |
| Deniz Arslan | `HOME_RESIDENT` | `A-5` | `F2`, `F4`–`F10_GOVERNANCE` |
| Elif Aydın | `HOME_OWNER` | `A-6` (the large flat) | `F2`, `F4`–`F10_GOVERNANCE` |
| Second Manager (Reviewer) | `SITE_MANAGER` | — | `F6`, `F9_RECON` |
| Ahmet Yılmaz (Duplicate) | `HOME_OWNER` | — | `F9_RECON` only |

Notes that decide a test:

- **`A-5` has two residents.** Can Öztürk is the owner and Deniz Arslan the resident; use them to check that operational dues follow the occupant while capital installments follow the owner.
- **`A-2` is the awkward unit.** In `F6` and `F9_RECON` it has three debtors across three periods (owner Ahmet Yılmaz, former tenant Selin Demir, tenant Mert Kılıç), which is why the `A-2` bank transfer must not auto-match.
- **`F6` and `F9_RECON` seed a second manager** so a four-eyes approval can be exercised with two real logins rather than one session approving itself.
- **`F9_RECON` seeds a duplicate person** (Ahmet Yılmaz twice) to exercise duplicate detection and merge.
- **Passwords are development-only.** They belong to a local stack behind a production guardrail; never copy them into an issue, a report or a bundle (the bundle redacts them anyway).

## 11. The 15-minute release smoke check

Run this before calling a build ready for a release demo or a stakeholder walkthrough. It is not a substitute for CI; it is the fastest way to find out that a build is not usable by a human. Budget 15 minutes.

**Minute 0–3 — start the stack**

```bash
cd apps/development-time/SitePulse
python3 scripts/pm_workbench.py up
python3 scripts/pm_workbench.py status          # backend and UI health must both be OK
```

- [ ] `http://localhost:9095` loads and the scenario gallery lists six packs
- [ ] `http://localhost:9090` loads the Flutter client and shows the login screen
- [ ] `status` reports the backend, Flutter Web and Workbench UI as running

**Minute 3–5 — prepare and trust the state**

- [ ] **Prepare F5 (Three periods, advance balance)** finishes and the cheat sheet shows clock `2026-11-19`, overdue `4,567.50`, advance `1,250.00`
- [ ] **Verify Ledger Health** shows five `PASS`, seven `MANUAL`, zero `v_integrity_violations`

**Minute 5–8 — money moves correctly**

- [ ] Sign in as the manager persona, open the dues workspace: `A-2`, `A-4` and `A-5` show `1,522.50` overdue, `A-6` shows an advance of `1,250.00`
- [ ] Sign in as a resident (quick-launch `A-2`), open the resident dues view: the same `1,522.50` appears, in the same format as the manager screen
- [ ] Record a payment for one overdue unit and confirm the receipt; the site overdue total drops by exactly the amount paid and the allocation is visible on the receipt

**Minute 8–11 — time and jobs**

- [ ] `+1 Day` then **Run Scheduler Tick**: no new charge is created and no late fee appears before the effective due date
- [ ] **Jump to Due Day (10th)** then **Run Scheduler Tick**: the tick completes without error and the dashboard totals still equal the API
- [ ] **Verify Ledger Health** is still green after the jump

**Minute 11–13 — files**

- [ ] Download the companion bank statement (CSV) and upload it in the reconciliation screen: `TXN-20261115-001` matches `A-1`, the `A-2` transfer lands UNMATCHED, the duplicate id is refused and the unknown IBAN stays unmatched
- [ ] Download the resident import (`.xlsx`) and import it: five rows accepted, the malformed row and the duplicate e-mail are reported and not written

**Minute 13–15 — evidence and shutdown**

- [ ] **Export Bug Bundle** produces a Markdown file with the roster, the scorecard and no passwords or plain IBANs
- [ ] `python3 scripts/pm_workbench.py down` stops everything (`--stop-db` also stops PostgreSQL)

A failure is a bug report, not a broken environment, when the cheat sheet numbers matched at minute 5 and the same step fails twice after a reset. Export the bundle first, then file it with the template in §12.

## 12. Reporting a defect

File an issue with the exported bundle attached and this body filled in:

```markdown
## What happened
<preset and pack, e.g. F5 / Pack B — Core dues and late fees>

## Expected
<the cheat-sheet value or checklist line that should have held, quoted exactly>

## Actual
<what the screen or API returned, quoted exactly, amounts to the kuruş>

## Steps
1. python3 scripts/pm_workbench.py up
2. Prepare F5, clock 2026-11-19
3. <exact click path>
4. <the step that broke>

## Evidence
- Bug bundle: <attached .md>
- Checklist item: <copy the line from §5>
- request_id / trace_id: <copy from the bundle's request table>
- Invariant: <the I-number that should have caught this, if any>
```

Two habits make the report actionable:

- **Quote money as the product shows it and as the API returns it.** `1.522,50` and `1522.50` are the same value in two notations; write both when they disagree, because that disagreement is invariant I9.
- **Name the invariant.** If the defect is a ledger rule, the row in §7 tells engineering which suite already claims to cover it — that is where the missing assertion goes.

## 13. Keeping this playbook true

Every number here is copied from code, and the browser cheat sheet is generated from that same code at run time. When the catalogue changes, this page must be regenerated, not edited from memory.

Sources of truth:

| What | Where |
| --- | --- |
| Preset labels, aliases, packs and the gallery | `scripts/pm_workbench_web.py` (`PACKS`, `PRESET_LABELS`, `PRESET_ALIASES`) |
| Reference clocks, expected totals, unit balances, checklists, personas | `scripts/pm_scenarios/seeder.py` (`REFERENCE_CLOCKS`, `EXPECTED_TOTALS`, `EXPECTED_UNIT_BALANCES`, `PM_CHECKLISTS`, `PERSONAS`) |
| Invariant IDs and their scope | `scripts/pm_ledger_health.py` (`INVARIANTS`) |
| Companion file contents | `e2e/support/bank_files.py` (`build_companion_statement_rows`, `DEFAULT_RESIDENT_IMPORT_ROWS`) |
| CLI surface | `python3 scripts/pm_workbench.py --help` and `python3 scripts/pm_ledger_health.py --help` |

Regeneration procedure:

1. Start a stack and prepare each preset, or read the values straight from the modules above with `python3 -c` (no stack needed for the catalogue).
2. Diff every table in §5, §7 and §10 against the source. A changed number in the source and not in this page is a documentation defect.
3. **The copies are checked.** `harness/tests/test_pm_playbook.py` parses the pack sections and their preset, unit-balance and metric tables, and fails when a pack, label, clock, total, unit balance or capital figure disagrees with `PACKS`, `PRESET_LABELS`, `REFERENCE_CLOCKS`, `EXPECTED_TOTALS` or `EXPECTED_UNIT_BALANCES`. A stale copy therefore fails the harness suite; fix the page, not the test.
4. Run the local gates before you push: `python3 -m unittest discover -s harness/tests` and `python3 scripts/run_tests.py --group lint --summary` (the same Python gate group CI runs; see [TEST_STRATEGY.md](TEST_STRATEGY.md) "Quality signals and gates").
5. Change this page in the same pull request as the catalogue change. A playbook that lags a preset by one PR is worse than no playbook, because a PM will assert the old total and file a false bug.

## 14. Where the manual lane stops

The manual lane is deliberately narrow. It does not:

- **prove a rule.** A manual pass on one site with one persona is one observation; the named scenario in `.specify/features/` is the evidence;
- **replace the automated journey suite.** The presets exist so a human can look at a realistic state, not so a human can re-run what `e2e/tests/test_journey_*.py` already asserts;
- **cover non-functional properties.** Performance, concurrency, restart safety and tenant isolation are proven by the suites named in [TEST_STRATEGY.md](TEST_STRATEGY.md), with the `MANUAL` rows of §7 pointing at the right one;
- **touch production.** The workbench refuses to start when `APP_ENV` or `ENVIRONMENT` is `production`, and it writes only to the local development database.

Use it to answer "can a person do this job on this build", and hand the answer back as a bug report or a green smoke result.
