@EPIC-09 @STORY-09-06
Feature: Tenant paying capital dues on behalf of the landlord
  A tenant transfer with a capital keyword settles the owner's capital dues and
  yields a rent-offset receipt.

  @SC-09-06-01 @GUI-09-05 @layer:gui @core @role_manager @linked
  Scenario: Tenant pays elevator fixture fee on behalf of landlord
    Given unit "A Blok D:14" has tenant "Canan Kaya" and owner "Selim Evsahibi"
    And the owner has an outstanding capital dues assessment of 3000.00 for "Asansör Revizyonu"
    When the tenant transfers 3000.00 with description "A Blok D:14 Asansör Demirbaş"
    Then the system identifies capital dues intent from the keyword
    And 3000.00 is allocated to the owner's capital dues liability with status "PAID"
    And an official receipt states the tenant as payer and the owner as the debtor
    And the tenant's operational dues balance remains unchanged

  @SC-09-06-02 @GUI-09-07 @layer:gui @edge @role_manager @linked
  Scenario: Advance balance is transferred to the owner's capital dues in one click
    Given a unit has an advance balance and an accrued capital due of the owner
    When the advance is transferred to the capital dues from the payment tracking screen
    Then the capital due is settled from the advance with an audit log entry
