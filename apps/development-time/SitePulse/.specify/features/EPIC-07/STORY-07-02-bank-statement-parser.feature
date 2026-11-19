@EPIC-07 @STORY-07-02
Feature: Zero-approval bank statement parser
  Managers upload Excel, CSV or MT940 statements; the parser matches transfers
  to units and proposes batch dues clearances.

  @SC-07-02-01 @GUI-07-03 @layer:gui @linked @smoke @role_manager
  Scenario: Site manager uploads a bank statement Excel file
    Given the manager uploads an Excel statement containing a transfer from "AHMET YILMAZ" for "A BLOK D:14" of 1400.00
    When the statement parsing engine processes the transaction rows
    Then the engine identifies unit "A Blok D:14" with 100% confidence
    And the exact outstanding dues balance is matched
    And the transaction is marked as pending approval in the reconciliation queue

  @SC-07-02-02 @GUI-07-04 @layer:gui @linked @core @role_manager
  Scenario: Approving a matched row clears the resident's balance
    Given a statement row is matched to unit "A Blok D:14"
    When the manager approves the match
    Then the dues of unit "A Blok D:14" are paid
    And the resident's hero balance shows 0.00

  @SC-07-02-03 @layer:gui @linked @core
  Scenario: MT940 statement transactions are extracted and matched to dues
    Given the manager uploads an MT940 statement with a transfer for unit "A Blok D:14"
    When the statement parsing engine processes the transactions
    Then the transactions are extracted and matched to the outstanding due

  @SC-07-02-04 @GUI-07-05 @layer:gui @linked @core @role_manager
  Scenario: An unmatched row is assigned to a unit by hand
    Given a statement row names no unit
    When the manager resolves the unmatched transaction and picks unit "A Blok D:14"
    Then the unmatched bank transactions banner count goes down

  @SC-07-02-05 @GUI-07-06 @layer:gui @linked @edge @role_manager
  Scenario: A stored payer-name alias auto-matches a re-uploaded row
    Given the manager adds a payer-name alias for unit "A Blok D:14"
    When the same statement is uploaded again
    Then the row is matched to unit "A Blok D:14" automatically
