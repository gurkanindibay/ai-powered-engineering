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

  @SC-13-03-01 @J-10 @depth:1 @state:F6 @layer:backend @smoke @core @role_manager @linked
  Scenario: A mid-month move-in splits a period between owner and tenant
    Given the site is in state F6
    Then the "Ekim 2026" principal shares for "A-2" are owner 483.87 and tenant 1016.13
    And the tenant liability names "Selin Demir" as its liable person
    And the owner of record of "A-2" is "Ahmet Yılmaz"
    And the two shares add up to 1500.00
    And the "Eylül 2026" principal of 1500.00 for "A-2" is an owner liability
    And the ledger invariants hold

  # Pending: the accrual splits a period by role (owner, tenant), not by person, so two successive tenants share one tenant liability; the effective due date comes from the real server date, not the E2E clock (the clock drives the scheduler only); the jointly liable owner needs #207.
  @SC-13-03-02 @J-10 @depth:1 @state:F6 @layer:backend @core @role_manager @pending
  Scenario: A tenant replaced mid-month leaves the old debt with the old tenant
    Given the site is in state F6
    Then the "Kasım 2026" principal shares for "A-2" are "Selin Demir" 700.00 and "Mert Kılıç" 800.00
    And "Selin Demir" still owes her "Ekim 2026" share of 1016.13 plus late fee 66.05
    And that fee counts 39 days from the effective due date "2026-10-11", the day October was accrued, not from "2026-10-10"
    And "Mert Kılıç" owes nothing for "Eylül 2026" or "Ekim 2026"

  # Pending: GUI layer is not automated yet; needs the per-person split of SC-13-03-02.
  @SC-13-03-03 @J-10 @depth:2 @state:F6 @layer:gui @core @role_resident @pending
  Scenario: A former tenant still sees their own debt and the new tenant sees only theirs
    Given the site is in state F6
    When "Selin Demir" signs in
    Then her dashboard lists unpaid principal of 1016.13 for "Ekim 2026" and 700.00 for "Kasım 2026"
    And it shows no liability from after 2026-11-15
    When "Mert Kılıç" signs in
    Then his dashboard lists only "Kasım 2026" with principal of 800.00

  @SC-13-03-04 @J-10 @depth:1 @state:F6 @layer:backend @core @role_manager @linked
  Scenario: A resident added after accruals is charged from their start residing date
    Given the site is in state F6
    Then tenant "Oya Çelik" is primary resident of unit "A-3" with start residing date "2026-11-18"
    And the owner of record of "A-3" is "Burak Şahin"
    And "A-3" has no tenant liability for "Eylül 2026" and "Ekim 2026"
    And the "Kasım 2026" principal of "A-3" is tenant 650.00, which is 13 of 30 days, and owner 850.00
    And the ledger invariants hold
    When the manager accrues period "Aralık 2026" due "2026-12-10"
    Then "A-3" has a tenant liability of 1500.00 and no owner liability for "Aralık 2026"
    And the ledger invariants hold

  # Pending: owner liabilities and the rows re-issued by a split correction carry no liable person id, so "who owes" cannot be asserted per person on those rows.
  @SC-13-03-21 @J-10 @depth:1 @state:F6 @layer:backend @core @role_manager @pending
  Scenario: Every liability row names the person who owes it
    Given the site is in state F6
    Then the owner liabilities of "A-2", "A-3" and "A-4" name the owner of record as liable person
    And the "Kasım 2026" liabilities of "A-3" name "Oya Çelik" for 650.00 and "Burak Şahin" for 850.00
    And "Oya Çelik" owes 0.00 for "Eylül 2026" and "Ekim 2026"

  @SC-13-03-20 @J-10 @depth:1 @state:F6 @layer:backend @core @role_manager @linked
  Scenario: A re-split share keeps an effective due date and a late fee that follow its creation
    Given the site is in state F6
    Then Oya's share is due on the approval date "2026-11-18" with late fee 1.08 at the reference instant
    And Burak's reduced share keeps its effective due date "2026-11-15" and its fee is recalculated on 850.00 to 5.67

  @SC-13-03-05 @J-10 @depth:1 @state:F6 @layer:backend @core @role_manager @linked
  Scenario Outline: Capital installments follow the owner at accrual unless a seller-pays override is approved
    Given the site is in state F6
    And installment 1 of the capital project "Cephe" (6000.00 for unit "A-4" in 2 installments) was accrued before the sale
    And the title transfer to "Gül Tanrıverdi" was recorded with seller-pays override "<override>"
    When the manager accrues installment 2 after the sale
    Then installment 1 stays with "Ahmet Yılmaz"
    And installment 2 of 3000.00 is billed to "<installment_2_debtor>"
    And "Ahmet Yılmaz" still owes every unpaid operational liability of "A-4" before 2026-11-05
    And the ledger invariants hold

    Examples:
      | override                          | installment_2_debtor |
      | none                              | Gül Tanrıverdi       |
      | requested, approved by a second manager | Ahmet Yılmaz   |
      | requested, still pending          | Gül Tanrıverdi       |
      | requested, rejected               | Gül Tanrıverdi       |

  # Pending: advance balances are keyed by unit and debtor role, not by person; the seller's retained advance is not automated yet.
  @SC-13-03-06 @J-10 @depth:1 @state:F2 @layer:backend @edge @role_manager @pending
  Scenario: The previous owner's advance is not silently given to the buyer
    Given the site is in state F2
    And "Ahmet Yılmaz" holds an advance of 500.00 on unit "A-4"
    When the title of "A-4" is transferred to "Gül Tanrıverdi"
    Then the advance stays with "Ahmet Yılmaz" until paid out or transferred with a second approver
    And "Gül Tanrıverdi" starts with debt and advance of 0.00 for unit "A-4"

  # Pending: effective dates after the real server date are refused and the accrual splits by role, so a same-day tenant handover on 2026-12-12 cannot be built.
  @SC-13-03-07 @J-10 @depth:1 @state:F6 @layer:backend @edge @role_manager @pending
  Scenario: Handover on the same day splits the month with no gap and no overlap
    Given the site is in state F6
    And the clock has advanced to the effective date of the handover
    When tenant "Mert Kılıç" moves out of "A-2" and tenant "Nil Acar" moves in on the same day "2026-12-12"
    And the manager accrues period "Aralık 2026" due "2026-12-10"
    Then "Mert Kılıç" owes 532.26 for the days 1 to 11 and "Nil Acar" owes 967.74 for the days 12 to 31
    And the two shares add up to 1500.00
    And no day is charged to two debtors and no day to none

  @SC-13-03-08 @J-10 @depth:1 @layer:backend @edge @role_manager @linked
  Scenario Outline: Proration respects month length and edge days
    Given unit "A-3" is owned and vacant on the first day of "<period>" and has tariff 1500.00
    And the clock is set to "<move_in>" and a tenant moves in on that date
    When the manager accrues period "<period>"
    Then owner "Burak Şahin" owes <owner_share> and tenant "Selin Demir" owes <tenant_share>
    And the two shares add up to 1500.00

    Examples:
      | period        | move_in    | owner_share | tenant_share |
      | Ekim 2026     | 2026-10-01 | 0.00        | 1500.00      |
      | Ekim 2026     | 2026-10-31 | 1451.61     | 48.39        |
      | Kasım 2026    | 2026-11-16 | 750.00      | 750.00       |
      | Şubat 2028    | 2028-02-15 | 724.14      | 775.86       |
      | Şubat 2027    | 2027-02-15 | 750.00      | 750.00       |

  # Pending: the accrual splits by role, so two successive tenants share one tenant liability and the three-segment row cannot be asserted.
  @SC-13-03-09 @J-10 @depth:1 @layer:backend @edge @role_manager @pending
  Scenario Outline: A tariff that does not divide evenly never gains or loses a kuruş
    Given unit "A-3" is owned and vacant on "2026-11-01" with monthly tariff <tariff>
    And the occupancy of "Kasım 2026" is <segments>
    When the manager accrues period "Kasım 2026"
    Then the shares in day order are <shares>
    And the shares add up to exactly <tariff>, with the rounding remainder on the last share

    # Naive per-share rounding gives 1500.02 and 999.99. The remainder rule in
    # domain/occupancy_proration.rs must give back the tariff exactly.
    Examples:
      | tariff  | segments                                              | shares                   |
      | 1500.01 | owner days 1-15, tenant days 16-30                    | 750.01, 750.00           |
      | 1000.00 | owner days 1-10, tenant 1 days 11-20, tenant 2 days 21-30 | 333.33, 333.33, 333.34 |

  @SC-13-03-10 @J-10 @depth:1 @state:F6 @layer:backend @edge @role_manager @linked
  Scenario: One person who owns one unit and rents another is billed in each role
    Given the site is in state F6
    And the clock has advanced to "2026-12-01"
    When the manager moves the tenant out of "A-2", leaving "Ahmet Yılmaz" as owner of the vacant unit
    And replaces the tenant of "A-5" with "Ahmet Yılmaz" on the same effective date
    And accrues period "Aralık 2026"
    Then "Ahmet Yılmaz" owes operational dues for "A-2" as owner and for "A-5" as tenant
    And his resident statement API lists both liabilities with their unit and role
    And the people directory shows one person "Ahmet Yılmaz", not two

  # Pending: duplicate national id matching is not automated yet.
  @SC-13-03-11 @J-10 @depth:1 @state:F6 @layer:backend @edge @role_manager @pending
  Scenario: The same national id entered twice does not create a second person
    Given the site is in state F6
    When the manager moves in a tenant with the national id of "Mert Kılıç" under a different spelling of the name
    Then the API returns the existing person as a match instead of creating a duplicate
    And the people directory still lists one "Mert Kılıç"

  @SC-13-03-12 @J-10 @depth:1 @state:F6 @layer:backend @core @role_manager @linked
  Scenario: Owner moves in after the tenant leaves and takes the operational dues back
    Given the site is in state F6
    And the clock has advanced to "2026-12-01"
    When tenant "Mert Kılıç" moves out of "A-2" and owner "Ahmet Yılmaz" moves in on "2026-12-01"
    And the manager accrues period "Aralık 2026"
    Then "Ahmet Yılmaz" owes 1500.00 for "A-2" as owner-occupant
    And "Mert Kılıç" owes nothing for "Aralık 2026"
    And the ledger invariants hold

  @SC-13-03-13 @J-10 @depth:1 @layer:backend @core @role_manager @linked
  Scenario Outline: Switching proration changes responsibility for a mid-month move-in
    Given unit "A-3" is owned and vacant on "2026-10-01" with monthly tariff 1500.00
    And proration is <setting>
    When a tenant moves in on "2026-10-11" and the period is accrued on "2026-10-20"
    Then owner "Burak Şahin" principal is <owner_share> and tenant "Oya Çelik" principal is <tenant_share>

    Examples:
      | setting  | owner_share | tenant_share |
      | enabled  | 483.87      | 1016.13      |
      | disabled | 0.00        | 1500.00      |

  # Pending: needs fault injection at the persistence boundary, which the E2E backend does not offer.
  @SC-13-03-14 @J-10 @depth:2 @state:F2 @layer:backend @edge @role_manager @pending
  Scenario: A failed replacement rolls back occupancy, household and settlement together
    Given a tenant-occupied unit with a linked household and an exit balance
    When tenant replacement fails at the persistence boundary after closing the old session
    Then the original occupant, household and ownership are still active
    And no replacement session, exit settlement or additional financial movement exists
    When the same replacement is retried after recovery
    Then one replacement session is active and the original tenant is settled exactly once

  @SC-13-03-15 @J-10 @depth:1 @state:F2 @layer:backend @core @role_manager @linked
  Scenario: A unit created mid-month is billed for chargeable days only
    Given a new owned vacant unit with monthly tariff 1500.00 is created on "2026-11-16"
    When the manager accrues November
    Then the unit's owner is charged 750.00 principal for 15 days
    And the ledger invariants hold

  @SC-13-03-16 @J-10 @depth:1 @state:F6 @layer:backend @core @role_manager @linked
  Scenario: A mid-month sale of an owner-occupied unit splits that month between seller and buyer
    Given the site is in state F6
    Then the "Kasım 2026" operational principal of "A-4" is 200.00 for "Ahmet Yılmaz" (days 1 to 4)
    And 1300.00 for "Gül Tanrıverdi" (days 5 to 30)
    And the two shares add up to 1500.00
    And "Ahmet Yılmaz" has no active occupancy of "A-4" after "2026-11-05"

  @SC-13-03-17 @J-10 @depth:1 @layer:backend @edge @role_manager @linked
  Scenario Outline: A share whose responsibility starts after the period due date is not late before it existed
    Given unit "A-3" is owned and vacant with tariff 1500.00 and the period "Kasım 2026" is due "2026-11-10"
    And the days before the tenant's start belong to the owner (Q9, decided)
    And a tenant's responsibility for "Kasım 2026" starts on "<start>" and the share is created on "<created>"
    When the late fee is evaluated on "2026-11-19"
    Then the tenant share is <share> due on "<share_due>" and its late fee is <fee>

    # Effective due date = max(period due date, share creation date), README section 2.
    # Today the share would keep "2026-11-10" (SC-07-10-03) and owe a fee for days before it existed.
    Examples:
      | start      | created    | share   | share_due  | fee   |
      | 2026-11-05 | 2026-11-05 | 1300.00 | 2026-11-10 | 19.50 |
      | 2026-11-15 | 2026-11-15 | 800.00  | 2026-11-15 | 5.33  |
      | 2026-11-18 | 2026-11-18 | 650.00  | 2026-11-18 | 1.08  |
      | 2026-11-05 | 2026-11-18 | 1300.00 | 2026-11-18 | 2.17  |

  # Pending: needs #207 (jointly liable owner) and #209 (sale of a tenant-occupied unit); the effective date 2026-12-15 is after the real server date.
  @SC-13-03-18 @J-10 @depth:1 @state:F5 @layer:backend @core @role_manager @pending
  # Backend coverage: backend/tests/db_accrual_atomic_tests.rs (atomic accrual keeps debtor shares singular and repeat-safe).
  Scenario: A sale of a tenant-occupied unit with the same tenant is not split
    Given the site is in state F5
    And the clock has advanced to "2026-12-15"
    When the manager transfers title of "A-2" from "Ahmet Yılmaz" to "Gül Tanrıverdi" effective "2026-12-15"
    And tenant "Selin Demir" stays in "A-2"
    And the manager accrues period "Aralık 2026" due "2026-12-10"
    Then "Selin Demir" owes the whole 1500.00 "Aralık 2026" operational principal for "A-2"
    And neither "Ahmet Yılmaz" nor "Gül Tanrıverdi" has an "Aralık 2026" operational liability for "A-2"
    And the jointly liable owner shown on that liability is "Ahmet Yılmaz" for days 1 to 14 and "Gül Tanrıverdi" from day 15
    And the ledger invariants hold

  @SC-13-03-19 @J-10 @depth:1 @state:F5 @layer:gui @core @role_manager @linked
  Scenario: The sale clearance statement lists everything that does or does not move with the unit
    Given the site is in state F5
    And the clock has advanced to "2026-12-20"
    And "Aralık 2026" was accrued on "2026-12-01" due "2026-12-10"
    And installment 1 of capital project "Cephe" (6000.00 for "A-4" in 3 installments, the first due "2026-12-10") was accrued on "2026-12-01"
    When the manager starts the title transfer of "A-4" from "Ahmet Yılmaz" to "Gül Tanrıverdi" effective "2026-12-20"
    Then the clearance statement shows open debt 5158.33 for "Ahmet Yılmaz"
    And it itemizes "Kasım 2026" 1600.00, "Aralık 2026" 1525.00 and installment 1 2033.33, principal and fee apart
    And it shows advance 0.00 and installments 2 and 3 of 2000.00 each as not yet accrued
    And it states that existing debt stays with the seller and later installments go to the buyer unless a seller-pays override is approved
    And the statement can be downloaded and totals the same as the ledger
