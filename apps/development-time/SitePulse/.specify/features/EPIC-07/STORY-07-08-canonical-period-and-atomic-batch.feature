@EPIC-07 @STORY-07-08
Feature: Canonical billing period and atomic accrual batch
  A period is one YYYY-MM key, a month is charged once whatever it is called, and a site's
  accrual commits completely or not at all.

  @SC-07-08-01 @pending @core @role_manager
  Scenario: Another spelling of an accrued month is a duplicate
    Given the site has 12 units and period "2026-10" is accrued
    When the manager accrues the period "ekim 2026"
    Then the request resolves to period "2026-10"
    And no liability is created and the response reports already_accrued
    And the period is shown as "Ekim 2026"

  @SC-07-08-02 @pending @edge @role_manager
  Scenario: A due date outside the period is rejected
    Given the site has units and period "2026-10" is not accrued
    When the manager accrues period "2026-10" with due date "2026-12-15"
    Then the request is rejected with status 400
    And no liability and no period row is created

  @SC-07-08-03 @pending @core
  Scenario: A failure partway through a batch writes nothing
    Given the site has 12 units and period "2026-10" is not accrued
    And the database fails while the 7th liability is written
    When the accrual for period "2026-10" runs
    Then no liability for period "2026-10" exists in the database or in memory
    And running the accrual again creates 12 liabilities linked to the period row

  @SC-07-08-04 @pending @core @role_manager
  Scenario: Skipped units are reported with their reason
    Given the site has no operating budget and unit "A-3" has no house type
    When the manager accrues period "2026-10"
    Then every other unit is charged its house-type tariff
    And the response lists unit "A-3" as skipped with the reason "no tariff"
