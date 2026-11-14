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

### STORY-12-02: Compact unit directory
- **Status:** IN PROGRESS
- **Task Ref:** task-34 / GitHub issue #85
- **Description:** Provide the shared directory scaffold and compact responsive unit rows with searchable, filterable, naturally sorted, locally paged results and restorable view state.
- **Acceptance Criteria:**
  - Search folds Turkish resident names and matches phone digits; occupancy and block filters and natural unit sorting work together.
  - The manager can select row density, change pages, and restore the selected page and density.
  - The search query and active filters remain selected after app restoration.
  - Compact rows adapt from phone to desktop widths and provide distinct actions and details targets.
  - Rendering 1,000 and 10,000 units builds only rows for the current page.
- **Verification:** targeted Flutter tests, GUI scenarios, Flutter analysis, shared-component reuse, UI style, test ID, and logging standards checks.

Executable scenarios: [STORY-12-02-unit-directory.feature](../features/EPIC-12/STORY-12-02-unit-directory.feature).

### STORY-12-03: Person card API and reference-based commands
- **Status:** IN PROGRESS
- **Task Ref:** task-33 / GitHub issue #84
- **Description:** Expose scoped person search, role-free create, card read, version-checked edit and login routes, and let unit commands accept a `PersonRef` while legacy request fields remain for one release.
- **Acceptance Criteria:**
  - Person routes are limited to the caller's site; search reports role eligibility for a unit.
  - Duplicates and stale versions return coded 409 responses; a confirmed distinct person is created.
  - Household, occupancy and registration approval accept an existing or new person; the primary contact is selected by `person_id`.
- **Verification:** cargo build, clippy, tests, tenant isolation lint, API system checks against PostgreSQL.

Executable scenarios: [STORY-12-03-person-card-api.feature](../features/EPIC-12/STORY-12-03-person-card-api.feature).
