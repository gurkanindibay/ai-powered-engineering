@EPIC-03 @STORY-03-07
Feature: Temporary password renewal and recovery for site managers
  The SaaS admin reissues a temporary password for a manager who lost theirs.

  @SC-03-07-01 @GUI-03-08 @layer:gui @linked @core @role_saas
  Scenario: SaaS Admin renews temporary password for a site manager
    Given a registered site with a site manager
    When SaaS Admin triggers "Şifre Yenile" for the site
    Then a new cryptographically secure temporary password (pattern: SP-[A-Z0-9]{4}-PASS) is generated
    And the site admin record is updated with mustChangePassword = true
    And the credentials dialog is presented to the SaaS Admin for delivery to the site manager

  @SC-03-07-02 @layer:gui @linked
  Scenario: Password renewal fails for non-existent site
    When SaaS Admin requests password renewal for an invalid site_id
    Then the request fails with 404 Not Found
