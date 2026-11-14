@EPIC-01 @STORY-01-02
Feature: KMK statutory delay fee calculation engine
  A 5% monthly delay penalty, pro-rated daily, applies to overdue operational dues.

  @SC-01-02-01 @GUI-01-01 @layer:gui @linked @smoke @role_homeowner
  Scenario: Calculate 10-day overdue statutory delay penalty
    Given an unpaid operational dues liability of 1400.00 that is 10 days past due
    When the delay compensation calculator executes
    Then the calculated delay penalty is exactly 23.33
    And the total liability displayed is 1423.33
