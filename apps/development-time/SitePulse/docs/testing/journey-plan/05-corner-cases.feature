@EPIC-13 @STORY-13-05
Feature: Corner cases around accrual, occupancy, access and time
  Cases the numbered starting points do not reach. Each runs on a named state so the numbers are fixed.

  Background:
    Given the scenario clock follows the fixture timeline in Europe/Istanbul
    And a SaaS admin has onboarded a site and manager unique to this scenario attempt
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
  Scenario Outline: A due day the month does not have falls on its last day
    Given the site is in state F2 with due day 31
    When the manager accrues period "<period>"
    Then the due date of every liability is "<due>"

    Examples:
      | period      | due        |
      | Şubat 2027  | 2027-02-28 |
      | Şubat 2028  | 2028-02-29 |
      | Kasım 2026  | 2026-11-30 |

  @SC-13-05-03 @J-12 @state:F4 @layer:backend @edge @role_manager @pending
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

  @SC-13-05-05 @J-12 @state:F2 @layer:backend @edge @role_manager @pending
  Scenario: The scheduler catches up months that were missed
    Given the site is in state F2 with the accrual scheduler enabled
    And the scheduler did not run for "Eylül 2026" and "Ekim 2026"
    When the scheduler runs on "2026-11-19"
    Then liabilities exist for "Eylül 2026", "Ekim 2026" and "Kasım 2026", each once
    And each liability keeps its own period's due date, so its late fee runs from that date (SC-07-10-03)
    And the total outstanding is 31183.75, which is 5 x 4797.50 plus 7196.25 for "A-6"
    And running the scheduler again adds nothing

  # ------------------------------------------------------------- occupancy

  @SC-13-05-06 @J-12 @state:F5 @layer:backend @edge @role_manager @pending
  Scenario: Moving out with debt keeps the debt and the history
    Given the site is in state F5
    And the clock has advanced to "2026-12-01" before any December accrual
    When tenant "Deniz Arslan" moves out of unit "A-5" effective "2026-12-01"
    Then "Deniz Arslan" still owes the same 4500.00 principal plus the accrued fee as of the move-out date
    And the move-out settlement shows that debt with no payout
    And unit "A-5" is vacant and its owner "Can Öztürk" is not charged for the tenant's debt

  @SC-13-05-07 @J-12 @state:F5 @layer:backend @edge @role_manager @pending
  Scenario: Moving out with an advance requires a decision before the advance leaves
    Given the site is in state F5
    And tenant "Selin Demir" pays 3422.50 on "2026-11-19", clearing existing debt and leaving advance 300.00
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

  @SC-13-05-09 @J-12 @state:F6 @layer:backend @edge @role_manager @pending
  Scenario: A move-out recorded after accrual re-splits the open liability
    Given the site is in state F6
    And the clock has advanced to "2026-11-26"
    When the manager records that tenant "Mert Kılıç" left "A-2" effective "2026-11-25"
    Then a split correction is requested and the liability amounts remain unchanged pending approval
    When a different manager approves the split correction
    Then November principal is 700.00 to "Selin Demir", 500.00 to "Mert Kılıç" and 300.00 to the owner

  # ------------------------------------------------------------ people data

  @SC-13-05-10 @J-12 @state:F1 @layer:gui @edge @role_manager @pending
  Scenario: An Excel import with one bad row imports the good rows and reports the bad one
    Given the site is in state F1
    When the manager imports a workbook with 5 valid people and 1 row with an invalid national id
    Then 5 people are created
    And the result lists row 6 with the reason
    And no partial person exists for the bad row

  @SC-13-05-11 @J-12 @state:F5 @layer:backend @edge @role_manager @pending
  Scenario: Merging two duplicate people keeps every liability and payment
    Given the site is in state F5
    And "Deniz Arslan" exists twice with different phone numbers, one of them owning a payment
    When the manager merges the duplicates
    Then one person remains and the liabilities and payments of both are attached to it
    And the ledger invariants hold

  # ----------------------------------------------------------- access control

  @SC-13-05-12 @J-12 @state:F5 @layer:backend @core @role_resident @pending
  Scenario: A resident cannot call manager actions
    Given the site is in state F5
    When tenant "Deniz Arslan" calls accrue, record-manual payment and move-out
    Then each call is answered 403
    And no data changes

  @SC-13-05-13 @J-12 @state:F5 @layer:backend @core @role_manager @pending
  Scenario: A manager of another site sees nothing of this site
    Given the site is in state F5
    And a second site, named in this attempt's manifest, has its own manager in state F5
    When the manager of the second site requests units, people, payments and liabilities of this site by id
    Then every response is 403 or 404 and contains no data of this site
    And invariant I10 holds in both directions

  # -------------------------------------------------------------------- time

  @SC-13-05-14 @J-12 @state:F5 @layer:backend @edge @role_manager @pending
  Scenario: The month boundary uses Istanbul time, not UTC
    Given the site is in state F5
    And the accrual scheduler is due to open December on the first local day and catch-up is disabled
    When it is ticked at "2026-11-30 23:30" Europe/Istanbul
    Then December has no accrued liability
    When it is ticked at "2026-12-01 00:30" Europe/Istanbul, still November 30 UTC
    Then it accrues December exactly once and leaves November principal unchanged

  @SC-13-05-15 @J-12 @state:F5 @layer:backend @edge @role_manager @pending
  Scenario: A late fee never makes a settled liability reopen
    Given the site is in state F5
    And unit "A-3" paid its "Eylül 2026" debt in full today
    When the clock moves forward 30 days
    Then unit "A-3" still owes 0.00 for "Eylül 2026"

  # ------------------------------------------------------------- persistence

  @SC-13-05-16 @J-12 @layer:backend @core @role_manager @pending
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
