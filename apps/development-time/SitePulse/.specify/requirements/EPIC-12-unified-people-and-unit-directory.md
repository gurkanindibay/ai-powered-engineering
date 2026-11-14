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

### STORY-12-03: Shared person selection components
- **Status:** IN PROGRESS
- **Task Ref:** task-36 / GitHub issue #87
- **Description:** Provide one typed person reference, an injectable repository boundary, a full-screen searchable picker, a duplicate-aware person form, a reusable person field, and person cards.
- **Acceptance Criteria:**
  - Existing person references and new person drafts serialize to the published API contract.
  - Search pages beyond the first 100 results and shows ineligible people with the server reason.
  - Creating a person surfaces duplicate candidates, blocks hard identity duplicates, and requires explicit confirmation for soft matches.
  - Person name, phone, and email editing lives in the shared person form.
  - Shared components keep stable automation ids and render in both themes at large text sizes.
- **Verification:** fake-repository Flutter tests, Flutter analysis, shared-component reuse, UI style, test ID, and logging standards checks.

Executable scenarios: [STORY-12-03-person-selection.feature](../features/EPIC-12/STORY-12-03-person-selection.feature).
