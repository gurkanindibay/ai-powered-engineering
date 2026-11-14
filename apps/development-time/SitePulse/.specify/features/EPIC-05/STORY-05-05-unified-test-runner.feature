@EPIC-05 @STORY-05-05
Feature: Unified automated test runner
  One command runs the harness tests, task DAG gates, Rust tests and Flutter tests.
  Running it is itself the verification, so it is not a scenario-level test.

  @SC-05-05-01 @pending
  Scenario: Run all system verification tests in one command
    When an engineer or the CI pipeline runs scripts/run-tests.sh
    Then harness tests, task DAG gates, Rust cargo tests and Flutter client tests execute
    And the exit code is 0 when all tests pass
