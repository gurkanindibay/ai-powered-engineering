@EPIC-01 @STORY-01-01
Feature: High-precision domain money and dues value objects
  Monetary values keep kurus-level precision with no floating-point drift.

  @SC-01-01-01 @layer:gui @pending
  Scenario: Preserve kurus-level precision in dues calculation
    Given a resident dues balance of 1450.00 and statutory interest
    When calculations are performed
    Then all monetary fields maintain 2 decimal places with HALF_EVEN rounding
    And zero floating-point drift occurs across successive operations
