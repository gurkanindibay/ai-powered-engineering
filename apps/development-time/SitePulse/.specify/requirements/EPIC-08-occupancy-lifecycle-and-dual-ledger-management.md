# Epic: Unit Occupancy Lifecycle & Dual-Ledger Financial Responsibility

> **Epic ID:** EPIC-08  
> **Module:** Property & Financial Domain (`flutter-domain`, `flutter-ui`, `backend-rust`, `postgres-db`)  
> **Status:** COMPLETED  
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
| **İkamet Durumu** | `OCCUPANCY_STATUS` | State machine governing the unit: `OWNER_OCCUPIED`, `TENANT_OCCUPIED`, or `VACANT`. |
| **İkamet / Oturum Tarihçesi**| `UNIT_OCCUPANCY_HISTORY` | Temporal ledger tracking move-in date, move-out date, closing balance, and identity of all historical occupants. |

---

## 3. User Stories & Acceptance Criteria

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

