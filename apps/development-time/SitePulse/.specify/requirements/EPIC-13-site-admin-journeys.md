# Epic: Site Admin Journeys

> **Epic ID:** EPIC-13
> **Module:** E2E verification harness
> **Status:** IN PROGRESS

## Overview

The site admin journey suite verifies connected workflows against named starting states, shared ledger invariants, and attempt-scoped test data. Every scenario owns a unique site and manifest so parallel attempts can run without leaking data across sites or touching shared seed records.

### STORY-13-01: Site admin starting points F0 to F3

As a site manager, I can view and interact with sites in early starting states (zero data, units without people, people without billing, or billing without people) with clear empty states, correct liability generation, unmatched payment handling, and state preservation across restarts.

#### Acceptance criteria

- Starting state F0 rejects accruals when no units exist and records unknown virtual IBAN transfers as unmatched.
- Starting state F1 and F2 reflect unassigned and assigned units, and first accrual on F2 charges correct tariffs and debtor types.
- Starting state F2 accrual separates units without owners from charged units.
- Starting state F3 exposes open periods with zero liabilities before residents arrive.
- Every starting state (F0 to F3) survives backend restart without data loss or balance drift.

### STORY-13-05: Corner cases around accrual, occupancy, access and time

As a site administrator, I need edge cases around billing, occupancy, access and local time to
preserve the ledger and reject invalid state changes without side effects.

#### Acceptance criteria

- Corner-case scenarios use the documented named states and assert ledger invariants after each stage.
- Scenarios without their required historical fixtures or product dependencies remain `@pending` with a specific reason.

### STORY-13-09: Financial transitions across periods and ledgers

As a site manager, I need targeted, partial and backdated payments and period corrections to keep
live balances, closed snapshots and operational/capital ledgers consistent.

#### Acceptance criteria

- Financial scenarios assert exact Decimal balances and ledger invariants after every state change.
- Scenarios that require unavailable historical fixtures remain `@pending` with a specific reason.

### STORY-13-11: Billing state machines

As a site manager, I need each liability, period, reconciliation and occupancy status to allow only
valid commands and preserve all rows when a command is refused.

#### Acceptance criteria

- State-machine scenarios cover each status transition and refusal at the backend or GUI layer named by the feature.
- Scenarios that need missing fixtures or transition evidence remain `@pending` with a specific reason.

### STORY-13-07: Journey setup, teardown and isolation

As a test author, I need named site fixtures, reusable ledger invariant checks, and retryable site-scoped teardown so journeys start from known balances and leave the E2E database safe for other attempts.

#### Acceptance criteria

- `site_in_state(F0..F7)` creates an isolated site from the reference catalogue and exposes its IDs through an attempt manifest.
- `ledger_invariants()` reports the stage and invariant that failed, and is callable after each journey stage.
- SQL test-support teardown deletes only resources recorded for that attempt, is safe to retry, and runs after evidence capture even when capture fails.
- Failures retain redacted site and network evidence; stale-run reclamation only removes confirmed inactive attempts.
- File 07 scenarios automate the backend boundaries and leave no rows belonging to completed attempts.

### STORY-13-01: Back-dated start residing date and late fees

As a manager, I need the supplementary charge created for a back-dated start residing date to count its late fee from the day it was created, so a resident owes no fee for days before the charge existed.

#### Acceptance criteria

- The supplementary charge keeps the referred month's period due date and stores the creation date as its effective due date.
- The late fee is 0.00 at creation and counts from the effective due date afterwards (16.94 ten days later for the 1016.13 charge).

### STORY-13-12: Back-dated owner into a closed month

As a manager, I need a back-dated owner in a closed month to receive supplementary charges in the open period without changing the closed snapshot, with late fees counted from creation.

#### Acceptance criteria

- Both supplementary charges have the creation date as effective due date and a late fee of 0.00 at creation.
- Ten days later the late fees are 16.94 and 25.00.
