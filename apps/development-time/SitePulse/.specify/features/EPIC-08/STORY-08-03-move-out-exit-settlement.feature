@EPIC-08 @STORY-08-03
Feature: Zero-data-loss move-out and exit settlement
  Move-out closes the occupancy session and preserves all history.

  @SC-08-03-01 @GUI-08-04 @layer:gui @linked @smoke @role_manager
  Scenario: Move-out preserves historical payment receipts and unsettled debt
    Given Tenant "Zeynep Kaya" in Unit "B Blok D:12" has 1500.00 unpaid operational dues
    When the Site Manager executes the move-out action on 2026-10-31
    Then the active occupancy record is closed with end_date = 2026-10-31, is_active = false, and exit_balance = 1500.00
    And Unit "B Blok D:12" status becomes VACANT with tenant_person_id = NULL
    And the 1500.00 historical liability remains attributed to Zeynep Kaya
    And zero records are deleted from dues_liabilities, collection_transactions, or persons
