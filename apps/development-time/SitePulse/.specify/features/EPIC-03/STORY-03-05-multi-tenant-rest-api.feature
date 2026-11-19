@EPIC-03 @STORY-03-05
Feature: Multi-tenant REST API endpoints
  POST and GET /api/v1/saas/sites register and list tenants.

  @SC-03-05-01 @layer:backend @linked
  Scenario: REST endpoint returns 201 Created on valid site onboarding
    When sending POST request to /api/v1/saas/sites with valid payload
    Then the HTTP status code is 201 Created
    And response includes site_id, slug, admin_user_id, and temporary_password
