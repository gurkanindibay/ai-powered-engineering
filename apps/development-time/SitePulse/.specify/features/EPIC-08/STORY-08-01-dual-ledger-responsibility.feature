@EPIC-08 @STORY-08-01
Feature: Dual-ledger financial responsibility separation
  Operational dues are charged to the tenant, capital dues to the owner.

  @SC-08-01-01 @GUI-08-02 @layer:gui @linked @core @role_manager
  Scenario: Accrue monthly operational dues to tenant and capital project to owner
    Given Unit "A Blok D:4" is TENANT_OCCUPIED with Tenant "Selin Demir" and Owner "Ahmet Yılmaz"
    When the monthly operational dues of 1500.00 are accrued
    Then an OPERATIONAL_DUES liability is charged to debtor TENANT
    When a capital facade renovation assessment of 5000.00 is accrued
    Then a CAPITAL_DUES liability is charged to debtor OWNER
    And the tenant balance reflects 1500.00 and the owner balance reflects 5000.00
