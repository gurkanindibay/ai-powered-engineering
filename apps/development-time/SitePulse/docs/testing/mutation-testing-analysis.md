# SitePulse mutation testing analysis

**Status** — First run, 20 November 2026 · revision `3c481b2e` (master) plus this change

## Why mutation testing

SitePulse reports test *counts* and scenario *traceability*, but neither says whether a test would fail if the code were wrong. The [coverage assessment of 10 November](test-coverage-assessment-2026-11-10.md) records that no line or branch coverage exists, and coverage would not answer the question either: a line can be executed by a test that asserts nothing about it.

Mutation testing answers it directly. Plant one small, realistic bug (a *mutant*) in production code, run the tests, and see whether they fail:

- **killed** — a test failed, so the tests guard that behaviour;
- **survived** — every test still passed, so that behaviour can break without anyone noticing.

The **mutation score** is killed ÷ (killed + survived). Mutants that do not compile (*unviable*) and suites that could not run (*skipped*) are kept out of the score.

## Approach: hand-designed scenarios, not blind operators

Generic tools (`cargo-mutants`, `mutmut`) produce thousands of mechanical mutants, many of them equivalent or irrelevant, and need hours per run on a backend of this size. They are also not installed here. This first pass uses a **curated catalogue**: each scenario is a single bug a developer or an AI agent could plausibly write, chosen where a defect would cost money, leak data across tenants, or let a gate pass falsely. Each scenario records:

| Field | Meaning |
| --- | --- |
| `id` | `MUT-<layer>-nnn` |
| `layer` / `area` | `rust`, `flutter`, `db`, `python` / functional area (`late-fee`, `tenancy`, …) |
| `operator` | the kind of change: `relational-boundary`, `rounding-strategy`, `remove-guard`, `swap-order`, … |
| `risk` | business impact if the bug shipped: `high`, `medium`, `low` |
| `original` → `mutant` | exact text replaced; `original` must occur exactly once in the file |
| `intent` | the bug in plain words, e.g. "a tenant may pay owner-only capital dues" |
| `suites` | test suites to run, cheapest first; the first failure kills the mutant |

- Catalogue: [`harness/mutation/scenarios.toml`](../../harness/mutation/scenarios.toml).
- Runner: [`scripts/mutation_scenarios.py`](../../scripts/mutation_scenarios.py). It supports `list`, `validate`, `baseline`, `run` and `restore`, plus `--json`.
- Drift guard: [`harness/tests/test_mutation_scenarios.py`](../../harness/tests/test_mutation_scenarios.py) fails when production code changes under a scenario, so the catalogue cannot go stale silently.

### Suites

| Suite | Command | Needs |
| --- | --- | --- |
| `rust-unit` | `cargo test --locked --lib` (in-module `#[cfg(test)]` tests) | — |
| `rust-integration` | `cargo test --locked --test '*'` (`backend/tests/*.rs`; the `db_*` tests are `#[ignore]` and skipped) | — |
| `rust-db` | `cargo test --locked --test 'db_*' -- --ignored --test-threads=1` (throwaway databases) | PostgreSQL |
| `flutter-money` | `flutter test` on the money format, design-system, reusable-components and financial-fixture tests | — |
| `flutter-all` | `flutter test` | — |
| `harness` | `python3 -m unittest discover -s harness/tests` | — |

A Rust mutant runs `rust-unit` first and `rust-integration` only if it survives, so **Killed by** in the results shows the cheapest layer that catches each bug. Four tenancy/capital-dues scenarios also list `rust-db` last; it runs only with `--with postgres`.

Every suite passed unmutated before the run (baseline). Each surviving mutant was checked to have run, and passed, every suite it names; each Flutter kill was checked to be an assertion failure, not a compile error.

## Results

| Layer | Scenarios | Killed | Survived | Other | Score |
| --- | ---: | ---: | ---: | --- | ---: |
| Rust backend | 40 | 22 | 17 | 1 timeout | **56%** |
| Flutter | 10 | 9 | 1 | — | **90%** |
| Python harness gates | 6 | 4 | 2 | — | **67%** |
| Database (PostgreSQL) | 2 | — | — | 2 skipped | n/a |
| **All** | **58** | **35** | **20** | 1 timeout, 2 skipped | **64%** |

The headline: **money arithmetic is well guarded, the rules around it are not.** Rates, rounding, day counts, FIFO/penalty ordering, IBAN check digits, journal balancing and Flutter money parsing kill their mutants, mostly at the unit layer within seconds. What survives are guards and boundaries: who may pay what, what a negative or out-of-range input does, and almost every authentication and tenant-isolation check that runs without PostgreSQL.

### Rust backend — 22 / 39 scored (56%)

