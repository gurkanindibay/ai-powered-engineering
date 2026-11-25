@EPIC-06 @STORY-06-05
Feature: Cross-platform Flutter login and registration experience
  The Flutter app offers email/password and Google sign-in and shows the active profile.

  @SC-06-05-01 @GUI-06-11 @linked @layer:gui @edge
  Scenario: Google sign-in option is offered on the login screen
    Given the user is on the SitePulse login screen
    When they tap the Google sign-in button
    Then the Google authentication flow starts

  @SC-06-05-02 @GUI-06-11 @linked @layer:gui
  Scenario: Google sign-in completes and the dashboard shows the Google profile
    Given the user is on the SitePulse login screen
    When they tap "Google ile Giriş Yap"
    Then the Google authentication flow completes
    And the app dashboard updates to show their Google profile picture and permissions

  @SC-06-05-03 @GUI-06-01 @linked @layer:gui @smoke @role_manager
  Scenario: Email and password sign-in opens the role dashboard
    Given the user is on the SitePulse login screen
    When they sign in with email and password
    Then the role's dashboard is shown

  @SC-06-05-04 @layer:gui @linked @smoke @role_manager
  Scenario: Sign-in role choices have accessible names
    Given the user is on the SitePulse login screen
    When the role choices are shown
    Then each choice exposes its visible label to assistive technology
