# Nightly quality checks

The SitePulse nightly quality workflow runs at 03:30 UTC and on demand. Each
job creates its own PostgreSQL database and runs the E2E backend and web bundle
on loopback. The workflow uploads JUnit, logs, and Playwright failure evidence
for each job. When a run on master fails, the workflow opens a GitHub issue or
updates the existing open nightly failure issue with the run link.

| Job | Check |
| --- | --- |
| Firefox and WebKit smoke | Existing `smoke` selection on each desktop browser |
| Mobile smoke | The same selection at 375 × 812 in Chromium |
| Accessibility | axe-core audits ten screens with Flutter semantics enabled. Critical violations and missing accessible names fail the job. All violations appear in per-screen JSON artifacts. |
| Performance | Runs the scheduler and measures API latency with 50 synthetic sites, each with 200 owned units. Measures 1,000 manual payments, 50 statements, and 50 bank previews with 20 transfers each. |
| Tenant authorization | Verifies a fixed set of documented routes against two fixture sites. Each check proves the resource exists and is accessible to its site's manager before testing the denied read. |

The accessibility audit excludes only Flutter Web's disabled hidden textarea used as its text-input
bridge. User-facing semantics remain in the axe scan; the excluded proxy count is recorded in JUnit.

The performance test applies the thresholds from the
[observability SLO matrix](../../docs/quality/product-action-observability-report.md#6-service-level-objectives-slos--alerting-hierarchy).
It expects at least 99.9% of sampled manual payments to finish within 800 ms, the
full accrual tick to finish within 30 minutes, and at least 98% of synthetic bank
rows to match within 60 seconds of submitting each statement. Statements have
no separate SLO in the matrix. The report includes their observed p95 and
maximum latency. This run uses deterministic synthetic data and reports a
point-in-time smoke measurement. Production SLOs use the observation windows
in the matrix.

The authorization suite checks reviewed fixtures. It uses the live OpenAPI
document to ensure each route remains part of the API. Its coverage is limited to
the routes listed in the test. Existing mutation and list isolation scenarios
remain in `tests/test_journey_tenant_isolation.py`.

## Local runs

Use the normal E2E prerequisites from `scripts/gui_e2e.py --help`. After
installing the Python requirements and the selected browser with Playwright,
run from `e2e/`:

```sh
python -m pytest tests/ --ignore=tests/test_linked_backend_suites.py -m smoke --browser firefox
python -m pytest tests/ --ignore=tests/test_linked_backend_suites.py -m smoke --browser webkit
SITEPULSE_E2E_VIEWPORT_WIDTH=375 python -m pytest tests/ --ignore=tests/test_linked_backend_suites.py -m smoke
python -m pytest nightly/test_performance.py -o junit_family=xunit1 --junitxml=.artifacts/junit.xml
python -m pytest nightly/test_tenant_contract.py
npm install --prefix /tmp/sitepulse-nightly-axe --ignore-scripts --no-audit --no-fund axe-core@4.10.3
SITEPULSE_AXE_JS=/tmp/sitepulse-nightly-axe/node_modules/axe-core/axe.min.js python -m pytest nightly/test_accessibility.py
```
