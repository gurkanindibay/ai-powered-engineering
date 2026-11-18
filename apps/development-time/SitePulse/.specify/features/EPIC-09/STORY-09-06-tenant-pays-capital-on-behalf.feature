@EPIC-09 @STORY-09-06
Feature: Tenant paying capital dues on behalf of the landlord
  A manager explicitly confirms capital intent before a tenant payment settles the owner's capital dues and yields a rent-offset receipt.

  @SC-09-06-01 @GUI-09-05 @layer:gui @core @role_manager @linked
  Scenario: Manager confirms tenant payment for landlord fixture fee
    Given unit "A Blok D:14" has tenant "Canan Kaya" and owner "Selim Evsahibi"
    And the owner has an outstanding capital dues assessment of 3000.00 for "Asansör Revizyonu"
    When the tenant transfers 3000.00 with description "A Blok D:14 Asansör Demirbaş"
    Then the description suggests capital dues intent to the manager
    And the manager explicitly confirms that the payment is on behalf of the owner
    And 3000.00 is allocated to the owner's capital dues liability with status "PAID"
    And an official receipt states the tenant as payer and the owner as the debtor
    And the tenant's operational dues balance remains unchanged

  @SC-09-06-02 @GUI-09-07 @layer:gui @edge @role_manager @linked
  Scenario: Advance balance is transferred to the owner's capital dues in one click
    Given a unit has an advance balance and an accrued capital due of the owner
    When the advance is transferred to the capital dues from the payment tracking screen
    Then the capital due is settled from the advance with an audit log entry

  @SC-09-06-03 @layer:api @edge @linked @pending
  Scenario: A capital keyword alone does not redirect a tenant payment
    Given a tenant has an operational due and the owner has a capital due
    When the tenant payment description contains "Asansör Demirbaş"
    And the manager has not explicitly confirmed owner capital intent
    Then the payment is allocated only to the tenant operational due

  @SC-09-06-04 @layer:api @linked
  Scenario: Tenant webhook capital intent waits for manager review
    Given an incoming tenant transfer is matched to a unit
    When its description contains "Asansör Demirbaş"
    Then the transfer stays in the reconciliation review queue
    And no payment is allocated until a manager confirms its purpose
