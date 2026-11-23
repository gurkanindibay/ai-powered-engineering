# SitePulse mutation coverage and improvement plan

**Assessment date** 23 November 2026. **Code inspected** `b47d5802`. **Mutants measured** at `777f5eeb` in the [23 November nightly run](https://github.com/gurkanindibay/ai-powered-engineering/actions/runs/45156174074). The catalogue and mutation workflow were identical at those revisions. The test and product code differed.

## Measured coverage

The nightly run killed **56 of 58 curated mutants (96.6%)**. Both survivors concern owner-only capital dues. The four shard reports contain all 58 catalogue IDs, with 40 of 42 high-risk scenarios killed. Mutation score is kills divided by kills plus survivors. The score measures the sampled faults. The file counts below describe where the catalogue plants faults. Neither metric measures line, branch, or application-wide defect coverage.

| Layer | Mutants | Killed | Survived | Score | Files targeted |
| --- | ---: | ---: | ---: | ---: | --- |
| Rust | 40 | 39 | 1 | 97.5% | 10 of 136 Rust source files |
| Flutter | 10 | 10 | 0 | 100% | 3 of 117 Dart library files |
| Python harness | 6 | 6 | 0 | 100% | 3 scripts |
| PostgreSQL | 2 | 1 | 1 | 50% | 2 of 51 SQL migrations |
| **Total** | **58** | **56** | **2** | **96.6%** | **18 files** |

The shard JSON recorded zero scenario-level skips, timeouts, or unviable mutants. The Rust shard did skip the PostgreSQL suite for `MUT-RS-004` after its unit and integration suites passed. Of the 39 Rust kills, 35 came from unit tests and four required integration tests. Nine Flutter kills came from the focused money suite. The tenth, `MUT-FL-009`, required the full Flutter suite. The PostgreSQL kill, `MUT-DB-001`, produced explicit row-visibility assertion failures in [the accrual persistence tests](../../backend/tests/db_accrual_persistence_tests.rs).

The mutation workflow took about 24 minutes, with the Rust shard on the critical path. All four shard jobs completed and uploaded results. The strict aggregator marked the run failed because two mutants survived. Its step exited before publishing the consolidated artifact, so the table above was reconstructed from the four shard JSON files. The [first local assessment](mutation-testing-analysis.md) and this nightly run describe different revisions and suite availability. The older 35/55 score is historical.

## 1. Kill both capital-dues survivors

[PR #343](https://github.com/gurkanindibay/ai-powered-engineering/pull/343) adds the Rust and database regressions and reports that both targeted mutants were killed. The next complete nightly run can confirm the combined score.

| Mutant | Why the existing assertions miss it | Test and acceptance criteria |
| --- | --- | --- |
| `MUT-RS-004` | [The ledger unit test](../../backend/src/services/dues_ledger.rs) denies a tenant paying an **owner** capital liability. The debtor-type comparison already produces that denial. The changed expense-type check matters for an in-memory liability with both `TENANT` and `CAPITAL_DUES`. | Extend the existing unit test with that combination and assert that the ordinary tenant payer is denied. Retain the positive controls for owner capital and tenant operational dues. Baseline passes and the mutant is killed by `rust-unit`. |
| `MUT-DB-002` | The selected PostgreSQL tests passed when the [V12 check constraint](../../backend/migrations/V12__financial_and_tenancy_remediation.sql) was replaced by an unconditional check. Tests using only application-accepted rows can pass with either constraint. | In a migrated throwaway database, use direct SQL with otherwise valid, distinct fixture rows. Accept an owner capital row, then reject a tenant capital row with constraint name `chk_dues_capital_owner_only`. PR #343 covers those cases. An additional tenant operational control and an explicit SQLSTATE `23514` assertion would confirm the allowed tenant path and the error class. Use an ignored PostgreSQL test in a `db_*` target so `rust-db` executes it. Baseline passes and the mutant is killed by `rust-db`. |

Treat the Rust fixture as a defensive test of the in-memory rule and the SQL fixture as a test of the persistence invariant. Keep the explicit payment-on-behalf flow working as covered by [the capital payment feature](../../.specify/features/EPIC-09/STORY-09-06-tenant-pays-capital-on-behalf.feature) and [existing payment integration tests](../../backend/tests/payment_ledger_hardening_tests.rs).

Run each baseline and mutation pair from the SitePulse root in an isolated checkout. Use PostgreSQL credentials from the test environment for the DB pair.

```bash
python3 scripts/mutation_scenarios.py baseline --layer rust --id MUT-RS-004 --json
python3 scripts/mutation_scenarios.py run --layer rust --id MUT-RS-004 --strict --json
python3 scripts/mutation_scenarios.py baseline --layer db --id MUT-DB-002 --with postgres --json
python3 scripts/mutation_scenarios.py run --layer db --id MUT-DB-002 --with postgres --strict --json
```

After both fixes, expect 58/58 on the existing catalogue with a fresh passing baseline and all four nightly shards present. Preserve the failure evidence for both kills.

### Capital-dues database control follow-up

Issue #354 extends the PostgreSQL control with an allowed tenant operational-dues insert and checks both SQLSTATE `23514` and `chk_dues_capital_owner_only` for the rejected tenant capital-dues insert. On the local PostgreSQL service, the clean `rust-db` baseline passed, the targeted ignored integration test passed, and `MUT-DB-002` was killed by `rust-db` on `the_database_rejects_capital_dues_billed_to_a_tenant`. PR #355 adds two verification-reporting probes; the complete four-shard mutation run records the scenario count and score for its revision.

## 2. Close gaps in the catalogue

The 58 mutants cover 16 named areas. All Flutter scenarios target money formatting, input, or decimal decoding. The Python scenarios target linting and traceability. Neither the recently changed statement service nor its Flutter rendering is a mutation target. The catalogue targets two migrations, so PostgreSQL coverage needs particular care even after the current survivor is killed.

Add the following eight candidates in order. These are proposed probes with expected assertions. Several reuse existing tests, and their outcomes must be measured before deciding which assertions to add.

| Priority | Area | Faults to sample | First suite and assertion |
| --- | --- | --- | --- |
| High | Unit statements | Group open items under the current occupant instead of the liable person. Count joint liability twice in statement totals. | Rust integration, [statement access tests](../../backend/tests/statement_access_tests.rs). Use distinct former and current holders, assert exact due IDs per person, and reconcile principal, penalty, and joint totals. |
| High | Accrual persistence | Treat two spellings of the same billing month as distinct. Keep partial writes when an accrual batch fails. | PostgreSQL, [accrual atomicity tests](../../backend/tests/db_accrual_atomic_tests.rs). Check persisted row counts and links after the retry, and confirm a second site can accrue its own period. |
| High | Statement UI | Omit a former holder's section. Render a joint item twice for a person who has both owner and tenant sections. | Flutter, [payment widget tests](../../flutter/test/payments_phase3_test.dart). Assert distinct section labels, visible item counts, and exact displayed amounts from a multi-person response fixture. |
| Medium | Verification reporting | Report missing required suite evidence as a pass. Collapse failed cases into passed cases during aggregation. | Python harness, [case-result tests](../../harness/tests/test_ci_case_results.py) and [report tests](../../harness/tests/test_ci_test_report.py). Assert per-suite status, status totals, and the treatment of incomplete input. |

Start with one precise assertion per fault, using exact IDs, decimal amounts, or persisted row counts. Run each new mutant before writing a test to establish whether it already dies. If it survives, add the cheapest assertion that detects the fault. Record the original result, the clean baseline, and the rerun result. Commit one behaving probe per fault. Where two probes are equivalent under the supported inputs, document the equivalence before changing the catalogue. Future regression fixes should contribute a probe when the fault exposes a distinct invariant.

### Verification reporting probe results

For #349, the initial runs used the existing harness suite before adding focused assertions. Both `MUT-PY-007` (missing required gate evidence reported as passed) and `MUT-PY-008` (failed cases included in passed totals) survived. The clean `harness` baseline passed in 16 seconds. After adding assertions in `harness/tests/test_ci_case_results.py`, both mutants were killed by the `harness` suite. The focused case-result tests passed (13 tests); the full harness suite is the final verification gate.

## 3. Make nightly scores trustworthy and actionable

| Change | Evidence from the current implementation | Acceptance criteria |
| --- | --- | --- |
| Baseline each selected suite on the same revision and configuration | [The workflow](../../../../../.github/workflows/mutation-testing.yml) invokes `run` directly. [The runner](../../scripts/mutation_scenarios.py) treats a nonzero exit without known compile markers as a test failure, so a broken test setup can inflate kills. | A failing clean suite blocks scoring for that suite. Its affected cases are reported as unscored and retain diagnostics. A kill names the failing test or assertion where the test runner provides it. |
| Require complete shard evidence and publish it even on failure | [The aggregator](../../scripts/ci_mutation_report.py) warns on unreadable JSON, silently keeps the first duplicate ID, and can score the remaining data. The current upload step is conditional on earlier steps succeeding. | Missing shards, malformed payloads, duplicate or unexpected IDs, and missing required-suite evidence surface as incomplete runs. Publish JSON and Markdown with `if: always()` and keep a failing check for survivors, timeouts, unviable mutants, or incomplete evidence. |
| Run applicable PostgreSQL suites for unresolved Rust cases | The Rust shard omits `--with postgres` and the DB shard selects only `layer=db`. A future survivor with a `rust-db` fallback could pass every executed suite while that fallback is skipped. | Give DB-capable Rust cases an explicit PostgreSQL route or rerun only unresolved Rust IDs that require it. Record suite-level skips separately and derive one final outcome per ID. A DB kill retains the identity of its detecting test. |
| Keep pull-request runs focused | The normal PR workflow validates catalogue drift. The local `--changed` option matches exact target-file paths, so changes to tests, shared helpers, or runner wiring can select zero mutants. | Use exact-file selection for direct edits. For selected high-risk areas, explicitly map test, migration, or dependency changes to relevant IDs or areas. Keep the full scheduled run and compare runtime to the observed 24-minute baseline before broadening PR gating. |

Track **mutation score**, **scored IDs / expected IDs**, and **high-risk survivors** by layer. Include suite-level skips, timeouts, unviable results, and the fastest detecting suite in the report. Check for zero unexplained high-risk survivors, complete nightly evidence, and the eight new probes measured with their own baselines. A falling score after catalogue expansion can reflect a newly exposed gap and should be interpreted alongside the added IDs.

## Verification and limits

This assessment used CI shard artifacts and a source review. It did not rerun the complete mutation matrix on `b47d5802`. The local catalogue validator passed for 58 scenarios across six suites and the Python harness passed 244 tests. PR #343 reports the targeted survivor reruns. The catalogue expansion and workflow changes remain follow-up work.
