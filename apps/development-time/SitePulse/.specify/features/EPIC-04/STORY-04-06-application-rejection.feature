@EPIC-04 @STORY-04-06
Feature: Application rejection
  The manager rejects an unverified registration request.

  @SC-04-06-01 @GUI-04-04 @layer:gui @linked @core @role_manager
  Scenario: Reject unverified registration
    Given a pending application with unverified tenant claims
    When Site Manager clicks "Reddet"
    Then the application status transitions to "REJECTED"
    And the item is removed from the active approval queue
