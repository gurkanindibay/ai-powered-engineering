@EPIC-05 @STORY-05-06
Feature: CMMI bidirectional requirements traceability validator
  rtm_validator.py checks that every requirement traces to tasks, sources and tests.
  Covered by harness/tests/test_harness.py (test_project_rtm_is_consistent), which the
  traceability linker does not read, so the scenario is pending.

  @SC-05-06-01 @layer:harness @linked
  Scenario: Validate bidirectional traceability
    When harness/rtm_validator.py runs
    Then every requirement in the traceability matrix has active task links, existing source files and test coverage
