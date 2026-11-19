@EPIC-13 @STORY-13-01
Feature: Site admin starting points F0 to F3
  What a site manager sees and can do when the site holds no data, units without people, people
  without billing, or billing without people. State definitions: README sections 2 and 3.

  Background:
    Given the clock is frozen at "2026-11-19 12:00" Europe/Istanbul
    And a SaaS admin has onboarded a site "e2e-j01" with manager "manager@e2e.test"
    And the manager has signed in with a permanent password

  # ---------------------------------------------------------------- F0 ZERO

  @SC-13-01-01 @J-01 @state:F0 @layer:gui @smoke @role_manager @pending
  Scenario: A site with no data shows empty states, not errors
    Given the site is in state F0
    When the manager opens each of: dashboard, collection tracking, dues ledger, units, people, payments, periods
    Then every page loads without a failed backend call
    And every page shows an empty-state message with a next action
    And the dashboard shows total outstanding 0.00, collected 0.00 and 0 units
    And the ledger invariants hold

  @SC-13-01-02 @J-01 @state:F0 @layer:backend @core @role_manager @pending
  Scenario: Accruing a period on a site with no units is refused with a clear reason
    Given the site is in state F0
    When the manager accrues period "Kasım 2026" with amount 1500.00 and due date "2026-11-10"
    Then the request is rejected with a "no units to accrue" error
    And no period, no liability and no payment exists for the site

  @SC-13-01-03 @J-01 @state:F0 @layer:backend @edge @role_manager @pending
  Scenario: A payment arriving at a site with no units is not lost
    Given the site is in state F0
    When the bank webhook sends a transfer of 1500.00 to an unknown virtual IBAN
    Then the transfer is stored as unmatched and appears in the manager's unmatched list
    And no balance anywhere changes

  # ----------------------------------------------------- F1 NO_RESIDENTS

  @SC-13-01-04 @J-02 @state:F1 @layer:gui @core @role_manager @pending
  Scenario: Units with no people show as unassigned and cannot be billed to anyone
    Given the site is in state F1
    When the manager opens the units page
    Then 7 units are listed, A-1 to A-7, each showing "no owner" and "vacant"
    And the people directory is empty
    And the collection dashboard shows total outstanding 0.00

  @SC-13-01-05 @J-02 @state:F1 @layer:gui @core @role_manager @pending
  Scenario: The manager can add the first owner and tenant from an empty unit
    Given the site is in state F1
    When the manager assigns owner "Ayşe Kaya" to unit "A-1"
    And the manager moves tenant "Selin Demir" into unit "A-2" owned by "Ahmet Yılmaz"
    Then unit "A-1" shows owner "Ayşe Kaya" and unit "A-2" shows tenant "Selin Demir"
    And the people directory lists 3 people
    And no liability exists because no period was accrued
    And the ledger invariants hold

  # ------------------------------------------- F2 RESIDENTS_NO_PERIOD

  @SC-13-01-06 @J-03 @state:F2 @layer:gui @core @role_manager @pending
  Scenario: People without a billing period have no debt and a clear first action
    Given the site is in state F2
    When the manager opens the collection tracking page
    Then it shows 0 open liabilities and total outstanding 0.00
    And it offers "create the first period"
    When the home owner "Ayşe Kaya" signs in
    Then her dashboard shows balance 0.00 and an empty statement, not an error

  @SC-13-01-07 @J-03 @state:F2 @layer:backend @core @role_manager @pending
  Scenario: The first accrual charges each unit its tariff and the right debtor
    Given the site is in state F2
    When the manager creates and accrues period "Ekim 2026" due "2026-10-10"
    Then 6 liabilities exist, one for each of A-1 to A-6
    And the debtor is the owner for A-1, A-3, A-4, A-6 and the tenant for A-2 and A-5
    And unit "A-6" owes 2250.00 and every other charged unit owes 1500.00
    And the ledger invariants hold

  @SC-13-01-08 @J-03 @state:F2 @layer:backend @edge @role_manager @pending
  Scenario: Units without an owner are reported separately from the accrual
    Given the site is in state F2
    When the manager creates and accrues period "Ekim 2026" due "2026-10-10"
    Then no liability exists for unit "A-7"
    And the accrual succeeds for the other units
    And the accrual result has a separate list "units without owner" containing "A-7"
    And the accrual screen shows that list apart from the charged units

  # ------------------------------------------ F3 PERIOD_NO_RESIDENTS

  @SC-13-01-09 @J-04 @state:F3 @decision @layer:backend @core @role_manager @pending
  Scenario: A period accrued before anyone lived in the units leaves nothing to collect
    Given the site is in state F3
    Then period "Ekim 2026" exists and is OPEN
    And 0 liabilities exist for it
    And the dashboard shows total outstanding 0.00

  @SC-13-01-10 @J-04 @state:F3 @layer:backend @edge @role_manager @pending
  Scenario: A primary resident is charged from their start residing date, not before
    Given the site is in state F3
    When the manager adds owner "Ayşe Kaya" as primary resident of unit "A-1" with start residing date "2026-11-02"
    Then period "Ekim 2026" still has 0 liabilities for unit "A-1"
    When the manager accrues period "Kasım 2026" due "2026-11-10"
    Then unit "A-1" owes 1450.00 for "Kasım 2026", which is 29 of 30 days
    And the ledger invariants hold

  @SC-13-01-14 @J-04 @state:F3 @layer:backend @edge @role_manager @pending
  Scenario: A back-dated start residing date creates the charge for an already accrued period
    Given the site is in state F3
    When the manager adds tenant "Selin Demir" as primary resident of unit "A-2" with start residing date "2026-10-11"
    Then period "Ekim 2026" now holds a liability of 1016.13 for "Selin Demir", which is 21 of 31 days
    And the days before 2026-10-11 are charged to nobody because the unit had no responsible party
    And the ledger invariants hold

  @SC-13-01-11 @J-04 @state:F3 @layer:gui @edge @role_manager @pending
  Scenario: Accruing the same period again after residents arrive is blocked, not doubled
    Given the site is in state F3
    And owners and tenants are added as in state F2
    When the manager accrues period "Ekim 2026" again
    Then the duplicate is rejected with the duplicate-prevention message
    And no liability is created
    And the ledger invariants hold

  # ------------------------------------------------- navigation across states

  @SC-13-01-12 @J-05 @state:F0 @layer:gui @core @role_manager @pending
  Scenario: Growing the site from F0 to F2 through the screens keeps every page consistent
    Given the site is in state F0
    When the manager adds block "A Blok" with 7 units and sets the tariffs
    Then the site is equal to state F1
    When the manager adds the owners and tenants of state F2
    Then the site is equal to state F2
    And the units page, the people directory and each unit workspace agree on every owner and occupant

  @SC-13-01-13 @J-06 @state:F2 @layer:backend @edge @role_manager @pending
  Scenario Outline: Every starting state survives a backend restart unchanged
    Given the site is in state <state>
    When the backend is restarted
    Then every balance, owner, occupant and period is identical to before the restart

    Examples:
      | state |
      | F0    |
      | F1    |
      | F2    |
      | F3    |
