# Epic: Unit Occupancy Lifecycle & Dual-Ledger Financial Responsibility

> **Epic ID:** EPIC-08  
> **Module:** Property & Financial Domain (`flutter-domain`, `flutter-ui`, `backend-rust`, `postgres-db`)  
> **Status:** REVISION SPECIFIED (STORY-08-01 to 08-05 completed; STORY-08-06 to 08-10 pending)  
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

Rationale, current gaps and open assumptions: [docs/UNIT_STATE_TRANSITIONS_ANALYSIS.md](../../docs/UNIT_STATE_TRANSITIONS_ANALYSIS.md).

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

---

## 4. User Stories & Acceptance Criteria

### STORY-08-01: Dual-Ledger Financial Responsibility Separation
- **Description:** Dues liabilities must be explicitly classified by `expense_type` (`OPERATIONAL_DUES` vs `CAPITAL_DUES`) and assigned to the appropriate `debtor_type` (`TENANT` vs `OWNER`).
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Accrue monthly operational dues to tenant and capital project to owner
    Given Unit "A Blok D:4" is marked as TENANT_OCCUPIED with Tenant "Selin Demir" and Owner "Ahmet Yılmaz"
    When the monthly operational dues of ₺1.500,00 are accrued
    Then an OPERATIONAL_DUES liability is charged to debtor TENANT (Selin Demir)
    When a capital facade renovation assessment of ₺5.000,00 is accrued
    Then a CAPITAL_DUES liability is charged to debtor OWNER (Ahmet Yılmaz)
    And Selin Demir's tenant balance reflects ₺1.500,00
    And Ahmet Yılmaz's owner balance reflects ₺5.000,00
  ```

---

### STORY-08-02: Unit Occupancy State Machine & Household Resident Scoping
- **Status:** COMPLETED. Amended by STORY-08-07 and STORY-08-10.
- **Description:** Every unit tracks its current `occupancy_status` (`OWNER_OCCUPIED`, `TENANT_OCCUPIED`, `VACANT`). Household members (`unit_members`) are scoped strictly to the current active resident's session.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Household members are bound to the active resident session
    Given Tenant "Zeynep Kaya" lives in "B Blok D:12" with household members "Ali Kaya (Son)" and "Can Kaya (Brother)"
    When inspecting the active residents of "B Blok D:12"
    Then the system returns Zeynep Kaya as primary contact and 2 household members
    And when Zeynep Kaya moves out and the flat becomes VACANT
    Then the active household member list is cleared and archived under Zeynep Kaya's occupancy record
  ```

---

### STORY-08-03: Zero-Data-Loss Move-Out (Tahliye) & Exit Settlement
- **Status:** COMPLETED. Amended by STORY-08-07 and STORY-08-10.
- **Description:** When a tenant or resident vacates a unit, the system must not delete historical records. It closes the active occupancy session, records the exit settlement balance, and preserves all historical dues liabilities and collection transactions.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Move-out preserves historical payment receipts and unsettled debt
    Given Tenant "Zeynep Kaya" in Unit "B Blok D:12" has ₺1.500,00 unpaid operational dues
    When the Site Manager executes the move-out action on 2026-10-31
    Then the active occupancy record is closed with end_date = 2026-10-31, is_active = false, and exit_balance = ₺1.500,00
    And Unit "B Blok D:12" status becomes VACANT with tenant_person_id = NULL
    And past payment receipts and the ₺1.500,00 historical liability remain attributed to Zeynep Kaya
    And zero records are deleted from dues_liabilities, collection_transactions, or persons
  ```

---

### STORY-08-04: Move-In & Historical Occupancy Audit Trail
- **Status:** COMPLETED. Amended by STORY-08-06, STORY-08-07 and STORY-08-08.
- **Description:** When a new resident moves in, a new active occupancy record is created. The Site Manager can view a complete chronological timeline of all past and present occupants for that unit.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: New tenant moves in and past occupancy history is retrievable
    Given Unit "B Blok D:12" is VACANT with past tenant "Zeynep Kaya"
    When the Site Manager registers new Tenant "Mehmet Demir" starting 2026-11-01
    Then a new active occupancy session is opened for Mehmet Demir
    And Unit "B Blok D:12" status transitions to TENANT_OCCUPIED
    When the Site Manager views the occupancy history timeline
    Then the timeline displays "Zeynep Kaya (2025 - 2026) • Left with ₺1.500,00" followed by "Mehmet Demir (2026 - Present) • Active"
  ```

---

