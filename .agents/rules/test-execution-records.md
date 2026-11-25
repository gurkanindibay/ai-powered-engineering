---
description: Scenarios are Gherkin; CI runs them on every PR and publishes the report as an artifact. Committing a recorded run per task is a switch (off by default).
globs: apps/development-time/SitePulse/**
---

# Test Execution Records (All Agents)

The overall test strategy (principles, layers, lanes, quality gates) is [docs/testing/TEST_STRATEGY.md](file:///apps/development-time/SitePulse/docs/testing/TEST_STRATEGY.md). This rule covers only how test runs are recorded and reported.

Operationalizes AGENTS.md rule 13. Paths are relative to `apps/development-time/SitePulse/`.

## What the harness enforces

| Check | Where it runs | Fails when |
|---|---|---|
| Gate `feature-traceability` | `scripts/run_tests.py` | A story of a migrated epic has no scenario, a scenario id is duplicated or misplaced, a `covers` link points at nothing |
| Gate `test-run-recorded` | `scripts/run_tests.py` (last gate) and every `harness/harness_cli.py verify --task` (global gate) | The branch changes `backend/`, `flutter/lib/`, `flutter/test/`, `e2e/` or a `.feature` file and (a) has no recorded run, (b) a scenario its changes affect was never executed on the branch, or (c) the latest execution of any test on the branch is FAIL or ERROR |
| Acceptance id `scenario:SC-xx-yy-nn` | `acceptance_tests` of a task in `.specify/tasks/task-dag.json` | The scenario's latest recorded execution is not PASS |

`test-run-recorded` passes without a run on `master`/`main` and on branches that change no behaviour file.

## Switch: recorded runs (currently off)

GitHub CI runs the suite on every PR, so committing a recorded run per task is switched off:
`.specify/executions/settings.json` has `"require_recorded_run": false`, and gate `test-run-recorded`
then passes with the note "not required: recorded runs are switched off". `$SITEPULSE_REQUIRE_RECORDED_RUN`
(`1`/`0`) overrides the file for one invocation. Set the file back to `true` to restore steps 2-5 below as requirements.

While it is off, the report comes from CI (`.github/workflows/sitepulse-ci.yml`):
- each e2e shard uploads its `e2e/.artifacts` (junit, execution records, Playwright traces, logs) as artifact `e2e-shard-N`;
- job `test-report` merges them with `scripts/ci_test_report.py`, writes the stats and the run to the job summary,
  and uploads artifact **`e2e-test-report`**: `test-report.md`, `feature-report.html` (dashboard: committed history plus this run),
  `executions.jsonl`, `summary.json`, and `product-status.json` / `product-status.html` (coverage per epic).
- On pushes to `master`, Pages build/deploy jobs store sanitized archive state on `gh-pages-archive` (a single replaced commit; `gh-pages` is no longer written) and publish an Actions artifact through
  the `github-pages` environment when repository variable `SITEPULSE_PAGES_ACTIONS_ENABLED` is `true`. The Pages `index.html`
  is the product status dashboard, `latest.html` is the newest reviewed report and `history.html` lists the archived runs. PR runs
  remain available as `e2e-test-report` artifacts and do not deploy.

Rule 12 still applies: a failing test fails its e2e shard and the required `verify` check. Steps 2-5 below stay available
for local runs (`gui_e2e.py run --affected --record`), but are not required.

## Run only what is affected

`python3 scripts/feature_traceability.py affected` maps the files your branch changes (against `master`, committed or not) to tests, using `.specify/features/impact-map.json`:

| Changed file | Selection |
|---|---|
| Names an epic in its path (`.specify/features/EPIC-10/…`, `test_epic10_…`) or matches an epic keyword (`capital`, `bank`, `occupancy`, …) | Smoke set plus that epic (`-m "smoke or epic_10"`) |
| Cross-cutting UI code, or only unit tests (`flutter/lib/ui/design_system`, `flutter/test/`, `backend/tests/`) | Smoke set |
| Shared code (`e2e/support`, `backend/src/main.rs`, migrations, lock files) or a behaviour file that maps to no epic | Full suite |
| No behaviour file | Nothing; no run is required |

Every test carries an `epic_NN` marker automatically (from its `GUI-NN-…` id or `@EPIC-NN` tag). Several targeted runs on a branch add up: the gate looks at the latest execution of each test across all of the branch's runs. When a new keyword or shared path is needed, extend `impact-map.json` in the same change.

## What you do for every task

Step 1 always; steps 2-5 only while recorded runs are switched on (see above). Otherwise link the CI run in the PR's `## Test report`.


1. **Specify**: add or update the scenario in `.specify/features/EPIC-xx/STORY-xx-yy-*.feature` (`@SC-xx-yy-nn`, `@layer:…`). Not automatable yet: tag it `@pending`. Covered by an existing non-Gherkin test: tag it `@linked` and declare `covers` on that test.
2. **Execute and record**: `python3 scripts/gui_e2e.py run --affected --record --task "<issue or PR> <few words>"`. A full gate run records too when the task is named: `SITEPULSE_TASK="<task>" python3 scripts/run_tests.py`.
3. **Commit** the new files under `.specify/executions/runs/` and `.specify/executions/reports/` with the task.
4. **Report in the PR**: fill the `## Test report` section of the PR description with `python3 scripts/feature_traceability.py task-report`, and refresh it after every newly recorded run.
5. **Verify**: `python3 scripts/feature_traceability.py check --require-run` passes.

## Durable engineering harness

Workers in `scripts/development_harness.py` runs cannot write `.specify/executions`. The `tester` role may write `.specify/features`, `e2e/steps` and `e2e/tests`; the `sitepulse-full` gate runs the suite with the task named, so the run is recorded inside the gate's disposable copy; the controller keeps the new record files in the run's hashed evidence. The operator delivers them with `python3 scripts/development_harness.py captures <run id> --output <repository root>` and commits them with the candidate.

## Never

- Edit or delete a recorded run or report, yours or another agent's. History is append-only.
- Write a run record by hand, or record a run made on different code than the PR contains.
- Remove a scenario, or tag an automated scenario `@pending`, to make a run pass.
- Report the task complete with a FAIL or ERROR scenario in your latest recorded run.

While recorded runs are switched on: if the suite cannot run in your environment (no PostgreSQL, no browser), say so in the PR with the reason and leave the task open; the gate stays red by design.
