@EPIC-05 @STORY-05-02
Feature: Rust domain models with high-precision decimals
  Domain models use rust_decimal. PostgreSQL uniqueness and transactions serialize
  competing writes for the same unit and period.

  @SC-05-02-01 @linked @layer:backend
  Scenario: Prevent concurrent balance modification race conditions
    Given two PostgreSQL accrual transactions for the same unit and period
    When both attempt to commit concurrently
    Then exactly one liability is committed
    And the conflicting transaction is a clean no-op with no duplicate balance
