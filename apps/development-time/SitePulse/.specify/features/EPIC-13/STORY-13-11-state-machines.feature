@EPIC-13 @STORY-13-11
Feature: Every status of the billing state machines is reached and left correctly
  The other files reach most statuses as a side effect. This file names every value of
  `DebtStatus`, `DuesPeriodStatus` and `ReconciliationStatus`, plus every unit occupancy state.
  It checks how each one is entered, what is allowed in it, and that a refused command
  changes nothing. Status names are the API values.

  Background:
    Given the scenario clock follows the fixture timeline in Europe/Istanbul
    And a SaaS admin has onboarded a site and manager unique to this scenario attempt
    And the manager has signed in with a permanent password

  # ------------------------------------------------------------- liability

  # Pending: the F4/F5 historical fixture and controllable fixture-date timeline are not available in the journey harness.
  @SC-13-11-01 @J-18 @depth:1 @layer:backend @core @role_manager @pending
  Scenario Outline: A liability moves through PENDING, OVERDUE, PAID and CANCELLED
    Given a unit has a single 1500.00 liability due "2026-11-10" with grace days <grace>
    When <event>
    Then the liability status is <status> and its outstanding total is <outstanding>

    Examples:
      | grace | event                                                         | status    | outstanding |
      | 0     | the liability is read on "2026-11-09"                         | PENDING   | 1500.00     |
      | 0     | the liability is read on "2026-11-10"                         | PENDING   | 1500.00     |
      | 0     | the liability is read on "2026-11-11"                         | OVERDUE   | 1502.50     |
      | 5     | the liability is read on "2026-11-15"                         | PENDING   | 1500.00     |
      | 5     | the liability is read on "2026-11-16"                         | OVERDUE   | 1515.00     |
      | 0     | 500.00 is paid on "2026-11-10" and it is read on "2026-11-10" | PENDING   | 1000.00     |
      | 0     | 1500.00 is paid on "2026-11-10"                               | PAID      | 0.00        |
      | 0     | 1502.50 is paid on "2026-11-11"                               | PAID      | 0.00        |
      | 0     | an approved cancellation takes effect on "2026-11-12"         | CANCELLED | 0.00        |

  # Pending: the F5 fixture and end-to-end payment/correction refusal checks with unchanged ledger rows are not available.
  @SC-13-11-02 @J-18 @depth:1 @state:F5 @layer:backend @edge @role_manager @pending
  Scenario Outline: A settled or cancelled liability cannot be paid or corrected again
    Given the site is in state F5
    And the "<period>" liability of unit "<unit>" is <status>, after an approved cancellation where the status is CANCELLED
    When the manager <command> that liability
    Then the command is refused with a reason naming status <status>
    And no payment, allocation, advance or correction request is created

    Examples:
      | unit | period     | status    | command                              |
      | A-1  | Eylül 2026 | PAID      | records a 100.00 payment designating |
      | A-1  | Eylül 2026 | PAID      | requests a 100.00 credit note on     |
      | A-5  | Eylül 2026 | CANCELLED | records a 100.00 payment designating |
      | A-5  | Eylül 2026 | CANCELLED | requests cancellation of             |

  # Pending: the journey harness has no fixed-date payment-reversal flow that verifies the ordered liability status history.
  @SC-13-11-03 @J-18 @depth:1 @state:F5 @layer:backend @core @role_manager @pending
  Scenario: A reversal moves a PAID liability back to OVERDUE
    Given the site is in state F5
    And unit "A-3" paid its "Eylül 2026" liability in full on "2026-11-19"
    When that payment is reversed on "2026-11-19"
    Then the "Eylül 2026" liability of "A-3" is OVERDUE with outstanding 1675.00
    And the status history lists OVERDUE, PAID and OVERDUE with the reversal reference

  # ---------------------------------------------------------------- period

  # Pending: the backend journey does not yet exercise DRAFT, OPEN and CLOSED through the complete command matrix with audit-state checks.
  @SC-13-11-04 @J-18 @depth:1 @state:F2 @layer:backend @core @role_manager @pending
  Scenario Outline: Each period status allows only its own commands
    Given the site is in state F2
    And period "Ekim 2026" is <status>
    When the manager tries to <command> period "Ekim 2026"
    Then the result is <result>
    And on refusal the period, its liabilities and the audit log are unchanged

    Examples:
      | status | command      | result                                  |
      | DRAFT  | accrue       | accepted, status OPEN, 6 liabilities    |
      | DRAFT  | close        | refused                                 |
      | OPEN   | accrue again | refused as a duplicate                  |
      | OPEN   | close        | accepted, status CLOSED with a snapshot |
      | CLOSED | accrue       | refused because the period is closed    |
      | CLOSED | close        | refused                                 |
      | CLOSED | reopen       | pending until a second manager approves |

  # Pending: the periods GUI has no automated status/action matrix scenario.
  @SC-13-11-05 @J-18 @depth:1 @state:F2 @layer:gui @core @role_manager @pending
  Scenario: The periods screen shows each status with only its allowed actions
    Given the site is in state F2
    And periods "Eylül 2026" CLOSED, "Ekim 2026" OPEN and "Kasım 2026" DRAFT exist
    When the manager opens the periods page
    Then each period shows its status label
    And each row offers only the actions SC-13-11-04 accepts for that status

  # -------------------------------------------------------- reconciliation

  # Pending: the F5 fixture and complete bank import/approve/reject/duplicate flow with payment and receipt counts are not wired to journeys.
  @SC-13-11-06 @J-18 @depth:1 @state:F5 @layer:backend @core @role_manager @pending
  Scenario Outline: A bank statement item reaches each reconciliation status
    Given the site is in state F5
    When a bank statement item of 1675.00 is imported <input>
    Then the item status is <status>
    And the payment and receipt count for unit "A-3" is <payments>

    Examples:
      | input                                                      | status            | payments |
      | to the virtual IBAN of "A-3"                               | PENDING_APPROVAL  | 0        |
      | to the virtual IBAN of "A-3" and the manager approves it   | APPROVED          | 1        |
      | to the virtual IBAN of "A-3" and the manager rejects it    | REJECTED          | 0        |
      | to an unknown virtual IBAN                                 | UNMATCHED         | 0        |
      | twice with the same bank reference, the first one approved | ALREADY_PROCESSED | 1        |

  # Pending: the GUI/API journey does not yet verify that approving a rejected item and rejecting an approved item are refused without changing counts.
  @SC-13-11-07 @J-18 @depth:1 @state:F5 @layer:backend @edge @role_manager @pending
  Scenario: A rejected or approved statement item cannot change status again
    Given the site is in state F5
    And one statement item for "A-3" is APPROVED and another is REJECTED
    When the manager approves the REJECTED item and rejects the APPROVED item
    Then both commands are refused and both statuses are unchanged
    And "A-3" has exactly one payment

  # ------------------------------------------------------------- occupancy

  # Pending: the API command-read matrix and unchanged occupancy, ownership, household and financial rows are not asserted together.
  @SC-13-11-08 @J-18 @depth:2 @state:F5 @layer:backend @core @role_manager @pending
  Scenario Outline: Each unit occupancy state offers its own commands and refuses the rest
    Given the site is in state F5
    When the manager reads the allowed commands of unit "<unit>"
    Then they match the EPIC-12 command matrix for state "<state>"
    When the manager sends the command "<refused>" to unit "<unit>"
    Then it is refused with the allowed commands for state "<state>"
    And no occupancy, ownership, household or financial row changes

    Examples:
      | unit | state           | refused         |
      | A-7  | no owner        | move in tenant  |
      | A-3  | owned, vacant   | move out tenant |
      | A-1  | owner-occupied  | move in tenant  |
      | A-2  | tenant-occupied | move in owner   |
