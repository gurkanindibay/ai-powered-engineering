@EPIC-11 @STORY-11-03
Feature: KMK 22 tenant claim cap and rent certificate
  KMK 22 tenant claim cap and rent certificate.

  @SC-11-03-01 @layer:backend @linked
  Scenario: Owner operational debts are claimable from the tenant up to the unpaid rent
    Given a tenant with a lease and an owner with operational debts
    When the claimable amount is computed
    Then it is capped at the unpaid rent

  @SC-11-03-02 @layer:backend @linked
  Scenario: Tenant payment of owner capital dues cites KMK 22 and issues a rent certificate
    Given a tenant who pays owner capital dues
    When the payment is ingested
    Then the receipt cites KMK 22 and a rent certificate is issued
