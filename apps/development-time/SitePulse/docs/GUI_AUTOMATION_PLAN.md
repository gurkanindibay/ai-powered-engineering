# SitePulse GUI Automation: Plan to Build the Test Plan and Browser Test Suite

Status: DRAFT v2 (nothing implemented yet). Facts in this version were checked against the code on 2026-11-07.

**Goal:** a written GUI test plan, plus an automated suite that opens a real browser, logs in as each role and runs every user-facing scenario in the epics against the real backend and database.

## 1. Verified starting point

| Fact | Where it comes from | What it means for the plan |
|---|---|---|
| Flutter **3.47.5** (stable) | `flutter --version` | `Semantics(identifier: ...)` is supported and is rendered as a `flt-semantics-identifier` DOM attribute. Stable selectors are possible. |
| The web client draws to a canvas | Flutter web default | Without semantics turned on, the browser sees no buttons. The app must enable semantics in a test build. |
| About 160 `Key('...')` ids exist, mostly in `dashboard_screen.dart`, `owners_residents_module_page.dart` and `capital_projects_view.dart` | grep of `flutter/lib/ui` | These are reused as the naming scheme. Nothing new is invented. |
| The UI text is Turkish, e.g. "Eylül 2026" | handlers and seed data | Tests target ids, never visible text. Text is only checked where a scenario asserts it. |
| Seed users exist when `SITEPULSE_SEED_TEST_DATA=true` | `backend/src/state.rs` | Manager `mehmet.demir@begonya.com`, homeowner `ahmet.yilmaz@begonya.com`, SaaS admin `admin@sitepulse.io` (bootstrap password, `must_change_password: true`). Pending registration: `kerem.yilmaz@gmail.com`. |
| A reseed endpoint exists | `backend/src/app.rs:219`, `POST /api/v1/system/seed-test-fixtures` (refused in production) | Each test module can reset to known data without restarting the stack. |
| The login screen has separate homeowner and manager panels and prefills test passwords in test mode | `login_screen.dart:67-108` | Login tests must clear the prefilled fields first, so the result never depends on prefill. |
| `playwright` and `pytest` are **not installed**. Google Chrome is at `/usr/bin/google-chrome`. | local check | Add `e2e/requirements.txt` and a virtualenv. Run with `channel="chrome"` locally and bundled Chromium in CI. |
| About 128 acceptance criteria across 10 epics (EPIC-05 is backend only) | `.specify/requirements/` | Expect roughly 90–110 GUI scenarios once backend-only criteria are removed. |

## 2. Tool choice

**Playwright (Python) driving the Flutter web build through the semantics tree.** It runs a real browser against the real backend, records a trace, video and screenshot when a test fails, and follows the AGENTS.md rule to prefer Python. Flutter `integration_test` with chromedriver stays a fallback for widgets that can't be reached through semantics, such as custom painters.

For tests, build the app with `flutter build web --dart-define=E2E=true --dart-define=SITEPULSE_API_BASE_URL=http://localhost:8080` and serve it as static files. Release builds refuse to start without the API URL, by design. Don't use the `flutter run` dev server: it starts slower and changes with hot-reload state.

## 3. Phases

### Phase 0: Scenario catalogue (`docs/GUI_TEST_PLAN.md`)
1. For each epic except EPIC-05, turn every Given/When/Then criterion with a visible UI effect into a scenario.
2. Cross-check against the screens: login, dashboard and manager cockpit, dues management, payment tracking, bank reconciliation, manual unit assignment, residents and owners module, capital projects, SaaS admin, profile and role sheet, house types, checkout dialog, virtual IBAN card.
3. Each scenario records: id `GUI-<EPIC>-<NN>`, role, story id, preconditions and seed data, steps, expected UI result, an optional database check (`scripts/db_verify.py query-json`), and a priority (P0 smoke, P1 core, P2 edge).
4. Add a coverage table: each acceptance criterion is mapped to a GUI scenario, or marked "covered by unit/API test" with a reason.

**Exit check:** every story in `COMPLETION_STATUS.md` has at least one GUI scenario or a written exclusion.

### Phase 1: Make the app testable (small Flutter changes) — ✅ DONE 2026-11-07 (results in GUI_TEST_PLAN.md §6)
- Add `lib/testing/test_id.dart`: `Widget testId(String id, Widget child)` wraps the child in `Semantics(identifier: id)`.
- In `main.dart`, when `const bool.fromEnvironment('E2E')` is true, call `SemanticsBinding.instance.ensureSemantics()`. This never affects production builds.
- Wrap every element a scenario touches (existing `Key`s first) using the same id string. Commit screen by screen; `dashboard_screen.dart` is 8.5k lines, so keep those diffs small.
- **Exit check:** a short Playwright probe finds `login_*` ids and dashboard ids after login.

