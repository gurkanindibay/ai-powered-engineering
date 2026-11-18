@EPIC-07 @STORY-07-12
Feature: Billing period lifecycle and close
  A closed period's figures never change; later corrections go to the open period.

  @SC-07-12-01 @layer:backend @linked @core @role_manager
  Scenario: Closing a period shows its summary and stores a snapshot
    Given period "2026-10" is open with 16800.00 accrued and 14000.00 collected
    When the manager closes period "2026-10"
    Then the summary shows accrued 16800.00, collected 14000.00 and outstanding 2800.00
    And the period status is CLOSED

  @SC-07-12-02 @layer:backend @linked @core @role_manager
  Scenario: A closed period still accepts payments
    Given period "2026-10" is closed and unit "B-3" owes 1400.00 for it
    When 1400.00 is received for unit "B-3" on "2026-11-03"
    Then the liability of period "2026-10" is paid
    And the payment is booked in period "2026-11"

  @SC-07-12-03 @layer:backend @linked @core @role_manager
  Scenario: A correction to a closed period is booked in the open period
    Given period "2026-10" is closed and period "2026-11" is open
    When a credit note of 200.00 on a liability of period "2026-10" is approved
    Then the credit note is booked in period "2026-11" with a reference to period "2026-10"
    And the account report for period "2026-10" is unchanged

  @SC-07-12-04 @layer:backend @linked @edge @role_manager
  Scenario: Accrual into a closed period is refused
    Given period "2026-10" is closed
    When the manager accrues period "2026-10" for a newly added unit
    Then the request is rejected with status 409

  @SC-07-12-05 @layer:backend @linked @edge @role_manager
  Scenario: Reopening a period needs a second approver
    Given period "2026-10" is closed
    When the manager requests to reopen it with reason "missed invoice"
    Then the period stays CLOSED until a second manager approves
    And the reopening is recorded in the audit list
