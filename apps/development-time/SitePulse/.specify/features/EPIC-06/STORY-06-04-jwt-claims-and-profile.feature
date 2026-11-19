@EPIC-06 @STORY-06-04
Feature: JWT claims, profile inspection and session handling
  Tokens carry the user's claims; the client exposes the profile, password change and logout.

  @SC-06-04-01 @pending @layer:backend @linked
  Scenario: User inspects their active profile and permissions
    Given an authenticated session for "Kat Maliki"
    When inspecting authentication claims
    Then response returns role "HOME_OWNER", unitId "d-14", and permission set including "UNIT_INVITE_CO_RESIDENT"

  @SC-06-04-02 @GUI-06-07 @linked @layer:gui @core @role_homeowner
  Scenario: Home owner changes the password from the profile and signs in again
    Given the home owner is signed in
    When the home owner changes the password from the profile sheet and logs out
    Then signing in with the new password succeeds
    And the old password is rejected

  @SC-06-04-03 @GUI-06-08 @linked @layer:gui @smoke @role_homeowner
  Scenario: Logout returns to the login screen
    Given the home owner is signed in
    When the home owner logs out
    Then the login screen is shown and no dashboard data remains

  @SC-06-04-04 @GUI-06-08 @linked @layer:gui @core @role_manager
  Scenario: Browser back after logout does not re-enter the session
    Given the manager is signed in
    When the manager logs out and navigates back
    Then the cockpit is not shown

  @SC-06-04-05 @GUI-06-10 @linked @layer:gui @core @role_manager
  Scenario: Manager switches between the cockpit and the own flat
    Given the manager cockpit is shown with 3 navigation tabs
    When the manager switches to the own flat and back
    Then the own flat shows 2 navigation tabs and the cockpit shows 3 again

  @SC-06-04-06 @GUI-06-08 @linked @layer:gui @core @role_homeowner
  Scenario: Cancelling the logout confirmation keeps the session
    Given the home owner is signed in
    When the home owner opens logout and cancels the confirmation
    Then the session is kept
