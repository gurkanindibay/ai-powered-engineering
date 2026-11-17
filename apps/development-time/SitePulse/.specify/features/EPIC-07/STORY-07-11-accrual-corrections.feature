@EPIC-07 @STORY-07-11
Feature: Accrual corrections with cancel, re-issue and credit note
  A wrong liability is corrected with an approved, audited entry; the original is never edited.

  @SC-07-11-01 @pending @core @role_manager
  Scenario: A cancelled liability moves its payment to the advance balance
    Given the owner of unit "A-14" owes 1400.00 for period "2026-10" and has paid 600.00
    When the manager requests a cancellation with reason "duplicate charge"
    And a second manager approves it
    Then the liability is CANCELLED and a reversing entry of 1400.00 is in the ledger
    And 600.00 is credited to the owner's advance balance
    And the receipt of the 600.00 payment is unchanged

  @SC-07-11-02 @pending @core @role_manager
  Scenario: A re-issue replaces the amount and links to the original
    Given the owner of unit "A-14" owes 1800.00 for period "2026-10" instead of 1400.00
    When the manager requests a re-issue for 1400.00 with reason "wrong house type"
    And a second manager approves it
    Then the original liability is CANCELLED
    And a new liability of 1400.00 for period "2026-10" refers to the original

  @SC-07-11-03 @pending @core @role_manager
  Scenario: A credit note reduces the amount and its late fee in proportion
    Given unit "A-14" owes 1400.00 due on "2026-10-15" with a late fee of 23.33
    When a credit note of 700.00 with reason "budget revision" is approved
    Then the liability amount is 700.00
    And the late fee is 11.67

  @SC-07-11-04 @pending @edge @role_manager
  Scenario: The requester cannot approve their own correction
    Given the manager requested a cancellation of a liability
    When the same manager tries to approve it
    Then the approval is rejected with status 403
    And the liability is unchanged

  @SC-07-11-05 @pending @core @role_homeowner
  Scenario: The resident statement shows the correction
    Given a credit note of 700.00 on period "2026-10" of unit "A-14" was approved
    When the resident of unit "A-14" opens the account statement
    Then the statement shows the original charge and the credit note with its reason
