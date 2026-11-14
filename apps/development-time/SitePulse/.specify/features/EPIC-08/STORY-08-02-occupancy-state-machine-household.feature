@EPIC-08 @STORY-08-02
Feature: Unit occupancy state machine and household resident scoping
  Household members are scoped to the current active resident.

  @SC-08-02-01 @GUI-08-03 @layer:gui @linked @core @role_manager
  Scenario: Household members are bound to the active resident session
    Given Tenant "Zeynep Kaya" lives in "B Blok D:12" with household members "Ali Kaya (Son)" and "Can Kaya (Brother)"
    When inspecting the active residents of "B Blok D:12"
    Then the system returns Zeynep Kaya as primary contact and 2 household members

  @SC-08-02-02 @GUI-08-03 @pending @core @role_manager
  Scenario: Household members are archived when the resident moves out
    Given Tenant "Zeynep Kaya" lives in "B Blok D:12" with household members "Ali Kaya (Son)" and "Can Kaya (Brother)"
    When Zeynep Kaya moves out and the flat becomes VACANT
    Then the active household member list is cleared and archived under Zeynep Kaya's occupancy record
