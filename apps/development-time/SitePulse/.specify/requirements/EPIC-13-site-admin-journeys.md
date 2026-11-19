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

### STORY-13-07: Journey setup, teardown and isolation

As a test author, I need named site fixtures, reusable ledger invariant checks, and retryable site-scoped teardown so journeys start from known balances and leave the E2E database safe for other attempts.

#### Acceptance criteria

- `site_in_state(F0..F7)` creates an isolated site from the reference catalogue and exposes its IDs through an attempt manifest.
- `ledger_invariants()` reports the stage and invariant that failed, and is callable after each journey stage.
- SQL test-support teardown deletes only resources recorded for that attempt, is safe to retry, and runs after evidence capture even when capture fails.
- Failures retain redacted site and network evidence; stale-run reclamation only removes confirmed inactive attempts.
- File 07 scenarios automate the backend boundaries and leave no rows belonging to completed attempts.
