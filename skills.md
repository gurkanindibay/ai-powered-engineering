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

## 2. Rust Engineering Skills (`rust-skills`)

- **Skill Definition:** [.agents/skills/rust-skills/SKILL.md](file:///.agents/skills/rust-skills/SKILL.md)
- **Purpose:** 265 coding rules across 26 categories covering ownership, error handling, async patterns, concurrency, memory optimization, and numeric precision (`rust_decimal`).

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

### Core Rules:
1. **Notice Repetitive Need:** If an ad-hoc query or multi-step command is executed more than once, extract and structure it.
2. **Author in Python:** Build with `argparse`, type annotations, structured table output, and `--json` support.
3. **Persist & Symlink:** Store in project `scripts/` (with workspace root symlinks where appropriate) and set executable permissions.
4. **Register in Skills:** Keep `skills.md` and `.agents/skills/` up to date so future sessions immediately discover and leverage the tool.
