@EPIC-10 @STORY-10-04
Feature: Inter-ledger virman from the advance balance
  Surplus operational advance of a unit can be offset against its capital dues.

  @SC-10-04-01 @GUI-10-09 @layer:gui @core @role_manager
  Scenario: Virman dialog offers the real advance balance of the unit
    Given the owner of unit A14 has paid 3500.00 by FAST with description "AHMET YILMAZ AVANS"
    When the site manager opens the virman dialog in dues management
    Then the virman unit list shows an advance of "₺3.500,00"

  @SC-10-04-02 @layer:gui @linked
  Scenario: Virman transfer clears a capital due from the advance balance
    Given unit 14 has an advance balance of 3500.00 and an accrued capital due of 2500.00
    When the site manager executes a virman transfer of 2500.00 to the capital project
    Then the advance balance of unit 14 decreases to 1000.00
    And the capital dues liability is fully paid
    And an inter-ledger audit record is stored in collection_transactions
