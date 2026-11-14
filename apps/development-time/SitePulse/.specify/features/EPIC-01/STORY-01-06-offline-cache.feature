@EPIC-01 @STORY-01-06
Feature: Offline cache and synchronization layer
  The dashboard degrades to the cached statement when offline.

  @SC-01-06-01 @GUI-01-05 @layer:gui @linked @edge @role_homeowner
  Scenario: Display cached dues when network is offline
    Given the resident has loaded the dashboard
    And the device is disconnected
    When the dashboard state is refreshed
    Then the offline banner is shown and the last balance is kept
