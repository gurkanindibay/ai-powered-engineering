@EPIC-10 @STORY-10-06
Feature: Resident view separates operational and capital dues
  Residents see capital projects apart from monthly dues, and who is legally
  responsible for them.

  @SC-10-06-01 @GUI-10-10 @layer:gui @core @role_homeowner
  Scenario: Owner dashboard shows capital dues separately
    Given capital project "Çatı Yalıtımı" with budget 42000.00 has installment 1 accrued
    And the owner of unit A14 has paid 4000.00 by FAST with description "AHMET YILMAZ DEMIRBAS 1. TAKSIT"
    When the home owner opens the resident dashboard
    Then the dashboard balance is above 0.00
    And the capital balance card is shown

  @SC-10-06-02 @GUI-10-11 @layer:gui @core @role_homeowner
  Scenario: Capital project is marked as the responsibility of the owner
    When the home owner signs in
    Then the owner responsibility capital badge is shown

  @SC-10-06-03 @layer:flutter @linked
  Scenario: Owner opens the project detail from the capital card
    Given property owner "Ahmet Yılmaz" has operational dues of 1500.00 and a capital installment of 3000.00
    When the owner selects "Detay" on the capital balance card
    Then the project breakdown, contractor info and installment schedule are shown

  @SC-10-06-04 @layer:flutter @linked
  Scenario: Tenant reads the statutory protection guidance
    Given tenant "Canan Can" signs in to a unit with an active capital project
    When the tenant views the dues breakdown
    Then the capital project is listed with badge "Kat Maliki Sorumluluğunda"
    And a banner states "Demirbaş giderleri yasal olarak ev sahibinize aittir. Ödemeniz halinde kiradan düşebilirsiniz."
