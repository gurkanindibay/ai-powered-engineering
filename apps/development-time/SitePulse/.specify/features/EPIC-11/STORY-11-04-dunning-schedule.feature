@EPIC-11 @STORY-11-04
Feature: Dunning schedule and lawful channels
  Dunning schedule and lawful channels.

  @SC-11-04-01 @layer:backend @linked
  Scenario: Each due dunning step is sent once and disputed items are paused
    Given an overdue debt and a disputed item
    When dunning runs twice
    Then the due step is sent once and the disputed item is paused

  @SC-11-04-02 @layer:backend @linked
  Scenario: SMS opt-out blocks reminders but not legal notices
    Given a resident who opted out of SMS
    When reminders and legal notices are sent
    Then reminders are blocked and legal notices go out

  @SC-11-04-03 @layer:backend @linked
  Scenario: Debt notices to a group channel are blocked and logged
    Given a debt notice targeting a group channel
    When the notice is sent
    Then it is blocked and the block is logged
