@EPIC-07 @STORY-07-13
Feature: One late-fee figure across dashboard, statement and ledger
  The KMK 20 late fee is accrued daily and every report shows the same outstanding total.

  @SC-07-13-01 @layer:backend @linked @core @role_manager
  Scenario: Dashboard, statement, aging and trial balance agree on an overdue unit
    Given unit "A-14" owes 1400.00 due on "2026-10-15" and nothing was paid
    When the daily late-fee job runs on "2026-10-25"
    Then the late fee of the liability is 23.33
    And the dashboard, the resident statement and the debt aging report show 1423.33 for unit "A-14"
    And the dues receivable of unit "A-14" in the trial balance is 1423.33

  @SC-07-13-02 @layer:backend @linked @core
  Scenario: The daily late-fee job is idempotent
    Given the daily late-fee job ran on "2026-10-25"
    When it runs again on "2026-10-25"
    Then no late fee and no ledger entry changes

  @SC-07-13-03 @layer:backend @linked @core @role_manager
  Scenario: Penalty revenue is booked in the month it accrued
    Given unit "A-14" owes 1400.00 due on "2026-10-15" and nothing was paid
    When the daily late-fee job runs every day until "2026-11-14"
    Then the ledger shows 37.33 of penalty revenue in October 2026
    And 32.67 of penalty revenue in November 2026

  @SC-07-13-04 @layer:backend @linked @edge @role_manager
  Scenario: The reconciliation check reports a mismatch
    Given the stored late fee of a liability differs from its evaluation for today
    When the late-fee reconciliation check runs
    Then it reports the site and the liability that differ
