@EPIC-09 @STORY-09-05
Feature: Occupancy lifecycle financial settlement on move-out
  Moving out closes the tenant's billing session, freezes the balance and shifts
  future recurring dues to the property owner.

  @SC-09-05-01 @layer:gui @core @role_manager @pending
  Scenario: Move-out freezes tenant balance and shifts recurring accrual to owner
    Given tenant "Zeynep Kaya" vacates "B Blok D:12" with 1400.00 unpaid dues
    When the move-out action is finalized in the property registry
    Then the tenant's sub-ledger is frozen with 1400.00 outstanding
    And subsequent monthly operational dues are automatically billed to the property owner
    And past payment receipts remain attributed to the tenant
