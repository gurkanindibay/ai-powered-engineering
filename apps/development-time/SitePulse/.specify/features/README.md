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
| `@GUI-10-02` | Row in `docs/GUI_TEST_PLAN.md`; becomes the `gui_id` marker |
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

`scripts/gui_e2e.py` writes one record per scenario to `e2e/.artifacts/executions.jsonl` and appends
the run to the local git branch `test-history` (`runs/<year>/<run id>.jsonl`, stamped with commit,
branch and time). Read it with `scripts/feature_traceability.py`:

```bash
python3 scripts/feature_traceability.py check                      # static gate `feature-traceability`
python3 scripts/feature_traceability.py report --epic EPIC-10 --steps
python3 scripts/feature_traceability.py history SC-10-01-01
python3 scripts/feature_traceability.py history STORY-10-05 --json
python3 scripts/feature_traceability.py html                       # visual report: e2e/.artifacts/feature-report.html
python3 scripts/feature_traceability.py record --push origin       # share the history branch
```