### Phase 2: Framework scaffold (`apps/development-time/SitePulse/e2e/`)
```
e2e/
  requirements.txt     # playwright, pytest, pytest-playwright, pytest-html (versions pinned)
  conftest.py          # stack check, reseed per module, browser context, login fixtures per role
  support/flutter.py   # by_id(page, id) -> locator('[flt-semantics-identifier="..."]'), wait for first frame
  support/money.py     # parse "₺1.400,00" into Decimal (never float)
  support/api.py       # reseed and read-back helpers for the backend
  pages/               # LoginPage, CockpitPage, DuesPage, PaymentTrackingPage, ReconciliationPage,
                       #   UnitAssignmentPage, ResidentsPage, CapitalProjectsPage, SaasAdminPage, ProfileSheet
  tests/test_epic01_*.py ... test_epic10_*.py, test_cross_cutting.py
  fixtures/bank/       # sample statement files for upload tests
```
- Markers: `smoke`, `core`, `edge`, `role_homeowner`, `role_manager`, `role_saas`.
- Reports: JUnit XML, an HTML report, and Playwright traces/videos for failed tests, written to `e2e/.artifacts/` (gitignored).
- Runner `scripts/gui_e2e.py` (Python, `--help`, `--json`) with `--build` (build the E2E web bundle), `--serve`, `--browser chrome|chromium|firefox|webkit`, `--headed`, `--marker`, `--base-url`, `--api-url`, `--skip-stack`. It checks `:8080/health` and the web port before running.

### Phase 3: Scenarios (P0 first, then P1, then P2)
| Epic | Example scenarios |
|---|---|
| EPIC-06 Auth | Login per role; wrong password shows `login_error_banner`; clear login cache; SaaS admin forced password change on first login; change password from the profile sheet; logout; role switch |
| EPIC-01 Resident dues | Hero balance card amount matches the API; dues breakdown; virtual IBAN card; checkout dialog; delay penalty (5% monthly) shown correctly |
| EPIC-02 Manager | Cockpit tiles; `btn_open_unified_dues_center`; segment tabs; house types and tariff modal with validation errors |
| EPIC-03 SaaS | Portfolio list; `btn_edit_site_*`; onboarding a new site, then logging in with the issued temporary credentials |
| EPIC-04 Invitations | Pending registration (Kerem Yılmaz) is approved or rejected by the manager, and the queue updates |
| EPIC-07 Bank | Upload a statement (`btn_stream_upload_bank_statement`); auto-matches; `banner_unmatched_bank_transactions` and resolve; manual unit assignment; matching criteria card |
| EPIC-08 Occupancy | Owner/tenant move-in and move-out; directory edit; ledger split across both ledgers |
| EPIC-09 Payments | Aging buckets; filters; `action_open_bank_reconciliation` link |
| EPIC-10 Capex | Create a project; fixture dues allocation; project view (reuse `TEST_PLAN_EPIC_10_CAPITAL_EXPENDITURE.md`) |
| Cross-cutting | Dark/light theme; zero-data guidance; 375px mobile smoke test; no uncaught console errors |

Rule for money: every amount shown on screen is parsed to `Decimal` and, for P0/P1, compared with the API or database value.

### Phase 4: Wiring it into the repo
- Add an optional `gui-e2e` gate to `scripts/run_tests.py`. With `--skip-gui` or no running stack it is reported SKIPPED, never PASSED, matching how `--skip-db` already behaves.
- Add a "GUI test" column to `COMPLETION_STATUS.md`.
- Add a harness lint: every `Key('x')` in `lib/ui` has a matching `testId('x')`.
- Document in `skills.md`, register in `.agents/skills/continuous-improvement-tooling`, and run `graphify update .`.

## 4. Risks and mitigations
- **Missing ids on new widgets:** the lint in Phase 4.
- **Flaky waits:** wait on ids and expected state, never fixed sleeps. Reseed per module. Retry once in CI only, and report flaky tests separately.
- **Resets wipe the dev database:** the reset endpoints (`reset-to-initial-state`, `seed-test-fixtures`) act on whichever backend the tests point at. Phase 2 must run its own backend on port 8180 against its own database (`sitepulse_e2e`), never the developer stack on 8080. The Phase 1 probe only logs in and reads, so it's safe on 8080.
- **Clock-dependent penalties:** see GUI_TEST_PLAN.md §4. Expected amounts come from the API, not from constants copied out of the stories.
- **Shared database across tests:** tests that write data (approvals, uploads, capex) each start with their own reseed. The stack is single-tenant (`site-1`), so these tests run one at a time.
- **SaaS bootstrap password:** read from the backend's environment or config (`bootstrap_admin_password()`), never hard-coded in tests.

## 5. Order of delivery and size
1. Phase 0 catalogue: about 0.5–1 day
2. Phase 1 ids and P0 probe: about 1 day
3. Phase 2 scaffold, runner, and P0 smoke (about 10 tests): about 1 day
4. Phase 3 P1, then P2, epic by epic: about 3–5 days
5. Phase 4 wiring: about 0.5 day

## 6. Open decisions
- CI target: local only, or a GitHub Actions job (needs Postgres and Rust in CI)?
- Browsers: Chrome only, or Chrome, Firefox and WebKit?
- Should the mobile layout get full scenarios, or only the smoke test?
