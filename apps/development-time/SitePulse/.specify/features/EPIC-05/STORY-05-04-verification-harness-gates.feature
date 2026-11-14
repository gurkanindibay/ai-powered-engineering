@EPIC-05 @STORY-05-04
Feature: Closed-loop verification harness and gate enforcement
  The maker-checker harness rejects financial floating-point leaks. Python harness
  tests (harness/tests/test_harness.py) exercise the loop, but the traceability linker
  does not read harness tests, so the scenario is pending.

  @SC-05-04-01 @pending
  Scenario: Verification gate rejects floating-point rounding leaks
    Given generated source code introducing float or double in financial packages
    When the FinancialIntegrityGate executes
    Then the verification gate fails and halts task promotion
    And actionable diagnostic feedback is returned to the maker agent
