@EPIC-05 @STORY-05-03
Feature: Rust Axum REST API handlers and endpoints
  The resident dashboard endpoint returns real-time calculated dues. The penalty
  arithmetic is covered at the service level in backend/tests/integration_tests.rs,
  but no test asserts these figures through the HTTP endpoint, so it stays pending.

  @SC-05-03-01 @pending
  Scenario: REST endpoint provides real-time calculated dues
    When the client sends GET to the resident dashboard endpoint for unit "d-14"
    Then the response is 200 OK with totalDue 1423.33 and penalty 23.33
