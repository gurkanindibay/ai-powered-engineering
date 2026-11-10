# Test Coverage Assessment — 2026-11-10

## Executive assessment

The repository has broad test activity across unit, integration, widget, browser, financial fixture, security, and harness layers. The evidence does **not** support a numeric statement such as “X% code coverage”: none of the reviewed suites emitted line/branch coverage reports during this assessment, and the test projects do not establish a repository-wide coverage threshold. Coverage is therefore assessed as **case/behavior coverage**, using test declarations, runner mappings, traceability records, and recent execution results.

Overall assessment: **mixed, with important unverified behavior**. Small runtime and DevFactory suites are fast and green. SitePulse has the broadest checks, but its local full gate could not complete because the filesystem ran out of space. Its latest documented browser run (2026-11-07) covers all 83 catalogued GUI scenarios, while only 53 of 96 executions passed normally; 43 are expected failures, including 28 scenarios whose requested behavior is not confirmed. About 20 UI features have no scenario. The project’s own status page marks all 25 requirements and all 25 task DAG nodes UNVERIFIED pending current CI evidence.

## Scope and evidence

Assessment covered `apps/runtime/AuditGuard`, `apps/runtime/TaskPilot`, `factory/DevFactory`, and `apps/development-time/SitePulse` (Rust backend, Flutter, Python harness, and browser E2E). Test counts below are test declarations or runner output, not unique requirements, and should not be summed as a single “coverage percentage.”

Execution was performed locally on 2026-11-10. The three .NET suites and SitePulse harness suite passed. SitePulse gates were attempted with DB and GUI explicitly skipped; Rust build, Clippy, Rust tests, money fixtures, Flutter analyze, and Flutter tests failed to start/finish because the filesystem had no space during compilation/tool setup. Those are **inconclusive infrastructure failures**, not evidence that those tests fail functionally. Database/API/schema and GUI gates were explicitly skipped in that run.

## Case coverage

| Area | Case evidence | Assessment |
|---|---:|---|
| AuditGuard | 12 tests, all passed; test files cover graph execution, loop control, arithmetic verification, and policy checks | Good focus on core runtime safety paths. Small suite; no instrumentation or demonstrated coverage for all CLI/agent/harness paths. |
| TaskPilot | 13 tests, all passed; domain item, JSON repository, and service workflow | Reasonable unit/workflow coverage for core task behavior; integration and failure-mode breadth is unclear. |
| DevFactory | 15 tests, all passed; agent, diagnostics, graph, AST gate, and workspace sandbox | Good coverage of selected factory primitives. No evidence here of end-to-end factory runs or broad failure/recovery behavior. |
| SitePulse harness | 88 Python unit tests, all passed in 1.433s | Strong regression coverage for harness and static-lint rules, but these tests validate tooling more than user-facing product behavior. |
| SitePulse backend / Flutter | Runner and source inventory show extensive Rust integration/unit and Flutter widget/domain suites; current run could not execute due to disk exhaustion | Potentially broad, but current functional status is unknown until rerun with adequate disk. |
| SitePulse GUI | 83/83 catalogued scenarios have a test, from 94 functions / 96 executions in the 2026-11-07 report | Catalogue traceability is strong. Effective behavior confirmation is weaker: 53 expected passes, 43 xfails; 28 scenarios are xfail-only. |

The GUI gap report also identifies roughly 20 existing UI features with no scenario. Examples include card payment/3-D Secure, manual cash recording, house-type create/delete, capital-project validation, household-member edit/delete, and bank reconciliation entry points. It reports only Chrome desktop coverage, with 375px mobile limited to a smoke test; accessibility assertions, large-dataset performance, browser concurrency, and input-hardening checks are absent.

## Performance

| Suite / run | Observed time | Interpretation |
|---|---:|---|
| AuditGuard .NET | 5.3s wall; 42ms reported test duration | Fast feedback; wall time includes build/test startup. |
| TaskPilot .NET | 2.8s wall; 78ms reported test duration | Fast feedback. |
| DevFactory .NET | 4.0s wall; 144ms reported test duration | Fast feedback. |
| SitePulse harness | 1.433s for 88 tests | Excellent unit-test feedback speed. |
| SitePulse gate run | 96.4s before completion | Not a valid full-suite timing: compilation exhausted disk and stopped remaining gates. |
| SitePulse GUI, documented 2026-11-07 | About 12 minutes for 96 executions | Slow feedback; CI/nightly execution is recommended by the project’s gap report. |

No product runtime/load benchmark was performed. The GUI report explicitly records no large-dataset or load-time checks, so test-suite speed should not be mistaken for application performance evidence.

## Effectiveness and quality signals

**Positive signals**

- Runtime tests focus on deterministic math/policy controls and typed workflow behavior, matching the safety-critical domain.
- SitePulse has cross-language financial fixtures and dedicated security, tenant-isolation, ledger-hardening, and integration suites in its declared test plan.
- The harness includes traceability validation and marks requirements UNVERIFIED unless CI records current evidence; this avoids claiming completion from static or stale checks.
- The GUI test design uses strict xfails to keep known defects visible rather than silently treating those behaviors as verified.

**Limits and risks**

- No line/branch coverage data was generated, so unexecuted code cannot be quantified.
- SitePulse’s latest local full check is inconclusive due to disk exhaustion. PostgreSQL-dependent and GUI checks were skipped in that run.
- The latest detailed GUI evidence is dated 2026-11-07 and should be refreshed after product or test changes. It reports 28 xfail-only scenarios and numerous defects/missing features; “all scenarios have a test” overstates functional coverage if interpreted as passing behavior.
- The GUI report lists no browser accessibility checks, no broad mobile run, no UI input-hardening checks, no two-user browser concurrency, and no large-dataset performance checks.
- SitePulse `COMPLETION_STATUS.md` says all 25 RTM requirements and all 25 task DAG nodes remain UNVERIFIED until CI evidence is recorded. It also documents that prior 100% completion claims were invalidated.
- The repository test plan describes change-driven selection and targeted gates, but this assessment did not test whether every change-to-gate mapping is complete.

## Recommendations

1. Restore adequate disk space, then rerun `python3 apps/development-time/SitePulse/scripts/run_tests.py` with PostgreSQL available; record each pass, failure, and skip. Do not count skipped gates as passed.
2. Prioritize converting the 28 GUI xfail-only scenarios to passing behavioral tests as defects are fixed; add scenarios for the untested money, capital, household, and reconciliation workflows.
3. Add coverage instrumentation and publish per-project line and branch coverage baselines. Set thresholds only after establishing representative baselines; use changed-code coverage for incremental enforcement.
4. Add performance checks for representative API latency and large portfolios, and accessibility/input-hardening checks at the UI/API boundary.
5. Run the GUI smoke suite in CI and the full 12-minute browser suite nightly or on release candidates; refresh traceability and xfail totals from current execution results.

## Reproduction commands

```text
dotnet test apps/runtime/AuditGuard/tests/AuditGuard.Tests --nologo --verbosity quiet
dotnet test apps/runtime/TaskPilot/tests/TaskPilot.Tests --nologo --verbosity quiet
dotnet test factory/DevFactory --nologo --verbosity quiet
python3 -m unittest discover -s apps/development-time/SitePulse/harness/tests
python3 apps/development-time/SitePulse/scripts/run_tests.py --skip-db --skip-gui --summary
```

The last command is included to reproduce the constrained local attempt; use the full runner with the configured test database for complete product verification.
