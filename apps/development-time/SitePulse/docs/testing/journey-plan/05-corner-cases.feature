@EPIC-13 @STORY-13-05
Feature: Corner cases around accrual, occupancy, access and time
  Cases the numbered starting points do not reach. Each runs on a named state so the numbers are fixed.

  Background:
    Given the clock is frozen at "2026-11-19 12:00" Europe/Istanbul
    And a SaaS admin has onboarded a site "e2e-j05" with manager "manager@e2e.test"
    And the manager has signed in with a permanent password

  # ----------------------------------------------------------- accrual input

  @SC-13-05-01 @J-12 @state:F2 @layer:backend @edge @role_manager @pending
  Scenario Outline: Invalid accrual input is rejected and creates nothing
    Given the site is in state F2
    When the manager accrues period "<period>" with amount <amount> and due date "<due>"
    Then the request is rejected with "<reason>"
    And no period and no liability exists

    Examples:
      | period     | amount  | due        | reason                      |
      | Ekim 2026  | 0.00    | 2026-10-10 | amount must be positive     |
      | Ekim 2026  | -1500.00| 2026-10-10 | amount must be positive     |
      | Ekim 2026  | 1500.00 | 2026-02-30 | invalid due date            |
      | Ekim 2025  | 1500.00 | 2026-10-10 | due date outside the period |

  @SC-13-05-02 @J-12 @state:F2 @layer:backend @edge @role_manager @pending
  Scenario: A due day the month does not have falls on its last day
    Given the site is in state F2 with due day 31
    When the manager accrues period "Şubat 2027"
    Then the due date of every liability is "2027-02-28"

  @SC-13-05-03 @J-12 @state:F2 @layer:backend @edge @role_manager @pending
  Scenario: A duplicate accrual with a different amount is still blocked
    Given the site is in state F4
    When the manager accrues period "Ekim 2026" again with amount 1800.00
    Then the request is rejected as a duplicate
    And every Ekim liability still has its original amount

  @SC-13-05-04 @J-12 @state:F2 @layer:backend @edge @role_manager @pending
  Scenario: Two admins accruing the same period at the same moment create one set of liabilities
    Given the site is in state F2
    When two manager sessions accrue period "Ekim 2026" in parallel
    Then exactly one request succeeds and the other is rejected as a duplicate
    And exactly 6 liabilities exist
    And the ledger invariants hold

  @SC-13-05-05 @J-12 @state:F5 @layer:backend @edge @role_manager @pending
  Scenario: The scheduler catches up months that were missed
    Given the site is in state F2 with the accrual scheduler enabled
    And the scheduler did not run for "Eylül 2026" and "Ekim 2026"
    When the scheduler runs on "2026-11-19"
    Then liabilities exist for "Eylül 2026", "Ekim 2026" and "Kasım 2026", each once
    And running the scheduler again adds nothing

  # ------------------------------------------------------------- occupancy

  @SC-13-05-06 @J-12 @state:F5 @layer:backend @edge @role_manager @pending
  Scenario: Moving out with debt keeps the debt and the history
    Given the site is in state F5
    When tenant "Deniz Arslan" moves out of unit "A-5"
    Then "Deniz Arslan" still owes 4797.50
    And the move-out settlement shows that debt with no payout
    And unit "A-5" is vacant and its owner "Can Öztürk" is not charged for the tenant's debt

  @SC-13-05-07 @J-12 @state:F5 @layer:backend @edge @role_manager @pending
  Scenario: Moving out with an advance requires a decision before the advance leaves
    Given the site is in state F5
    And tenant "Selin Demir" holds an advance of 300.00
    When "Selin Demir" moves out of unit "A-2"
    Then the manager must choose keep, pay out or transfer
    And a payout or transfer only happens after a second approver confirms

  @SC-13-05-08 @J-12 @state:F5 @layer:backend @edge @role_manager @pending
  Scenario: Moving out twice and moving in on an occupied unit are refused
    Given the site is in state F5
    When tenant "Deniz Arslan" moves out of unit "A-5"
    And the manager moves out unit "A-5" again
    Then the second move-out is refused because the unit is vacant
    When the manager moves tenant "Selin Demir" into unit "A-1" that is owner-occupied
    Then the request is refused with the allowed commands for the current state

  @SC-13-05-09 @J-12 @state:F5 @layer:backend @edge @role_manager @pending
  Scenario: A move-out recorded after accrual re-splits the open liability
    Given the site is in state F6
    When the manager records that tenant "Mert Kılıç" left "A-2" on "2026-11-25" instead of staying
    Then the "Kasım 2026" liability of "A-2" is re-split between "Mert Kılıç" and the owner
    And the shares still add up to 1500.00

  # ------------------------------------------------------------ people data

  @SC-13-05-10 @J-12 @state:F2 @layer:gui @edge @role_manager @pending
  Scenario: An Excel import with one bad row imports the good rows and reports the bad one
    Given the site is in state F1
    When the manager imports a workbook with 5 valid people and 1 row with an invalid national id
    Then 5 people are created
    And the result lists row 6 with the reason
    And no partial person exists for the bad row

  @SC-13-05-11 @J-12 @state:F2 @layer:backend @edge @role_manager @pending
  Scenario: Merging two duplicate people keeps every liability and payment
    Given the site is in state F5
    And "Deniz Arslan" exists twice with different phone numbers, one of them owning a payment
    When the manager merges the duplicates
    Then one person remains and the liabilities and payments of both are attached to it
    And the ledger invariants hold

  # ----------------------------------------------------------- access control

  @SC-13-05-12 @J-12 @state:F5 @layer:backend @core @role_manager @pending
  Scenario: A resident cannot call manager actions
    Given the site is in state F5
    When tenant "Deniz Arslan" calls accrue, record-manual payment and move-out
    Then each call is answered 403
    And no data changes

  @SC-13-05-13 @J-12 @state:F5 @layer:backend @core @role_manager @pending
  Scenario: A manager of another site sees nothing of this site
    Given the site is in state F5
    And a second site "e2e-j05-other" with its own manager in state F5
    When the manager of "e2e-j05-other" requests units, people, payments and liabilities of this site by id
    Then every response is 403 or 404 and contains no data of this site
    And invariant I10 holds in both directions

  # -------------------------------------------------------------------- time

  @SC-13-05-14 @J-12 @state:F5 @layer:backend @edge @role_manager @pending
  Scenario: The month boundary uses Istanbul time, not UTC
    Given the clock is frozen at "2026-11-30 23:30" Europe/Istanbul which is "2026-11-30 20:30" UTC
    When the manager accrues period "Aralık 2026" with proration on
    Then the day of 2026-11-30 is billed to the November occupant
    When the clock moves to "2026-12-01 00:30" Europe/Istanbul
    Then the day is December and a new move-in is dated "2026-12-01"

  @SC-13-05-15 @J-12 @state:F5 @layer:backend @edge @role_manager @pending
  Scenario: A late fee never makes a settled liability reopen
    Given the site is in state F5
    And unit "A-3" paid its "Eylül 2026" debt in full today
    When the clock moves forward 30 days
    Then unit "A-3" still owes 0.00 for "Eylül 2026"

  # ------------------------------------------------------------- persistence

  @SC-13-05-16 @J-12 @state:F5 @layer:backend @core @role_manager @pending
  Scenario Outline: Balances are identical after a backend restart at any point of the history
    Given the site is in state <state>
    When the backend is restarted
    Then every balance on the collection dashboard, every resident dashboard and every unit workspace is identical
    And invariant I8 holds

    Examples:
      | state |
      | F4    |
      | F5    |
      | F6    |
      | F7    |
