# SitePulse Cucumber.js + Serenity/JS pilot (Arm B)

Reference implementation of the Arm B pilot from the
[Cucumber and Serenity migration analysis](../docs/testing/cucumber-serenity-migration-analysis.md):
four Gherkin scenarios (`SC-10-01-01`, `SC-10-04-01`, `SC-10-04-02`, `SC-07-06-03`) run by
Cucumber.js and TypeScript Playwright, with a Serenity BDD living-documentation report.

This is **reference material, not the adopted suite**. The canonical runner stays
[`../e2e`](../e2e) (pytest-bdd + Python Playwright), and no CI job or SitePulse gate runs this
directory. Keep it runnable when touching it, but do not grow it without a migration decision.

## Run

```bash
npm ci
npm run lint:money        # arbitrary-precision money check over src/**/*.ts
python3 scripts/run_pilot.py   # isolated stack: Postgres + backend :8180 + Flutter web :9190
```

`scripts/run_pilot.py` needs the Rust backend build and the Flutter web build available locally;
it starts the stack, runs `npm test` (the four pilot scenarios), generates the Serenity report, then
stops the stack. To run against an already-running stack, just use `npm test`.

## Outputs

| Path | Content |
| --- | --- |
| `target/executions.jsonl` | SitePulse execution records (same schema as `e2e/support/executions.py`) |
| `target/junit-report.xml` | JUnit results |
| `target/site/serenity/index.html` | Serenity BDD report |
