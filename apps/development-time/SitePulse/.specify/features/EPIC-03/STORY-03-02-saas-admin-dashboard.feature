@EPIC-03 @STORY-03-02
Feature: SaaS super admin management dashboard
  The SaaS administrator sees the whole portfolio with cumulative statistics.

  @SC-03-02-01 @GUI-03-01 @layer:gui @linked @smoke @role_saas
  Scenario: SaaS Admin views portfolio overview
    Given a user with SAAS_ADMIN role
    When accessing the SaaS Super Yönetici dashboard
    Then display active site cards for every registered site

  @SC-03-02-02 @GUI-03-01 @layer:gui @linked @smoke @role_saas
  Scenario: Portfolio statistics agree with the site list
    Given a user with SAAS_ADMIN role
    When accessing the SaaS Super Yönetici dashboard
    Then the totals for sites, units and monthly dues equal the sum of the site list
