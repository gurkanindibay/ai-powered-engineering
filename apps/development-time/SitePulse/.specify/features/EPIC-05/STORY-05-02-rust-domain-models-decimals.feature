@EPIC-05 @STORY-05-02
Feature: Rust domain models with high-precision decimals
  Domain models use rust_decimal with optimistic concurrency versioning. No existing
  Rust test exercises two concurrent balance updates, so the scenario is pending.

  @SC-05-02-01 @layer:backend @linked
  Scenario: Prevent concurrent balance modification race conditions
    Given two concurrent requests attempting to update the same unit balance
    When both commit simultaneously
    Then optimistic locking ensures sequence safety
    And no balance inconsistency or corruption occurs
