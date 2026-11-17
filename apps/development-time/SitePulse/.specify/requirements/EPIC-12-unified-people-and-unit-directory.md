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

### STORY-12-04: People directory
- **Status:** IN PROGRESS
- **Task Ref:** task-37 / GitHub issue #88
- **Description:** Move the people list onto the shared directory scaffold while keeping the existing person profile page and server-side search, filters and paging.
- **Acceptance Criteria:**
  - Search and the existing role and login filters query the server and reset paging.
  - The shared pager requests the selected server page and page size without loading the whole directory.
  - Query, filters, page and page size survive app restoration; list scroll state survives opening and returning from a person profile.
  - The existing profile, import and audited CSV export remain available.
- **Verification:** targeted Flutter tests, GUI scenarios, Flutter analysis, shared-component reuse, UI style, test ID, and logging standards checks.

Executable scenarios: [STORY-12-04-people-directory.feature](../features/EPIC-12/STORY-12-04-people-directory.feature).

### STORY-12-05: Person card API and reference-based commands
- **Status:** IN PROGRESS
- **Task Ref:** task-33 / GitHub issue #84
- **Description:** Expose scoped person search, role-free create, card read, version-checked edit and login routes, and let unit commands accept a `PersonRef` while legacy request fields remain for one release.
- **Acceptance Criteria:**
  - Person routes are limited to the caller's site; search reports role eligibility for a unit.
  - Duplicates and stale versions return coded 409 responses; a confirmed distinct person is created.
  - Household, occupancy and registration approval accept an existing or new person; the primary contact is selected by `person_id`.
- **Verification:** cargo build, clippy, tests, tenant isolation lint, API system checks against PostgreSQL.

Executable scenarios: [STORY-12-05-person-card-api.feature](../features/EPIC-12/STORY-12-05-person-card-api.feature).

### STORY-12-06: Unit actions choose people through person cards
- **Status:** IN PROGRESS
- **Task Ref:** task-42 / GitHub issue #99
- **Description:** Connect the shared person field to the person API and replace inline person inputs in registration, move-in, title transfer, household and primary-contact actions; unit edit shows owner and tenant identity read-only and opens the person card.
- **Acceptance Criteria:**
  - Action pages keep no person text inputs; people are chosen or created through the shared person field.
  - Registration sends owner, tenant and household members as person references.
  - The primary contact is selected by person id.
- **Verification:** flutter analyze and tests, reuse, test-id and style lints.

Executable scenarios: [STORY-12-06-unit-action-person-inputs.feature](../features/EPIC-12/STORY-12-06-unit-action-person-inputs.feature).

### STORY-12-07: Person card and cross-navigation
- **Status:** IN PROGRESS
- **Task Ref:** task-43 / GitHub issue #100
- **Description:** Expand the person card with edit, login, unit links and role actions that start from the person; unit tabs link to the person card.
- **Acceptance Criteria:**
  - Unit to person to unit navigation keeps the unit list's search, filters and focus.
  - A card edit updates the owner, tenant and household roles the person holds on every unit shown.
  - A person without a login can be given one from the card; role actions ask for the unit with the person fixed.
- **Verification:** targeted Flutter tests, cargo build, Flutter analysis, shared-component reuse, UI style, test ID, and logging standards checks.

Executable scenarios: [STORY-12-07-person-card-navigation.feature](../features/EPIC-12/STORY-12-07-person-card-navigation.feature).

### STORY-12-08: Person card merge
- **Status:** IN PROGRESS
- **Task Ref:** task-44 / GitHub issue #101
- **Description:** Add the step-up protected merge flow to the person card using the server merge endpoint (task-38). Server unit-directory paging is not added: the filter and sort benchmark measures 133.1 ms at 10,000 units, under the 200 ms target (see `docs/architecture/UNIT_DIRECTORY_BENCHMARK.md`).
- **Acceptance Criteria:**
  - Merge is started from the person card, asks for confirmation, and requires a fresh password check (step-up).
  - The request carries the version of the surviving card so a stale card is refused.
  - A card cannot be merged into itself.
- **Verification:** targeted Flutter tests, Flutter analysis, shared-component reuse, test ID, and logging standards checks.

Executable scenarios: [STORY-12-08-person-merge-ui.feature](../features/EPIC-12/STORY-12-08-person-merge-ui.feature).

### STORY-12-09: Person import from Excel
- **Status:** DONE
- **Task Ref:** user-import-excel-csv
- **Description:** The site manager imports owners and tenants from an Excel (.xlsx) or CSV file. The Excel file is read in the app into the same CSV text the existing import API checks (dry run, then commit), so the server rules do not change. The page offers a CSV and an Excel template with the import columns and one example row.
- **Acceptance Criteria:**
  - The import page accepts `.xlsx`, `.csv` and `.txt` files.
  - The Excel template holds the import columns in order and one example row.
  - A file named `.xlsx` that is not a workbook is rejected with an error.
- **Verification:** targeted Flutter tests, Flutter analysis, shared-component reuse checks.

Executable scenarios: [STORY-12-09-person-import-excel.feature](../features/EPIC-12/STORY-12-09-person-import-excel.feature).

### STORY-12-10: Person actions repeated in cycles
- **Status:** DONE
- **Description:** Every person action (create, edit, open and remove a login, preferences, national id, merge, use of an existing card in unit actions) is performed several times. After each run the card, its login status, its unit relations and the unit history are read back. Moving a person out also closes the household relation of their dependents.
- **Acceptance Criteria:**
Executable scenarios: [STORY-12-10-person-action-cycles.feature](../features/EPIC-12/STORY-12-10-person-action-cycles.feature).
- **Verification:** `cargo test --test db_unit_person_action_cycles_tests -- --ignored --test-threads=1` (gate `rust-db-test`).
