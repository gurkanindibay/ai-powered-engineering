@EPIC-01 @STORY-01-03
Feature: Reactive resident dashboard state management
  The dashboard controller emits balance, overdue badge and announcements on launch.

  @SC-01-03-01 @GUI-01-01 @layer:gui @linked @smoke @role_homeowner
  Scenario: Emit reactive state on dashboard launch
    Given a logged-in resident of unit A14 with an overdue dues liability
    When the dashboard controller initializes
    Then it emits the backend total as the current balance

  @SC-01-03-02 @GUI-01-04 @layer:gui @linked @core @role_homeowner
  Scenario: Site announcement reaches the resident
    Given the site manager has published an announcement
    When the resident opens the site announcements
    Then the announcement title and body are shown
