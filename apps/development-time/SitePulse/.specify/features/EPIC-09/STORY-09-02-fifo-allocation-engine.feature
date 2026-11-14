@EPIC-09 @STORY-09-02
Feature: Dual-ledger FIFO payment allocation and KMK interest settlement
  A payment settles the delay penalty first, then the oldest operational dues,
  then capital dues for an owner, and credits any surplus as advance balance.

  @SC-09-02-01 @GUI-09-02 @layer:gui @core @role_manager @linked
  Scenario: Settle delay penalty first, then oldest dues, then credit surplus as advance
    Given unit "A Blok D:14" has an overdue operational due of 1400.00 with 23.33 delay penalty
    When a payment of 2000.00 is received via the virtual IBAN
    Then 23.33 is allocated to clear the delay penalty
    And 1400.00 is allocated to settle the principal dues liability with status "PAID"
    And the surplus of 576.67 is credited to the unit's advance balance
    And the payment allocation audit record reflects the exact 3-tier distribution

  @SC-09-02-02 @layer:gui @core @edge @role_manager @pending
  Scenario: Owner payment settles capital dues after operational dues
    Given a property owner has an unpaid operational due and an unpaid capital due
    When the owner's payment covers the operational due and part of the capital due
    Then the operational due is paid first and the remainder is applied to the capital due
