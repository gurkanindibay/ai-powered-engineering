@EPIC-07 @STORY-07-10
Feature: Accrual schedule, catch-up and grace period
  Each site sets its accrual and due days, missed months are accrued, and a grace period can delay
  the late fee.

  @SC-07-10-01 @layer:backend @linked @core @role_manager
  Scenario: The site's due day is used for every accrued liability
    Given the site's due day is 5
    When period "2026-11" is accrued
    Then every liability of period "2026-11" is due on "2026-11-05"

  @SC-07-10-02 @layer:backend @linked @edge
  Scenario: A due day beyond the end of the month falls on its last day
    Given the site's due day is 31
    When period "2027-02" is accrued
    Then every liability of period "2027-02" is due on "2027-02-28"

  @SC-07-10-03 @layer:backend @linked @core
  Scenario: The scheduler catches up months it missed
    Given the site's last accrued period is "2026-08"
    And the scheduler was off until "2026-11-02"
    When the scheduler runs on "2026-11-02"
    Then periods "2026-09", "2026-10" and "2026-11" are accrued, oldest first
    And each liability keeps its own period's due date for month and FIFO order
    And each liability created after its period due date counts its late fee and grace from "2026-11-02", the day it was created
    And the run reports the three periods it accrued

  @SC-07-10-04 @layer:backend @linked @edge
  Scenario: Catch-up stops at the configured limit
    Given the catch-up limit is 12 months
    And the site has no accrued period and went live on "2025-01-01"
    When the scheduler runs on "2026-11-02"
    Then periods "2025-12" to "2026-11" are accrued
    And the run reports that periods before "2025-12" were not accrued because of the limit

  @SC-07-10-05 @layer:backend @linked @core @role_homeowner
  Scenario: A payment inside the grace period carries no late fee
    Given the site's grace period is 5 days
    And unit "A-14" owes 1400.00 due on "2026-10-15"
    When 1400.00 is received for unit "A-14" on "2026-10-19"
    Then the liability is paid with a late fee of 0.00

  @SC-07-10-06 @layer:backend @linked @core @role_homeowner
  Scenario: After the grace period the late fee runs from the due date
    Given the site's grace period is 5 days
    And unit "A-14" owes 1400.00 due on "2026-10-15"
    When the late fee is evaluated on "2026-10-25"
    Then the late fee is 23.33

  @SC-07-10-07 @layer:backend @linked @core @role_manager
  Scenario: A charge created after its period due date owes no fee for days before it existed
    Given unit "A-14" has a November share of 650.00 with period due date "2026-11-10"
    And the share is created on "2026-11-18"
    Then its effective due date is "2026-11-18" and its period due date stays "2026-11-10"
    When the late fee is evaluated on "2026-11-19"
    Then the late fee is 1.08, not 9.75
    And the statement shows the charge as created late
