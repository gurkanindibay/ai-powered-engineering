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

  @SC-07-03-03 @layer:backend @linked @core @role_manager
  Scenario: A transfer to a unit with several open debtors waits for the manager
    Given unit "A Blok D:14" has open charges for both its owner and its tenant
    When the bank webhook sends a transfer to its virtual IBAN with no payer identity
    Then the transfer is stored as UNMATCHED with the reason "several open debtors"
    And no charge is reduced and no receipt is created
    When the manager assigns the item to the tenant and approves it
    Then only the tenant's charge is settled
    And approving the item again is refused

  @SC-07-03-04 @layer:backend @linked @edge @role_manager
  Scenario: A repeated delivery of a held transfer adds no queue item
    Given a transfer is held UNMATCHED for several open debtors
    When the bank webhook sends the same transaction id again
    Then the delivery is reported as a duplicate and the queue still holds one item
