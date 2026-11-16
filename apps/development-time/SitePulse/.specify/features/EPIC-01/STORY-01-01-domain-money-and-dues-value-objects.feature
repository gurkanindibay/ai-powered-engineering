@EPIC-01 @STORY-01-01
Feature: High-precision domain money and dues value objects
  Monetary values keep kurus-level precision with no floating-point drift.

  @SC-01-01-01 @layer:backend @linked
  Scenario: Preserve kurus-level precision in dues calculation
    Given a resident dues balance of 1450.00 and statutory interest
    When calculations are performed
    Then all monetary fields maintain 2 decimal places (KMK delay penalty segments use midpoint away from zero, SPEC-005)
    And zero floating-point drift occurs across successive operations