| Area | Killed | Survived | Survivors |
| --- | ---: | ---: | --- |
| Late fees | 6 | 1 | RS-018 (RS-016 timed out) |
| Allocation waterfall | 3 | 1 | RS-010 |
| Unit state machine | 2 | 0 | — |
| Double-entry | 3 | 1 | RS-024 |
| Dues ledger | 3 | 3 | RS-001, RS-004, RS-006 |
| Identifiers (IBAN, VKN) | 2 | 2 | RS-029, RS-030 |
| Proration | 1 | 3 | RS-020, RS-021, RS-022 |
| Tenancy | 2 | 3 | RS-034, RS-036, RS-037 |
| Authentication | 0 | 3 | RS-031, RS-032, RS-033 |

Where kills happen: 18 of the 22 at `rust-unit` (seconds), 4 only at `rust-integration` (RS-002 cancelled principal, RS-008 FIFO order, RS-012 rounding strategy, RS-015 grace end in re-evaluation). The integration suite rescued 4 mutants the unit tests missed and caught nothing else, so **gaps are not covered by "it is tested end-to-end somewhere"**.

**RS-016 (timeout)**: changing `payments[index].0 <= cursor` to `<` makes `penalty_through_with_grace` loop forever on a payment dated on the cursor. The suite hung until the 900 s timeout. That is detection in practice (CI would time out), but no test fails *fast*; a bounded loop or a test with its own timeout would turn a 15-minute hang into a clear failure.

### Flutter — 9 / 10 (90%)

All high-risk parsing and formatting mutants die in `flutter-money` within 5 s: rounding vs truncation, thousands grouping, Turkish `1.423,33` parsing, the 1000× `1.423` regex, zero and sub-kuruş validation, the malformed-decimal log, and the sign position. **FL-009** (an explicit fallback overriding a valid API amount) was caught only by the full suite (one test outside the money files), so it is thinly guarded. **FL-007** survived: `formatSigned(0)` is never asserted.

### Python harness gates — 4 / 6 (67%)

- **PY-002 survived**: the secret scanner's entropy threshold can rise from 3.5 to 4.5 unnoticed. The only synthetic secret in the tests has entropy ≈ 4.9; no test sits near the threshold.
- **PY-003 survived**: `tenant_isolation_lint` can accept *every* `AuthzContext` handler. Its tests cover `TenantScope`/`Claims` signatures but have no `AuthzContext` case, scoped or unscoped. A gate that protects tenant isolation has an untested branch.
- Killed: the 20-character secret length, the `@linked`-needs-`covers:` rule, duplicate scenario ids, and worst-status aggregation.

### Database — not run

MUT-DB-001 (row-level security `USING (TRUE …)`) and MUT-DB-002 (capital dues billable to tenants at the schema level) need PostgreSQL. The `rust-db` suite builds throwaway databases from the migrations; running it needs `DB_PASS`, which this run did not have. Run them with:

```bash
DB_PASS=... python3 apps/development-time/SitePulse/scripts/mutation_scenarios.py run --with postgres --layer db --id MUT-RS-004 --id MUT-RS-034 --id MUT-RS-036 --id MUT-RS-037
```

RS-004, RS-034, RS-036 and RS-037 are included because the DB tests (`db_tenant_isolation_tests`, `payment_ledger_hardening_tests`) are the most likely place they are covered today. If they are killed there, the gap is narrower — but those tests run only in the `rust-db-test` gate, never in a plain `cargo test`.

## Survivors, by risk

Each survivor is a concrete missing assertion. "Test to add" names the smallest test that would kill it.

### High risk

| ID | Bug that goes unnoticed | Test to add |
| --- | --- | --- |
| RS-036 | `AuthzContext::require` grants every action once the caller holds *any* permission | Unit test: context with only `ResidentRead` calling `require(Permission::RoleGrant, own_site)` → `Forbidden` |
| RS-037 | `require` skips the site check: cross-tenant actions with a valid permission | Unit test: context for site 1 calling `require(p, "2")` → `NotFound`; HTTP test of a role grant to another site's user |
| RS-034 | `TenantScope::allows` accepts an empty site claim | Unit test: `TenantScope::site("").allows("")` and `.allows("0")` are false |
| RS-031 | Access tokens with a lifetime above 10 minutes are accepted | Unit test: sign a token with `exp - iat = TOKEN_TTL_SECONDS + 1` using the test secret → `verify_token` errors |
| RS-033 | An unsalted SHA-256 digest becomes a usable plaintext password | Extend `passwords_only_verify_against_argon2`: `legacy_plaintext(&"a".repeat(64))` is `None` |
| RS-004 | A tenant may settle owner-only capital dues | Unit test on `payer_may_settle`: tenant + `CapitalDues` liability → false (currently no test calls it) |
| RS-001 | Overpaid principal goes negative and offsets other debt | Unit test: `paid_principal > principal_amount` → `outstanding_principal` is zero |
| RS-018 | A paid liability is re-evaluated and accrues a new late fee | Unit test: `calculate_delay_penalty` on a `Paid` liability months later leaves penalty and status unchanged |
| RS-020 | Owner and tenant shares are rounded separately and drift from the month total | Property-style test: for every split day in 28/30/31-day months, shares sum to the prorated total (pick amounts with a half-kuruş remainder, e.g. 1000.00 over 31 days) |
| RS-022 | With proration off, an unoccupied day is billed to the tenant | Unit test: proration disabled, no span covering `accrued_on` → share is `Owner` |

