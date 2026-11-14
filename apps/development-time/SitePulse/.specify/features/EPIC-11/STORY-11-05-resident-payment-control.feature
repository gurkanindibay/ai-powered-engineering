@EPIC-11 @STORY-11-05
Feature: Selecting debts, disputes and virman requests
  Selecting debts, disputes and virman requests.

  @SC-11-05-01 @layer:backend @linked
  Scenario: Tenant virman request settles the owner debt from the tenant advance
    Given a tenant with an advance and an owner debt
    When the tenant requests a virman and staff approve it
    Then the owner debt is settled from the tenant advance

  @SC-11-05-02 @layer:backend @linked
  Scenario: Resolving a dispute resumes dunning
    Given a disputed item with dunning paused
    When the dispute is resolved
    Then dunning resumes for the item

  @SC-11-05-03 @layer:flutter @linked
  Scenario: Selecting open items enables a designated card payment
    Given a resident statement with open items
    When the resident selects items
    Then the designated card payment is enabled for the selection

  @SC-11-05-04 @layer:flutter @linked
  Scenario: Designated amount is the sum of the selected items only
    Given open items with different amounts
    When some of them are selected
    Then the designated amount is the Decimal sum of the selected items only
