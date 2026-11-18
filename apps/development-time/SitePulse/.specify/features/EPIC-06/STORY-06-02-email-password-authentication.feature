@EPIC-06 @STORY-06-02
Feature: Email and password registration and authentication
  Users register with a validated password and sign in with it.

  @SC-06-02-01 @layer:backend @linked
  Scenario: User registers and authenticates with password
    Given a new user provides valid registration details with password "GucluSifre2026!"
    When registration is submitted
    Then user entity is created with hashed password and provider "LOCAL"
    And logging in with matching credentials issues a valid JWT access token

  @SC-06-02-02 @GUI-06-01 @linked @layer:gui @smoke @role_manager
  Scenario: Site manager signs in and reaches the cockpit
    Given the manager login form is shown
    When the manager submits valid credentials
    Then the manager cockpit is shown

  @SC-06-02-03 @GUI-06-02 @linked @layer:gui @smoke @role_homeowner
  Scenario: Home owner signs in and reaches the resident dashboard
    Given the home owner login form is shown
    When the home owner submits valid credentials
    Then the resident dashboard is shown

  @SC-06-02-04 @GUI-06-03 @linked @layer:gui @smoke @role_manager
  Scenario: Wrong password shows an error and stays on the login screen
    When the manager submits a wrong password
    Then the login error banner is shown
    And the login screen is still displayed

  @SC-06-02-05 @GUI-06-05 @linked @layer:gui @core @role_manager
  Scenario: Clearing the login cache empties the credential fields
    When the user clears the login cache
    Then the email and password fields are empty

  @SC-06-02-06 @GUI-06-04 @linked @layer:gui @edge @role_manager
  Scenario: Empty password is rejected without a request
    When the manager submits the form with an empty password
    Then a validation message is shown
    And no login request is sent
