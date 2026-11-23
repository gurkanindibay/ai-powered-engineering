# SitePulse Cucumber.js + Serenity/JS pilot (Arm B)

Reference implementation of the Arm B pilot from the
[Cucumber and Serenity migration analysis](../docs/testing/cucumber-serenity-migration-analysis.md):
four Gherkin scenarios (`SC-10-01-01`, `SC-10-04-01`, `SC-10-04-02`, `SC-07-06-03`) run by
Cucumber.js and TypeScript Playwright, with a Serenity BDD living-documentation report.

This is **reference material, not the adopted suite**. The canonical runner stays
[`../e2e`](../e2e) (pytest-bdd + Python Playwright), and no CI job or SitePulse gate runs this
directory. Keep it runnable when touching it, but do not grow it without a migration decision.

The opt-in GitHub Actions workflow is [`sitepulse-cucumber-pilot.yml`](../../../../.github/workflows/sitepulse-cucumber-pilot.yml).
It produces the allowlisted `cucumber-pilot-results-<run-id>-<attempt>` artifact from JUnit and execution records.
The artifact contains `cucumber-results.json` (the comparison-only summary) and a separate
schema-1 `public-report.json` for the shared Pages renderer. Both contain only the five fixed pilot
case IDs, example IDs where applicable, static labels, normalized statuses, durations, and safe run
metadata. The gate label states that this is comparison-only and pytest remains authoritative for
overlapping scenarios. The private JUnit, execution JSONL, Serenity tree, and runner log are not
uploaded. The Cucumber artifact remains separate from the authoritative inventory; a dedicated
Pages archive ingestion path must be enabled before it is published. The workflow does not deploy
Pages itself.

Serenity is generated once by `run_pilot.py` and remains on the ephemeral runner. The current report
captures screenshots on failed scenarios and embeds detailed test evidence, so it has not passed a
full-tree public-safety review. A Pages-ready Serenity build still needs a separate synthetic-input
run with attachments disabled and an audit of every HTML, JSON, and asset before retention.

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
It builds the Flutter E2E bundle, starts an isolated SitePulse stack, runs
`npm test` (five cases across the four pilot scenarios), generates the Serenity
report, and stops the stack. To run
against an already-running stack, use `npm test`, then run
`npx serenity-bdd run --features ../.specify/features` to generate the HTML report.

## Outputs

| Path | Content |
| --- | --- |
| `target/executions.jsonl` | SitePulse execution records (same schema as `e2e/support/executions.py`) |
| `target/junit-report.xml` | JUnit results |
| `target/site/serenity/index.html` | Serenity BDD report |
