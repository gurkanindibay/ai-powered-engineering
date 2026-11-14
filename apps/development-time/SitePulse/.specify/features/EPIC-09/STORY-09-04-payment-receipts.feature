@EPIC-09 @STORY-09-04
Feature: Official digital payment receipt and voucher export
  Every settled payment issues a sequentially numbered receipt that the
  resident can view and download.

  @SC-09-04-01 @GUI-09-04 @layer:gui @core @role_homeowner @linked
  Scenario: Issue sequential payment receipt upon settlement
    Given a successful dues payment of 1423.33 for "A Blok D:14"
    When the payment is recorded in the collection ledger
    Then a receipt record is created with a "TAH-2026-" sequence code
    And the resident can view and download the official receipt in fullscreen view
    And the receipt includes the site tax ID and itemized dues breakdown

  @SC-09-04-02 @GUI-09-04 @layer:gui @core @role_manager @linked
  Scenario: Manager downloads the receipt PDF and reverses the receipt
    Given a settled payment with an issued receipt
    When the site manager downloads the receipt PDF and reverses the receipt
    Then the PDF is delivered and the receipt is marked as reversed

  @SC-09-04-03 @GUI-09-02 @layer:gui @core @role_manager @linked
  Scenario: Receipt shows the penalty, principal and advance split
    Given an overdue payment has been allocated with a penalty, principal and advance part
    When the site manager opens the receipt
    Then the receipt number and the exact allocation split are shown

  @SC-09-04-04 @GUI-01-03 @layer:gui @core @role_homeowner @linked
  Scenario: Card payment on the provider page issues a receipt
    Given a resident has an open dues item
    When the resident pays by card on the provider page
    Then a receipt is issued for the payment
