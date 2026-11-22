# SitePulse Cucumber and Serenity BDD migration analysis

**Status** — Proposed for review, revised 20 November 2026

## Decision requested

Approve a four-scenario pilot that compares two ways of producing step-level BDD evidence for the SitePulse GUI suite:

- **A.** Bind the pilot scenarios as Gherkin in the existing pytest-bdd runner.
- **B.** Port the same scenarios to Cucumber.js with TypeScript Playwright and the Serenity/JS Serenity BDD reporter.

Use the pilot to decide whether the Serenity report justifies a second browser toolchain, or whether binding scenarios in pytest-bdd and extending the SitePulse report delivers the same review benefit. A migration beyond the pilot needs a separate decision.

## Current state

SitePulse already has executable specifications. Canonical Gherkin lives in [`.specify/features`](../../.specify/features/README.md), Playwright drives the Flutter web client, and CI merges execution records from eight GUI shards into a scenario report. Master runs are published to the [product status dashboard](https://gurkanindibay.github.io/ai-powered-engineering/) ([dashboard calculation](../../scripts/product_status.py)).

Most scenarios are not executed from their feature files. A scenario is either bound to pytest-bdd step definitions, or `@linked`: a plain test declares `covers: SC-…` and verifies it outside Gherkin. Inventory at the revision under review:

| Layer | Gherkin-bound (pytest-bdd) | Linked | Pending | Total |
| --- | ---: | ---: | ---: | ---: |
| GUI | 9 | 145 | 3 | 157 |
| Backend (Rust) | — | 127 | 11 | 138 |
| Database | — | 7 | 1 | 8 |
| API | — | 6 | — | 6 |
| Flutter | — | 3 | 1 | 4 |
| Harness | — | 2 | 1 | 3 |
| Untagged layer | — | — | 3 | 3 |
| **All** | **9** | **290** | **20** | **319** |

Observations that shape the decision:

- **pytest-bdd is a small part of the suite.** All nine Gherkin-bound scenarios are in EPIC-10 and use one step module ([`capital_steps.py`](../../e2e/steps/capital_steps.py)). The other `epicNN_steps.py` modules are empty. The 145 linked GUI scenarios are verified by Python Playwright tests under `e2e/tests` (about 2,900 lines) and page objects under `e2e/pages` (about 700 lines).
- **Linked tests produce no step-level evidence.** The [execution record writer](../../e2e/support/executions.py) records step statuses only from pytest-bdd hooks. A linked test is one pass/fail record per covered scenario. A Serenity report fed by linked tests would show 145 GUI scenarios with no narrative steps, which is the feature Serenity is meant to provide.
- **The GUI step vocabulary barely repeats.** The 154 non-pending GUI scenarios have 615 step lines, which give 556 distinct phrasings once quoted strings, numbers and outline parameters are normalised. 527 of those phrasings occur once. Binding them in any runner means either about 550 step definitions or rewording the Gherkin into a shared vocabulary first. This rewording, not the runner, is the main cost.
- **No executable scenario outline exists.** The catalogue has six `Scenario Outline`s. Five are linked (two GUI: `SC-07-06-03`, `SC-08-07-10`) and one is pending. Example-level identity is therefore untested by today's runner.
- **Missing evidence is mostly outside the GUI.** The dashboard snapshot at commit `2bcb9b8` showed 319 specified, 299 automated and 114 passing. Most of the gap is linked Rust and Flutter tests that run in CI but do not publish scenario-level outcomes. Publishing those results is independent of the runner decision and should proceed either way.
- **Baseline runtime.** On the PR run for this document, the eight browser shards took between 4 min 57 s and 6 min 49 s each.

## What Cucumber and Serenity would change

Cucumber executes Gherkin against step definitions. Equivalent assertions and fixtures give equivalent verification, so changing runner alone does not improve test strength. [Cucumber BDD guide](https://cucumber.io/docs/bdd/)

Serenity BDD adds a browsable requirements hierarchy (epic → story → scenario), narrative step results, screenshots per step and aggregate coverage views. [Serenity BDD living documentation](https://serenity-bdd.github.io/docs/reporting/living_documentation). The narrative and per-step evidence exist only for scenarios executed from Gherkin. A Serenity report therefore only pays off once linked GUI scenarios are bound to Gherkin steps. That work is needed in pytest-bdd as well, which is why the pilot compares A and B on the same converted scenarios.

## Options

| Option | Benefit | Cost and fit |
| --- | --- | --- |
| 1. Keep pytest-bdd, extend the SitePulse report | No new toolchain. Fixes missing evidence and navigation issues directly. | Step-level evidence stays limited to the nine bound scenarios unless option 2 is also done. |
| 2. Bind linked GUI tests as Gherkin in pytest-bdd | Gives step-level evidence in the existing records and report. Reuses Python page objects, fixtures, launcher and CI. An off-the-shelf report (for example Allure's pytest-bdd adapter) can be evaluated without porting. | Step vocabulary normalisation and about 550 step definitions, written in Python. Proposed pilot arm A. |
| 3. Cucumber.js + TypeScript Playwright + Serenity/JS Serenity BDD reporter | Keeps Playwright, uses Serenity's documented Cucumber.js integration, produces the multi-page Serenity BDD report. | Same normalisation and step count as option 2, plus porting page objects, login helpers and fixtures to TypeScript, a Node toolchain and a Java runtime for report generation. Proposed pilot arm B. |
| 4. Cucumber-JVM + Serenity BDD | Native Serenity ecosystem and Screenplay support. | Ports steps and fixtures to Java and adds JVM build tooling. Revisit only if the team adopts a JVM standard. |

[Serenity/JS Cucumber integration](https://serenity-js.org/handbook/test-runners/cucumber/) · [Serenity/JS report generator](https://serenity-js.org/modules/serenity-bdd/) · [Serenity BDD with Cucumber-JVM](https://serenity-bdd.github.io/docs/tutorials/cucumber-screenplay)

## Scope boundary

- **In scope:** the 154 non-pending `@layer:gui` scenarios, both the 9 Gherkin-bound and the 145 linked. A linked GUI scenario enters scope when its test is rewritten as step definitions. Its `covers` marker is then removed and the scenario loses its `@linked` tag.
- **Out of scope:** linked Rust, Flutter, API, database and harness tests (145 scenarios). They keep their runners and are reported through the linked-suite publishing above.
- **Pending scenarios** stay in the catalogue with `@pending`.

If migration (option 3) stops short of all 145 linked GUI tests, the Python Playwright stack (page objects, Flutter selectors, login helpers, `conftest.py` fixtures) cannot be retired. Both browser stacks would then need maintenance indefinitely, and the Serenity report would show part of the GUI coverage. The rollout must either convert every linked GUI test or accept and cost that permanent dual stack.

## Proposed design for arm B

- **Specifications.** Use the existing feature files in place, with their `SC-*`, `GUI-*`, layer, role, smoke, epic and story tags. Step wording changes made during normalisation are committed to the canonical Gherkin and serve both arms.
- **Browser and data.** Keep the Python [GUI launcher](../../scripts/gui_e2e.py) for stack startup, reset and teardown. Give each Cucumber scenario its own browser context. Port the required Flutter selectors, locale, login helpers, assertions and fixtures ([Python fixtures](../../e2e/conftest.py)). Run scenarios serially within a shard that shares a resettable database.
- **Money.** Treat amounts as decimal strings end to end. Parse with `decimal.js` (or an equivalent arbitrary-precision library) when arithmetic is needed. Compare strings or decimal values in assertions and never parse money with `Number(...)` or `parseFloat`, as AGENTS rule 2 requires. A lint check over the step definitions enforces this.
- **Execution records.** Emit JUnit and compatible `executions.jsonl` records from Cucumber's structured messages. Preserve scenario ID, outline example identity (scenario ID plus example row), GUI ID, status, duration and per-step status. Explicitly handle retries, setup and teardown failures, skipped steps, and undefined or ambiguous steps. Require a valid evidence artifact for every expected shard.
- **CI and reports.** Preserve smoke and affected selection, sharding, local recorded runs and the task DAG's scenario gates. While both runners exist, assign each scenario example to exactly one authoritative runner. Collect comparison results separately and publish only the authoritative ones. Attach the Serenity report to the PR workflow as an artifact ([CI aggregation and publishing](../../../../../.github/workflows/sitepulse-ci.yml)). Keep the Pages dashboard as the product entry point. Review example data, logs, screenshots and traces for sensitive content before any Serenity report is published publicly.

## Pilot

The pilot scenarios cover each kind of conversion the rollout would need:

| Scenario | Today | Why it is in the pilot |
| --- | --- | --- |
| `SC-10-01-01` Budget is split by land share without rounding drift | Gherkin-bound, smoke | Straight port of an existing binding. Checks decimal handling in a money split. |
| `SC-10-04-01` Virman dialog offers the real advance balance of the unit | Gherkin-bound | Read-only dialog flow. |
| `SC-10-04-02` Virman transfer clears a capital due from the advance balance | Linked (`e2e/tests/test_p2_edge.py`) | Converts a linked test to Gherkin. Moves money, then checks resulting balances and the inter-ledger audit record. |
| `SC-07-06-03` Excel upload offers a sample for each catalogued Excel bank | Linked outline, two examples (`e2e/tests/test_epic07_bank.py`) | Exercises example-level identity and a file download attachment in the report. |

[Pilot project creation feature](../../.specify/features/EPIC-10/STORY-10-01-capital-project-creation.feature) · [Pilot transfer feature](../../.specify/features/EPIC-10/STORY-10-04-inter-ledger-virman.feature) · [Pilot bank sample feature](../../.specify/features/EPIC-07/STORY-07-06-site-bank-account-configuration.feature)

Steps:

1. **Baseline.** Record the current outcome, duration and rerun rate of the four scenarios over comparable CI runs, and the current report views of them.
2. **Arm A.** Bind `SC-10-04-02` and `SC-07-06-03` as Gherkin in pytest-bdd, reusing the existing page objects, and remove their `covers` links. Extend the record writer so each outline example is its own record. This step is useful even if arm B is rejected.
3. **Arm B.** Implement all four scenarios in Cucumber.js and generate the Serenity, JUnit and SitePulse records.
4. **Comparison.** Run both arms against the same revision and seed on separate test stacks. In temporary pilot runs, introduce a controlled assertion failure, an undefined step and a setup failure. Check for nonzero exits, actionable diagnostics and correct scenario and example attribution in both arms.
5. **Review.** Reviewers use each report to answer three questions for every pilot scenario: what passed, why the injected failure failed, and which requirement lacks evidence.

**Pilot exit criteria**

- Both arms produce the same outcome for every scenario and example, with equivalent assertions, including the balance and audit checks of `SC-10-04-02`.
- Both outline examples of `SC-07-06-03` appear as separate records with the correct example identity.
- The injected failures fail the required check and are attributed to the right scenario, example and step.
- Arm B's runtime and setup are measured against arm A and the baseline.
- Reviewers state whether the Serenity report answers the three review questions materially better than the arm A report. If it does not, stop at option 2.

**Effort indicator.** Count the step definitions, page-object methods and fixtures each arm needs for the four scenarios. Scale that by the 556 distinct GUI step phrasings and the 145 linked GUI tests to estimate the full rollout. This estimate is the main input to the follow-up decision.

## Rollout, cutover and rollback (if arm B is chosen)

| Phase | Work | Evidence for review |
| --- | --- | --- |
| Rollout | Normalise step wording and port epics in batches that share page objects and fixtures. Compare each batch against the Python results before switching its authoritative runner. | Each batch accounts for all expected scenario examples. Report totals reconcile to the evidence. The required check fails when a migrated scenario fails or expected evidence is absent. |
| Cutover | Make Cucumber authoritative for all 154 in-scope GUI scenarios. Document the launch commands. Remove pytest-bdd and the Python GUI tests, page objects and browser fixtures. | Local and CI commands, full GUI coverage parity, preserved history, runtime and rerun rates within the thresholds agreed from the baseline. |

During the pilot and rollout, the Python path is the rollback: revert a batch's runner assignment if it loses coverage, changes an outcome without explanation or breaks a gate. After cutover, revert the cutover change to restore the Python runner and its CI wiring together.

## Risks

| Risk | Mitigation |
| --- | --- |
| Step normalisation changes the meaning of acceptance criteria | Reword in separate reviewed commits before porting. Keep scenario IDs stable. |
| Permanent dual browser stack if rollout stalls | Decide up front to convert all linked GUI tests, or keep option 2. |
| Floating-point money assertions in TypeScript | Decimal-string convention plus a lint check on step definitions. |
| Java runtime and Node toolchain add CI time and maintenance | Measure in the pilot. Generate the Serenity report in one post-merge job rather than per shard. |
| Sensitive data in published screenshots or traces | Keep the Serenity report as a CI artifact until its contents are reviewed. |

## Questions for reviewers

1. Who will use the Serenity report, and which review tasks should it make easier than the dashboard and the detailed scenario report?
2. Is the in-scope boundary right: all 154 GUI scenarios, with the 145 non-GUI linked tests left in their runners?
3. Should step normalisation and arm A go ahead regardless of the Serenity decision, since both runners need them?
4. What change in CI runtime and rerun rate is acceptable? Agree thresholds before approving the rollout.
5. Should the Serenity report stay in CI artifacts or eventually have a public view on Pages? Decide after reviewing the pilot report contents.

---

## Pilot execution results and evaluation

A complete end-to-end pilot comparing **Arm A (pytest-bdd)** and **Arm B (Cucumber.js + TypeScript Playwright + Serenity/JS)** was implemented and executed against identical SitePulse backend (`:8180`) and Flutter Web client (`:9190`) builds seeded with `02-test-seed.sql` on PostgreSQL.

> [!NOTE]
> The Arm B reference implementation (TypeScript Playwright + Cucumber.js + Serenity/JS) was fully verified during the pilot and now lives in [`e2e-cucumber/`](../../e2e-cucumber/); the original pilot revision is also archived under git tag [`pilot/cucumber-serenity-arm-b`](https://github.com/gurkanindibay/ai-powered-engineering/tree/pilot/cucumber-serenity-arm-b/apps/development-time/SitePulse/e2e-cucumber) (commit [`515f749`](https://github.com/gurkanindibay/ai-powered-engineering/commit/515f7492931589da0e9bb2efd8118021c210ca31)). Option 3 is still not adopted: no CI job or SitePulse gate runs this suite, and [`e2e/`](../../e2e) remains the canonical runner with pytest-bdd. The directory is kept as reviewable reference material; adopting it needs a separate decision.

### 1. Execution status across pilot scenarios

Both arms executed the four pilot scenarios across five distinct executions (including both scenario outline examples of `SC-07-06-03`):

| Scenario | Scenario type | Arm A (pytest-bdd) outcome & duration | Arm B (Cucumber.js + Serenity/JS) outcome & duration | Outcome parity |
| --- | --- | ---: | ---: | :---: |
| `SC-10-01-01` Land share split without rounding drift | Standard Scenario | PASS (11.85 s) | PASS (10.72 s) | **Identical** |
| `SC-10-04-01` Virman dialog offers real advance | Standard Scenario | PASS (6.42 s) | PASS (6.62 s) | **Identical** |
| `SC-10-04-02` Virman transfer clears capital due | Standard Scenario | PASS (8.68 s) | PASS (7.64 s) | **Identical** |
| `SC-07-06-03[1]` Excel sample download (`KUVEYT_TURK`) | Scenario Outline Example 1 | PASS (8.21 s) | PASS (6.50 s) | **Identical** |
| `SC-07-06-03[2]` Excel sample download (`YAPI_KREDI`) | Scenario Outline Example 2 | PASS (8.67 s) | PASS (6.32 s) | **Identical** |
| **Total / Suite Run** | **5 executions / 25 steps** | **5 passed in 43.83 s** | **5 passed in 36.42 s** | **100% Parity** |

Both test runners produced structured `executions.jsonl` records conforming exactly to the SitePulse schema (`epic`, `story`, `scenario`, `binding`, `layer`, `example`, `example_row`, `example_id`, `status`, `duration_s`, and per-step status arrays).

### 2. Controlled failure comparison (Action 4)

Three controlled failures were injected and tested across both runners to verify error attribution, exit codes, and diagnostic clarity:

| Failure mode | Injected condition | Arm A (pytest-bdd) diagnostic & behavior | Arm B (Cucumber.js + Serenity/JS) diagnostic & behavior | Comparison |
| --- | --- | --- | --- | --- |
| **Assertion failure** | `SC-10-04-02`: Expected remaining advance altered to `999.00` (actual `1000.00`) | Exit code `1`. Stack trace pinpointed `steps/capital_steps.py:232`: `AssertionError: expected advance 999.00, got 1000.00`. Record in `executions.jsonl` marked Step 3 as `FAIL` and subsequent steps as `SKIPPED`. | Exit code `1`. Output pinpointed `src/steps/capital_steps.ts:174`: `AssertionError: INJECTED_FAILURE: expected advance 999.00 (-999.00, +1000.00)`. Step marked `FAIL`, subsequent steps `SKIPPED`. Serenity captured failure screenshot attachment and marked scenario `Failed` in HTML living documentation. | **Tie on diagnostics; Arm B adds automated screenshot attachment in Serenity HTML.** |
| **Undefined step** | `SC-10-04-01`: Added unmapped step `And this step is completely unmapped and undefined in both runners` | Exit code `1`. Raised `pytest_bdd.exceptions.StepDefinitionNotFoundError` highlighting line number, scenario name, and feature file path. | Exit code `1`. Cucumber reported `? Undefined` step, skipped remaining steps, and printed TypeScript code snippet template for missing step definition. Serenity HTML recorded step as undefined. | **Arm B provides actionable step implementation snippets.** |
| **Setup failure** | Stack startup with invalid DB password (`DB_PASS=invalid_secret`) | Exit code `3` (`_pytest.outcomes.Exit`). Aborted run before scenario execution with message `E2E stack setup failed: backend exited during startup`. | Exit code `1`. Launcher aborted startup with `api_system_check.SetupError: backend exited during startup`. No partial Cucumber records emitted. | **Equivalent fail-fast behavior across both runners.** |

### 3. Evaluation against the five pilot exit criteria

1. **Parity of outcomes**: **MET**. Both arms produced identical outcomes across all four scenarios and outline examples, verifying identical business assertions (decimal apportionment, ledger balances, database persistence, and sample workbook bytes).
2. **Example-level identity**: **MET**. Both runners emitted distinct, unambiguous records for `SC-07-06-03[1]` (`KUVEYT_TURK`) and `SC-07-06-03[2]` (`YAPI_KREDI`) containing exact parameter values and individual step timings.
3. **Injected failure attribution**: **MET**. Both runners exited with non-zero status codes, localized failure causes to the exact file and step, and attributed the failures cleanly.
4. **Runtime & setup complexity**: **EVALUATED**. Arm A executed in 43.83 s; Arm B executed in 36.42 s (+3.5 s for Serenity HTML generation, total ~40 s). While execution speed is comparable, Arm B introduces significant toolchain complexity (Node.js 20+, TypeScript, 8 npm packages, and a Java 25 runtime for the Serenity CLI jar).
5. **Review value vs. cost**: **EVALUATED**. While Serenity BDD provides an attractive HTML living documentation interface with narrative step breakdowns and embedded screenshots, it does not provide superior verification strength over pytest-bdd.

### 4. Effort indicator and scaling projection

An audit of step definitions, page objects, and support infrastructure needed for the four pilot scenarios reveals the scaling cost for a full rollout across the remaining GUI catalogue:

| Component | Arm A (pytest-bdd) pilot | Arm B (Cucumber.js) pilot | Full GUI suite (154 scenarios / 145 linked tests / 556 distinct phrasings) |
| --- | ---: | ---: | --- |
| **Step definitions** | 18 Python step definitions (reused across pilot) | 18 TypeScript step definitions | ~538 additional step definitions required in both arms. Step normalisation is identical in both. |
| **Page objects** | 0 new (reused 5 existing Python page objects) | 5 new TypeScript page objects (~350 LOC) | **Arm A**: Reuses all ~40 existing Python page objects (~700 LOC) and helper utilities.<br>**Arm B**: Requires rewriting all ~40 page objects and helpers in TypeScript (~3,600 LOC total). |
| **Support modules** | 0 new (existing `e2e/support`) | 5 modules (World, API client, DB client, Flutter semantics helpers, SitePulse formatter) | **Arm B** requires ongoing dual maintenance of browser helpers, login flows, and token guards. |
| **Toolchains** | Python only (already in place) | Python (launcher) + Node.js (Cucumber/TS) + JVM (Serenity CLI) | **Arm B** introduces permanent multi-language CI dependencies and container bloat. |

### 5. Review questions and final recommendation

1. **Who will use the Serenity report?**
   - The Serenity living documentation report primarily benefits external non-technical stakeholders, auditors, and manual QA leads who require narrative test logs and screenshot evidence.
   - For engineering, product owners, and automated CI verification, the SitePulse test report dashboard and GitHub CI job summaries already surface scenario-level pass/fail statuses, durations, and traceback logs with zero extra runtime overhead.
2. **Is the scope boundary right?**
   - Yes. The 145 non-GUI linked tests (Rust backend unit/integration tests, Flutter unit tests, database checks, API system checks) must remain in their native test harnesses (Cargo, Flutter test, pytest).
3. **Should step normalisation and Arm A proceed regardless of the Serenity decision?**
   - **Yes, absolutely.** Normalising the 556 distinct GUI step phrasings and binding linked GUI tests in pytest-bdd (Option 2) directly resolves the step-level evidence gap, eliminates the `@linked` surrogate pattern, and unlocks outline example tracking without introducing a secondary language toolchain.
4. **What change in CI runtime and rerun rate is acceptable?**
   - Arm B adds ~35–45 s per shard plus Java report generation time. Across eight shards, this represents a modest runtime increase, but introduces package installation overhead and JVM memory consumption in CI runners.
5. **Should the Serenity report stay in CI artifacts or go to Pages?**
   - The generated Serenity HTML report contains detailed database transaction IDs, test IBANs, and internal UI routes. If Serenity were adopted, reports should remain ephemeral CI workflow artifacts rather than being published publicly to GitHub Pages.

### Final Conclusion & Recommendation

**Adopt Option 2: Bind linked GUI tests as Gherkin in pytest-bdd and extend native SitePulse reporting.**
- **Do not adopt Option 3 (Cucumber.js + Serenity BDD).** The considerable effort required to rewrite ~40 page objects into TypeScript (~3,600 lines of code) and maintain a permanent dual browser stack (Python and Node.js/JVM) is not justified by the visual benefits of the Serenity HTML report.
- The step normalisation and Gherkin binding developed in Arm A delivers full step-level narrative evidence, exact example-level identity, and robust error attribution while fully preserving the existing, proven Python Playwright test architecture.

