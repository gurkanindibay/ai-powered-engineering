@EPIC-11 @STORY-11-10
Feature: Payment plans, waivers and write-offs
  Payment plans, waivers and write-offs.

  @SC-11-10-01 @layer:backend @linked
  Scenario: Waiver approved by a second person lowers what is owed and the ledger balances
    Given a waiver requested by one manager
    When a second person approves it
    Then what is owed drops and the ledger still balances

  @SC-11-10-02 @layer:backend @linked
  Scenario: Kept plan completes and waives the penalty, a late plan breaks
    Given a payment plan
    When instalments are paid on time or late
    Then a kept plan completes and waives the penalty and a late plan breaks
