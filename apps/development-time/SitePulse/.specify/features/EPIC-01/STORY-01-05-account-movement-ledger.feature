@EPIC-01 @STORY-01-05
Feature: Account movement ledger and payment receipts
  Itemised ledger of accrued dues and statutory interest debits.

  @SC-01-05-01 @GUI-01-03 @layer:gui @linked @core @role_homeowner
  Scenario: View recent financial movements
    Given an authenticated resident with an overdue dues liability of 1400.00
    When viewing the account movements
    Then the monthly dues row shows 1400.00
    And the KMK delay penalty row is shown as a debit
