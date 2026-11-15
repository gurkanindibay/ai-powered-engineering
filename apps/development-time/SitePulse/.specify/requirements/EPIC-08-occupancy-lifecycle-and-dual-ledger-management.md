# Epic: Unit Occupancy Lifecycle & Dual-Ledger Financial Responsibility

> **Epic ID:** EPIC-08  
> **Module:** Property & Financial Domain (`flutter-domain`, `flutter-ui`, `backend-rust`, `postgres-db`)  
> **Status:** COMPLETED (STORY-08-01 to 08-10; the state model of §3 is implemented)  
> **Governing Principles:** Kat Mülkiyeti Kanunu (KMK Articles 20 & 22), GAAP Dual-Ledger Accounting  
> **Terminology Standard:** English domain identifiers (`OPERATIONAL_DUES`, `CAPITAL_DUES`, `OWNER`, `TENANT`, `OWNER_OCCUPIED`, `TENANT_OCCUPIED`, `VACANT`)  

---

## 1. Epic Overview

Establishes strict domain and financial separation between property owners and tenants, provides explicit unit occupancy state management (`OWNER_OCCUPIED`, `TENANT_OCCUPIED`, `VACANT`), links household residents strictly to the active resident, and logs the complete move-in / move-out occupancy lifecycle (`unit_occupancies`) without losing historical dues, payments, or audit records.

---

## 2. Key Domain Terminology

| Turkish Domain Concept | English Domain Identifier | Definition & Accounting Rule |
| :--- | :--- | :--- |
| **Aidat (İşletme Avansı)** | `OPERATIONAL_DUES` | Monthly operational maintenance, cleaning, security, gardening, and management costs. Incurred by the active resident (Tenant if rented, Owner if residing). |
| **Demirbaş (Yatırım Avansı)** | `CAPITAL_DUES` | Long-term capital expenditures, structural renovations, elevator renewals, roof repairs, and facade painting. Incurred strictly by the Property Owner (`OWNER`). Tenants are legally exempt. |
| **Kat Maliki** | `OWNER` (or `PROPERTY_OWNER`) | The legal title deed holder. Retains ultimate statutory liability for the property under KMK Art. 20. |
| **Kat Sakini / Kiracı** | `TENANT` | The leaseholder occupying the unit under a lease agreement. Jointly liable for operational dues up to monthly rent amount under KMK Art. 22. |
| **Hane Halkı** | `HOUSEHOLD_MEMBER` | Individuals co-residing with the primary resident. Bound to the active residency session; they do not carry independent financial debt. |
| **İkamet Durumu** | `OCCUPANCY_STATUS` | Who lives in the unit: `OWNER_OCCUPIED`, `TENANT_OCCUPIED`, or `VACANT`. Changed only by move-in and move-out. Independent of ownership (see §3). |
| **Mülkiyet Durumu** | `OWNERSHIP_STATUS` | Who holds the title deed: `UNOWNED` or `OWNED`. Changed only by owner registration and title deed transfer. A move-in or move-out never changes it. |
| **İkamet / Oturum Tarihçesi**| `UNIT_OCCUPANCY_HISTORY` | Temporal ledger tracking move-in date, move-out date, closing balance, and identity of all historical occupants. |

---

## 3. Unit State Model (Normative)

Rationale, current gaps and confirmed decisions: [docs/architecture/UNIT_STATE_TRANSITIONS_ANALYSIS.md](../../docs/architecture/UNIT_STATE_TRANSITIONS_ANALYSIS.md).

### 3.1 Two independent dimensions

| Dimension | States | Source of truth | Changed only by |
| :--- | :--- | :--- | :--- |
| **Ownership** | `UNOWNED`, `OWNED` | active row in `unit_ownerships` | Owner registration, title deed transfer |
| **Occupancy** | `VACANT`, `OWNER_OCCUPIED`, `TENANT_OCCUPIED` | active row in `unit_occupancies` | Move-in, move-out |

`units.owner_person_id`, `units.tenant_person_id` and `units.occupancy_status` are projections of these tables.

### 3.2 Occupancy states

| State | Active occupancy session | Operational dues debtor | Capital dues debtor |
| :--- | :--- | :--- | :--- |
| `VACANT` | none | Owner | Owner |
| `OWNER_OCCUPIED` | type `OWNER`; the person is an active owner of the unit | Owner | Owner |
| `TENANT_OCCUPIED` | type `TENANT`; the person is not an active owner of the unit | Tenant | Owner |

`UNOWNED` is valid only together with `VACANT`.

### 3.3 Transitions

