# SitePulse test reporting on GitHub Pages

> **Superseded by the [SitePulse Test Strategy](TEST_STRATEGY.md) (2026-11-24).** Merged into the strategy (Reporting and evidence).

## Recommendation

Use the existing [SitePulse Pages dashboard](https://gurkanindibay.github.io/ai-powered-engineering/) as the entry point for all SitePulse CI results. Add a per-run test inventory for every suite, and keep the existing epic, story, and scenario views for acceptance evidence. The Cucumber/Serenity pilot is retired and has no Pages view. The full generated report belongs with the raw diagnostics in Actions artifacts, whose access follows the source repository's permissions. This repository is public, so artifact storage alone does not make the report confidential.

This proposal covers reporting for SitePulse CI. It does not require rewriting existing tests in Gherkin or adopting a new canonical runner. Adding missing behavioral coverage is a separate backlog item.

## What exists today

- [SitePulse CI](../../../../../.github/workflows/sitepulse-ci.yml) runs eight pytest/Playwright shards. The [report builder](../../scripts/ci_test_report.py) totals shard JUnit counts and merges execution records for the Gherkin catalogue. It does not render a case-by-case list from JUnit, so tests without a scenario link count toward the totals but lack an individual row in the report.
- The Cucumber/Serenity pilot was archived to the `pilot/cucumber-serenity-arm-b` tag. Its runner, report exporter, workflow and Pages view have been removed. The [migration analysis](cucumber-serenity-migration-analysis.md#pilot-execution-results-and-evaluation) is retained as historical context.
- The existing Pages source has been `gh-pages:/`. The legacy [publisher](../../scripts/publish_test_report.py) maintained the product dashboard, latest feature report, and a run-and-attempt archive. A branch push alone is not deployment evidence. GitHub's custom workflow uses `upload-pages-artifact` and `deploy-pages`; the deploy job needs `pages: write`, `id-token: write`, and a `github-pages` environment. [GitHub Pages custom workflows](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages)
- In [master run 45054743421](https://github.com/gurkanindibay/ai-powered-engineering/actions/runs/45054743421), verification, reporting, and publishing succeeded, but `record-evidence` failed because `history/runs` was missing from the downloaded report. The builder deletes its temporary history directory before upload. Restore an explicit Actions-only evidence payload and test its handoff before expanding that artifact contract.

## What the combined report would show

| CI source | Proposed collection |
| --- | --- |
| Python browser E2E | Parse individual JUnit test cases from all eight shards. Join scenario and step evidence from execution records where available. |
| Rust unit, integration, documentation, and opt-in PostgreSQL tests | Capture per-case results from the existing Cargo invocations or validated stable tooling. Check parity for doctests, ignored cases, and the explicit database selections before changing runners. |
| Flutter unit and widget tests | Capture the Flutter machine-reporter event stream and convert completed cases into the shared result format. Account for setup and runner errors. |
| Rust and Dart money fixtures | Collect both fixture runs. Show their gate outcomes and group repeat executions of the same case within the same suite. |
| Python harness self-tests | Capture `unittest` results with a result adapter that preserves discovery and exit behavior. |
| API system and schema checks | Expose individual checks where the existing JSON provides them, plus the overall gate result. |
| Build, lint, analysis, and final verification | Show gate outcomes and durations without adding them to case counts. |
| Cucumber and Serenity | Run the pilot on demand first. Collect JUnit for the case inventory and JSONL for step evidence. Generate the Serenity BDD site once per run and retain it as an Actions artifact after reviewing its contents against repository access. |

The reporting denominator is the SitePulse suites and gates expected for the selected run. The dashboard should show pass, fail, skip, and error, plus a visible missing, cancelled, or not-run status for each expected suite or shard. A configured suite that never started must not appear as a passing suite with zero tests. Historical runs should show the suites they actually collected.

Use commit, run ID, and attempt for the report identity. Use runner, suite, native test ID, and parameter or example ID for the case identity. Preserve execution attempts separately so reruns and fixture re-executions are visible without inflating unique-case counts. Use explicit `SC-*` mappings for acceptance evidence and keep outline examples distinct. During the pilot, pytest remains authoritative for overlapping scenarios, and Cucumber results are labeled as comparison evidence. Cases without a scenario mapping still appear in the test inventory, and pending requirements remain visible in the scenario view.

## Delivery sequence

1. Repair the existing evidence handoff. Define the expected suite and shard manifest, and extend the current report job to ingest structured outputs from the same executions CI already runs. Validate adapter counts against native output. Preserve failure and cancellation states and keep verification independent of report generation.
2. Add the inventory to the existing dashboard and archive. Generate a public payload from an explicit field allowlist, including statuses, durations, safe case names or IDs, and CI run links. Keep resolved step values, failure bodies, logs, screenshots, traces, and raw XML/JSON out of the Pages artifact. Apply the same boundary to existing rendered pages, which can currently show error text.
3. Move Pages publishing to the GitHub Actions source using `upload-pages-artifact` and `deploy-pages`. Deploy from `master` in the `github-pages` environment with Pages and OIDC permissions on the deployment job. Import existing archive links and retain reviewed historical content. Serialize deployments and prevent a late older run from replacing the latest report. Build PR reports as artifacts for review. [GitHub Pages custom workflows](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages)
4. Wire the pilot as an opt-in CI job using its Node, Java, Playwright, and isolated SitePulse stack. Publish an allowlisted Cucumber result view on Pages. Evaluate a separately generated public Serenity site using synthetic inputs and attachment settings. Review the complete generated tree, including embedded data, before publishing its HTML and assets together under the same run archive.

## Acceptance checks

- Every expected suite and shard appears for a master run, with case totals reconciled to native output. An interrupted shard, malformed result, or failed setup is visible as incomplete evidence and never counted as a pass.
- The pilot shows all five cases with distinct outline examples. Enabling it does not change authoritative scenario coverage or double-count overlapping scenarios.
- The product dashboard, latest report, and archive links resolve at the repository Pages URL. The deployed revision is verified against the Actions run that built it.
- A failure fixture containing representative sensitive values stays out of all public HTML, JSON, and assets. Diagnostic artifact access is appropriate for its contents.
- The `record-evidence` job can consume the exact history produced by its CI run, and the required verification check continues to reflect the test and gate outcomes.

## Pages source migration contract

The Pages Actions build is gated by repository variable `SITEPULSE_PAGES_ACTIONS_ENABLED`. Enable it only after the repository's Pages publishing source is Actions and the public inventory from delivery step 2 is integrated. The build also requires `public-report.json` and fails closed if the reviewed inventory is missing. The ordinary PR review artifact (`e2e-test-report`) remains available independently of Pages publishing.

The `gh-pages` branch remains archive storage, not the Pages publishing source. `scripts/pages_site.py` reads only JSON from that branch, deletes the old rendered HTML and Markdown, and rebuilds the existing routes (`index.html`, `latest.html`, `history.html`, and `reports/<run>-<attempt>/index.html`). Old runs without reviewed inventory receive a metadata-only detail page; their original HTML is deliberately discarded. The one-time migration therefore preserves archive URLs and rollup counts but removes legacy test prose, failure details, and other unreviewed presentation content.

The required Pages input `public-report.json` is schema 1: `gates` contains only `name`, `status`, and optional `duration_seconds`; `cases` contains only `id`, `name`, `status`, optional `duration_seconds`, and optional `scenario_id`. The renderer validates labels and status enums, accepts only finite non-negative durations, escapes all text, and generates Actions links from the run identity. Raw HTML, Markdown, XML, JSONL, traces, logs, and arbitrary URLs are not accepted. The inventory producer in delivery step 2 must write this file before the repository variable is enabled.

The archive marker `sitepulse-pages.json` records the run ID, workflow run number, attempt, commit, and Actions run ID. Workflow-level master concurrency serializes build/deploy runs; the builder compares `(run_number, attempt)` with the persisted marker and preserves a newer latest report if an older artifact arrives late. It also checks that `github.sha` is still the current `master` head before constructing the artifact. After deployment, the verifier fetches the marker, dashboard, latest report, history, and current archive at the environment URL and checks their identity and navigation links.
