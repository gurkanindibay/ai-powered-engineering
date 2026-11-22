# SitePulse test reporting on GitHub Pages

## Recommendation

Use the existing [SitePulse Pages dashboard](https://gurkanindibay.github.io/ai-powered-engineering/) as the entry point for all SitePulse CI results. Add a per-run test inventory for every suite, and keep the existing epic, story, and scenario views for acceptance evidence. Publish a Cucumber pilot view when a pilot run is available. If the team wants the Serenity presentation on Pages, generate it from reviewed, public-safe inputs. The full generated report belongs with the raw diagnostics in Actions artifacts, whose access follows the source repository's permissions. This repository is public, so artifact storage alone does not make the report confidential.

This proposal covers reporting for SitePulse CI and the Cucumber pilot. It does not require rewriting existing tests in Gherkin or adopting a new canonical runner. Adding missing behavioral coverage is a separate backlog item.

## What exists today

- [SitePulse CI](../../../../../.github/workflows/sitepulse-ci.yml) runs eight pytest/Playwright shards. The [report builder](../../scripts/ci_test_report.py) totals shard JUnit counts and merges execution records for the Gherkin catalogue. It does not render a case-by-case list from JUnit, so tests without a scenario link count toward the totals but lack an individual row in the report.
- The [Cucumber pilot](../../e2e-cucumber/README.md) runs five cases across four scenarios. It produces JUnit XML, SitePulse execution JSONL, and a Serenity BDD HTML site. It has no CI job today. The [migration analysis](cucumber-serenity-migration-analysis.md#pilot-execution-results-and-evaluation) records that the rendered report contains transaction IDs, test IBANs, and internal UI routes.
- The public Pages source is `gh-pages:/`. The [publisher](../../scripts/publish_test_report.py) maintains the product dashboard, latest feature report, and a run-and-attempt archive. The public branch and latest successful Pages build pointed at the same commit when checked. Even so, a successful branch push alone is not deployment evidence. GitHub documents that pushes using the workflow's `GITHUB_TOKEN` do not trigger Pages builds. [GitHub Pages publishing source](https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site#troubleshooting-publishing-from-a-branch)
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
