@EPIC-07 @STORY-07-09
Feature: Occupancy-aware accrual and proration
  Operational dues for a month are shared between its occupants by the days each was responsible.

  @SC-07-09-01 @layer:backend @linked @core @role_manager
  Scenario: A mid-month move-in splits the month between owner and tenant
    Given proration is enabled for the site
    And unit "A-14" has monthly dues of 1400.00 and is vacant
    And a tenant moves into unit "A-14" on "2026-10-11"
    When period "2026-10" is accrued
    Then the owner owes 451.61 for period "2026-10"
    And the tenant owes 948.39 for period "2026-10"
    And the two shares add up to 1400.00

  @SC-07-09-02 @layer:backend @linked @core @role_manager
  Scenario: A unit created mid-month is charged from its creation date
    Given proration is enabled for the site
    And unit "C-2" with monthly dues of 1800.00 is created on "2026-11-16"
    When period "2026-11" is accrued
    Then unit "C-2" owes 900.00 for period "2026-11"

  @SC-07-09-03 @layer:backend @linked @edge @role_manager
  Scenario: A move-out recorded after accrual re-splits the open liability
    Given proration is enabled for the site
    And the tenant of unit "A-14" owes 1400.00 for period "2026-10" and has paid 1400.00
    When a move-out of the tenant is recorded on "2026-10-21"
    Then a split correction is requested for the open liability
    When a different manager approves the split correction
    Then the tenant's share of period "2026-10" is corrected to 903.23
    And 496.77 is credited to the tenant's advance balance
    And the owner owes 496.77 for period "2026-10"

  @SC-07-09-04 @layer:backend @linked @edge @role_manager
  Scenario: With proration switched off the occupant on the accrual date owes the whole month
    Given proration is disabled for the site
    And a tenant moves into unit "A-14" on "2026-10-11"
    When period "2026-10" is accrued on "2026-10-20"
    Then the tenant owes 1400.00 for period "2026-10"
    And the owner owes nothing for period "2026-10"

  @SC-07-09-05 @layer:backend @linked @edge @role_manager
  Scenario Outline: A scheduler retry after move-in does not add another monthly liability
    Given proration is <setting>
    And unit "A-14" with monthly dues of 1400.00 is vacant
    And the scheduler accrues period "2026-10" to the owner
    When a tenant moves into unit "A-14" on "2026-10-11"
    And the scheduler retries period "2026-10"
    Then unit "A-14" still has exactly one 1400.00 operational liability for period "2026-10"

    Examples:
      | setting  |
      | disabled |
      | enabled  |

  @SC-07-09-06 @layer:backend @linked @edge @role_manager
  Scenario Outline: A manual accrual retry after move-in does not add another monthly liability
    Given proration is <setting>
    And unit "A-14" with monthly dues of 1400.00 is vacant
    And manual accrual records period "2026-10" to the owner
    When a tenant moves into unit "A-14" on "2026-10-11"
    And the manager manually retries period "2026-10"
    Then unit "A-14" still has exactly one 1400.00 operational liability for period "2026-10"

    Examples:
      | setting  |
      | disabled |
      | enabled  |
