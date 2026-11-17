@EPIC-02 @STORY-02-01
Feature: Complex-wide dues collection tracking and progress metrics
  The management dashboard shows the accrued total, the collected amount and
  the collection percentage badge for the complex.

  @SC-02-01-01 @GUI-02-01 @layer:gui @linked @smoke @role_manager
  Scenario: Cockpit shows the accrued total before any payment
    Given dues of "1400.00" are accrued for every unit
    When the Site Manager opens the management dashboard
    Then the collected amount is "0.00" and the badge starts with "%0"

  @SC-02-01-02 @GUI-02-01 @layer:gui @linked @core @role_manager
  Scenario: Cockpit counts a payment as collected
    Given dues of "1400.00" are accrued for every unit
    And one unit paid its dues in full
    When the Site Manager opens the management dashboard
    Then the collected amount, the expected amount and the percentage badge equal the ledger totals

  @SC-02-01-03 @GUI-02-01 @layer:gui @linked @core @role_manager
  Scenario: Cockpit amounts keep kurus
    Given dues of "1400.55" are accrued for every unit
    When the Site Manager opens the management dashboard
    Then the expected amount is "2801.10"

  @SC-02-01-04 @GUI-02-08 @layer:gui @linked @core @role_manager
  Scenario: House type tariff is saved and a negative amount is rejected
    Given the Site Manager opens the house types modal
    When the 2+1 tariff is edited
    Then a valid amount is saved and a negative amount is rejected

  @SC-02-01-05 @GUI-02-08 @layer:gui @linked @core @role_manager
  Scenario: House type tariff rejects more than two decimals
    Given the Site Manager opens the house types modal
    When the 2+1 tariff is edited with more than two decimals
    Then a validation error is shown

  @SC-02-01-06 @GUI-02-01 @layer:gui @linked @core @role_manager
  Scenario: Display complex collection progress with the unit status breakdown
    Given a complex with 24 units and total monthly dues of "120000.00"
    And 18 units paid and 6 units are overdue
    When the Site Manager opens the management dashboard
    Then the cockpit shows "96000.00" collected out of "120000.00" with the "%80 Tahsil Edildi" badge
    And the unit breakdown shows 24 total, 18 paid, 6 overdue and "24000.00" in remaining debt
