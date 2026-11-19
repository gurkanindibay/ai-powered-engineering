# SitePulse Cucumber and Serenity BDD migration analysis

**Status** — Proposed for review, 19 November 2026

## Decision requested

Approve a two-scenario pilot of Cucumber.js, TypeScript Playwright, and Serenity BDD reporting. Use the pilot to decide whether the stakeholder reporting benefit justifies porting the Python acceptance suite and maintaining another toolchain. Full migration requires a separate decision after the pilot.

## Current state and opportunity

SitePulse already has executable BDD specifications. Canonical Gherkin lives in [`.specify/features`](../../.specify/features/README.md), pytest-bdd binds scenarios to Python steps, and Playwright drives the Flutter web client. Linked tests can verify a scenario outside Gherkin. CI combines execution records from GUI shards into a scenario report and publishes master runs to the [product status dashboard](https://gurkanindibay.github.io/ai-powered-engineering/).

The dashboard snapshot at commit `2bcb9b8` showed 319 specified scenarios, 299 marked automated, and 114 passing in the latest CI evidence. The report distinguishes failure from missing evidence. Some Rust and Flutter tests run in CI while their scenario-level outcomes are absent from the dashboard. Publishing results from those linked suites is a separate improvement and can proceed regardless of the runner decision. [Dashboard calculation](../../scripts/product_status.py)

Cucumber executes Gherkin against step definitions. Equivalent assertions and fixtures should produce equivalent verification. Serenity BDD's potential gain is a browsable requirements hierarchy with narrative step results and diagnostic evidence. The pilot should establish whether reviewers can explain what passed, why a scenario failed, and which requirements lack evidence using the generated report. [Cucumber BDD guide](https://cucumber.io/docs/bdd/) · [Serenity BDD living documentation](https://serenity-bdd.github.io/docs/reporting/living_documentation)

## Options

| Option | Benefit | Cost and fit |
| --- | --- | --- |
| Keep pytest-bdd and extend the SitePulse report | Reuses Python steps, fixtures, and CI. Targets missing evidence or specific navigation problems directly. | SitePulse continues to maintain its reporting views. Appropriate if the pilot shows limited stakeholder benefit. |
| Cucumber.js + TypeScript Playwright + Serenity/JS Serenity BDD reporter | Keeps Playwright and uses Serenity's documented Cucumber.js integration. Generates the multi-page Serenity BDD report. | Ports application-level steps and fixtures, adds a Node toolchain, and uses Java for report generation. Proposed pilot. |
| Cucumber-JVM + Serenity BDD | Uses the Java Serenity ecosystem and its native Cucumber integration. | Ports steps and fixtures to Java and introduces JVM build tooling. Revisit if the team has an explicit JVM standard. |

[Serenity/JS Cucumber integration](https://serenity-js.org/handbook/test-runners/cucumber/) · [Serenity/JS report generator](https://serenity-js.org/modules/serenity-bdd/) · [Serenity BDD with Cucumber-JVM](https://serenity-bdd.github.io/docs/tutorials/cucumber-screenplay)

## Proposed design

- **Specifications and scope.** Use the existing Gherkin files in place, with their `SC-*`, `GUI-*`, layer, role, smoke, epic, and story tags. Migrate executable Gherkin GUI scenarios. Keep existing linked and standalone Rust, Flutter, API, and Python tests in their existing runners. Preserve pending scenarios in the catalogue.
- **Browser and data.** Keep the Python launcher and reuse its stack startup, reset, and teardown. Give each Cucumber scenario its own browser context and port the required Flutter selectors, locale, login helpers, assertions, and fixtures. Run scenarios serially within a shard that shares a resettable database. Keep money as decimal strings or use arbitrary-precision decimals for arithmetic.
- **Execution records.** Use Cucumber's structured execution output to emit JUnit and compatible `executions.jsonl` records. Preserve scenario IDs, example-level identity, GUI IDs, status, duration, and step diagnostics. Explicitly handle retries, setup and teardown failures, skipped steps, and undefined or ambiguous steps. Require a valid evidence artifact for every expected shard.
- **CI and reports.** Preserve smoke and affected selection, sharding, local recorded runs, and the task DAG's scenario gates. During parallel runs, collect comparison results separately and publish only the runner assigned to each scenario example. Attach the full Serenity report to the PR workflow. Keep the Pages dashboard as the product entry point and review example data, logs, screenshots, and traces for sensitive content before publishing any Serenity report publicly.

[GUI launcher](../../scripts/gui_e2e.py) · [Python fixtures](../../e2e/conftest.py) · [Execution record writer](../../e2e/support/executions.py) · [CI aggregation and publishing](../../../../../.github/workflows/sitepulse-ci.yml)

## Pilot, rollout, and rollback

| Phase | Work | Evidence for review |
| --- | --- | --- |
| Baseline | Inventory executable, linked, and pending scenarios. Capture the expected scenario/example IDs and baseline durations and reruns from comparable CI runs. | A baseline commit, scenario inventory, and current reporting examples. |
| Pilot | Port `SC-10-01-01` (capital project creation) and `SC-10-04-01` (inter-ledger transfer). Run both implementations against the same revision and seed using separate test stacks. Generate Serenity, JUnit, and SitePulse records. | Matching outcomes and assertions. Introduce a controlled failure and an undefined step in temporary pilot runs and verify nonzero exits, actionable diagnostics, and scenario attribution. Reviewers use both reports to locate the outcome, failure, and supporting evidence. |
| Rollout | Port epics in batches that share fixtures. Compare each batch before switching its authoritative runner. Exercise outline examples, shared-database isolation, smoke and affected selection, and shard merging. | Each batch accounts for all expected scenario examples. Report totals reconcile to the evidence. The required check fails when a migrated scenario fails or expected evidence is absent. |
| Cutover | Make Cucumber authoritative for the complete in-scope acceptance suite. Document launch commands and remove pytest-bdd after parity is established. | Local and CI commands, complete scenario coverage parity, preserved history, and runtime and rerun rates within thresholds agreed from the baseline. |

Use the existing pytest-bdd path as the rollback during the pilot and rollout. Revert a batch's runner assignment if it loses coverage, changes outcomes without explanation, or breaks a gate. After removing pytest-bdd, revert the cutover change to restore the previous runner and CI wiring together.

[Pilot project creation feature](../../.specify/features/EPIC-10/STORY-10-01-capital-project-creation.feature) · [Pilot transfer feature](../../.specify/features/EPIC-10/STORY-10-04-inter-ledger-virman.feature)

## Questions for reviewers

1. Who will use the Serenity report, and which review tasks should it make easier than the existing dashboard and detailed scenario report?
2. Does the proposed boundary cover the right tests? The effort estimate depends on the number of distinct steps, fixtures, and assertions in scope.
3. What change in CI runtime and rerun rate is acceptable? Agree thresholds before approving rollout.
4. Should the Serenity report stay in CI artifacts or eventually have a public view on Pages? Decide after reviewing the pilot report contents.
