@EPIC-13 @STORY-13-03
Feature: Residents and owners change after periods were accrued (state F6)
  Households, tenants and owners arrive or leave once billing history exists.
  The rule under test: old liabilities stay with whoever was responsible then (invariant I7).
  F6 narrative: README section 3.1.

  Background:
    Given the scenario clock follows the fixture timeline in Europe/Istanbul
    And a SaaS admin has onboarded a site and manager unique to this scenario attempt
    And the manager has signed in with a permanent password
    And proration is enabled for the site

  @SC-13-03-01 @J-10 @state:F6 @layer:backend @smoke @core @role_manager @pending
  Scenario: A mid-month move-in splits a period between owner and tenant
    Given the site is in state F6
    Then the "Ekim 2026" principal shares for "A-2" are owner "Ahmet Yılmaz" 483.87 and tenant "Selin Demir" 1016.13
    And the two shares add up to 1500.00
    And the "Eylül 2026" principal of 1500.00 for "A-2" is assigned to "Ahmet Yılmaz"

  @SC-13-03-02 @J-10 @state:F6 @layer:backend @core @role_manager @pending
  Scenario: A tenant replaced mid-month leaves the old debt with the old tenant
    Given the site is in state F6
    Then the "Kasım 2026" principal shares for "A-2" are "Selin Demir" 700.00 and "Mert Kılıç" 800.00
    And "Selin Demir" still owes her "Ekim 2026" share of 1016.13 plus its late fee
    And "Mert Kılıç" owes nothing for "Eylül 2026" or "Ekim 2026"

  @SC-13-03-03 @J-10 @state:F6 @layer:gui @core @role_homeowner @pending
  Scenario: A former tenant still sees their own debt and the new tenant sees only theirs
    Given the site is in state F6
    When "Selin Demir" signs in
    Then her dashboard lists unpaid principal of 1016.13 for "Ekim 2026" and 700.00 for "Kasım 2026"
    And it shows no liability from after 2026-11-15
    When "Mert Kılıç" signs in
    Then his dashboard lists only "Kasım 2026" with principal of 800.00

  @SC-13-03-04 @J-10 @state:F6 @decision @layer:backend @core @role_manager @pending
  Scenario: A resident added after accruals is charged from their start residing date
    Given the site is in state F6
    Then tenant "Oya Çelik" is primary resident of unit "A-3" with start residing date "2026-11-18"
    And "Oya Çelik" owes 0.00 for "Eylül 2026" and "Ekim 2026"
    And "Oya Çelik" is charged principal of 650.00 for "Kasım 2026", which is 13 of 30 days
    And owner "Burak Şahin" owes the full "Eylül 2026" and "Ekim 2026" and 850.00 for "Kasım 2026"
    When the manager accrues period "Aralık 2026" due "2026-12-10"
    Then tenant "Oya Çelik" owes 1500.00 for "Aralık 2026"
    And owner "Burak Şahin" owes nothing for "Aralık 2026" operational dues

  @SC-13-03-05 @J-10 @state:F6 @layer:backend @core @role_manager @pending
  Scenario: A title deed transfer moves future capital dues but not old debt
    Given the site is in state F6
    And installment 1 of the capital project "Cephe" (6000.00 for unit "A-4" in 2 installments) was accrued before the sale
    When the manager accrues installment 2 after the sale
    Then installment 1 stays with "Ahmet Yılmaz"
    And installment 2 is billed to "Gül Tanrıverdi"
    And "Ahmet Yılmaz" still owes every unpaid operational liability of "A-4" before 2026-11-05
    And the ledger invariants hold

  @SC-13-03-06 @J-10 @state:F2 @layer:backend @edge @role_manager @pending
  Scenario: The previous owner's advance is not silently given to the buyer
    Given the site is in state F2
    And "Ahmet Yılmaz" holds an advance of 500.00 on unit "A-4"
    When the title of "A-4" is transferred to "Gül Tanrıverdi"
    Then the advance stays with "Ahmet Yılmaz" until paid out or transferred with a second approver
    And "Gül Tanrıverdi" starts with debt and advance of 0.00 for unit "A-4"

  @SC-13-03-07 @J-10 @state:F6 @layer:backend @edge @role_manager @pending
  Scenario: Handover on the same day splits the month with no gap and no overlap
    Given the site is in state F6
    And the clock has advanced to the effective date of the handover
    When tenant "Mert Kılıç" moves out of "A-2" and tenant "Nil Acar" moves in on the same day "2026-12-12"
    And the manager accrues period "Aralık 2026" due "2026-12-10"
    Then "Mert Kılıç" owes for the days 1 to 11 and "Nil Acar" for the days 12 to 31
    And the two shares add up to 1500.00
    And no day is charged to two debtors and no day to none

  @SC-13-03-08 @J-10 @layer:backend @edge @role_manager @pending
  Scenario Outline: Proration respects month length and edge days
    Given unit "A-3" is owned and vacant on the first day of "<period>" and has tariff 1500.00
    And the clock is set to "<move_in>" and a tenant moves in on that date
    When the manager accrues period "<period>"
    Then the owner owes <owner_share> and the tenant owes <tenant_share>
    And the two shares add up to 1500.00

    Examples:
      | period        | move_in    | owner_share | tenant_share |
      | Ekim 2026     | 2026-10-01 | 0.00        | 1500.00      |
      | Ekim 2026     | 2026-10-31 | 1451.61     | 48.39        |
      | Kasım 2026    | 2026-11-16 | 750.00      | 750.00       |
      | Şubat 2028    | 2028-02-15 | 724.14      | 775.86       |
      | Şubat 2027    | 2027-02-15 | 750.00      | 750.00       |

  @SC-13-03-09 @J-10 @layer:backend @edge @role_manager @pending
  Scenario: A tariff that does not divide evenly never loses a kuruş
    Given unit "A-3" has a monthly tariff of 333.33 and a tenant moving in on "2026-11-11"
    When the manager accrues period "Kasım 2026"
    Then the owner share plus the tenant share equals exactly 333.33

  @SC-13-03-10 @J-10 @state:F6 @layer:backend @edge @role_manager @pending
  Scenario: One person who owns one unit and rents another is billed in each role
    Given the site is in state F6
    And the clock has advanced to "2026-12-01"
    When the manager moves the tenant out of "A-2", leaving "Ahmet Yılmaz" as owner of the vacant unit
    And replaces the tenant of "A-5" with "Ahmet Yılmaz" on the same effective date
    And accrues period "Aralık 2026"
    Then "Ahmet Yılmaz" owes operational dues for "A-2" as owner and for "A-5" as tenant
    And his dashboard lists both liabilities with their unit and role
    And the people directory shows one person "Ahmet Yılmaz", not two

  @SC-13-03-11 @J-10 @state:F6 @layer:backend @edge @role_manager @pending
  Scenario: The same national id entered twice does not create a second person
    Given the site is in state F6
    When the manager moves in a tenant with the national id of "Mert Kılıç" under a different spelling of the name
    Then the existing person is offered for selection instead of creating a duplicate
    And the people directory still lists one "Mert Kılıç"

  @SC-13-03-12 @J-10 @state:F6 @layer:backend @core @role_manager @pending
  Scenario: Owner moves in after the tenant leaves and takes the operational dues back
    Given the site is in state F6
    And the clock has advanced to the effective date of the handover
    And the clock has advanced to "2026-12-01"
    When tenant "Mert Kılıç" moves out of "A-2" and owner "Ahmet Yılmaz" moves in on "2026-12-01"
    And the manager accrues period "Aralık 2026"
    Then "Ahmet Yılmaz" owes 1500.00 for "A-2" as owner-occupant
    And "Mert Kılıç" owes nothing for "Aralık 2026"
    And the ledger invariants hold

  @SC-13-03-13 @J-10 @layer:backend @core @role_manager @pending
  Scenario Outline: Switching proration changes responsibility for a mid-month move-in
    Given unit "A-3" is owned and vacant on "2026-10-01" with monthly tariff 1500.00
    And proration is <setting>
    When a tenant moves in on "2026-10-11" and the period is accrued on "2026-10-20"
    Then owner principal is <owner_share> and tenant principal is <tenant_share>

    Examples:
      | setting  | owner_share | tenant_share |
      | enabled  | 483.87      | 1016.13      |
      | disabled | 0.00        | 1500.00      |

  @SC-13-03-14 @J-10 @state:F2 @layer:backend @edge @role_manager @pending
  Scenario: A failed replacement rolls back occupancy, household and settlement together
    Given a tenant-occupied unit with a linked household and an exit balance
    When tenant replacement fails at the persistence boundary after closing the old session
    Then the original occupant, household and ownership are still active
    And no replacement session, exit settlement or additional financial movement exists
    When the same replacement is retried after recovery
    Then one replacement session is active and the original tenant is settled exactly once

  @SC-13-03-15 @J-10 @state:F2 @layer:backend @core @role_manager @pending
  Scenario: A unit created mid-month is billed for chargeable days only
    Given a new owned vacant unit with monthly tariff 1500.00 is created on "2026-11-16"
    When the manager accrues November
    Then the unit's owner is charged 750.00 principal for 15 days
    And the ledger invariants hold
