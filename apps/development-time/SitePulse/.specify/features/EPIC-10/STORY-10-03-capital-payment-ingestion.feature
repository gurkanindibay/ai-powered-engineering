@EPIC-10 @STORY-10-03
Feature: Capital payment ingestion and rent-offset receipts
  Owners and tenants pay accrued capital installments; a tenant payment
  produces a TBK 314 rent-offset receipt.

  @SC-10-03-01 @GUI-10-07 @layer:gui @core @role_manager
  Scenario: Owner FAST payment raises the collected amount of the project
    Given capital project "Çatı Yalıtımı" with budget 42000.00 has installment 1 accrued
    And the owner of unit A14 has paid 4000.00 by FAST with description "AHMET YILMAZ DEMIRBAS 1. TAKSIT"
    When the site manager opens the capital projects segment
    Then the "collected" capital metric shows 4000.00
    And capital dues paid in the ledger total 4000.00

  @SC-10-03-02 @GUI-10-08 @layer:gui @linked
  Scenario: Tenant payment produces a TBK 314 rent-offset receipt
    Given unit 14 is occupied by a tenant and has an accrued capital due
    When the tenant pays the capital due
    Then the capital dues liability is marked "PAID"
    And the receipt names the owner as debtor and is tagged is_rent_offset_eligible = true
    And the receipt contains the statutory legal clause:
      """
      634 sayılı KMK Madde 20 & 22 uyarınca ortak demirbaş giderleri Kat Maliki sorumluluğundadır.
      Kiracı tarafından ödenen bu tutar TBK Madde 314 gereğince kira bedelinden mahsuba uygundur.
      """