### STORY-08-05: Title Deed Transfer & Property Ownership Sale Handover (Mülk Satış / Malik Değişikliği)
- **Description:** When a unit is sold to a new owner, the system must separate past liabilities from future obligations according to the deed transfer date. The previous owner's historical profile is closed, the new owner is registered as legal deed holder, while any existing active lease agreement (Tenant) continues unaffected.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Change property owner upon title deed sale without affecting tenant
    Given Unit "A Blok D:14" has Tenant "Canan Kaya" and Owner "Ahmet Yılmaz"
    When the Site Manager registers a Title Deed Transfer to New Owner "Selim Evsahibi" effective 2026-10-28
    Then Ahmet Yılmaz is archived as historical property owner with closing balance
    And Selim Evsahibi becomes the active owner_person_id for Unit "A Blok D:14"
    And Canan Kaya remains the active tenant with zero interruption to her occupancy session
    And subsequent capital dues assessments are billed to Selim Evsahibi
  ```

---

### STORY-08-06: Owner Move-In Without Ownership Change
- **Status:** PENDING
- **Description:** A vacant unit still belongs to its owner. When the owner moves in, the system opens an owner occupancy session for the owner on record. The manager does not enter a name, phone or email for an owner move-in, and ownership is not changed. A different person can become the owner only through a title deed transfer (STORY-08-05). The vacant unit offers two separate actions: tenant move-in (person form) and owner move-in (confirmation naming the owner on record). When the unit has several active owners, the manager selects one of them.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Owner moves into the unit after the tenant left
    Given Unit "B Blok D:12" is TENANT_OCCUPIED with Tenant "Zeynep Kaya" and Owner "Ahmet Yılmaz"
    And Zeynep Kaya has moved out and the unit is VACANT
    When the Site Manager executes the owner move-in action
    Then the confirmation names Ahmet Yılmaz and offers no person input fields
    And a new active OWNER occupancy session is opened for Ahmet Yılmaz
    And Unit "B Blok D:12" status becomes OWNER_OCCUPIED
    And the owner of the unit is still Ahmet Yılmaz
    And no unit_ownerships row is inserted, closed or modified

  Scenario: Owner move-in for a person who is not the owner is rejected
    Given Unit "B Blok D:12" is VACANT with Owner "Ahmet Yılmaz"
    When an owner move-in is requested for "Mehmet Demir"
    Then the request is rejected with a validation error
    And the unit remains VACANT with Owner "Ahmet Yılmaz"

  Scenario: Tenant move-in still accepts a new person
    Given Unit "B Blok D:12" is VACANT with Owner "Ahmet Yılmaz"
    When the Site Manager registers new Tenant "Mehmet Demir"
    Then Unit "B Blok D:12" status becomes TENANT_OCCUPIED
    And the owner of the unit is still Ahmet Yılmaz
  ```

---

### STORY-08-07: Guarded State Transitions
- **Status:** PENDING
- **Description:** Every occupancy command is accepted only in the states listed in §3.3. An illegal command is rejected with an error that names the current state, and changes no data. The rule applies to every entry point that changes occupancy or ownership: move-in, move-out, title transfer, owner edit, and registration approval (EPIC-04). The user interface shows only the actions that are legal for the unit's current state.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario Outline: Illegal commands are rejected
    Given a unit in state <state>
    When the Site Manager requests <command>
    Then the request is rejected and the unit remains in state <state>
    And no occupancy or ownership row is inserted or modified

    Examples:
      | state           | command         |
      | VACANT          | move-out        |
      | OWNER_OCCUPIED  | tenant move-in  |
      | OWNER_OCCUPIED  | owner move-in   |
      | TENANT_OCCUPIED | tenant move-in  |
      | TENANT_OCCUPIED | owner move-in   |
      | UNOWNED, VACANT | tenant move-in  |
      | UNOWNED, VACANT | owner move-in   |

  Scenario: Registration approval respects the unit state
    Given Unit "A Blok D:4" is TENANT_OCCUPIED with Tenant "Selin Demir"
    When a resident registration request for the same unit is approved as tenant
    Then the approval is rejected with the reason that the unit is occupied
    And Selin Demir remains the active tenant
  ```

---

### STORY-08-08: Compound Transitions Preserve Exit Settlement
- **Status:** PENDING
- **Description:** Replacing a tenant (C1), an owner renting out the unit (C2) and an owner taking the unit back (C3) are executed as a move-out followed by a move-in, in one database transaction with one effective date. The outgoing occupant's session is closed with `end_date` and `exit_balance` exactly as in a standalone move-out. The owner edit screen uses these same commands and has no separate rule for adding or removing a tenant.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Replacing a tenant settles the outgoing tenant
    Given Tenant "Zeynep Kaya" in Unit "B Blok D:12" has ₺1.500,00 unpaid operational dues
    When the Site Manager replaces the tenant with "Mehmet Demir" effective 2026-11-01
    Then Zeynep Kaya's session is closed with end_date = 2026-11-01 and exit_balance = ₺1.500,00
    And a new active TENANT session is opened for Mehmet Demir with start_date = 2026-11-01
    And Unit "B Blok D:12" status is TENANT_OCCUPIED

  Scenario: Owner takes the unit back from the tenant
    Given Unit "B Blok D:12" is TENANT_OCCUPIED with Tenant "Zeynep Kaya" and Owner "Ahmet Yılmaz"
    When the Site Manager executes "owner takes the unit back"
    Then Zeynep Kaya's session is closed with an exit balance
    And an active OWNER session is opened for Ahmet Yılmaz
    And the owner of the unit is still Ahmet Yılmaz

  Scenario: A failed second step leaves nothing changed
    Given Unit "B Blok D:12" is TENANT_OCCUPIED with Tenant "Zeynep Kaya"
    When a tenant replacement fails while registering the incoming tenant
    Then Zeynep Kaya is still the active tenant and her session is still open
  ```

