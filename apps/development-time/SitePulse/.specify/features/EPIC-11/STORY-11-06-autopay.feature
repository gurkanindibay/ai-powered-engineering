@EPIC-11 @STORY-11-06
Feature: Saved card and automatic payment
  Saved card and automatic payment.

  @SC-11-06-01 @layer:backend @linked
  Scenario: Autopay charges due items once through the ingestion path
    Given a saved card mandate and due items
    When autopay runs
    Then each due item is charged once through the ingestion path

  @SC-11-06-02 @layer:backend @linked
  Scenario: Declined card keeps the due open and an expired card suspends the mandate
    Given a declined card and an expired card
    When autopay runs
    Then the due stays open and is retried and the expired mandate is suspended
