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
