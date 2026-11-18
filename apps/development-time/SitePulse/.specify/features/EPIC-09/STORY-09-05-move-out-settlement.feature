@EPIC-09 @STORY-09-05
Feature: Occupancy lifecycle financial settlement on move-out
  Moving out closes the tenant's billing session, freezes the balance and shifts
  future recurring dues to the property owner. Unpaid dues are recorded in the
  closed session's exit_balance. Exit-settlement requests are blocked until the
  departing resident's frozen dues have been paid, so funds are not paid or
  transferred while that debt remains open. Ledger changes wait for a different
  authorized approver.

  @SC-09-05-01 @layer:gui @core @role_manager @linked
  Scenario: Move-out freezes tenant balance and shifts recurring accrual to owner
    Given tenant "Zeynep Kaya" vacates "B Blok D:12" with 1400.00 unpaid dues
    When the move-out action is finalized in the property registry
    Then the tenant's sub-ledger is frozen with 1400.00 outstanding
    And subsequent monthly operational dues are automatically billed to the property owner
    And past payment receipts remain attributed to the tenant

  @SC-09-05-02 @layer:backend @pending @role_manager
  Scenario: Approver cannot approve their own advance settlement request
    Given a Site Manager created a pending advance payout request
    When the same Site Manager attempts to approve the request
    Then the approval is rejected and the advance balance is unchanged
    And the denied approval attempt is recorded in audit_events

  @SC-09-05-03 @layer:backend @pending @role_manager
  Scenario: Departing tenant's advance is paid out only after four-eyes approval
    Given a departing tenant has an advance balance of 800.00 for the unit
    When the manager requests payout of the advance as part of move-out settlement
    Then the request remains pending until a different authorized person approves it
    And approval records an outgoing payment and reduces the tenant's advance balance by 800.00

  @SC-09-05-05 @layer:backend @pending @role_manager
  Scenario: Departing tenant's advance transfers only after four-eyes approval
    Given a departing tenant has an advance balance of 800.00 for the unit
    When the manager requests transfer of the advance to the owner debtor
    Then the transfer remains pending until a different authorized person approves it
    And approval records an audited advance transfer without creating an outgoing payment

  @SC-09-05-06 @layer:backend @pending @role_manager
  Scenario: Frozen exit dues block advance settlement until the debt is paid
    Given the departing tenant has 300.00 in frozen exit dues and 800.00 in tenant advance
    When the manager requests an 800.00 payout or transfer
    Then the request is rejected while the 300.00 frozen exit debt remains unpaid
    And the 800.00 tenant advance remains unchanged
    When the 300.00 frozen exit debt is paid through the normal collection flow
    Then the manager may request a settlement of the tenant's remaining 800.00 advance

  @SC-09-05-04 @layer:backend @pending @role_manager
  Scenario: Retrying a timed-out settlement request does not create a duplicate
    Given a payout request was committed but its response was lost
    When the client retries with the same request key and identical details
    Then the existing request is returned
    And only one pending reservation exists for that request key