| # | Command | Precondition | Result | Person | Ownership effect |
| :-- | :--- | :--- | :--- | :--- | :--- |
| T1 | Register owner | `UNOWNED` + `VACANT` | `OWNED` + `VACANT`, or `OWNED` + `OWNER_OCCUPIED` when the owner resides | New or existing person | Opens ownership |
| T2 | Tenant move-in | `OWNED` + `VACANT` | `TENANT_OCCUPIED` | New or existing person; not an active owner of the unit | None |
| T3 | Owner move-in | `OWNED` + `VACANT` | `OWNER_OCCUPIED` | The owner on record; no person data is entered | None |
| T4 | Tenant move-out | `TENANT_OCCUPIED` | `VACANT` | The active tenant | None |
| T5 | Owner move-out | `OWNER_OCCUPIED` | `VACANT` | The active owner-occupant | None |
| T6 | Title deed transfer | `OWNED` | `VACANT` stays `VACANT`; `TENANT_OCCUPIED` stays `TENANT_OCCUPIED` (becomes `OWNER_OCCUPIED` when the buyer is the tenant); `OWNER_OCCUPIED` becomes `VACANT`, or `OWNER_OCCUPIED` when the new owner moves in | New owner: new or existing person | Closes old ownership, opens new |
| C1 | Replace tenant | `TENANT_OCCUPIED` | `TENANT_OCCUPIED` | T4 then T2 | None |
| C2 | Owner rents out | `OWNER_OCCUPIED` | `TENANT_OCCUPIED` | T5 then T2 | None |
| C3 | Owner takes the unit back | `TENANT_OCCUPIED` | `OWNER_OCCUPIED` | T4 then T3 | None |

Any command not listed for the unit's current state is illegal and is rejected without changing data.

### 3.4 Invariants

1. A unit has at most one active occupancy session.
2. `occupancy_status` always equals the state implied by the active occupancy session (none means `VACANT`).
3. The person of an active `OWNER` session is an active owner of the unit.
4. Move-in and move-out never insert, close or modify a `unit_ownerships` row and never change `owner_person_id`.
5. Every session close records `end_date` and `exit_balance`; no session is closed implicitly.
6. A session row is created only by a move-in, an owner registration with residence, or a title transfer; a move-out never creates one.

### 3.5 Resident details and initial registration

For an existing unit, resident and owner details display occupancy as read-only and
explain that changes use the unit workspace actions from §3.3. These pages must not
submit occupancy fields through a generic Save action. Person cards and household
member actions retain their independent save flows. Closing details changes no unit
state. All states, including vacant and units without an owner, follow this rule.

Initial registration may collect the starting occupancy together with the owner and,
when rented, the tenant. It must create the matching ownership and occupancy records;
this is not an edit mechanism for an existing unit. Title transfer retains the
state-dependent behavior in T6; selecting a contact or adding a household member
never changes occupancy.

Regression scenarios: `SC-08-07-09`, `SC-08-07-10`; identity navigation: `SC-12-06-02`.
Analysis and case inventory: [occupancy editing analysis](../../docs/architecture/OCCUPANCY_EDIT_ACTIONS_ANALYSIS.md).

---

## 4. User Stories & Acceptance Criteria

