@EPIC-13 @STORY-13-03
Feature: Residents and owners change after periods were accrued (state F6)
  Households, tenants and owners arrive or leave once billing history exists.
  The rule under test: old liabilities stay with whoever was responsible then (invariant I7).
  F6 narrative: README section 3.1.

  Background:
    Given the clock is frozen at "2026-11-19 12:00" Europe/Istanbul
    And a SaaS admin has onboarded a site "e2e-j03" with manager "manager@e2e.test"
    And the manager has signed in with a permanent password
    And proration is enabled for the site

  @SC-13-03-01 @J-10 @state:F6 @layer:backend @smoke @core @role_manager @pending
  Scenario: A mid-month move-in splits a period between owner and tenant
    Given the site is in state F6
    Then for unit "A-2" in "Ekim 2026" owner "Ahmet Yılmaz" owes 483.87 and tenant "Selin Demir" owes 1016.13
    And the two shares add up to 1500.00
    And for unit "A-2" in "Eylül 2026" owner "Ahmet Yılmaz" owes the whole 1500.00

  @SC-13-03-02 @J-10 @state:F6 @layer:backend @core @role_manager @pending
  Scenario: A tenant replaced mid-month leaves the old debt with the old tenant
    Given the site is in state F6
    Then for unit "A-2" in "Kasım 2026" tenant "Selin Demir" owes 700.00 and tenant "Mert Kılıç" owes 800.00
    And "Selin Demir" still owes her "Ekim 2026" share of 1016.13 plus its late fee
    And "Mert Kılıç" owes nothing for "Eylül 2026" or "Ekim 2026"

  @SC-13-03-03 @J-10 @state:F6 @layer:gui @core @role_homeowner @pending
  Scenario: A former tenant still sees their own debt and the new tenant sees only theirs
    Given the site is in state F6
    When "Selin Demir" signs in
    Then her dashboard lists "Ekim 2026" 1016.13 and "Kasım 2026" 700.00 as unpaid
    And it shows no liability from after 2026-11-15
    When "Mert Kılıç" signs in
    Then his dashboard lists only "Kasım 2026" 800.00

  @SC-13-03-04 @J-10 @state:F6 @layer:backend @core @role_manager @pending
  Scenario: A resident added after accruals is charged from their start residing date
    Given the site is in state F6
    Then tenant "Oya Çelik" is primary resident of unit "A-3" with start residing date "2026-11-18"
    And "Oya Çelik" owes 0.00 for "Eylül 2026" and "Ekim 2026"
    And "Oya Çelik" owes 650.00 for "Kasım 2026", which is 13 of 30 days
    And owner "Burak Şahin" owes the full "Eylül 2026" and "Ekim 2026" and 850.00 for "Kasım 2026"
    When the manager accrues period "Aralık 2026" due "2026-12-10"
    Then tenant "Oya Çelik" owes 1500.00 for "Aralık 2026"
    And owner "Burak Şahin" owes nothing for "Aralık 2026" operational dues

  @SC-13-03-05 @J-10 @state:F6 @layer:backend @core @role_manager @pending
  Scenario: A title deed transfer moves future capital dues but not old debt
    Given the site is in state F6
    And a capital project "Cephe" of 6000.00 in 2 installments was accrued for unit "A-4" before the sale
    When the manager accrues installment 2 after the sale
    Then installment 1 stays with "Ahmet Yılmaz"
    And installment 2 is billed to "Gül Tanrıverdi"
    And "Ahmet Yılmaz" still owes every unpaid operational liability of "A-4" before 2026-11-05
    And the ledger invariants hold

  @SC-13-03-06 @J-10 @state:F6 @layer:backend @edge @role_manager @pending
  Scenario: The previous owner's advance is not silently given to the buyer
    Given the site is in state F6
    And "Ahmet Yılmaz" holds an advance of 500.00 on unit "A-4"
    When the title of "A-4" is transferred to "Gül Tanrıverdi"
    Then the advance stays with "Ahmet Yılmaz" until paid out or transferred with a second approver
    And "Gül Tanrıverdi" starts with a balance of 0.00

  @SC-13-03-07 @J-10 @state:F6 @layer:backend @edge @role_manager @pending
  Scenario: Handover on the same day splits the month with no gap and no overlap
    Given the site is in state F6
    When tenant "Mert Kılıç" moves out of "A-2" and tenant "Nil Acar" moves in on the same day "2026-12-12"
    And the manager accrues period "Aralık 2026" due "2026-12-10"
    Then "Mert Kılıç" owes for the days 1 to 11 and "Nil Acar" for the days 12 to 31
    And the two shares add up to 1500.00
    And no day is charged to two debtors and no day to none

  @SC-13-03-08 @J-10 @state:F6 @layer:backend @edge @role_manager @pending
  Scenario Outline: Proration respects month length and edge days
    Given unit "A-3" has a monthly tariff of 1500.00 and a tenant moving in on "<move_in>"
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

  @SC-13-03-09 @J-10 @state:F6 @layer:backend @edge @role_manager @pending
  Scenario: A tariff that does not divide evenly never loses a kuruş
    Given unit "A-3" has a monthly tariff of 333.33 and a tenant moving in on "2026-11-11"
    When the manager accrues period "Kasım 2026"
    Then the owner share plus the tenant share equals exactly 333.33

  @SC-13-03-10 @J-10 @state:F6 @layer:backend @edge @role_manager @pending
  Scenario: One person who owns one unit and rents another is billed in each role
    Given the site is in state F6
    When "Ahmet Yılmaz" moves into unit "A-5" as a tenant
    And the manager accrues period "Aralık 2026"
    Then "Ahmet Yılmaz" owes operational dues for "A-4" as owner and for "A-5" as tenant
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
    When tenant "Mert Kılıç" moves out of "A-2" and owner "Ahmet Yılmaz" moves in on "2026-12-01"
    And the manager accrues period "Aralık 2026"
    Then "Ahmet Yılmaz" owes 1500.00 for "A-2" as owner-occupant
    And "Mert Kılıç" owes nothing for "Aralık 2026"
    And the ledger invariants hold
