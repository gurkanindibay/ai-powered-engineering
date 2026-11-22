# SitePulse Cucumber.js + Serenity/JS pilot (Arm B)

Reference implementation of the Arm B pilot from the
[Cucumber and Serenity migration analysis](../docs/testing/cucumber-serenity-migration-analysis.md):
four Gherkin scenarios (`SC-10-01-01`, `SC-10-04-01`, `SC-10-04-02`, `SC-07-06-03`) run by
Cucumber.js and TypeScript Playwright, with a Serenity BDD living-documentation report.

This is **reference material, not the adopted suite**. The canonical runner stays
[`../e2e`](../e2e) (pytest-bdd + Python Playwright), and no CI job or SitePulse gate runs this
directory. Keep it runnable when touching it, but do not grow it without a migration decision.

## Run

Use Node.js 22.22.2+ (22.x) or 24.15.0+ (24.x) and Java 17 or newer. Make
`java` available on `PATH` so the Serenity BDD CLI can generate the HTML report.
The locked `@serenity-js/serenity-bdd` package includes the CLI JAR under
`node_modules/@serenity-js/serenity-bdd/cache/`; `npm ci` installs it.

```bash
npm ci
npx playwright install chromium
npm run lint:money        # arbitrary-precision money check over src/**/*.ts
python3 scripts/run_pilot.py   # isolated stack: Postgres + backend :8180 + Flutter web :9190
```

On a Linux machine that also needs Chromium's system dependencies, use
`npx playwright install --with-deps chromium`.

The runner needs a local PostgreSQL server and the Rust and Flutter build tools.
It starts an isolated SitePulse stack, runs `npm test` (five cases across the four
pilot scenarios), generates the Serenity report, and stops the stack. To run
against an already-running stack, use `npm test`, then run
`npx serenity-bdd run --features ../.specify/features` to generate the HTML report.

## Outputs

| Path | Content |
| --- | --- |
| `target/executions.jsonl` | SitePulse execution records (same schema as `e2e/support/executions.py`) |
| `target/junit-report.xml` | JUnit results |
| `target/site/serenity/index.html` | Serenity BDD report |
