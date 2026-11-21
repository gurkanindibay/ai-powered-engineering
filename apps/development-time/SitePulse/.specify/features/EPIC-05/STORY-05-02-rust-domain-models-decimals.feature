@EPIC-05 @STORY-05-02
Feature: Rust domain models with high-precision decimals
  Domain models use rust_decimal with optimistic concurrency versioning. No existing
  Rust test exercises two concurrent balance updates, so the scenario is pending.

  # Pending: no test runs two concurrent payments on one unit, and the ledger serializes with row locks, not a balance version column, so the 'optimistic locking' wording needs revising before it is automated.
  @SC-05-02-01 @pending @layer:backend
  Scenario: Prevent concurrent balance modification race conditions
    Given two concurrent requests attempting to update the same unit balance
    When both commit simultaneously
    Then optimistic locking ensures sequence safety
    And no balance inconsistency or corruption occurs
