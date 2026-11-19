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

### STORY-13-03: Residents and owners change after periods were accrued

As a site manager, I need old liabilities to stay with whoever was responsible at the time, and new residents or owners to be charged only from their start date, so that mid-period occupancy changes never move debt between people.

#### Acceptance criteria

- A mid-month move-in splits the period between owner and tenant by days, and the shares add up to the tariff.
- A resident added after accruals is charged from their start residing date and does not owe earlier periods.
- Proration follows month length and edge days, and switching it off charges the tenant the whole period.
- A unit created mid-month is billed for its chargeable days only.
- Scenarios that need per-person splits, the seller-pays override (#209), the jointly liable owner (#207) or an E2E clock for the API handlers stay `@pending` with the reason in the feature file.
