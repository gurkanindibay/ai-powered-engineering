@EPIC-10 @STORY-10-02
Feature: Installment scheduling and accrual
  A capital budget is divided into installments; accruing one creates
  CAPITAL_DUES liabilities for property owners only.

  @SC-10-02-01 @GUI-10-04 @layer:gui @smoke @role_manager
  Scenario: Accruing an installment charges owners only
    Given the site manager opens the capital projects segment
    And the manager creates capital project "Çatı Yalıtımı" with budget 90000.00 allocated by land share in 3 installments
    When the manager accrues installment 1
    Then installment 1 is shown as accrued
    And one "CAPITAL_DUES" liability per unit is charged to "OWNER" totalling 30000.00
    And no capital liability is charged to any other debtor
    And installment 1 is stored as accrued
