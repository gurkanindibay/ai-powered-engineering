@EPIC-05 @STORY-05-05
Feature: Unified automated test runner
  One command runs the harness tests, task DAG gates, Rust tests and Flutter tests.
  The gate groups that CI runs partition the full run (harness/tests/test_run_tests_groups.py).

  @SC-05-05-01 @layer:harness @linked
  Scenario: Run all system verification tests in one command
    When an engineer or the CI pipeline runs scripts/run_tests.py
    Then harness tests, task DAG gates, Rust cargo tests and Flutter client tests execute
    And the exit code is 0 when all tests pass
