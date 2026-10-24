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

The database verification tool is located at:
- `apps/development-time/SitePulse/scripts/db-verify.sh`
- Root symlink: `scripts/db-verify.sh`

### Available Commands

1. **Query Database (Tabular):**
   ```bash
   ./scripts/db-verify.sh query "SELECT id, full_name, email, person_type FROM persons;"
   ```

2. **Query Database (JSON Output for JSON processing):**
   ```bash
   ./scripts/db-verify.sh query-json "SELECT id, full_name, email, person_type FROM persons;"
   ```

3. **List All Tables & Record Counts:**
   ```bash
   ./scripts/db-verify.sh tables
   ```

4. **Inspect Table Schema & Sample Rows:**
   ```bash
   ./scripts/db-verify.sh inspect persons
   ./scripts/db-verify.sh inspect units
   ./scripts/db-verify.sh inspect dues_liabilities
   ```

5. **List Residents & Home Owners for a Site:**
   ```bash
   ./scripts/db-verify.sh residents [site_id]
   # Example:
   ./scripts/db-verify.sh residents 1
   ```

6. **Full Database Health & Integrity Verification Report:**
   ```bash
   ./scripts/db-verify.sh verify [site_id]
   # Example:
   ./scripts/db-verify.sh verify 1
   ```
   Checks:
   - Core entity counts (sites, blocks, units, persons, users, periods, dues, transactions).
   - Financial balances (total accrued dues, paid amounts, penalties, status counts).
   - Integrity & orphan checks (orphaned units, orphaned dues, orphaned members).
   - Virtual IBAN allocations per unit with owner/tenant mapping.

## Environment Details
- **Docker Container:** `sitepulse-postgres`
- **Database Name:** `sitepulse`
- **User:** `sitepulse_user`
- **Port:** `5432`
