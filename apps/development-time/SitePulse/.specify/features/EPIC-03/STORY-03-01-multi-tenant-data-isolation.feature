@EPIC-03 @STORY-03-01
Feature: Multi-tenant architecture and data isolation
  Every entity is scoped by the mandatory site_id, so a site manager only sees
  the records of their own site.

  @SC-03-01-01 @GUI-03-04 @layer:gui @linked @core @role_manager
  Scenario: Query operations strictly scoped by tenant
    Given multiple registered sites in the database
    When a Site Manager queries units or finances
    Then queries only return records matching the manager's site_id
    And no cross-tenant data leakage is possible
