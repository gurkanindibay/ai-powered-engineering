@EPIC-13 @STORY-13-05
Feature: Corner cases around accrual, occupancy, access and time
  Cases the numbered starting points do not reach. Each runs on a named state so the numbers are fixed.

  Background:
    Given the scenario clock follows the fixture timeline in Europe/Istanbul
    And a SaaS admin has onboarded a site and manager unique to this scenario attempt
    And the manager has signed in with a permanent password

  # ----------------------------------------------------------- accrual input

  # Pending: the API journey does not yet cover every invalid amount/date/period combination and assert no rows were created.
  @SC-13-05-01 @J-12 @depth:1 @state:F2 @layer:backend @edge @role_manager @pending
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

  @SC-13-05-02 @J-12 @depth:1 @state:F2 @layer:backend @edge @role_manager @linked
  Scenario Outline: A due day the month does not have falls on its last day
    Given the site is in state F2 with due day 31
    When the manager accrues period "<period>"
    Then the due date of every liability is "<due>"

    Examples:
      | period      | due        |
      | Şubat 2027  | 2027-02-28 |
      | Şubat 2028  | 2028-02-29 |
      | Kasım 2026  | 2026-11-30 |

  # Pending: the duplicate-accrual API test does not verify that a retry with a different amount is blocked and leaves the original shares intact.
  @SC-13-05-03 @J-12 @depth:1 @state:F4 @layer:backend @edge @role_manager @pending
  Scenario: A duplicate accrual with a different amount is still blocked
    Given the site is in state F4
    When the manager accrues period "Ekim 2026" again with amount 1800.00
    Then the request is rejected as a duplicate
    And every Ekim liability still has its original amount

  # Pending: the concurrent accrual test does not yet prove two independent manager requests serialize to exactly one six-liability set.
  @SC-13-05-04 @J-12 @depth:1 @state:F2 @layer:backend @edge @role_manager @pending
  Scenario: Two admins accruing the same period at the same moment create one set of liabilities
    Given the site is in state F2
    When two manager sessions accrue period "Ekim 2026" in parallel
    Then exactly one request succeeds and the other is rejected as a duplicate
    And exactly 6 liabilities exist
    And the ledger invariants hold

  # Pending: the scheduler test does not assert this six-unit fixture’s exact late-fee totals at both dates.
  @SC-13-05-05 @J-12 @depth:2 @state:F2 @layer:backend @edge @role_manager @pending
  Scenario: The scheduler catches up months that were missed
    Given the site is in state F2 with the accrual scheduler enabled
    And the scheduler did not run for "Eylül 2026" and "Ekim 2026"
    When the scheduler runs on "2026-11-19"
    Then liabilities exist for "Eylül 2026", "Ekim 2026" and "Kasım 2026", each once
    And each liability keeps its period due date for FIFO but its effective due date is "2026-11-19"
    And the total outstanding is 29250.00 with late fee 0.00, because no charge existed before "2026-11-19"
    When the clock advances to "2026-11-29"
    Then the total late fee is 487.50, which is 15 x 25.00 plus 3 x 37.50 for "A-6"
    And running the scheduler again adds nothing

  # ------------------------------------------------------------- occupancy

  @SC-13-05-06 @J-12 @depth:1 @state:F5 @layer:backend @edge @role_manager @linked
  Scenario: Moving out with debt keeps the debt and the history
    Given the site is in state F5
    And the clock has advanced to "2026-12-01" before any December accrual
    When tenant "Deniz Arslan" moves out of unit "A-5" effective "2026-12-01"
    Then "Deniz Arslan" still owes the same 4500.00 principal plus the accrued fee as of the move-out date
    And the move-out settlement shows that debt with no payout
    And unit "A-5" is vacant and the debt stays a single liability with "Deniz Arslan" as primary debtor
    And owner "Can Öztürk" is shown as jointly liable for it (KMK m.22), without a second liability

  # Pending: the journey harness does not exercise the full move-out advance decision and second-approver flow.
  @SC-13-05-07 @J-12 @depth:1 @state:F5 @layer:backend @edge @role_manager @pending
  Scenario: Moving out with an advance requires a decision before the advance leaves
    Given the site is in state F5
    And tenant "Selin Demir" pays 3422.50 on "2026-11-19", clearing existing debt and leaving advance 300.00
    When "Selin Demir" moves out of unit "A-2"
    Then the manager must choose keep, pay out or transfer
    And a payout or transfer only happens after a second approver confirms

  # Pending: the current occupancy tests do not combine both refusals with proof that all financial and household rows stayed unchanged.
  @SC-13-05-08 @J-12 @depth:2 @state:F5 @layer:backend @edge @role_manager @pending
  Scenario: Moving out twice and moving in on an occupied unit are refused
    Given the site is in state F5
    When tenant "Deniz Arslan" moves out of unit "A-5"
    And the manager moves out unit "A-5" again
    Then the second move-out is refused because the unit is vacant
    When the manager moves tenant "Selin Demir" into unit "A-1" that is owner-occupied
    Then the request is refused with the allowed commands for the current state

  # Pending: the F6 journey fixture and exact 700.00/500.00/300.00 split-correction assertions are not available yet.
  @SC-13-05-09 @J-12 @depth:2 @state:F6 @layer:backend @edge @role_manager @pending
  Scenario: A move-out recorded after accrual re-splits the open liability
    Given the site is in state F6
    And the clock has advanced to "2026-11-26"
    When the manager records that tenant "Mert Kılıç" left "A-2" effective "2026-11-25"
    Then a split correction is requested and the liability amounts remain unchanged pending approval
    When a different manager approves the split correction
    Then November principal is 700.00 to "Selin Demir", 500.00 to "Mert Kılıç" and 300.00 to the owner
    And the owner's new 300.00 share is due on the approval date and Mert's reduced share keeps "2026-11-15"

  # ------------------------------------------------------------ people data

  # Pending: the Excel import GUI scenario does not yet run against the journey attempt fixture.
  @SC-13-05-10 @J-12 @depth:1 @state:F1 @layer:gui @edge @role_manager @pending
  Scenario: An Excel import with one bad row imports the good rows and reports the bad one
    Given the site is in state F1
    When the manager imports a workbook with 5 valid people and 1 row with an invalid national id
    Then 5 people are created
    And the result lists row 6 with the reason
    And no partial person exists for the bad row

  # Pending: the journey harness does not verify duplicate-person merging preserves every liability and payment relationship.
  @SC-13-05-11 @J-12 @depth:1 @state:F5 @layer:backend @edge @role_manager @pending
  Scenario: Merging two duplicate people keeps every liability and payment
    Given the site is in state F5
    And "Deniz Arslan" exists twice with different phone numbers, one of them owning a payment
    When the manager merges the duplicates
    Then one person remains and the liabilities and payments of both are attached to it
    And the ledger invariants hold

  # ----------------------------------------------------------- access control

  # Pending: the journey does not yet assert all three resident manager-action calls return 403 with no data changes.
  @SC-13-05-12 @J-12 @depth:1 @state:F5 @layer:backend @core @role_resident @pending
  Scenario: A resident cannot call manager actions
    Given the site is in state F5
    When tenant "Deniz Arslan" calls accrue, record-manual payment and move-out
    Then each call is answered 403
    And no data changes

  # Pending: a journey-level second-site fixture and bidirectional data-isolation assertions are not wired for this scenario.
  @SC-13-05-13 @J-12 @depth:1 @state:F5 @layer:backend @core @role_manager @pending
  Scenario: A manager of another site sees nothing of this site
    Given the site is in state F5
    And a second site, named in this attempt's manifest, has its own manager in state F5
    When the manager of the second site requests units, people, payments and liabilities of this site by id
    Then every response is 403 or 404 and contains no data of this site
    And invariant I10 holds in both directions

  # -------------------------------------------------------------------- time

  @SC-13-05-14 @J-12 @depth:2 @state:F5 @layer:backend @edge @role_manager @linked
  Scenario: The month boundary uses Istanbul time, not UTC
    Given the site is in state F5
    And the accrual scheduler is due to open December on the first local day and catch-up is disabled
    When it is ticked at "2026-11-30 23:30" Europe/Istanbul
    Then December has no accrued liability
    When it is ticked at "2026-12-01 00:30" Europe/Istanbul, still November 30 UTC
    Then it accrues December exactly once and leaves November principal unchanged

  @SC-13-05-15 @J-12 @depth:1 @state:F5 @layer:backend @edge @role_manager @linked
  Scenario: A late fee never makes a settled liability reopen
    Given the site is in state F5
    And unit "A-3" paid its "Eylül 2026" debt in full today
    When the clock moves forward 30 days
    Then unit "A-3" still owes 0.00 for "Eylül 2026"

  # ------------------------------------------------------------- persistence

  # Pending: historical F4-F7 fixture construction and restart checkpoints are not available to this journey suite.
  @SC-13-05-16 @J-12 @depth:1 @layer:backend @core @role_manager @pending
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

  # ------------------------------------------------- tenant departure (Q9)

  # Pending: GUI check-out screen is not automated; tracked by #273 (automate the @pending GUI journey scenarios). The backend side of the same flow is covered by SC-13-05-06.
  @SC-13-05-17 @J-12 @depth:2 @state:F5 @layer:gui @core @role_manager @pending
  Scenario: Check-out shows the tenant's debt and the owner can still be collected from
    Given the site is in state F5
    When the manager starts the check-out of tenant "Deniz Arslan" from "A-5" effective "2026-11-19"
    Then the check-out screen shows open debt 4797.50, split into principal 4500.00 and late fee 297.50
    And the manager confirms the check-out with that debt open
    When owner "Can Öztürk" pays 1675.00 toward the tenant's debt
    Then the "Eylül 2026" liability of "Deniz Arslan" is settled
    And the receipt names payer "Can Öztürk" and debtor "Deniz Arslan"
    And the owner's own statement shows the remaining jointly liable amount 3122.50
    And the owner does not see the tenant's own receipts or contact details
    And the ledger invariants hold

  @SC-13-05-18 @J-12 @depth:1 @state:F6 @layer:backend @core @role_manager @linked
  Scenario: A tenant who left without notice is moved out at the real date and the owner takes over
    Given the site is in state F6
    And the clock has advanced to "2026-12-05" after "Aralık 2026" was accrued to "Mert Kılıç"
    When the manager records that "Mert Kılıç" left "A-2" effective "2026-11-25" without check-out
    And a different manager approves the resulting split corrections
    Then the "Kasım 2026" principal is 700.00 to "Selin Demir", 500.00 to "Mert Kılıç" and 300.00 to owner "Ahmet Yılmaz"
    And the whole "Aralık 2026" principal of 1500.00 moves to owner "Ahmet Yılmaz"
    And the unpaid 500.00 of "Mert Kılıç" stays his, with "Ahmet Yılmaz" shown as jointly liable
    And the owner's new November and December shares are due on the approval date "2026-12-05"
    And the audit log records the late notice, both actors and the original shares
    And the ledger invariants hold