### STORY-08-01: Dual-Ledger Financial Responsibility Separation
- **Description:** Dues liabilities must be explicitly classified by `expense_type` (`OPERATIONAL_DUES` vs `CAPITAL_DUES`) and assigned to the appropriate `debtor_type` (`TENANT` vs `OWNER`).
- **Acceptance Criteria (Gherkin):**
Executable scenarios: [`STORY-08-01-dual-ledger-responsibility.feature`](../features/EPIC-08/STORY-08-01-dual-ledger-responsibility.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

---

### STORY-08-02: Unit Occupancy State Machine & Household Resident Scoping
- **Status:** COMPLETED. Amended by STORY-08-07 and STORY-08-10.
- **Description:** Every unit tracks its current `occupancy_status` (`OWNER_OCCUPIED`, `TENANT_OCCUPIED`, `VACANT`). Household members (`unit_members`) are scoped strictly to the current active resident's session.
- **Acceptance Criteria (Gherkin):**
Executable scenarios: [`STORY-08-02-occupancy-state-machine-household.feature`](../features/EPIC-08/STORY-08-02-occupancy-state-machine-household.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

---

### STORY-08-03: Zero-Data-Loss Move-Out (Tahliye) & Exit Settlement
- **Status:** COMPLETED. Amended by STORY-08-07 and STORY-08-10.
- **Description:** When a tenant or resident vacates a unit, the system must not delete historical records. It closes the active occupancy session, records the exit settlement balance, and preserves all historical dues liabilities and collection transactions.
- **Acceptance Criteria (Gherkin):**
Executable scenarios: [`STORY-08-03-move-out-exit-settlement.feature`](../features/EPIC-08/STORY-08-03-move-out-exit-settlement.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

---

### STORY-08-04: Move-In & Historical Occupancy Audit Trail
- **Status:** COMPLETED. Amended by STORY-08-06, STORY-08-07 and STORY-08-08.
- **Description:** When a new resident moves in, a new active occupancy record is created. The Site Manager can view a complete chronological timeline of all past and present occupants for that unit.
- **Acceptance Criteria (Gherkin):**
Executable scenarios: [`STORY-08-04-move-in-occupancy-history.feature`](../features/EPIC-08/STORY-08-04-move-in-occupancy-history.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

---

### STORY-08-05: Title Deed Transfer & Property Ownership Sale Handover (Mülk Satış / Malik Değişikliği)
- **Description:** When a unit is sold to a new owner, the system must separate past liabilities from future obligations according to the deed transfer date. The previous owner's historical profile is closed, the new owner is registered as legal deed holder, while any existing active lease agreement (Tenant) continues unaffected.
- **Acceptance Criteria (Gherkin):**
Executable scenarios: [`STORY-08-05-title-deed-transfer.feature`](../features/EPIC-08/STORY-08-05-title-deed-transfer.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

---

### STORY-08-06: Owner Move-In Without Ownership Change
- **Status:** COMPLETED
- **Description:** A vacant unit still belongs to its owner. When the owner moves in, the system opens an owner occupancy session for the owner on record. The manager does not enter a name, phone or email for an owner move-in, and ownership is not changed. A different person can become the owner only through a title deed transfer (STORY-08-05). The vacant unit offers two separate actions: tenant move-in (person form) and owner move-in (confirmation naming the owner on record). When the unit has several active owners, the manager selects one of them.
- **Acceptance Criteria (Gherkin):**
Executable scenarios: [`STORY-08-06-owner-move-in.feature`](../features/EPIC-08/STORY-08-06-owner-move-in.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

---

### STORY-08-07: Guarded State Transitions
- **Status:** COMPLETED
- **Description:** Every occupancy command is accepted only in the states listed in §3.3. An illegal command is rejected with an error that names the current state, and changes no data. The rule applies to every entry point that changes occupancy or ownership: move-in, move-out, title transfer, owner edit, and registration approval (EPIC-04). The user interface shows only the actions that are legal for the unit's current state.
- **Acceptance Criteria (Gherkin):**
Executable scenarios: [`STORY-08-07-guarded-state-transitions.feature`](../features/EPIC-08/STORY-08-07-guarded-state-transitions.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

---

### STORY-08-08: Compound Transitions Preserve Exit Settlement
- **Status:** COMPLETED
- **Description:** Replacing a tenant (C1), an owner renting out the unit (C2) and an owner taking the unit back (C3) are executed as a move-out followed by a move-in, in one database transaction with one effective date. The outgoing occupant's session is closed with `end_date` and `exit_balance` exactly as in a standalone move-out. The owner edit screen uses these same commands and has no separate rule for adding or removing a tenant.
- **Acceptance Criteria (Gherkin):**
Executable scenarios: [`STORY-08-08-compound-transitions.feature`](../features/EPIC-08/STORY-08-08-compound-transitions.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

---

### STORY-08-09: Title Deed Transfer Keeps Occupancy Consistent
- **Status:** COMPLETED
- **Description:** Extends STORY-08-05 with the occupancy effect of a transfer for each state (§3.3, T6). A transfer of an owner-occupied unit closes the previous owner's occupancy session and leaves the unit `VACANT`, unless the manager states that the new owner moves in. A transfer to the current tenant converts the tenancy into owner occupancy.
- **Acceptance Criteria (Gherkin):**
Executable scenarios: [`STORY-08-09-title-transfer-occupancy.feature`](../features/EPIC-08/STORY-08-09-title-transfer-occupancy.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

---

### STORY-08-10: Atomic Transitions, Derived Status & Per-Person Exit Balance
- **Status:** COMPLETED
- **Description:** Each transition runs in a single database transaction with the unit row locked, takes an effective date (not in the future; it may be earlier than the recorded start of the session being closed, in which case the session start moves back to that date), and writes an audit record with the command, the previous state and the new state. `occupancy_status` is derived from the active occupancy session and cannot differ from it. The exit balance of a closed session is the sum of the unpaid liabilities charged to that person for that unit, not of all unpaid liabilities of the unit. A move-out never creates an occupancy session. Because a leave is often recorded after it happened, every move-out screen lets the Site Manager choose the effective date (default today); the same date rules apply.
- **Acceptance Criteria (Gherkin):**
Executable scenarios: [`STORY-08-10-atomic-transitions-exit-balance.feature`](../features/EPIC-08/STORY-08-10-atomic-transitions-exit-balance.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).

---

### STORY-08-11: Actions-First Unit Workspace
- **Status:** IN PROGRESS
- **Description:** A unit opens in a full-screen workspace with two modes on the same unit: actions and information. The action list follows the unit's allowed commands and keeps the existing occupancy workflows; the information mode keeps residents, owners and the separate operating and capital ledgers. The workspace is opened from the unit card; wiring it to the directory rows is a later task.
- **Acceptance Criteria (Gherkin):**
Executable scenarios: [`STORY-08-11-unit-workspace.feature`](../features/EPIC-08/STORY-08-11-unit-workspace.feature) (run and reported by scenario id, see `scripts/feature_traceability.py`).
