@EPIC-07 @STORY-07-07
Feature: Monthly dues periodic accrual and duplicate prevention
  Accrual runs from the scheduler or the manager UI and never charges a period twice.

  @SC-07-07-01 @GUI-07-10 @layer:gui @linked @smoke @role_manager
  Scenario: Manager accrues a period once and the duplicate is blocked
    Given the site has units and the period "Ekim 2026" is not yet accrued
    When the monthly accrual is executed for period "Ekim 2026" with dues of 1400.00 each
    Then a liability is created for every unit
    And accruing the same period again creates nothing and reports already_accrued
    And the total number of liabilities is unchanged

  @SC-07-07-02 @layer:gui @linked @core
  Scenario: Scheduler batch accrues and prevents duplicate accrual
    Given the scheduler batch runs for a period
    When the batch runs a second time for the same period
    Then the second run accrues nothing

  @SC-07-07-03 @layer:gui @linked @core @role_manager
  Scenario: Accrual confirmation dialog shows the duplicate prevention note
    Given the manager opens the dues management view
    When the manager opens the Toplu Aidat Tahakkuku dialog
    Then the confirmation dialog shows the duplicate prevention note
