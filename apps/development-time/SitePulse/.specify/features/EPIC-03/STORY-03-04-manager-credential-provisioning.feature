@EPIC-03 @STORY-03-04
Feature: Automated site manager account creation and credential provisioning
  Onboarding issues a temporary SP-XXXX-YYYY password that must be changed on first login.

  @SC-03-04-01 @GUI-03-02 @layer:gui @linked @smoke @role_saas
  Scenario: Generate temporary password for newly registered Site Admin
    When a new site is registered with admin email "murat@palmiyesitesi.com"
    Then generate a 12-character temporary password in format "SP-XXXX-YYYY"
    And return response with mustChangePassword = true
    And display a modal with instant copy-to-clipboard functionality

  @SC-03-04-02 @GUI-03-03 @layer:gui @linked @core @role_manager
  Scenario: New manager is forced to change the temporary password
    Given a site manager signs in with the issued temporary password
    Then the forced password change screen is shown and the cockpit is not reachable

  @SC-03-04-03 @layer:gui @pending
  Scenario: SMS credential alert is dispatched to the manager's mobile number
    When a new site is registered with admin phone "0532 444 55 66"
    Then an SMS credential alert is triggered to that number

  @SC-03-04-04 @layer:backend @linked
  Scenario: Duplicate admin email is rejected
    Given a user with email "murat@palmiyesitesi.com" already exists
    When a new site is registered with admin email "murat@palmiyesitesi.com"
    Then the registration is rejected and no site is created
