---
name: database-verification
description: >
  PostgreSQL database access, data verification, and schema inspection tool for SitePulse.
  Use whenever verifying database state, checking table record counts, validating
  integrity constraints, querying rows (as tables or JSON), inspecting residents/owners,
  or confirming data persistence across tests and live executions.
license: MIT
metadata:
  author: Antigravity
  version: "1.0.0"
---

# Database Verification & Access Skill

This skill provides direct PostgreSQL database access and automated data verification for the SitePulse residential management platform.

## When to Use

Use this skill whenever you need to:
- Inspect records in the PostgreSQL database (e.g. `persons`, `units`, `users`, `dues_liabilities`, `dues_periods`, `collection_transactions`, `unit_members`).
- Verify data persistence between user actions, API calls, and test executions.
- Check data integrity (orphaned records, foreign keys, total financial balances).
- Query records programmatically using JSON or formatted tabular outputs.

## Tool Execution

The primary database verification tool is a Python CLI located at:
- `apps/development-time/SitePulse/scripts/db_verify.py`
- Root symlink: `scripts/db_verify.py`

### Available Commands (Python CLI)

1. **Query Database (Tabular):**
   ```bash
   ./scripts/db_verify.py query "SELECT id, full_name, email, person_type FROM persons;"
   ```

2. **Query Database (JSON Output for script pipelines):**
   ```bash
   ./scripts/db_verify.py query-json "SELECT id, full_name, email, person_type FROM persons;"
   ```

3. **List All Tables & Record Counts:**
   ```bash
   ./scripts/db_verify.py tables
   # For JSON:
   ./scripts/db_verify.py --json tables
   ```

4. **Inspect Table Schema & Sample Rows:**
   ```bash
   ./scripts/db_verify.py inspect persons
   ./scripts/db_verify.py inspect units
   ./scripts/db_verify.py inspect dues_liabilities
   ```

5. **List Residents & Home Owners for a Site:**
   ```bash
   ./scripts/db_verify.py residents 1
   ```

6. **Full Database Health & Integrity Verification Report:**
   ```bash
   ./scripts/db_verify.py verify 1
   ```
   Outputs:
   - Core entity counts (sites, blocks, units, persons, users, periods, dues, collections).
   - Financial totals (principal accrued, paid, remaining, penalties, status counts).
   - Foreign key & orphan audits (units missing owners, orphaned dues, orphaned members).

7. **Schema Integrity Gate (schema sources + constraints):**
   ```bash
   ./scripts/schema_integrity_check.py          # human readable
   ./scripts/schema_integrity_check.py --json   # CI
   ```
   Replays the append-only `backend/migrations/V*.sql` into throwaway databases,
   uses per-process scratch database names, verifies constraints and the upgrade path, and loads `backend/db/seed/` against the
   current indexes. Repeat-seeding checks prove identity IDs remain stable and archived
   sites/people and inactive accounts remain unchanged when identifiers are reused.
   Migrations are the schema source; do not edit released migrations or regenerate them
   from seeds. Add regression checks to this gate rather than writing scratch seed SQL.

## Environment Details
- **Docker Container:** `sitepulse-postgres`
- **Database Name:** `sitepulse`
- **User:** `sitepulse_user`
- **Port:** `5432`
