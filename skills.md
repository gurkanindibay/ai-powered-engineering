# Workspace Skills Registry

This document lists the available skills and custom tools available to AI agents in this workspace.

---

## 1. Database Verification & Inspection Tool (`database-verification`)

- **Skill Definition:** [.agents/skills/database-verification/SKILL.md](file:///.agents/skills/database-verification/SKILL.md)
- **Executable Script:** [apps/development-time/SitePulse/scripts/db_verify.py](file:///apps/development-time/SitePulse/scripts/db_verify.py) (symlinked to `scripts/db_verify.py`)
- **Purpose:** Direct PostgreSQL database access, data verification, schema inspection, and data integrity validation for the SitePulse platform (authored in Python for robust parsing and type handling).

### Capabilities:
- **`query <SQL>`**: Run arbitrary SQL query with formatted tabular output.
- **`query-json <SQL>`**: Run SQL query and return aggregated JSON array for automated assertions.
- **`tables`**: List all database tables, column counts, and live row counts.
- **`inspect <table_name>`**: Display column definitions, types, nullability, defaults, and 5 sample rows.
- **`residents [site_id]`**: Directory of all persons, units, owners, and tenants with active status and contact info.
- **`verify [site_id]`**: Full integrity report:
  1. Core entity counts (`sites`, `blocks`, `units`, `persons`, `users`, `dues_periods`, `dues_liabilities`, `collection_transactions`).
  2. Financial balances (total accrued, paid, delay penalties, status breakdowns).
  3. Orphan detection (orphaned units, orphaned dues, orphaned members).
  4. Virtual IBAN allocations per unit.

### Quick Usage Examples:
```bash
# Query any table
./scripts/db_verify.py query "SELECT id, full_name, email, person_type FROM persons;"

# Return JSON for automated checks
./scripts/db_verify.py query-json "SELECT * FROM units WHERE site_id = 1;"

# Inspect schema and sample data of a table
./scripts/db_verify.py inspect dues_liabilities

# Check all residents & owners of Site 1
./scripts/db_verify.py residents 1

# Run full health & integrity verification
./scripts/db_verify.py verify 1
```

---

## 1b. Schema Integrity Gate (`schema_integrity_check.py`)

- **Executable Script:** [apps/development-time/SitePulse/scripts/schema_integrity_check.py](file:///apps/development-time/SitePulse/scripts/schema_integrity_check.py) (symlinked to `scripts/schema_integrity_check.py`)
- **Purpose:** `backend/migrations/V*.sql` is the only schema source (applied by the backend's migration runner, `backend/src/migrations.rs`). The gate replays the migrations into a throwaway database and proves the constraints reject bad data, then runs an **upgrade test**: V1–V7, V7-era rows, then V8 onwards, asserting the rows survive, backfills run, every constraint is validated and the upgraded schema equals a fresh install.

### Capabilities:
- **Negative cases:** domains and vocabularies, FKs (phantom unit/site), ledgers RESTRICT unit deletion, paid-amount invariants, case-insensitive e-mail uniqueness, receipt sequence uniqueness, IBAN format, one active bank account per site.
- **Negative cases (V16 payment ledger):** receipts, allocations, advance ledger and idempotency keys are append-only; a `SETTLED` entry needs a receipt; one entry per receipt; entry amount/unit/channel/date are immutable; only `UNMATCHED -> SETTLED` (with receipt) and `SETTLED -> REVERSED` transitions; penalty accrual date not before the due date.
- **Negative cases (V17 / SPEC-006):** a reversal receipt names its original and a receipt is reversed at most once; a contra entry needs a reason and its reversal columns are immutable; `SETTLED -> REVERSED` needs a contra entry; a receipt with advance names the advance debtor; site tax id is 10/11 digits; one webhook claim per (bank account, transaction) and the payload hash is SHA-256 hex; one English reconciliation vocabulary; a bank account with statement history cannot be deleted; `PAID` iff fully paid; `payer_role` has no default.
- **Positive cases:** national ids never stored in clear text, unit owner follows the ownership history, an `UNMATCHED` entry settles in place, payer identity resolves from the ownership history, the purge switch lifts the ledger guard for one transaction only, a full SQL reversal keeps the drift views clean, TAH and IAD series number independently, the same transaction id is accepted for another account/site, `v_dues_effective_status` derives `OVERDUE`, `v_integrity_violations` empty on seed data.
- **Seed replay:** repeated seed loads preserve identity IDs (including mixed-case emails); archived sites/people and inactive users with reused slugs/emails remain unchanged, with no active links to archived people. Runs in rolled-back transactions on scratch databases named per process, allowing concurrent gate runs.
- **Upgrade path:** existing rows survive V8+ (incl. legacy `IDEMPOTENCY:<key>` receipt references copied into `payment_idempotency_keys` and PascalCase reconciliation statuses translated); the upgraded schema has no drift from a fresh install.

### Quick Usage Examples:
```bash
./scripts/schema_integrity_check.py          # human-readable
./scripts/schema_integrity_check.py --json   # CI
```

Released migrations are append-only: add `V<n+1>__name.sql` and register it in `backend/src/migrations.rs` (a unit test fails if a file is not registered). Seeds live in `backend/db/seed/`.

---

## 1c. Database Schema Designer (`database-schema-designer`)

- **Skill Definition:** [.agents/skills/database-schema-designer/SKILL.md](file:///.agents/skills/database-schema-designer/SKILL.md)
- **Source:** [OneWave-AI/claude-skills](https://github.com/OneWave-AI/claude-skills/tree/main/database-schema-designer)
- **Purpose:** Designs relational and document database schemas from requirements or application specifications — tables, keys, relationships, constraints, indexes derived from real query patterns, ERDs, and reversible migration scripts, with PostgreSQL (including Supabase), MySQL, SQLite, and MongoDB supported.
- **Key References:**
  - [PostgreSQL Patterns & Idioms](file:///.agents/skills/database-schema-designer/references/postgres.md)
  - [Schema Templates & Worked Examples](file:///.agents/skills/database-schema-designer/references/schema-templates.md)
  - [Output Format Guidelines](file:///.agents/skills/database-schema-designer/references/output-format.md)
  - [Other Engines (MySQL, SQLite, MongoDB)](file:///.agents/skills/database-schema-designer/references/other-engines.md)
- **SitePulse / Workspace Integration:**
  - Complements `schema_integrity_check.py` and `db_verify.py` by ensuring all newly authored migrations strictly adhere to 3NF normalization, explicit foreign key cascades/restrictions, numeric monetary fields (`NUMERIC(15,2)` / `rust_decimal`), case-insensitive uniqueness, tenant scoping (`site_id`), and query-driven partial indexes.

---

## 2. Rust Engineering Skills & Standards (`rust-skills`)

- **Skill Definition:** [.agents/skills/rust-skills/SKILL.md](file:///.agents/skills/rust-skills/SKILL.md)
- **Authoritative Standards Document:** [apps/development-time/SitePulse/docs/standards/RUST_STANDARDS.md](file:///apps/development-time/SitePulse/docs/standards/RUST_STANDARDS.md)
- **Rule Directives:** [.agents/rules/rust-standards.md](file:///.agents/rules/rust-standards.md)
- **Purpose:** 265 coding rules across 26 categories ([leonardomso/rust-skills](https://github.com/leonardomso/rust-skills)) covering ownership, error handling, async patterns, concurrency, memory optimization, and numeric precision (`rust_decimal`).
- **Agent Bindings:** Formally bound to **Architect Agent** (contracts, DTOs, migrations, concurrency models) and **Developer Agent** (synthesis, zero-clippy, zero-unwrap, persistence safety).

### 2a. SitePulse Rust Backend Workflow (`sitepulse-rust-backend`)

- **Skill Definition:** [.agents/skills/sitepulse-rust-backend/SKILL.md](file:///.agents/skills/sitepulse-rust-backend/SKILL.md)
- **Purpose:** How to apply `apps/development-time/SitePulse/docs/standards/RUST_STANDARDS.md` sections 10–16 in the backend. Covers where new code goes (`src/domain/` vs services vs db vs handlers), which shared primitives to reuse (`apportion`, `fold_turkish`, `TrIban`, `NormalizedEmail`, `fingerprint`, `ParseReport`), recipes for domain primitives, persisted contracts, money, external input and multi-tenant state, test conventions, verification commands, and a review checklist.

### 2b. Rust Standards Lint (`rust_standards_lint.py`)

- **Executable Script:** [apps/development-time/SitePulse/scripts/rust_standards_lint.py](file:///apps/development-time/SitePulse/scripts/rust_standards_lint.py) (symlinked to `scripts/rust_standards_lint.py`)
- **Purpose:** Mechanically enforces `apps/development-time/SitePulse/docs/standards/RUST_STANDARDS.md` sections 10–16 on `backend/src`.
  - **Hard rules** fail on any hit: `domain-purity` (no Axum/PostgreSQL/AppState/env in `src/domain/`), `layering` (only handlers/app/main import `crate::handlers`), `inline-email`, `inline-turkish-fold`, `inline-iban-check`, `regex-per-call`, `implicit-rounding` (`round_dp(..)`), `float-money`, `ad-hoc-hash` (SHA-256/HMAC outside `domain::fingerprint`), `non-english-identifier`, and `domain-unformatted`.
  - **Ratchet rules** count `unwrap`, `expect`, `string-error` (`Result<_, String>` in services), `pool-branch` and `unformatted-file`. These counts in `scripts/rust_standards_baseline.json` may only go down.
  - Comments, string/char literals and `#[cfg(test)]` modules are ignored. Run against the baseline commit, it reports all 75 issues fixed by the reusability work.
  - Gate `rust-standards-lint` in `run_tests.py`. Self-tests are in `harness/tests/test_rust_standards_lint.py`.

### Quick Usage Examples:
```bash
./scripts/rust_standards_lint.py                    # human-readable, exit 1 on findings
./scripts/rust_standards_lint.py --json             # CI / harness gate
./scripts/rust_standards_lint.py --no-fmt           # skip rustfmt-based rules (no cargo)
./scripts/rust_standards_lint.py --update-baseline  # lower the ratchet after paying down debt
```

---

## 3. Flutter & Dart Development Skills

- [dart-build-cli-app](file:///.agents/skills/dart-build-cli-app/SKILL.md): Dart CLI structure, argument parsing, and process control.
- [dart-add-unit-test](file:///.agents/skills/dart-add-unit-test/SKILL.md): Writing unit tests with `package:test`.
- [flutter-add-widget-test](file:///.agents/skills/flutter-add-widget-test/SKILL.md): Component-level UI tests with `WidgetTester`.
- [flutter-add-integration-test](file:///.agents/skills/flutter-add-integration-test/SKILL.md): Flutter Driver & end-to-end integration flows.
- [flutter-build-responsive-layout](file:///.agents/skills/flutter-build-responsive-layout/SKILL.md): Responsive UI layouts with `LayoutBuilder` and `MediaQuery`.
- [flutter-implement-json-serialization](file:///.agents/skills/flutter-implement-json-serialization/SKILL.md): JSON serialization models.
- [flutter-apply-architecture-best-practices](file:///.agents/skills/flutter-apply-architecture-best-practices/SKILL.md): Layered architecture (UI, Logic, Data).
- [dart-run-static-analysis](file:///.agents/skills/dart-run-static-analysis/SKILL.md): Static analysis and mechanical lint fixes.
- **[flutter-reusable-components](file:///.agents/skills/flutter-reusable-components/SKILL.md)**: SitePulse's shared Flutter component catalogue (`SpTone`, metrics, guidance cards, status badges, filter chips, `showSpSelection`, `SpMoneyFormField`/`MoneyInput`, `sp_clipboard.dart`, `ResidentSummary`, `readDecimal`, `BankFileParser`), when to promote a widget to a shared component, and the review checklist. Mandatory for SitePulse Flutter work through [.agents/rules/flutter-components.md](file:///.agents/rules/flutter-components.md); enforced by gate `flutter-reuse`.

---

## 4. Continuous Improvement & Tool Crystallization (`continuous-improvement-tooling`)

- **Skill Definition:** [.agents/skills/continuous-improvement-tooling/SKILL.md](file:///.agents/skills/continuous-improvement-tooling/SKILL.md)
- **Purpose:** Directs the agent to evaluate whether bespoke scripts, inspection routines, or verification procedures created during feature development or debugging have recurring value, and crystallize them into durable, well-documented Python CLI tools in `scripts/` for future iterations.

---

## 5. Persistence Lint (`memory_persistence_lint.py`)

- **Executable Script:** [apps/development-time/SitePulse/scripts/memory_persistence_lint.py](file:///apps/development-time/SitePulse/scripts/memory_persistence_lint.py) (symlinked to `scripts/memory_persistence_lint.py`)
- **Purpose:** Fails when database results are discarded again: `let _ = <db call>`, `.await.ok();` on a DB call, `if let Ok(..) = client.query(..)`, `parse_id_to_i64(..).unwrap_or(n>0)`, or a missing `#![deny(unused_must_use)]` in `src/lib.rs`. (The original code had 215 such violations.)

### Quick Usage Examples:
```bash
./scripts/memory_persistence_lint.py
./scripts/memory_persistence_lint.py --json
```

## 5a. Multi-Tenant & Lock Guardrails (`tenant_isolation_lint.py`, `lock_scope_lint.py`)

- **Executable Scripts:** [apps/development-time/SitePulse/scripts/tenant_isolation_lint.py](file:///apps/development-time/SitePulse/scripts/tenant_isolation_lint.py) and [apps/development-time/SitePulse/scripts/lock_scope_lint.py](file:///apps/development-time/SitePulse/scripts/lock_scope_lint.py) (both symlinked into `scripts/`)
- **Purpose:** Keep one site's data out of another's reach and keep the shared state lock off I/O (`apps/development-time/SitePulse/docs/standards/RUST_STANDARDS.md` §15.4–15.11).
  - `tenant_isolation_lint.py` rules: `unscoped-site-input` (a handler takes a `site_id`-bearing Query/Json without `TenantScope`), `unscoped-object-path` (a route's path id is not middleware-attributable and the handler takes no scope, e.g. `/capital-projects/:id`; both `.route(..)` and table-style `post "/p" => handlers::x` routes are parsed, and an unparseable router fails the rule; an `AuthzContext` handler must call `ctx.require(..)`, pin via `TenantScope` or state `// tenant-scope: checked in <Service::fn>`), `guessed-tenant` (`unwrap_or_else(|| "1".to_string())`, hard-coded `"site-..."`), `unbound-tenant-transaction` (a service transaction without `tx_bind_tenant`), `rls-coverage` (a tenant-keyed table without `sp_enable_tenant_rls`). Run against the pre-guardrail commit it reports 83 findings (35 unscoped handlers, 7 object paths, 6 guessed tenants, 4 unbound transactions, 31 tables without RLS).
  - `lock_scope_lint.py` rules: `write-guard-across-io` / `read-guard-across-io` (an `inner` guard alive at a database, pool, HTTP or I/O-service `.await`; opt out with `// lock-scope: allow <reason>`). It matches a whole statement, so an `.await` on a continuation line is still found. It reported 16 sites in total (10 on the pre-guardrail commit, plus 6 that the line-based first version missed), all now fixed.
  - Gates `tenant-lint` and `lock-lint` in `run_tests.py`. Self-tests: `harness/tests/test_tenant_isolation_lint.py`.
  - The database half of the guardrail is tested by `backend/tests/db_tenant_isolation_tests.rs` (gate `rust-db-test`, needs `DB_PASS`): RLS hides and refuses foreign rows in a bound transaction, GETs leave the ledger untouched, accrual offsets are booked with receipts and allocations, listings never cross sites, and ledger reads return 503 when PostgreSQL is gone.

### Quick Usage Examples:
```bash
./scripts/tenant_isolation_lint.py           # human-readable, exit 1 on findings
./scripts/tenant_isolation_lint.py --json    # gate tenant-lint
./scripts/lock_scope_lint.py --json          # gate lock-lint
./scripts/tenant_isolation_lint.py --backend /path/to/other/checkout/backend
(cd apps/development-time/SitePulse/backend && DB_PASS=... cargo test --test db_tenant_isolation_tests -- --ignored --test-threads=1)
```

## 5b. API System Check (`api_system_check.py`)

- **Executable Script:** [apps/development-time/SitePulse/scripts/api_system_check.py](file:///apps/development-time/SitePulse/scripts/api_system_check.py) (symlinked to `scripts/api_system_check.py`)
- **Purpose:** Creates a throwaway database, boots the real backend binary on a free port, seeds it, and checks over HTTP: every non-public route returns 401 without a token, forged tokens are rejected, cross-site resources return scoped 404, bank webhooks need a valid HMAC, 20 concurrent payments get unique receipt numbers, idempotent retries return the first receipt, receipts/inserts survive a backend restart, match-all settles an `UNMATCHED` entry in place (no duplicate ledger row), payments record the payer person on entry and receipt, the non-production site purge removes a site with ledger history atomically (SPEC-005 / V16); a tenant surplus is TENANT credit and a `TENANT -> OWNER` virman pays the owner's capital due (`tenant_surplus_virman`), a reversal issues an `IAD-` receipt with a contra entry, un-allocates, refunds advance, survives a restart and is idempotent (`reversal_restores_ledger`), webhook claims record account, receipt and payload hash and a reused id with other content is 409 (`webhook_claim_scoped`), the site tax id is validated and snapshotted on receipts (`issuer_snapshot_on_receipt`), the aging snapshot writes one row per unit/debtor per day (`debt_aging_snapshot_persisted`), and `v_integrity_violations` is empty afterwards (SPEC-006 / V17).

- **Additional payment coverage:** virman reversal, scoped statements, receipt PDFs/public verification, signed provider captures and budget-based accrual (SPEC-007 / V18).

```bash
DB_PASS=... ./scripts/api_system_check.py                    # all checks
DB_PASS=... ./scripts/api_system_check.py --only cross_site_forbidden,restart_persistence --json
```
Uses `psql` when on PATH, otherwise `docker exec <--pg-container> psql`.

SPEC-008 checks also verify durable household membership and rollback (`household_members_persisted`), session rotation/replay/logout (`security_session_lifecycle`), payment rollback on audit failure (`transactional_audit`), non-owner RLS and immutable evidence (`audit_scope_and_privileges`), database-only registration review (`registration_repository_scope`), second-approver support access (`support_grant_lifecycle`), and concurrent invitation consumption with identity/membership rollback (`invitation_atomic_registration`). The method/template inventory is parsed from the router registry. GUI bundles are rebuilt when source, dependencies, assets, or the API origin change; fixture resets preserve audit evidence.

- **Identity reuse:** `person_activation_lifecycle` checks immediate re-registration after archival, one active account, and preserved person history without a backend restart.

## 5a-2. Security Guardrails (`security_lint.py`, `dependency_audit.py`)

- **Executable Scripts:** [apps/development-time/SitePulse/scripts/security_lint.py](file:///apps/development-time/SitePulse/scripts/security_lint.py) and [apps/development-time/SitePulse/scripts/dependency_audit.py](file:///apps/development-time/SitePulse/scripts/dependency_audit.py)
- **Purpose:** Keep the weaknesses found in [SECURITY_ASSESSMENT.md](file:///apps/development-time/SitePulse/docs/quality/SECURITY_ASSESSMENT.md) from returning.
  - `security_lint.py` rules: `tracked-secret-file`, `hardcoded-secret`, `workflow-permissions`, `workflow-untrusted`, `unpinned-image`, `public-route` (a new `Public` route must be added to `public_routes` in the baseline after review), `dev-route-guard`, `permissive-cors`, `weak-crypto`, `insecure-token-storage`, `unsafe-python`, and the `internal-error-leak` ratchet. Accepted findings: `scripts/security_lint_baseline.json` (`--write-baseline` never accepts public routes). Only the working tree is scanned, not git history.
  - `dependency_audit.py` checks the versions pinned in `backend/Cargo.lock` and `flutter/pubspec.lock` against OSV. Accepted advisories go in `scripts/dependency_audit_allowlist.json` with `id`, `package`, `reason` and `expires`. Exit 2 means the audit could not run; it is never counted as passed.
  - Gate `security-lint` in `run_tests.py` (group `lint`); the dependency audit runs in `.github/workflows/security-audit.yml` (lock file changes, weekly, manual) because it needs the network. Self-tests: `harness/tests/test_security_lint.py`.

### Quick Usage Examples:
```bash
python3 apps/development-time/SitePulse/scripts/security_lint.py
python3 apps/development-time/SitePulse/scripts/security_lint.py --json
python3 apps/development-time/SitePulse/scripts/dependency_audit.py
python3 apps/development-time/SitePulse/scripts/dependency_audit.py --json
```

## 5b-2. GUI End-to-End Suite (`gui_e2e.py`)

- **Executable Script:** [apps/development-time/SitePulse/scripts/gui_e2e.py](file:///apps/development-time/SitePulse/scripts/gui_e2e.py) (symlinked to `scripts/gui_e2e.py`)
- **Purpose:** Runs the Playwright GUI suite (`apps/development-time/SitePulse/e2e/`) in a real browser against an isolated stack: a throwaway database `sitepulse_e2e_<pid>`, the real backend on :8180 and the Flutter web E2E bundle (`--dart-define=E2E=true`) on :9190. It never touches the developer stack on :8080. The database is reset to the seed before every test; tests fail on uncaught page errors or backend 5xx. Scenario catalogue: `apps/development-time/SitePulse/docs/testing/GUI_TEST_PLAN.md`.
- **Writing tests:** locate widgets only through page objects (`e2e/pages/`) and `testId(...)` ids (`flutter/lib/testing/test_id.dart`); mark known product bugs and gaps `xfail(strict=True, reason=...)`.

```bash
./scripts/gui_e2e.py --env-file apps/development-time/SitePulse/backend/.env   # whole suite (DB_PASS from the file)
DB_PASS=... ./scripts/gui_e2e.py run -m smoke --json                        # P0 only, JSON summary
DB_PASS=... ./scripts/gui_e2e.py run -k login --headed                      # watch it in a browser window
DB_PASS=... ./scripts/gui_e2e.py run --shard 2/8 --json                    # one of 8 duration-balanced shards (CI matrix)
DB_PASS=... ./scripts/gui_e2e.py serve                                      # keep the stack up while writing tests
./scripts/gui_e2e.py build                                                  # rebuild the E2E web bundle
```
Failure traces and screenshots: `apps/development-time/SitePulse/e2e/.artifacts/`. Exit codes: 0 pass, 1 test failures, 2 setup error.

### 5b-2a. E2E Shard Planner (`e2e_shard.py`)

- **Executable Script:** [apps/development-time/SitePulse/scripts/e2e_shard.py](file:///apps/development-time/SitePulse/scripts/e2e_shard.py)
- **Purpose:** Splits the GUI suite into N shards of similar run time, using the latest `duration_s` per test from `.specify/executions/runs` (a test with no recorded duration counts as the median). `gui_e2e.py run --shard I/N` (or `$SITEPULSE_E2E_SHARD`) loads it as a pytest plugin that deselects other shards' tests after marker and `-k` filtering. The partition is deterministic, so each test runs in exactly one shard. `sitepulse-ci.yml` runs the `e2e` job as an 8-shard matrix and ignores `e2e/tests/test_linked_backend_suites.py` there, because other CI gates already run the suites it wraps (`harness/tests/test_ci_linked_suites.py` enforces this). Self-tests: `harness/tests/test_e2e_shard.py`.

```bash
python3 apps/development-time/SitePulse/scripts/e2e_shard.py plan --shards 4          # expected seconds per shard
python3 apps/development-time/SitePulse/scripts/e2e_shard.py --json plan --shards 3
```

## 5b-3. testId Lint (`testid_lint.py`)

- **Executable Script:** [apps/development-time/SitePulse/scripts/testid_lint.py](file:///apps/development-time/SitePulse/scripts/testid_lint.py) (symlinked to `scripts/testid_lint.py`)
- **Purpose:** Fails when a widget `Key('<id>')` under `flutter/lib/ui` has no `testId('<id>', ...)` with the same id in the same file, so new widgets cannot become invisible to the GUI suite. Constructors that cannot carry a Semantics wrapper (DropdownMenuItem, Tab, Expanded, ...) are skipped; a key that only resets state is exempted with `// testid-lint: ignore`. Gate `testid-lint` in `run_tests.py`.

```bash
./scripts/testid_lint.py           # exit 1 and file:line for every missing testId
./scripts/testid_lint.py --json
```

## 5b-3b. UI Style Lint (`ui_style_lint.py`)

- **Executable Script:** [apps/development-time/SitePulse/scripts/ui_style_lint.py](file:///apps/development-time/SitePulse/scripts/ui_style_lint.py) (symlinked to `scripts/ui_style_lint.py`)
- **Purpose:** Enforces the design-system rules from `apps/development-time/SitePulse/docs/ux/UX_UI_EVALUATION_REPORT.md` on `flutter/lib/ui`. Hard rules fail on any hit: font sizes below 12 px, amounts printed by hand (`'₺${x.toStringAsFixed(2)}'`, `'₺$x'`; use `formatTry`/`MoneyFormatter`), emoji in string literals, the `Icons.g_mobiledata` stand-in, and floating popups or partial sheets (`no-popup`: `showDialog`, `showModalBottomSheet`, `AlertDialog`, `SimpleDialog`, `Dialog`; the constitution mandates full-screen pages, so use `AppFullscreenPage` or `showSpPage` with `SpAlertPage`/`SpDialogPage`/`SpSelectionPage` from `ui/components/sp_dialog_pages.dart`). Ratchet rules count literal `fontSize:` and `Color(0x…)` outside `ui/theme` and `ui/design_system`; the counts in `scripts/ui_style_baseline.json` may only go down. Comments are ignored. Gate `ui-style-lint` in `run_tests.py`.

```bash
./scripts/ui_style_lint.py                    # exit 1 with file:line:[rule] for every finding
./scripts/ui_style_lint.py --json
./scripts/ui_style_lint.py --update-baseline  # after removing literals: record the lower counts
```

## 5b-3c. Flutter Reuse Inventory (`flutter_reuse_inventory.py`)

- **Executable Script:** [apps/development-time/SitePulse/scripts/flutter_reuse_inventory.py](file:///apps/development-time/SitePulse/scripts/flutter_reuse_inventory.py) (symlinked to `scripts/flutter_reuse_inventory.py`)
- **Purpose:** Tracks component reuse from [apps/development-time/SitePulse/docs/reusability/flutter-reusability-report.md](file:///apps/development-time/SitePulse/docs/reusability/flutter-reusability-report.md). The inventory counts design-token adoption and repeated patterns in `flutter/lib/ui` (`EdgeInsets.` vs `AppSpacing.`, raw colours vs `SpTone.`, `appSnackBar(` vs `spSnackBar(`, shared-widget usage). Reuse rules fail with `--check`: `clipboard` (raw `Clipboard.setData` outside `sp_clipboard.dart`), `money-parse` (`Decimal.tryParse` in `lib/ui`; use `MoneyInput`/`SpMoneyFormField`), `json-decimal` (the `?? '0') ?? Decimal.zero` fallback; use `readDecimal`), and `bank-amount` (hand-rolled `.replaceAll('.', '').replaceAll(',', '.')`; use `BankFileParser.parseAmount`), `filter-chip` (raw `FilterChip(`; use `SpFilterChip`), `selection-page` (hand-built `SpSelectionPage(`; use `showSpSelection<T>`), and `raw-snackbar` (direct `SnackBar(`; use `SpToast`/`spSnackBar(kind:)`). Comments are ignored. Gate `flutter-reuse` in `run_tests.py`.

```bash
./scripts/flutter_reuse_inventory.py           # inventory table + rule findings (exit 0)
./scripts/flutter_reuse_inventory.py --check   # exit 1 when a reuse rule fires
./scripts/flutter_reuse_inventory.py --json
```

The full catalogue and the promotion procedure are in the [flutter-reusable-components](file:///.agents/skills/flutter-reusable-components/SKILL.md) skill. Shared Flutter components that the rules point to live in `flutter/lib/ui/design_system/` (`SpPageHeader`, `SpTone`, `SpMetricValue`/`SpIconMetric`, `SpGuidanceCard`, `SpStatusBadge`, `SpFilterChip`, `SpMoneyFormField`/`MoneyInput`, `SpIbanCopyRow`/`spCopyToClipboard`), `ui/components/sp_dialog_pages.dart` (`showSpSelection<T>`), `ui/residents/resident_directory.dart` (`ResidentSummary`, `matchesResidentFilters`, `ResidentOccupancyStats`) and `domain/formatting/json_decimal.dart` (`readDecimal`).

## 5b-4. GUI Traceability (`gui_traceability.py`)

- **Executable Script:** [apps/development-time/SitePulse/scripts/gui_traceability.py](file:///apps/development-time/SitePulse/scripts/gui_traceability.py) (symlinked to `scripts/gui_traceability.py`)
- **Purpose:** Joins the stories (`.specify/requirements`), the scenario catalogue (`apps/development-time/SitePulse/docs/testing/GUI_TEST_PLAN.md` §3) and the last GUI run (`e2e/.artifacts/junit.xml`, where each test records its `gui_ids`) into a per-story status: PASS, DEFECT (strict xfail), FAIL, NOT RUN, GAP, EXCLUDED or MISSING. `--write-status` refreshes the generated section in `COMPLETION_STATUS.md`. Exit 1 on FAIL or MISSING.

```bash
./scripts/gui_traceability.py                  # table
./scripts/gui_traceability.py --write-status   # after a GUI run
./scripts/gui_traceability.py --json
```

## 5b-5. Feature Traceability & Test History (`feature_traceability.py`)

- **Executable Script:** [apps/development-time/SitePulse/scripts/feature_traceability.py](file:///apps/development-time/SitePulse/scripts/feature_traceability.py) (symlinked to `scripts/feature_traceability.py`)
- **Purpose:** Epic → story → Gherkin scenario → execution traceability. The acceptance criteria are the `.feature` files under `.specify/features/EPIC-xx/` (tags `@EPIC-xx`, `@STORY-xx-yy`, `@SC-xx-yy-nn`; conventions in [.specify/features/README.md](file:///apps/development-time/SitePulse/.specify/features/README.md)). CI reports every PR's run (artifact `e2e-test-report`, see 5b-6). `gui_e2e.py run --affected --record --task "<task>"` (only the smoke set plus the epics its changes affect, unless shared code changed) records a run into `.specify/executions/` (run records plus a markdown report). `check` is the static gate `feature-traceability`; `check --require-run` is the gate `test-run-recorded` (last gate of `run_tests.py`, global gate of `harness_cli.py verify`), which, only while `require_recorded_run` is true in `.specify/executions/settings.json` (or `SITEPULSE_REQUIRE_RECORDED_RUN=1`; currently off), fails when a branch that changes behaviour has no recorded run or its latest run has a failing scenario; `task-report` prints the task's latest run for the PR; `runs`, `report` and `history <SC-|STORY-|EPIC- id>` read the history; `html` writes the dashboard.

```bash
./scripts/feature_traceability.py affected      # full suite, or smoke + affected epics (impact-map.json)
./scripts/feature_traceability.py check --require-run
./scripts/feature_traceability.py task-report
./scripts/feature_traceability.py runs --detail --limit 5
./scripts/feature_traceability.py report --epic EPIC-10 --steps
./scripts/feature_traceability.py history SC-10-01-01 --limit 20
./scripts/feature_traceability.py html          # e2e/.artifacts/feature-report.html
```

## 5b-6. CI Test Report (`ci_test_report.py`)

- **Executable Script:** [apps/development-time/SitePulse/scripts/ci_test_report.py](file:///apps/development-time/SitePulse/scripts/ci_test_report.py) (symlinked to `scripts/ci_test_report.py`)
- **Purpose:** Merges the e2e shard artifacts of one CI run (`e2e-shard-N`: junit.xml, executions.jsonl) into one report, without touching the committed history. Writes `test-report.md`, `feature-report.html` (committed history plus this run), `executions.jsonl`, `summary.json`, `product-status.json` and `product-status.html` (see 5b-8), and appends the stats to `$GITHUB_STEP_SUMMARY`. Job `test-report` in `sitepulse-ci.yml` uploads the result as artifact `e2e-test-report`. Use it locally on downloaded artifacts (`gh run download <run> -p 'e2e-shard-*' -D shards`).

```bash
./scripts/ci_test_report.py --shards shards --out /tmp/e2e-test-report --task "PR 131"
./scripts/ci_test_report.py --shards shards --out /tmp/e2e-test-report --json --no-summary
```

## 5b-7. Publish CI Test Report History (`publish_test_report.py`)

- **Executable Script:** [apps/development-time/SitePulse/scripts/publish_test_report.py](file:///apps/development-time/SitePulse/scripts/publish_test_report.py)
- **Purpose:** Adds a generated CI report to a cumulative static Pages site, keeps one URL per GitHub workflow run, updates `latest.html` (newest feature report), rebuilds the newest-first `history.html`, and renders the product status dashboard (5b-8) as `index.html`. `publish-test-report` in `sitepulse-ci.yml` publishes the site to `gh-pages` after master pushes.

```bash
python3 apps/development-time/SitePulse/scripts/publish_test_report.py --report /tmp/e2e-test-report --site /tmp/test-report-site --run-id 1234 --attempt 1 --json
```

## 5b-8. Product Status Dashboard (`product_status.py`)

- **Executable Script:** [apps/development-time/SitePulse/scripts/product_status.py](file:///apps/development-time/SitePulse/scripts/product_status.py) (symlinked to `scripts/product_status.py`)
- **Purpose:** The product view of the test report: per epic, how many stories have acceptance scenarios and how many scenarios are passing, failing, automated without a CI result, or planned; trends of stories, scenarios, automation and passing scenarios; what was added recently; and the CI run history. `snapshot` writes `product-status.json` for one run (catalogue growth is read from the git history of `.specify`, so it needs a full clone). `html` renders the dashboard from one or more snapshots or from a published site directory. `ci_test_report.py` writes the snapshot into artifact `e2e-test-report`; `publish_test_report.py` keeps one snapshot per run on `gh-pages` and renders the dashboard as the site's `index.html`.

```bash
./scripts/product_status.py snapshot --out /tmp/product-status.json
./scripts/product_status.py snapshot --executions apps/development-time/SitePulse/e2e/.artifacts/executions.jsonl --json
./scripts/product_status.py html --snapshot /tmp/product-status.json --out /tmp/product-status.html
./scripts/product_status.py html --site /tmp/test-report-site --out /tmp/product-status.html
```

## 5b-9. Mutation Scenarios (`mutation_scenarios.py`)

- **Executable Script:** [apps/development-time/SitePulse/scripts/mutation_scenarios.py](file:///apps/development-time/SitePulse/scripts/mutation_scenarios.py) (symlinked to `scripts/mutation_scenarios.py`)
- **Purpose:** Tests the tests. Applies hand-designed mutants from [harness/mutation/scenarios.toml](file:///apps/development-time/SitePulse/harness/mutation/scenarios.toml) (one realistic bug each: boundaries, rounding, sign, tenancy and authorization checks) one at a time, runs the suites named for each, restores the file, and reports killed / survived / unviable / skipped with a mutation score. `validate` fails when production code drifts from a scenario. The check also runs in `harness/tests/test_mutation_scenarios.py`, so it gates every PR: if a refactor touches a targeted line, rewrite that scenario's `original`/`mutant` for the new code instead of deleting it. CI does not run the mutation run itself. Each checkout has its own crash-recovery journal, and a suite that times out has its whole process group killed. Suites that need PostgreSQL run only with `--with postgres`. Analysis and results: [docs/testing/mutation-testing-analysis.md](file:///apps/development-time/SitePulse/docs/testing/mutation-testing-analysis.md).

```bash
python3 apps/development-time/SitePulse/scripts/mutation_scenarios.py validate
python3 apps/development-time/SitePulse/scripts/mutation_scenarios.py list --layer rust
python3 apps/development-time/SitePulse/scripts/mutation_scenarios.py run --area late-fee --markdown /tmp/mut.md --output /tmp/mut.json
python3 apps/development-time/SitePulse/scripts/mutation_scenarios.py restore   # after an interrupted run
```

## 5c. Test Execution & Verification Run (`run_tests.py`)

- **Executable Script:** [apps/development-time/SitePulse/scripts/run_tests.py](file:///apps/development-time/SitePulse/scripts/run_tests.py) (`run-tests.sh` is a wrapper; symlinked to `scripts/run_tests.py`)
- **Test Plan & Matrix:** [apps/development-time/SitePulse/docs/testing/TEST_PLAN_AND_EXECUTION_MATRIX.md](file:///apps/development-time/SitePulse/docs/testing/TEST_PLAN_AND_EXECUTION_MATRIX.md)
- **Purpose:** Runs platform verification across 6 execution cases: full platform run, area-specific verification (`finance`, `auth`, `residents`, `ui`, `db`, `core`), or change-driven selective testing (`--changed`) using real compilers, linters, test targets, and database tools. The fast Python gates run first, so a lint failure reports in seconds. `GATE_GROUPS` splits the gates into the groups that `.github/workflows/sitepulse-ci.yml` runs as parallel jobs; `harness/tests/test_run_tests_groups.py` fails when a gate is in no group or a group is not run in CI.

```bash
# Area-specific verification & change-driven testing
./scripts/run_tests.py --list-areas               # list all 6 functional areas and their test assets
./scripts/run_tests.py --area ui                  # run UI design system & widget test battery
./scripts/run_tests.py --area finance --skip-db   # run finance invariants & ledger tests without DB
./scripts/run_tests.py --changed --skip-db        # auto-detect git diff/status and run tests covering changes
./scripts/run_tests.py --area finance --plan      # dry-run print execution plan without running tests

# Global & CI verification gates
DB_PASS=... ./scripts/run_tests.py            # everything including GUI Playwright suite
./scripts/run_tests.py --from-dev-container  # load local container credentials without printing them
./scripts/run_tests.py --skip-db              # DB gates (incl. gui-e2e) reported as SKIPPED, not passed
DB_PASS=... ./scripts/run_tests.py --skip-gui # everything except the browser suite (CI gate)
./scripts/run_tests.py --only rust-test,money-fixtures --json
./scripts/run_tests.py --group lint           # one CI job's gates: lint (Python, seconds), rust, flutter, e2e, final
./scripts/run_tests.py --changed --skip-db --summary   # agent-friendly: one line per gate, <=15 diagnostic lines per failure
```

## 5c-2. Token Guard Hook (`token_guard.py`)

- **Executable Script:** [scripts/token_guard.py](file:///scripts/token_guard.py), wired in [.claude/settings.json](file:///.claude/settings.json) as a `PreToolUse`/`PostToolUse` hook.
- **Purpose:** Keeps agent context small, because every tool result is re-sent on each later step. It denies `cat` of files over 50 KB, `ls -R`, unfiltered `find`, `Read` of files over 50 KB without offset/limit, and browser screenshots without `scale` <= 0.5 (including inside `browser_batch`). Each denial suggests a cheaper alternative. Bash results over 30K characters get a non-blocking reminder. Set `TOKEN_GUARD=off` to disable it.

```bash
echo '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls -R"}}' | python3 scripts/token_guard.py --json
python3 -m unittest discover -s tests/token_guard
```

## 5c-3. Issue Claim Labels (`issue_claim.py`)

- **Executable Script:** [scripts/issue_claim.py](file:///scripts/issue_claim.py)
- **Purpose:** Lets different agent harnesses identify each other. A claim is two labels: `in progress` and one owner label `claim:<harness>/<session-id>` (harness: codex, claude, antigravity), so harness and session can't drift apart. Concurrent claims are settled by GitHub's labeled-event order: the first claim wins and the loser removes only its own label. `claim` refuses an issue owned by another session (or a legacy bare `in progress`), `release` only removes the caller's own claim, `status` reports the owner. Session id: `--session`, else `$AGENT_SESSION_ID`, else `$<HARNESS>_SESSION_ID`, else generated and printed.

```bash
python3 scripts/issue_claim.py claim 123 --harness claude --session <id>
python3 scripts/issue_claim.py sync 123 --pr 130   # copy the issue labels to its PR
python3 scripts/issue_claim.py claim 123 --harness claude --session <id> --pr 130   # claim + label PR
python3 scripts/issue_claim.py status 123 --json
python3 scripts/issue_claim.py release 123 --harness claude --session <id> --pr 130   # clears issue and PR
python3 -m unittest discover -s tests/issue_claim
```

## 5c-4. PR Review Bot (`review_bot.py`)

- **Executable Script:** [scripts/review_bot.py](file:///scripts/review_bot.py)
- **Purpose:** Posts PR reviews and comments as the `local-reviewer-agent` GitHub App instead of a personal account (AGENTS.md rule 14). It signs the app JWT with `openssl`, mints and caches an installation token, and submits real reviews. `--commit` refuses to post if the PR head moved after the review was written. Configuration comes from the untracked `.env` (`REVIEW_BOT_APP_ID`, `REVIEW_BOT_INSTALLATION_ID`, `REVIEW_BOT_KEY`, `REVIEW_BOT_REPO`). The worktree's `.env` is read first, then the main checkout's.

```bash
python3 scripts/review_bot.py whoami --json
python3 scripts/review_bot.py review 123 --event APPROVE --body-file review.md --commit <head-sha>
python3 scripts/review_bot.py review 123 --event REQUEST_CHANGES --body-file review.md --commit <head-sha>
python3 scripts/review_bot.py comment 123 --body-file note.md
python3 scripts/review_bot.py gh -- api repos/{owner}/{repo}/pulls/123/reviews   # any gh call as the bot
python3 -m unittest discover -s tests/review_bot
```

## 5d. Harness CLI (`harness/harness_cli.py`)

- **Purpose:** Task DAG scheduler and verification loop. `verify --task <id>` runs the global build gates, the task's `gates` and its named `acceptance_tests` (read-only). `--record` (CI only) writes `.specify/evidence/<task>.json` (git SHA, gate results, timestamps) and updates the status with a retry budget (FAILED, then BLOCKED). `python3 harness/rtm_validator.py` accepts a VERIFIED requirement only with passing evidence from the current commit.

```bash
python3 apps/development-time/SitePulse/harness/harness_cli.py status
python3 apps/development-time/SitePulse/harness/harness_cli.py gates
python3 apps/development-time/SitePulse/harness/harness_cli.py verify --task task-16 --no-global --json
```

## 5e. Password Hash Generator (`hash-password`)

- **Binary:** `apps/development-time/SitePulse/backend/src/bin/hash_password.rs`
- **Purpose:** Prints the argon2id PHC hash of a password read from stdin, for seed files and manual account resets. Plaintext and placeholder hashes are rejected by the backend.

```bash
echo -n 'new-password' | cargo run --quiet --bin hash-password   # from backend/
```

---

## 6. Durable Engineering Harness (`development_harness.py`)

- **Skill:** [.agents/skills/team-orchestration/SKILL.md](.agents/skills/team-orchestration/SKILL.md)
- **Guide:** [apps/development-time/SitePulse/docs/engineering-process/engineering-harness.md](apps/development-time/SitePulse/docs/engineering-process/engineering-harness.md)
- **Runtime:** `scripts/development_harness.py` (Python 3.12+, Docker for execution).
- **Planner compatibility:** `scripts/team_orchestrator.py`; plans only, unresolved model targets without capabilities.
- **Capabilities:** five specialized roles plus conditional Architect, risk floors, live target validation, SQLite scheduling, decimal budgets, per-attempt evidence, cancellation/recovery, container isolation and trusted final-candidate gates.
- **CLI:** `plan`, `create`, `step`, `run`, `status`, `cancel`, `recover`, `events`, `audit`, `evaluate`, `validate-policy`, `sitepulse-policy`, `t3-dispatch`, `t3-submit`, `t3-heartbeat`; `--help` and `--json` supported.
- **T3 transport:** `--t3-catalog` (saved `orchestrator_capabilities` output) routes roles to T3 child-agent models from `config/engineering-harness/t3-registry.json`; the T3 orchestrator sends each `t3-dispatch` payload via `delegate_task` and returns the child's message with `t3-submit`.

```bash
python3 scripts/development_harness.py --json plan --task "Implement payment reconciliation" --financial
python3 scripts/development_harness.py --json evaluate --cases config/engineering-harness/routing-cases.json
python3 -m unittest discover -s tests/engineering_harness -v
```

Execution needs a digest-pinned bridge/toolchain image and operator policy. The bundled gateway bridge uses live `/v1/models` and Chat Completions through an external credential-brokering proxy. Registry tiers/prices require operator evaluation; fixture results do not establish model quality. Existing SitePulse checks are reused through a generated policy. Full setup and protocol schemas are in the guide.

### Core Rules:
1. **Notice Repetitive Need:** If an ad-hoc query or multi-step command is executed more than once, extract and structure it.
2. **Author in Python:** Build with `argparse`, type annotations, structured table output, and `--json` support.
3. **Persist & Symlink:** Store in project `scripts/` (with workspace root symlinks where appropriate) and set executable permissions.
4. **Register in Skills:** Keep `skills.md` and `.agents/skills/` up to date so future sessions immediately discover and leverage the tool.
## 5b-5. Person Integrity Baseline (`person_integrity_report.py`)

- **Executable Script:** `apps/development-time/SitePulse/scripts/person_integrity_report.py`
- **Purpose:** Read-only baseline for people without a site, household members without a person link, multiple active logins, primary contacts that do not match a person on their unit, likely duplicate person groups, and unit count.
- **Usage:** `python3 apps/development-time/SitePulse/scripts/person_integrity_report.py [--json]`
- **Database:** Uses `DATABASE_URL` or `DB_HOST`, `DB_PORT`, `DB_USER`, and `DB_PASS`. Requires `psql` on `PATH`.

