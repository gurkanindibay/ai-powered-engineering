@EPIC-13 @STORY-13-09
Feature: Financial transitions that cross periods or ledgers
  Verify exact balances and movement identifiers after each transition. The existing
  EPIC-07, EPIC-08 and EPIC-09 stories define the individual commands.

  @SC-13-09-01 @J-16 @depth:1 @state:F5 @layer:backend @core @role_manager @pending
  Scenario: A designated payment can settle a newer liability ahead of FIFO
    Given the site is in state F5
    When the manager records a payment of 1522.50 for "A-5" designating "Kasım 2026"
    Then the payment settles November principal and late fee
    And September 1675.00 and October 1600.00 remain open
    And the ledger invariants hold

  @SC-13-09-02 @J-16 @depth:2 @layer:backend @core @role_manager @pending
  Scenario: A partial payment reduces the principal used for later fees
    Given a single 1500.00 liability was due on "2026-11-10" with no grace days
    When the manager records a payment of 515.00 on "2026-11-16"
    Then 15.00 clears the fee and 500.00 clears principal
    When the fee job runs on "2026-11-19" and is retried at the same instant
    Then outstanding principal is 1000.00 and outstanding fee is 5.00
    And the retry creates no second fee entry

  @SC-13-09-03 @J-16 @depth:1 @layer:backend @core @role_manager @pending
  Scenario: A backdated payment recalculates fees using its value date
    Given a 1500.00 liability due on "2026-11-10" has accrued fee 22.50 through "2026-11-19"
    When a 1500.00 payment with value date "2026-11-10" is recorded on "2026-11-19"
    Then principal and outstanding fee are both 0.00
    And the ledger shows a traceable 22.50 fee adjustment and one payment receipt

  @SC-13-09-04 @J-16 @depth:2 @state:F7 @layer:backend @core @role_manager @pending
  Scenario: A credit note adjusts live debt while the close snapshot stays fixed
    Given the site is in state F7 and the September close snapshot has been saved
    When a manager requests a 300.00 credit note for the September liability of "A-3"
    Then live principal remains 1500.00 pending approval
    When a second manager approves it
    Then live principal is 1200.00 and the September snapshot is unchanged
    And the original charge and the November credit note can be traced in the statement

  @SC-13-09-05 @J-16 @depth:2 @state:F7 @layer:backend @edge @role_manager @pending
  Scenario: A closed period reopens only after independent approval
    Given the site is in state F7
    When the manager requests reopening of September and attempts self-approval
    Then self-approval is rejected and the period remains CLOSED
    When a different manager approves the request
    Then the period is OPEN and the audit records both actors and the reason
    And the pre-existing September liabilities and payments are present exactly once

  @SC-13-09-06 @J-16 @depth:1 @state:F5 @layer:backend @edge @role_manager @pending
  Scenario: Concurrent deliveries of the same bank event are credited once
    Given the site is in state F5
    When two deliveries of the same bank transaction ID and amount 1675.00 race for "A-3"
    Then one payment and one receipt exist and allocations total 1675.00
    And "A-3" has zero debt and zero advance

  @SC-13-09-07 @J-16 @depth:1 @state:F5 @layer:backend @core @role_manager @pending
  Scenario: An unmatched statement item can be approved exactly once
    Given an imported 1675.00 bank statement item for the site has no match in state F5
    Then the reconciliation queue shows one unmatched item and "A-3" still owes 1675.00
    When the manager assigns the item to "A-3" and approves reconciliation
    And retries approval of that same item
    Then the item is settled, "A-3" owes 0.00, and one payment, receipt and allocation set exist

  @SC-13-09-08 @J-16 @depth:2 @state:F2 @layer:backend @core @role_manager @pending
  Scenario: Operational and capital balances stay separate for a tenant-occupied unit
    Given unit "A-2" has operational principal of 1500.00 for the tenant and capital principal of 1000.00 for the owner
    And both charges are current and have no fee or advance
    When the tenant makes an ordinary operational payment of 1500.00
    Then the tenant's operational debt is 0.00 and the owner's capital debt is 1000.00
    When the tenant explicitly pays 400.00 toward capital on behalf of the owner
    Then the owner's capital debt is 600.00 and the tenant's operational debt is still 0.00
    And the receipt identifies both the payer and the capital debtor

  @SC-13-09-09 @J-16 @depth:1 @layer:backend @edge @role_manager @pending
  Scenario Outline: The aging bucket changes at each day boundary
    Given a unit has one unpaid liability with principal 1500.00 and grace days 0
    When the admin aging report and the resident statement are read <days> local calendar days after the due date
    Then admin bucket "<admin_bucket>" contains principal 1500.00 and all other admin buckets are zero
    And statement bucket "<statement_bucket>" contains principal 1500.00 and all other statement buckets are zero
    And both show fee <fee> separately

    # The admin report ends at 60+; the resident statement splits 61-90 and 90+.
    Examples:
      | days | admin_bucket | statement_bucket | fee    |
      | 0    | current      | current          | 0.00   |
      | 1    | 1-30         | 1-30             | 2.50   |
      | 30   | 1-30         | 1-30             | 75.00  |
      | 31   | 31-60        | 31-60            | 77.50  |
      | 60   | 31-60        | 31-60            | 150.00 |
      | 61   | 60+          | 61-90            | 152.50 |
      | 90   | 60+          | 61-90            | 225.00 |
      | 91   | 60+          | 90+              | 227.50 |
