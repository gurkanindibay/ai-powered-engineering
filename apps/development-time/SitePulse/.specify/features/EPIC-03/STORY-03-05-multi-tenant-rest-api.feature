@EPIC-03 @STORY-03-05
Feature: Multi-tenant REST API endpoints
  POST and GET /api/v1/saas/tenants register and list tenants.

  @SC-03-05-01 @layer:gui @linked
  Scenario: REST endpoint returns 201 Created on valid site onboarding
    When sending POST request to /api/v1/saas/tenants with valid payload
    Then the HTTP status code is 201 Created
    And response includes siteId, slug, siteAdminId, and temporaryPassword
