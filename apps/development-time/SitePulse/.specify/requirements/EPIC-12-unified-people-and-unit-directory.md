# Epic: Unified People and Unit Directory

> **Epic ID:** EPIC-12
> **Module:** postgres-db, backend-rust, flutter-ui
> **Status:** SPECIFIED
> **Source:** [Unified owners and residents design](../../docs/OWNERS_RESIDENTS_UNIFIED_DESIGN.md)

## Overview

Represent a person once and derive unit roles and directory views from scoped relationships. Preserve existing data and request compatibility while the API and clients migrate to person references.

## User Stories

### STORY-12-01: Person schema foundations
- **Status:** IN PROGRESS
- **Task Ref:** task-32 / GitHub issue #83
- **Description:** Add normalized person search keys, optimistic version, merge tombstones, a person-based primary contact reference, and scoped directory and relationship views.
- **Acceptance Criteria:**
  - Existing person, unit, household, and primary contact rows survive the migration.
  - Search keys follow the shared Turkish name folding and phone key rules.
  - Primary contacts are backfilled only when their unit relationship can be resolved safely.
  - Directory and relationship views exclude deleted or merged people and stay within the unit's site.
  - Integrity checks report violations; constraints are added only when measured data and compatible write paths permit them.
- **Verification:** schema-integrity, PostgreSQL-backed tests, tenant isolation lint, and logging standards lint.

Executable scenarios: [STORY-12-01-person-schema-foundations.feature](../features/EPIC-12/STORY-12-01-person-schema-foundations.feature).
