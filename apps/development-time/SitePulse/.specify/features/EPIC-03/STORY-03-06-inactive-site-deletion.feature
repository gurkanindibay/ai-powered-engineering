@EPIC-03 @STORY-03-06
Feature: Deletion of inactive or action-free sites
  A site can be deleted only when it has no units, dues or registration requests.

  @SC-03-06-01 @GUI-03-06 @layer:gui @linked @core @role_saas
  Scenario: Delete site without any related actions
    Given a site has zero units, zero dues collection, and zero registration requests
    When SaaS Admin confirms deletion of the site
    Then the site is permanently removed from the system
    And the tenant portfolio is updated

  @SC-03-06-02 @GUI-03-07 @layer:gui @linked @core @role_saas
  Scenario: Invariant prevents deletion of active site with transactions
    Given a site has active units or dues records
    When SaaS Admin attempts to delete the site
    Then the deletion request is blocked
    And an explanatory invariant violation error is returned
