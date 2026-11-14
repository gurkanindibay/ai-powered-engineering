---
description: Every task records the test run that verifies it; scenarios are Gherkin, results are stored per scenario and step.
globs: apps/development-time/SitePulse/**
---

# Test Execution Records (All Agents)

Operationalizes AGENTS.md rule 13. Paths are relative to `apps/development-time/SitePulse/`.

## What the harness enforces

| Check | Where it runs | Fails when |
|---|---|---|
| Gate `feature-traceability` | `scripts/run_tests.py` | A story of a migrated epic has no scenario, a scenario id is duplicated or misplaced, a `covers` link points at nothing |
| Gate `test-run-recorded` | `scripts/run_tests.py` (last gate) and every `harness/harness_cli.py verify --task` (global gate) | The branch changes `backend/`, `flutter/lib/`, `flutter/test/`, `e2e/` or `.specify/features/` and has no recorded run, or its latest recorded run has a FAIL or ERROR scenario |
| Acceptance id `scenario:SC-xx-yy-nn` | `acceptance_tests` of a task in `.specify/tasks/task-dag.json` | The scenario's latest recorded execution is not PASS |

`test-run-recorded` passes without a run on `master`/`main` and on branches that change no behaviour file.

## What you do for every task

1. **Specify**: add or update the scenario in `.specify/features/EPIC-xx/STORY-xx-yy-*.feature` (`@SC-xx-yy-nn`, `@layer:…`). Not automatable yet: tag it `@pending`. Covered by an existing non-Gherkin test: tag it `@linked` and declare `covers` on that test.
2. **Execute and record**: `python3 scripts/gui_e2e.py run --record --task "<issue or PR> <few words>"`. A full gate run records too when the task is named: `SITEPULSE_TASK="<task>" python3 scripts/run_tests.py`.
3. **Commit** the new files under `.specify/executions/runs/` and `.specify/executions/reports/` with the task.
4. **Report**: paste `python3 scripts/feature_traceability.py task-report` into the PR description.
5. **Verify**: `python3 scripts/feature_traceability.py check --require-run` passes.

## Never

- Edit or delete a recorded run or report, yours or another agent's. History is append-only.
- Write a run record by hand, or record a run made on different code than the PR contains.
- Remove a scenario, or tag an automated scenario `@pending`, to make a run pass.
- Report the task complete with a FAIL or ERROR scenario in your latest recorded run.

If the suite cannot run in your environment (no PostgreSQL, no browser), say so in the PR with the reason and leave the task open; the gate stays red by design.
