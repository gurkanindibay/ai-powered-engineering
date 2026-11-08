# Workspace Skills Registry

This document lists the available skills and custom tools available to AI agents in this workspace.

---

## 1. Database Verification & Inspection Tool (`database-verification`)

- **Skill Definition:** [.agents/skills/database-verification/SKILL.md](file:///.agents/skills/database-verification/SKILL.md)
- **Executable Script:** [apps/development-time/SitePulse/scripts/db-verify.sh](file:///apps/development-time/SitePulse/scripts/db-verify.sh) (symlinked to `scripts/db-verify.sh`)
- **Purpose:** Direct PostgreSQL database access, data verification, schema inspection, and data integrity validation for the SitePulse platform.

### Capabilities:
- **`query <SQL>`**: Run arbitrary SQL query with formatted tabular output.
- **`query-json <SQL>`**: Run SQL query and return aggregated JSON array for automated assertions.
- **`tables`**: List all database tables and estimated live row counts.
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
./scripts/db-verify.sh query "SELECT id, full_name, email, person_type FROM persons;"

# Return JSON for automated checks
./scripts/db-verify.sh query-json "SELECT * FROM units WHERE site_id = 1;"

# Inspect schema of a table
./scripts/db-verify.sh inspect dues_liabilities

# Check all residents & owners of Site 1
./scripts/db-verify.sh residents 1

# Run full health & integrity verification
./scripts/db-verify.sh verify 1
```

---

## 1b. Database Schema Designer (`database-schema-designer`)

- **Skill Definition:** [.agents/skills/database-schema-designer/SKILL.md](file:///.agents/skills/database-schema-designer/SKILL.md)
- **Source:** [OneWave-AI/claude-skills](https://github.com/OneWave-AI/claude-skills/tree/main/database-schema-designer)
- **Purpose:** Designs relational schemas, indexes, constraints, ERDs, and reversible migrations driven by real query patterns (PostgreSQL, MySQL, SQLite, MongoDB).

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
