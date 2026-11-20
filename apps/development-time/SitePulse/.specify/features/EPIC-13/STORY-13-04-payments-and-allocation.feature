@EPIC-13 @STORY-13-04
Feature: Paying, allocation and advance across periods
  Payments arrive by manual entry or bank webhook and are allocated FIFO: late fee first, then
  principal, oldest liability first; any remainder is an advance. Uses states F4 and F5.

  Background:
    Given the scenario clock follows the fixture timeline in Europe/Istanbul
    And a SaaS admin has onboarded a site and manager unique to this scenario attempt
    And the manager has signed in with a permanent password

  @SC-13-04-01 @J-11 @depth:1 @state:F5 @layer:backend @smoke @core @role_manager @linked
  Scenario: A payment clears the oldest period first
    Given the site is in state F5
    When the manager records a manual payment of 2000.00 for unit "A-5"
    Then late fees are settled oldest first: 175.00 for "Eylül 2026", 100.00 for "Ekim 2026" and 22.50 for "Kasım 2026"
    And the remaining 1702.50 settles all 1500.00 of "Eylül 2026" principal and 202.50 of "Ekim 2026" principal
    And "Ekim 2026" has 1297.50 principal open, while "Kasım 2026" has 1500.00 principal open and no late fee
    And unit "A-5" owes 2797.50
    And the ledger invariants hold

  @SC-13-04-02 @J-11 @depth:1 @state:F5 @layer:backend @core @role_manager @linked
  Scenario: Paying exactly the whole debt leaves zero and no advance
    Given the site is in state F5
    When the manager records a manual payment of 4797.50 for unit "A-5"
    Then unit "A-5" owes 0.00 and holds an advance of 0.00
    And its 3 liabilities are settled

  @SC-13-04-03 @J-11 @depth:1 @state:F5 @layer:backend @edge @role_manager @linked
  Scenario: One kuruş short leaves one kuruş open
    Given the site is in state F5
    When the manager records a manual payment of 4797.49 for unit "A-5"
    Then unit "A-5" owes exactly 0.01
    And the "Kasım 2026" liability is the one still open

  @SC-13-04-04 @J-11 @depth:2 @state:F5 @layer:backend @core @role_manager @linked
  Scenario: An overpayment becomes an advance that offsets the next accrual
    Given the site is in state F5
    When the manager records a manual payment of 5000.00 for unit "A-5"
    Then unit "A-5" owes 0.00 and holds an advance of 202.50
    When the manager accrues period "Aralık 2026" due "2026-12-10"
    Then 202.50 of the "Aralık 2026" liability of 1500.00 is settled from the advance
    And 1297.50 remains open
    And the ledger invariants hold

  @SC-13-04-05 @J-11 @depth:1 @state:F5 @layer:backend @edge @role_manager @linked
  Scenario Outline: Invalid payment amounts are rejected without any side effect
    Given the site is in state F5
    When the manager records a manual payment of <amount> for unit "A-5"
    Then the request is rejected with "<reason>"
    And no new payment, receipt or allocation exists and every balance is unchanged

    Examples:
      | amount  | reason                     |
      | 0.00    | amount must be positive    |
      | -100.00 | amount must be positive    |
      | 10.005  | at most two decimal places |

  @SC-13-04-06 @J-11 @depth:1 @state:F5 @layer:backend @core @role_manager @linked
  Scenario: The bank webhook matches a transfer to the unit and allocates it
    Given the site is in state F5
    When the bank webhook sends 1675.00 with transaction id "TX-001" to the virtual IBAN of unit "A-3"
    Then unit "A-3" owes 0.00
    And the payment stream lists "TX-001" once, allocated to "Eylül 2026"

  # Pending: Webhook transaction idempotence test pending.
  @SC-13-04-07 @J-11 @depth:1 @state:F5 @layer:backend @edge @role_manager @pending
  Scenario: The same bank transaction sent twice is applied once
    Given the site is in state F5
    When the bank webhook sends 1675.00 with transaction id "TX-001" to the virtual IBAN of unit "A-3"
    And the bank webhook sends the same transaction "TX-001" again
    Then the payment stream lists "TX-001" once
    And the second delivery is acknowledged as already processed, not as an error the bank retries
    And unit "A-3" owes 0.00 and holds an advance of 0.00

  # Pending: Concurrent webhook transfers test pending.
  @SC-13-04-08 @J-11 @depth:1 @state:F5 @layer:backend @edge @role_manager @pending
  Scenario: Two transfers for one unit at the same moment are both applied
    Given the site is in state F5
    When two webhooks of 1000.00 with different transaction ids arrive for unit "A-5" in parallel
    Then unit "A-5" owes 2797.50
    And both payments are listed and no allocation is counted twice

  # Pending: Multi-site webhook isolation test pending.
  @SC-13-04-09 @J-11 @depth:1 @state:F5 @layer:backend @edge @role_manager @pending
  Scenario: A transfer matched to another site is applied only there
    Given the site is in state F5
    And another site exists with its own units and one 1500.00 current liability
    When the bank webhook sends 1500.00 to the virtual IBAN for that liability
    Then the other site's liability is settled and only its payment stream shows the transfer
    And no balance of the original site changes

  # Pending: Grace period boundary late fee test pending.
  @SC-13-04-10 @J-11 @depth:1 @layer:backend @edge @role_manager @pending
  Scenario Outline: The grace boundary decides whether a late fee is charged
    Given the site has a grace period of <grace> days and the clock is set to "<paid_on>"
    And a unit has a single 1500.00 liability due "2026-11-10" and nothing else
    When the manager records a manual payment of 1500.00 for that unit dated "<paid_on>"
    Then <fee> of the payment clears the accrued fee and <remaining> principal remains open

    # After grace the fee runs from the due date, not from the end of grace (SC-07-10-06).
    Examples:
      | grace | paid_on    | fee   | remaining |
      | 0     | 2026-11-10 | 0.00  | 0.00      |
      | 0     | 2026-11-11 | 2.50  | 2.50      |
      | 5     | 2026-11-10 | 0.00  | 0.00      |
      | 5     | 2026-11-15 | 0.00  | 0.00      |
      | 5     | 2026-11-16 | 15.00 | 15.00     |

  # Pending: Payment correction and advance transfer test pending.
  @SC-13-04-11 @J-11 @depth:1 @state:F2 @layer:backend @core @role_manager @pending
  Scenario: A correction after a partial payment moves the paid amount to the advance
    Given the site was built from F2 with only September accrued
    And the manager recorded a 600.00 manual payment for unit "A-5" on "2026-09-10"
    When the manager requests cancelling liability "Eylül 2026" of unit "A-5" and a second manager approves
    Then the liability is cancelled with nothing outstanding
    And exactly 600.00 is credited to the payer's advance at cancellation
    And the original receipt remains available with its original amount
    And the ledger invariants hold

  # Pending: Correction four-eyes approval enforcement test pending.
  @SC-13-04-12 @J-11 @depth:1 @state:F5 @layer:backend @edge @role_manager @pending
  Scenario: The requester of a correction cannot approve it
    Given the site is in state F5
    When the manager requests a credit note of 500.00 on a liability of unit "A-5"
    And the same manager tries to approve it
    Then the approval is refused
    And the liability is unchanged

  # Pending: Resident confirmed payment view updates pending.
  @SC-13-04-13 @J-11 @depth:1 @state:F5 @layer:gui @core @role_resident @pending
  Scenario: A resident's confirmed payment appears in their statement and the admin view
    Given the site is in state F5
    When a bank webhook confirms a transfer of 1675.00 for tenant "Deniz Arslan"
    And the resident and manager refresh their respective views
    Then her dashboard balance drops by 1675.00
    And the admin collection page total outstanding drops by 1675.00
    And a receipt exists for the payment
    And the ledger invariants hold

  # Pending: Payment reversal and penalty restoration test pending.
  @SC-13-04-14 @J-11 @depth:1 @state:F5 @layer:backend @core @role_manager @pending
  Scenario: A payment reversal restores the debt it settled and the fee it stopped
    Given the site is in state F5
    And the manager recorded a manual payment of 1675.00 for unit "A-3" on "2026-11-19"
    When a staff user reverses that payment with reason "bounced transfer"
    Then unit "A-3" owes 1675.00 again with its "Eylül 2026" liability open
    And the late fee keeps running from the original due date
    And the receipt is marked reversed and the reversal records the operator and the reason
    And a second reversal of the same payment is refused and changes nothing
    And the ledger invariants hold

  # Pending: Multi-debtor reconciliation queue assignment test pending.
  @SC-13-04-15 @J-11 @depth:2 @state:F6 @layer:backend @core @role_manager @pending
  # Backend coverage: backend/tests/bank_multi_debtor_tests.rs (SC-07-03-03)
  Scenario: A unit-level transfer on a unit with several debtors waits for the manager
    Given the site is in state F6
    And unit "A-2" has open shares for "Ahmet Yılmaz", "Selin Demir" and "Mert Kılıç"
    When the bank webhook sends 800.00 to the virtual IBAN of unit "A-2" with no payer identity
    Then the transfer is stored as UNMATCHED in the reconciliation queue with the reason "several open debtors"
    And no share of any debtor is reduced and no receipt exists
    When the manager assigns the item to "Mert Kılıç" and approves it
    Then the "Kasım 2026" share of "Mert Kılıç" is settled and the other shares are unchanged
    And the ledger invariants hold

  # Pending: Payment for unit with no debt becoming payer advance test pending.
  @SC-13-04-16 @J-11 @depth:1 @state:F5 @layer:backend @edge @role_manager @pending
  Scenario: A payment for a unit with no debt becomes the payer's advance
    Given the site is in state F5
    When the manager records a manual payment of 500.00 for unit "A-1"
    Then unit "A-1" owes 0.00 and "Ayşe Kaya" holds an advance of 500.00 on "A-1"
    And a receipt exists that shows the amount as an advance
