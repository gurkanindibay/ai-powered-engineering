# Epic: Site Admin Journeys

> **Epic ID:** EPIC-13
> **Module:** E2E verification harness
> **Status:** IN PROGRESS

## Overview

The site admin journey suite verifies connected workflows against named starting states, shared ledger invariants, and attempt-scoped test data. Every scenario owns a unique site and manifest so parallel attempts can run without leaking data across sites or touching shared seed records.

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

### STORY-13-10: Tenant data isolation across sites and resident accounts

As a tenant and property manager, I need strict data isolation across sites and accounts so that managers cannot view or mutate another site's data and residents cannot view another resident's private transactions.

#### Acceptance criteria

- Manager lists, searches and aggregates are strictly scoped to the authenticated site.
- Direct reads and downloads require access to the requested site (403 or 404).
- A site parameter cannot widen manager collection or export permissions.
- A manager cannot mutate another site's records.
- A resident cannot read another unit's financial records.
- A tenant statement excludes the owner's private transactions for the same unit.
- Replacing a tenant keeps each occupant's history and receipts private.
- Late browser responses cannot repopulate the next tenant's session.

