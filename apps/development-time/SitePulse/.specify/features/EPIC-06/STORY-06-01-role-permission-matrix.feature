@EPIC-06 @STORY-06-01
Feature: Multi-role scoped permission matrix
  Roles map to capabilities, with site-wide and unit-level isolation enforced by the server.

  @SC-06-01-01 @GUI-06-09 @linked @layer:gui @core @role_homeowner
  Scenario: Home resident is restricted from site-wide management
    Given a user with role "HOME_RESIDENT" bound to unit "A Blok D:14"
    When they attempt to access site expense audit or invite other units
    Then access is denied with 403 Forbidden
    And they are permitted only to view dues and open tickets for "A Blok D:14"
