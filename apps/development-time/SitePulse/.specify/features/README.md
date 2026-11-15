# Executable acceptance criteria

One `.feature` file per story: `EPIC-xx/STORY-xx-yy-<slug>.feature`. The epic documents in
`../requirements` keep the narrative and link here; the Gherkin lives only in these files.

| Level | Id | Where |
|---|---|---|
| Epic | `EPIC-10` | `@EPIC-10` on the `Feature` |
| Story (feature) | `STORY-10-01` | `@STORY-10-01` on the `Feature` |
| Scenario (acceptance criterion) | `SC-10-01-02` | `@SC-10-01-02` on the `Scenario` |
| Step | position in the scenario | `Given` / `When` / `Then` line |

## Tags

| Tag | Meaning |
|---|---|
| `@layer:gui` | Test layer that executes the scenario (required unless `@pending`) |
| `@GUI-10-02` | Row in `docs/testing/GUI_TEST_PLAN.md`; becomes the `gui_id` marker |
| `@smoke`, `@core`, `@edge`, `@role_*` | Ordinary pytest markers (`e2e/pytest.ini`) |
| `@pending` | Specified, not automated yet. Reported as PENDING, never executed |
| `@linked` | Verified by a non-Gherkin test that declares `covers`. Not executed from the feature file |

## How a scenario is executed

- **Gherkin** (default): `e2e/tests/test_features.py` runs every scenario through pytest-bdd with the
  step definitions in `e2e/steps/`. Each step gets its own status and duration.
- **Linked**: an existing test declares the scenario it verifies:
  `@pytest.mark.covers("SC-10-03-02")` in `e2e/tests` (its result is recorded for the scenario), or a
  `// covers: SC-10-01-01` comment above a Rust or Dart test (listed under the scenario; its result is
  not recorded yet).

Amounts in steps are plain decimals (`500000.00`) and are parsed as `Decimal`.

## Results and history

GitHub CI runs the suite on every PR and publishes the result: the stats on the `test-report` job's
summary, and artifact `e2e-test-report` (markdown report, HTML dashboard of the committed history plus
that run, merged execution records). On pushes to `master`, CI also publishes the latest report and
an archive of earlier master runs to the repository's GitHub Pages site using the `gh-pages` branch.
Configure Pages to deploy from `gh-pages` at the repository root. PR reports remain available through
their workflow summary and artifact. Committing a recorded run with every task is switched off
(`"require_recorded_run": false` in `.specify/executions/settings.json`; `SITEPULSE_REQUIRE_RECORDED_RUN=1`
overrides it). A run can still be recorded locally (AGENTS.md rule 13):

```bash
python3 scripts/gui_e2e.py run --affected --record --task "issue-123 virman transfer"
```

`--affected` selects the smoke set plus the epics the branch's changes touch, or the full suite when
shared code changed. The mapping from changed files to epics is `impact-map.json` in this directory;
`python3 scripts/feature_traceability.py affected` prints the selection and the reason per file.

That writes, under `.specify/executions/`:

| Path | Content |
|---|---|
| `runs/<year>/<run id>.jsonl` | One record per executed test (a scenario, or a test not yet linked to one): epic, story, scenario, status, duration, one status per step, error text, plus the run's task label, commit, branch and time |
| `reports/<year>/<run id>.md` | The same run as a readable report: result, what regressed or was fixed, every scenario, and the automated scenarios that were not executed |

A run id is `<UTC time>-<commit>`, so runs from different branches never collide. Recorded runs are append-only.
The dashboard `e2e/.artifacts/feature-report.html` is regenerated after every recorded run.

```bash
python3 scripts/feature_traceability.py check --require-run        # gate `test-run-recorded`: this branch has a passing recorded run (when switched on)
python3 scripts/feature_traceability.py affected                   # what this branch's changes call for
python3 scripts/feature_traceability.py task-report                # the "Test report" section for the PR description
python3 scripts/feature_traceability.py runs --detail --limit 5    # recent runs: executed, regressed, fixed
python3 scripts/feature_traceability.py report --epic EPIC-10 --steps
python3 scripts/feature_traceability.py history SC-10-01-01
python3 scripts/feature_traceability.py html                       # dashboard: e2e/.artifacts/feature-report.html
```

## Harness tasks

A task in `.specify/tasks/task-dag.json` can name scenarios as acceptance tests
(`"acceptance_tests": ["scenario:SC-10-01-01"]`): the task verifies only when the scenario's
latest recorded execution is PASS. Every `harness_cli.py verify` also runs `test-run-recorded` (a pass while it is switched off).
