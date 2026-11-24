@EPIC-10 @STORY-10-01
Feature: Capital project creation and budget allocation
  A site manager defines a capital project and the budget is apportioned to the
  units by land share or equally (KMK Art. 20), with no rounding drift.

  @SC-10-01-01 @GUI-10-02 @layer:gui @smoke @role_manager
  Scenario: Budget is split by land share without rounding drift
    Given the site manager opens the capital projects segment
    When the manager creates capital project "Asansör Revizyonu" with budget 500000.00 allocated by land share in 3 installments
    Then the project is stored as "ACTIVE" with budget 500000.00 and allocation "BY_LAND_SHARE"
    And the unit shares shown add up to exactly 500000.00
    And unit "14" is shown its land share proportion of 500000.00

  @SC-10-01-02 @GUI-10-03 @layer:gui @core @role_manager
  Scenario: Equal allocation gives every unit the same share
    Given the site manager opens the capital projects segment
    When the manager creates capital project "Kamera Sistemi" with budget 60000.00 allocated equally in 1 installments
    Then every unit is shown an equal share of 60000.00
    And the project is stored as "ACTIVE" with budget 60000.00 and allocation "EQUAL_PER_UNIT"

  @SC-10-01-03 @layer:api @role_manager
  Scenario: Installment accrual persists tenant-scoped liabilities
    Given a capital project has an unaccrued installment for a site
    When the site manager accrues that installment
    Then the installment is marked accrued
    And liabilities are created only for units in that site
