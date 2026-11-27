@EPIC-09 @STORY-09-01
Feature: Unified payment inflow stream and multi-channel ledger
  The site manager sees the payments of every channel in one stream and filters it
  by period, unit, debtor type, channel and settlement status.

  @SC-09-01-01 @GUI-09-01 @layer:gui @smoke @role_manager @linked
  Scenario: Filter payment stream by tenant payments for current month
    Given the site manager opens the "Ödeme Takibi" payment tracking module
    When filtering by period "Ekim 2026" and debtor type "TENANT"
    Then the system lists all verified tenant payments
    And the total collected amount, collection rate and channel distribution breakdown are displayed
    And clicking any payment opens the detailed allocation breakdown dialog

  @SC-09-01-02 @GUI-09-06 @layer:gui @edge @role_manager @linked
  Scenario: Debt aging buckets total the overdue sum
    Given the unit has overdue dues in several delay ranges
    When the site manager opens the debt aging report
    Then the aging buckets add up to the total overdue sum

  @SC-09-01-03 @GUI-09-08 @layer:gui @edge @role_manager @linked
  Scenario: Opening payment tracking requests the payment stream once
    Given the site manager is in the dues management view
    When the site manager opens the payment tracking module
    Then exactly one payment stream request is sent
    And the stream shows the data of that request, not a superseded response
