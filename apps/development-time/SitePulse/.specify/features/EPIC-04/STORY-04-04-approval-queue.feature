@EPIC-04 @STORY-04-04
Feature: Site manager real-time approval queue
  The manager sees pending applications with a counter badge.

  @SC-04-04-01 @GUI-04-02 @layer:gui @linked @smoke @role_manager
  Scenario: Site manager views pending applications
    Given 2 pending registration requests
    When the site manager views the dashboard
    Then the header badge displays "2 Bekliyor"
    And applicant cards display block, unit, contact info, and submission age
