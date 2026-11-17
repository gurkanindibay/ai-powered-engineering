@EPIC-09 @STORY-09-05
Feature: Occupancy lifecycle financial settlement on move-out
  Moving out closes the tenant's billing session, freezes the balance and shifts
  future recurring dues to the property owner. Current implementation records
  unpaid dues in the closed session's exit_balance; it does not settle or move
  any advance balance, which remains in the unit/debtor advance ledger.

  @SC-09-05-01 @layer:gui @core @role_manager @linked
  Scenario: Move-out freezes tenant balance and shifts recurring accrual to owner
    Given tenant "Zeynep Kaya" vacates "B Blok D:12" with 1400.00 unpaid dues
    When the move-out action is finalized in the property registry
    Then the tenant's sub-ledger is frozen with 1400.00 outstanding
    And subsequent monthly operational dues are automatically billed to the property owner
    And past payment receipts remain attributed to the tenant

  @SC-09-05-02 @layer:backend @pending @role_manager
  Scenario: Departing tenant's advance is paid out or transferred only after four-eyes approval
    Given a departing tenant has an advance balance of 800.00 for the unit
    When the manager requests payout of the advance as part of move-out settlement
    Then the request remains pending until a different authorized person approves it
    And approval records an outgoing payment and reduces the tenant's advance balance by 800.00
    When the manager requests transfer of the advance to another debtor instead
    Then the transfer remains pending until a different authorized person approves it
    And approval records an audited advance transfer without creating an outgoing payment
