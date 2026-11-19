@EPIC-10 @STORY-10-05
Feature: Contractor milestone disbursements and capital reserve
  Progress payments to contractors are paid from collected capital funds and
  can never exceed them.

  @SC-10-05-01 @GUI-10-05 @layer:gui @core @role_manager
  Scenario: Disbursement within collected cash updates the reserve
    Given capital project "Çatı Yalıtımı" with budget 42000.00 has installment 1 accrued
    And the owner of unit A14 has paid 4000.00 by FAST with description "AHMET YILMAZ DEMIRBAS 1. TAKSIT"
    And the site manager opens the capital projects segment
    When the manager records disbursement "1. Hakediş" of 1000.00 to "Yıldız Yalıtım Ltd."
    Then the disbursement dialog closes
    And the "disbursed" capital metric shows 1000.00
    And the "reserve" capital metric shows 3000.00
    And a single contractor disbursement of 1000.00 is stored

  @SC-10-05-02 @GUI-10-06 @layer:gui @core @role_manager
  Scenario: Disbursement larger than collected cash is refused
    Given the site manager opens the capital projects segment
    And the manager creates capital project "Asansör Revizyonu" with budget 500000.00 allocated by land share in 1 installments
    When the manager records disbursement "1. Hakediş" of 120000.00 to "Yıldız Asansör Ltd."
    Then no contractor disbursement is stored

  @SC-10-05-03 @layer:backend @linked
  Scenario: Disbursement carries its invoice number and warns when overdrawn
    Given capital project "Asansör Revizyonu" has collected 220000.00 and disbursed 50000.00
    When the site manager authorizes "2. Hakediş (Motor & Halat Montajı)" of 120000.00 to "Otis Asansör San. Tic."
    Then the disbursement is recorded with invoice number "ASN-2026-0044"
    And the project disbursed amount becomes 170000.00
    And the remaining capital fund cash balance displays 50000.00
    And a disbursement exceeding collected funds shows an overdrawn cash warning