### Medium and low risk

| ID | Bug | Test to add |
| --- | --- | --- |
| RS-006 | A negative settlement reduces what was paid | `settle(d, -100)` returns zero and leaves `paid_*` unchanged |
| RS-010 | A reversal on the due date marks the liability OVERDUE | `unsettle` with `today == due_date` → `Pending` |
| RS-021 | A negative monthly amount is prorated instead of rejected | `split_monthly_dues(-1, …)` → `NegativeAmount` |
| RS-024 | Sub-kuruş debit precision accepted in journals | `validate_entry` with a `10.005` debit → `LineAmount` |
| RS-029 | IBANs over 26 characters reach the checksum | `Iban::parse` of a valid IBAN plus `"0"` → `NotTurkish` (or a length error) |
| RS-030 | Any 10-digit number accepted as VKN | `TaxId::parse` on a 10-digit number with a wrong check digit → `Checksum` (only TCKN checksums are tested now) |
| RS-032 | A password of exactly 10 characters is rejected | `validate_new_password` on a 10-char and a 9-char password |
| PY-003 | Tenant lint accepts unscoped `AuthzContext` handlers | Fixture handler taking `AuthzContext` with no `require`/claims use → flagged |
| PY-002 | Secret entropy threshold can drift | Two fixtures straddling 3.5 bits (e.g. 24 chars from a 10-letter alphabet vs. 24 distinct chars) |
| FL-007 | Zero movement shown as `+₺0,00` | `formatSigned(Decimal.zero) == '₺0,00'` |

## Patterns behind the gaps

1. **Boundary tests stop at the happy side.** 7 of the 20 survivors are `<` vs `<=`, a removed clamp, or a missing negative-input check. The tests exercise typical values, rarely the exact limit or a value just past it.
2. **Guards are tested through the path that passes them.** `payer_may_settle`, `TenantScope::allows`, `AuthzContext::require` and `verify_token`'s TTL check are exercised only by callers that are allowed through. No test asserts the *refusal*.
3. **Security checks lean on the DB suite.** Without PostgreSQL, removing the permission check or the site check in `require` changes no test result. Those tests are `#[ignore]` by default, so the fast feedback loop most agents use (`cargo test`) cannot see tenancy regressions.
4. **Rounding is asserted on totals, not on parts.** Rate and rounding-strategy mutants die, but independent rounding of two shares (RS-020) survives because no test checks that the parts add up.
5. **Gates are tested less than the product.** Two of six harness mutants survived; both weaken a security gate. A green gate is only as trustworthy as its own tests.

## Recommendations

1. **Write the ten high-risk "test to add" rows first** (authorization, tenancy, auth, capital dues, proration residual). Each is a small unit test; together they would lift the Rust score from 56% to about 80%.
2. **Make one non-DB HTTP test per tenancy guard.** The in-memory `AppState` used by `integration_tests.rs` is enough to send a request for a foreign site and assert a 404/403, so the checks are verified on every `cargo test`, not only in `rust-db-test`.
3. **Bound the late-fee segment loop** (or give the re-evaluation tests a timeout) so RS-016-style bugs fail in seconds instead of hanging CI.
4. **Run the DB layer** (`--with postgres`) where `DB_PASS` is available and record the result here.
5. **Re-run after each fix**: `mutation_scenarios.py run --id <ID>` must report `killed`. Re-run a whole area (`--area tenancy`) when its code changes; a full run takes about 40 minutes (Rust ≈ 30 s per mutant, Flutter 5–36 s, Python 4 s).
6. **Grow the catalogue with each defect.** When a bug escapes to review or production, add the scenario that reproduces it before fixing; it then guards the fix.
7. **Later: sample with a generic tool.** Once the curated survivors are fixed, a time-boxed `cargo-mutants --file src/services/dues_ledger.rs`-style run on one module at a time would find mutants this hand-made list does not imagine.

## Limits

- 58 scenarios are a sample chosen by risk, not an exhaustive mutation of the code base; the score describes these behaviours only.
- RS-025 is near-equivalent (the entry is still rejected, by another rule) and was killed anyway because the tests assert the error kind.
- The GUI end-to-end suite was not used as a killing suite: at ≈12 minutes per run it is too slow per mutant. The scenarios here all have faster tests that should catch them.
- Results are from one machine at one revision; scenario drift is caught by the harness test, but results are not re-recorded automatically.