---

### STORY-08-09: Title Deed Transfer Keeps Occupancy Consistent
- **Status:** PENDING
- **Description:** Extends STORY-08-05 with the occupancy effect of a transfer for each state (§3.3, T6). A transfer of an owner-occupied unit closes the previous owner's occupancy session and leaves the unit `VACANT`, unless the manager states that the new owner moves in. A transfer to the current tenant converts the tenancy into owner occupancy.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Selling an owner-occupied unit vacates it
    Given Unit "A Blok D:3" is OWNER_OCCUPIED by Owner "Ahmet Yılmaz"
    When the Site Manager registers a Title Deed Transfer to "Selim Evsahibi" effective 2026-10-28
    Then Ahmet Yılmaz's occupancy session is closed with end_date = 2026-10-28 and an exit balance
    And Unit "A Blok D:3" status becomes VACANT
    And Selim Evsahibi is the owner of the unit

  Scenario: The new owner moves in at transfer
    Given Unit "A Blok D:3" is OWNER_OCCUPIED by Owner "Ahmet Yılmaz"
    When the Site Manager registers a Title Deed Transfer to "Selim Evsahibi" with "new owner moves in"
    Then an active OWNER session is opened for Selim Evsahibi
    And Unit "A Blok D:3" status is OWNER_OCCUPIED

  Scenario: The tenant buys the unit
    Given Unit "A Blok D:14" has Tenant "Canan Kaya" and Owner "Ahmet Yılmaz"
    When the Site Manager registers a Title Deed Transfer to Canan Kaya
    Then Canan Kaya's TENANT session is closed with an exit balance
    And an active OWNER session is opened for Canan Kaya
    And Unit "A Blok D:14" status becomes OWNER_OCCUPIED

  Scenario: Selling a vacant unit leaves it vacant
    Given Unit "B Blok D:12" is VACANT with Owner "Ahmet Yılmaz"
    When the Site Manager registers a Title Deed Transfer to "Selim Evsahibi"
    Then Unit "B Blok D:12" status remains VACANT
    And Selim Evsahibi can move in through the owner move-in action
  ```

---

### STORY-08-10: Atomic Transitions, Derived Status & Per-Person Exit Balance
- **Status:** PENDING
- **Description:** Each transition runs in a single database transaction with the unit row locked, takes an effective date (not in the future, not before the start of the session being closed), and writes an audit record with the command, the previous state and the new state. `occupancy_status` is derived from the active occupancy session and cannot differ from it. The exit balance of a closed session is the sum of the unpaid liabilities charged to that person for that unit, not of all unpaid liabilities of the unit. A move-out never creates an occupancy session.
- **Acceptance Criteria (Gherkin):**
  ```gherkin
  Scenario: Exit balance counts only the departing tenant's liabilities
    Given Unit "B Blok D:12" has ₺900,00 unpaid operational dues charged to Owner "Ahmet Yılmaz" from a vacant period
    And Tenant "Zeynep Kaya" has ₺1.500,00 unpaid operational dues for the same unit
    When the Site Manager executes the move-out action for Zeynep Kaya
    Then the closed session has exit_balance = ₺1.500,00

  Scenario: Status cannot drift from the occupancy sessions
    Given any sequence of legal transitions on a unit
    Then occupancy_status equals the state implied by the unit's active occupancy session
    And the unit's owner equals the active unit_ownerships record

  Scenario: A transition is all or nothing
    Given Unit "B Blok D:12" is TENANT_OCCUPIED
    When the move-out fails after the session is closed but before the unit is updated
    Then the session is still active and the unit is still TENANT_OCCUPIED

  Scenario: Effective date is validated
    Given Tenant "Zeynep Kaya" moved into Unit "B Blok D:12" on 2026-03-01
    When the Site Manager executes the move-out action with effective date 2026-02-15
    Then the request is rejected because the date is before the session start
  ```
