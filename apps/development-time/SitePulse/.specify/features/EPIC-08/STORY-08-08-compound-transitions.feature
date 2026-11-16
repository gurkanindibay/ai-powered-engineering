@EPIC-08 @STORY-08-08
Feature: Compound transitions preserve exit settlement
  Replacing a tenant or taking the unit back is a move-out plus move-in in one transaction.

  @SC-08-08-01 @GUI-08-12 @layer:backend @linked @core @role_manager
  Scenario: Replacing a tenant settles the outgoing tenant
    Given Tenant "Zeynep Kaya" in Unit "B Blok D:12" has 1500.00 unpaid operational dues
    When the Site Manager replaces the tenant with "Mehmet Demir" effective 2026-11-01
    Then Zeynep Kaya's session is closed with end_date = 2026-11-01 and exit_balance = 1500.00
    And a new active TENANT session is opened for Mehmet Demir with start_date = 2026-11-01
    And Unit "B Blok D:12" status is TENANT_OCCUPIED

  @SC-08-08-02 @layer:backend @linked @core @role_manager
  Scenario: Owner takes the unit back from the tenant
    Given Unit "B Blok D:12" is TENANT_OCCUPIED with Tenant "Zeynep Kaya" and Owner "Ahmet Yılmaz"
    When the Site Manager executes "owner takes the unit back"
    Then Zeynep Kaya's session is closed with an exit balance
    And an active OWNER session is opened for Ahmet Yılmaz
    And the owner of the unit is still Ahmet Yılmaz

  @SC-08-08-03 @layer:backend @linked @edge @role_manager
  Scenario: A failed second step leaves nothing changed
    Given Unit "B Blok D:12" is TENANT_OCCUPIED with Tenant "Zeynep Kaya"
    When a tenant replacement fails while registering the incoming tenant
    Then Zeynep Kaya is still the active tenant and her session is still open
