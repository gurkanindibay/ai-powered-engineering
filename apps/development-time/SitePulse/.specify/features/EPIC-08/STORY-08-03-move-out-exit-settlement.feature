@EPIC-08 @STORY-08-03
Feature: Zero-data-loss move-out and exit settlement
  Move-out closes the occupancy session and preserves all history. The manager
  can keep the advance or request an audited payout/transfer that requires a
  different authorized approver.

  @SC-08-03-01 @GUI-08-04 @layer:gui @linked @smoke @role_manager
  Scenario: Move-out preserves historical payment receipts and unsettled debt
    Given Tenant "Zeynep Kaya" in Unit "B Blok D:12" has 1500.00 unpaid operational dues
    When the Site Manager executes the move-out action on 2026-10-31
    Then the active occupancy record is closed with end_date = 2026-10-31, is_active = false, and exit_balance = 1500.00
    And Unit "B Blok D:12" status becomes VACANT with tenant_person_id = NULL
    And the 1500.00 historical liability remains attributed to Zeynep Kaya
    And zero records are deleted from dues_liabilities, collection_transactions, or persons

  @SC-08-03-02 @layer:gui @pending @role_manager
  Scenario: Move-out can keep the advance without changing the balance
    Given departing Tenant "Zeynep Kaya" has 800.00 in the tenant advance ledger
    When the Site Manager chooses to keep the advance during move-out
    Then the tenant advance remains unchanged

  @SC-08-03-03 @layer:gui @pending @role_manager
  Scenario: Move-out payout is debited only after four-eyes approval
    Given departing Tenant "Zeynep Kaya" has 800.00 in the tenant advance ledger
    When the Site Manager requests a 500.00 payout during move-out
    Then an outgoing-payment request is created for a different authorized person to approve
    And the tenant advance remains 800.00 while the payout is pending
    And the advance is debited only after that approval

  @SC-08-03-04 @layer:gui @pending @role_manager
  Scenario: Move-out transfer changes debtor only after four-eyes approval
    Given departing Tenant "Zeynep Kaya" has 800.00 in the tenant advance ledger
    When the Site Manager requests a 500.00 transfer to the owner advance during move-out
    Then the transfer request waits for a different authorized person to approve
    And approval debits 500.00 from tenant advance and credits 500.00 to owner advance
    And no outgoing payment is created
