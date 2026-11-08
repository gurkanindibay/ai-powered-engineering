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
- **Upgrade path:** existing rows survive V8+ (incl. legacy `IDEMPOTENCY:<key>` receipt references copied into `payment_idempotency_keys` and PascalCase reconciliation statuses translated); the upgraded schema has no drift from a fresh install.

### Quick Usage Examples:
```bash
./scripts/schema_integrity_check.py          # human-readable
./scripts/schema_integrity_check.py --json   # CI
```

Released migrations are append-only: add `V<n+1>__name.sql` and register it in `backend/src/migrations.rs` (a unit test fails if a file is not registered). Seeds live in `backend/db/seed/`.

---

## 2. Rust Engineering Skills & Standards (`rust-skills`)

- **Skill Definition:** [.agents/skills/rust-skills/SKILL.md](file:///.agents/skills/rust-skills/SKILL.md)
- **Authoritative Standards Document:** [docs/RUST_STANDARDS.md](file:///docs/RUST_STANDARDS.md)
- **Rule Directives:** [.agents/rules/rust-standards.md](file:///.agents/rules/rust-standards.md)
- **Purpose:** 265 coding rules across 26 categories ([leonardomso/rust-skills](https://github.com/leonardomso/rust-skills)) covering ownership, error handling, async patterns, concurrency, memory optimization, and numeric precision (`rust_decimal`).
- **Agent Bindings:** Formally bound to **Architect Agent** (contracts, DTOs, migrations, concurrency models) and **Developer Agent** (synthesis, zero-clippy, zero-unwrap, persistence safety).

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

## 5b. API System Check (`api_system_check.py`)

- **Executable Script:** [apps/development-time/SitePulse/scripts/api_system_check.py](file:///apps/development-time/SitePulse/scripts/api_system_check.py) (symlinked to `scripts/api_system_check.py`)
- **Purpose:** Creates a throwaway database, boots the real backend binary on a free port, seeds it, and checks over HTTP: every non-public route returns 401 without a token, forged tokens are rejected, cross-site resources return scoped 404, bank webhooks need a valid HMAC, 20 concurrent payments get unique receipt numbers, idempotent retries return the first receipt, receipts/inserts survive a backend restart, match-all settles an `UNMATCHED` entry in place (no duplicate ledger row), payments record the payer person on entry and receipt, the non-production site purge removes a site with ledger history atomically (SPEC-005 / V16); a tenant surplus is TENANT credit and a `TENANT -> OWNER` virman pays the owner's capital due (`tenant_surplus_virman`), a reversal issues an `IAD-` receipt with a contra entry, un-allocates, refunds advance, survives a restart and is idempotent (`reversal_restores_ledger`), webhook claims record account, receipt and payload hash and a reused id with other content is 409 (`webhook_claim_scoped`), the site tax id is validated and snapshotted on receipts (`issuer_snapshot_on_receipt`), the aging snapshot writes one row per unit/debtor per day (`debt_aging_snapshot_persisted`), and `v_integrity_violations` is empty afterwards (SPEC-006 / V17).

```bash
DB_PASS=... ./scripts/api_system_check.py                    # all checks
DB_PASS=... ./scripts/api_system_check.py --only cross_site_forbidden,restart_persistence --json
```
Uses `psql` when on PATH, otherwise `docker exec <--pg-container> psql`.

SPEC-007 checks also verify session rotation/replay/logout (`security_session_lifecycle`), payment rollback on audit failure (`transactional_audit`), non-owner RLS and immutable evidence (`audit_scope_and_privileges`), database-only registration review (`registration_repository_scope`), second-approver support access (`support_grant_lifecycle`), and concurrent invitation consumption with identity/membership rollback (`invitation_atomic_registration`). The method/template inventory is parsed from the router registry. GUI bundles are rebuilt when source, dependencies, assets, or the API origin change; fixture resets preserve audit evidence.

## 5b-2. GUI End-to-End Suite (`gui_e2e.py`)

- **Executable Script:** [apps/development-time/SitePulse/scripts/gui_e2e.py](file:///apps/development-time/SitePulse/scripts/gui_e2e.py) (symlinked to `scripts/gui_e2e.py`)
- **Purpose:** Runs the Playwright GUI suite (`apps/development-time/SitePulse/e2e/`) in a real browser against an isolated stack: a throwaway database `sitepulse_e2e_<pid>`, the real backend on :8180 and the Flutter web E2E bundle (`--dart-define=E2E=true`) on :9190. It never touches the developer stack on :8080. The database is reset to the seed before every test; tests fail on uncaught page errors or backend 5xx. Scenario catalogue: `apps/development-time/SitePulse/docs/GUI_TEST_PLAN.md`.
- **Writing tests:** locate widgets only through page objects (`e2e/pages/`) and `testId(...)` ids (`flutter/lib/testing/test_id.dart`); mark known product bugs and gaps `xfail(strict=True, reason=...)`.

```bash
./scripts/gui_e2e.py --env-file apps/development-time/SitePulse/backend/.env   # whole suite (DB_PASS from the file)
DB_PASS=... ./scripts/gui_e2e.py run -m smoke --json                        # P0 only, JSON summary
DB_PASS=... ./scripts/gui_e2e.py run -k login --headed                      # watch it in a browser window
DB_PASS=... ./scripts/gui_e2e.py serve                                      # keep the stack up while writing tests
./scripts/gui_e2e.py build                                                  # rebuild the E2E web bundle
```
Failure traces and screenshots: `apps/development-time/SitePulse/e2e/.artifacts/`. Exit codes: 0 pass, 1 test failures, 2 setup error.

## 5b-3. testId Lint (`testid_lint.py`)

- **Executable Script:** [apps/development-time/SitePulse/scripts/testid_lint.py](file:///apps/development-time/SitePulse/scripts/testid_lint.py) (symlinked to `scripts/testid_lint.py`)
- **Purpose:** Fails when a widget `Key('<id>')` under `flutter/lib/ui` has no `testId('<id>', ...)` with the same id in the same file, so new widgets cannot become invisible to the GUI suite. Constructors that cannot carry a Semantics wrapper (DropdownMenuItem, Tab, Expanded, ...) are skipped; a key that only resets state is exempted with `// testid-lint: ignore`. Gate `testid-lint` in `run_tests.py`.

```bash
./scripts/testid_lint.py           # exit 1 and file:line for every missing testId
./scripts/testid_lint.py --json
```

## 5b-3b. UI Style Lint (`ui_style_lint.py`)

- **Executable Script:** [apps/development-time/SitePulse/scripts/ui_style_lint.py](file:///apps/development-time/SitePulse/scripts/ui_style_lint.py) (symlinked to `scripts/ui_style_lint.py`)
- **Purpose:** Enforces the design-system rules from `docs/UX_UI_EVALUATION_REPORT.md` on `flutter/lib/ui`. Hard rules fail on any hit: font sizes below 12 px, amounts printed by hand (`'₺${x.toStringAsFixed(2)}'`, `'₺$x'`; use `formatTry`/`MoneyFormatter`), emoji in string literals, the `Icons.g_mobiledata` stand-in, and floating popups or partial sheets (`no-popup`: `showDialog`, `showModalBottomSheet`, `AlertDialog`, `SimpleDialog`, `Dialog`; the constitution mandates full-screen pages, so use `AppFullscreenPage` or `showSpPage` with `SpAlertPage`/`SpDialogPage`/`SpSelectionPage` from `ui/components/sp_dialog_pages.dart`). Ratchet rules count literal `fontSize:` and `Color(0x…)` outside `ui/theme` and `ui/design_system`; the counts in `scripts/ui_style_baseline.json` may only go down. Comments are ignored. Gate `ui-style-lint` in `run_tests.py`.

```bash
./scripts/ui_style_lint.py                    # exit 1 with file:line:[rule] for every finding
./scripts/ui_style_lint.py --json
./scripts/ui_style_lint.py --update-baseline  # after removing literals: record the lower counts
```

## 5b-4. GUI Traceability (`gui_traceability.py`)

- **Executable Script:** [apps/development-time/SitePulse/scripts/gui_traceability.py](file:///apps/development-time/SitePulse/scripts/gui_traceability.py) (symlinked to `scripts/gui_traceability.py`)
- **Purpose:** Joins the stories (`.specify/requirements`), the scenario catalogue (`docs/GUI_TEST_PLAN.md` §3) and the last GUI run (`e2e/.artifacts/junit.xml`, where each test records its `gui_ids`) into a per-story status: PASS, DEFECT (strict xfail), FAIL, NOT RUN, GAP, EXCLUDED or MISSING. `--write-status` refreshes the generated section in `COMPLETION_STATUS.md`. Exit 1 on FAIL or MISSING.

```bash
./scripts/gui_traceability.py                  # table
./scripts/gui_traceability.py --write-status   # after a GUI run
./scripts/gui_traceability.py --json
```

## 5c. Full Verification Run (`run_tests.py`)

- **Executable Script:** [apps/development-time/SitePulse/scripts/run_tests.py](file:///apps/development-time/SitePulse/scripts/run_tests.py) (`run-tests.sh` is a wrapper; symlinked to `scripts/run_tests.py`)
- **Purpose:** Runs every harness gate with the real tools: harness self-tests, `cargo build`, `clippy -D warnings`, `cargo test`, the shared money fixtures (Rust + Dart), `flutter analyze`, `flutter test`, the persistence lint, the testId lint, the schema gate, the API system check and the browser suite (`gui-e2e`, about 15 minutes; an unexpected XPASS fails it). A missing toolchain fails; nothing is printed as passed unless the tool passed; nothing in the repo is modified.

```bash
DB_PASS=... ./scripts/run_tests.py            # everything
./scripts/run_tests.py --from-dev-container  # load local container credentials without printing them
./scripts/run_tests.py --skip-db              # DB gates (incl. gui-e2e) reported as SKIPPED, not passed
DB_PASS=... ./scripts/run_tests.py --skip-gui # everything except the browser suite
./scripts/run_tests.py --only rust-test,money-fixtures --json
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

## 6. Team Orchestrator & Dynamic Model Selection (`team_orchestrator.py`)

- **Skill Definition:** [.agents/skills/team-orchestration/SKILL.md](file:///.agents/skills/team-orchestration/SKILL.md)
- **Executable Script:** [scripts/team_orchestrator.py](file:///scripts/team_orchestrator.py)
- **Purpose:** Multi-agent software engineering team orchestration across Product Owner, Architect, Developer, and Tester roles with dynamic model selection based on complexity (low, medium, high, critical).

### Capabilities:
- Automated complexity calculation based on task descriptions, file counts, and risk domains (financial invariants, schema migrations, concurrency, authentication).
- Dynamic model, provider, reasoning effort, and git worktree isolation configuration per role.
- Generates ready-to-run T3 `delegate_task` JSON payloads for automated execution.

### Quick Usage Examples:
```bash
# Auto-score complexity and view model assignments
./scripts/team_orchestrator.py --task "Implement payment gateway retry logic"

# Output structured JSON for automation or scripting
./scripts/team_orchestrator.py --task "Migrate user authentication schema" --schema --auth --json

# Explicitly override complexity
./scripts/team_orchestrator.py --task "Refactor logging pipeline" --complexity medium
```

### Core Rules:
1. **Notice Repetitive Need:** If an ad-hoc query or multi-step command is executed more than once, extract and structure it.
2. **Author in Python:** Build with `argparse`, type annotations, structured table output, and `--json` support.
3. **Persist & Symlink:** Store in project `scripts/` (with workspace root symlinks where appropriate) and set executable permissions.
4. **Register in Skills:** Keep `skills.md` and `.agents/skills/` up to date so future sessions immediately discover and leverage the tool.

