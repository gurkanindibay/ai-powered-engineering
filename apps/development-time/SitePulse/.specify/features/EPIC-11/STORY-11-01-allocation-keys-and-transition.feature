@EPIC-11 @STORY-11-01
Feature: Allocation keys and the 90-day transition
  Allocation keys and the 90-day transition.

  @SC-11-01-01 @layer:backend @linked
  Scenario: Budget line split by house type or meter weights
    Given a budget line allocated by house type and meter keys
    When the budget is approved and dues are generated
    Then each unit share follows the configured weights and the shares add up to the line total

  @SC-11-01-02 @layer:backend @linked
  Scenario: Site in transition accrues the tariff and reports it without basis
    Given a site that requires a budget but is still within the 90-day transition
    When dues are accrued from the tariff
    Then the accrual is reported as without a budget basis
