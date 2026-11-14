@EPIC-07 @STORY-07-03
Feature: Real-time bank webhook and payment notification listener
  Bank transfer notifications settle dues instantly, idempotently.

  @SC-07-03-01 @GUI-07-08 @layer:gui @linked @core @role_homeowner
  Scenario: Real-time incoming transfer clears dues once
    Given a valid incoming webhook payload to the virtual IBAN of unit "A Blok D:14"
    When the webhook controller processes the event
    Then the dues of the unit are paid and an official sequential receipt is issued
    And a duplicate request is reported as duplicate without double-crediting

  @SC-07-03-02 @layer:gui @linked @core
  Scenario: A statement row containing the virtual IBAN matches the flat with full confidence
    Given a statement transaction that contains the virtual IBAN of unit "A Blok D:14"
    When the reconciliation engine matches it
    Then the flat is matched with 100% confidence
