@EPIC-06 @STORY-06-03
Feature: Google ID token authentication and account linking
  Sign in with Google links an existing account by email or provisions a new one.

  @SC-06-03-01 @layer:gui @pending
  Scenario: Sign in with Google links existing account
    Given an existing user registered with email "ahmet.yilmaz@gmail.com"
    When they authenticate using a verified Google ID token with matching email
    Then the Google subject ID and avatar URL are linked to their account
    And an authenticated session is returned with auth_provider "GOOGLE"

  @SC-06-03-02 @GUI-06-11 @linked @layer:gui @edge
  Scenario: Google sign-in button starts the provider flow
    Given the login screen is shown
    When the user taps the Google sign-in button
    Then the browser is sent to the Google sign-in host
