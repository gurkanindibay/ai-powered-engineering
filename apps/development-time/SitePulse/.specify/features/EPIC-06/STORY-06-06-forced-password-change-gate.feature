@EPIC-06 @STORY-06-06
Feature: Forced password change gate before any operation
  An account flagged must_change_password is held at the password change screen until it sets a permanent password.

  @SC-06-06-01 @GUI-06-06 @GUI-03-03 @linked @layer:gui @smoke @role_saas
  Scenario: SaaS admin with a temporary password is held at the password change screen
    Given a SAAS_ADMIN account with must_change_password = true
    When the user signs in with the temporary password
    Then the password change screen is shown instead of the dashboard
    And no business data is requested from the server
    When the user sets a new valid password
    Then the SAAS_ADMIN home page is shown with the role's data
    And signing in again with the new password does not ask for a change

  @SC-06-06-02 @GUI-J-02 @linked @layer:gui @core @role_manager
  Scenario: Site manager with a temporary password is held at the password change screen
    Given a SITE_MANAGER account with must_change_password = true
    When the user signs in with the temporary password
    Then the password change screen is shown instead of the dashboard
    And no business data is requested from the server
    When the user sets a new valid password
    Then the SITE_MANAGER home page is shown with the role's data
    And signing in again with the new password does not ask for a change

  @SC-06-06-03 @GUI-J-03 @linked @layer:gui @core @role_homeowner
  Scenario: Home owner with a temporary password is held at the password change screen
    Given a HOME_OWNER account with must_change_password = true
    When the user signs in with the temporary password
    Then the password change screen is shown instead of the dashboard
    And no business data is requested from the server
    When the user sets a new valid password
    Then the HOME_OWNER home page is shown with the role's data
    And signing in again with the new password does not ask for a change

  @SC-06-06-04 @GUI-J-04 @linked @layer:gui @core @role_resident
  Scenario: Home resident with a temporary password is held at the password change screen
    Given a HOME_RESIDENT account with must_change_password = true
    When the user signs in with the temporary password
    Then the password change screen is shown instead of the dashboard
    And no business data is requested from the server
    When the user sets a new valid password
    Then the HOME_RESIDENT home page is shown with the role's data
    And signing in again with the new password does not ask for a change

  @SC-06-06-05 @GUI-J-05 @linked @layer:gui @core @role_auditor
  Scenario: Auditor with a temporary password is held at the password change screen
    Given a AUDITOR account with must_change_password = true
    When the user signs in with the temporary password
    Then the password change screen is shown instead of the dashboard
    And no business data is requested from the server
    When the user sets a new valid password
    Then the AUDITOR home page is shown with the role's data
    And signing in again with the new password does not ask for a change

  @SC-06-06-06 @layer:backend @linked @role_saas
  Scenario: Server blocks operations before the password is changed
    Given an authenticated session whose user must change the password
    When the client calls any business endpoint
    Then the server answers 403 with code "PASSWORD_CHANGE_REQUIRED"
    And the client shows the password change screen
