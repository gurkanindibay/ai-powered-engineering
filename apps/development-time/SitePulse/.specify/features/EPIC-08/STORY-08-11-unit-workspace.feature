@EPIC-08 @STORY-08-11
Feature: Actions-first unit workspace
  A unit is operated from a workspace that separates actions from information.

  @SC-08-11-01 @GUI-08-15 @layer:gui @pending @core @role_manager
  Scenario: Workspace actions follow the unit's allowed commands
    Given Unit "B Blok 24" is TENANT_OCCUPIED with Owner "Kemal Ev Sahibi"
    When the Site Manager opens the unit workspace in actions mode
    Then the workspace offers replace tenant, owner takes back, move-out and title transfer
    And the workspace offers no tenant move-in and no owner rents out action

  @SC-08-11-02 @layer:gui @pending @core @role_manager
  Scenario: Workspace information keeps the operating and capital ledgers separate
    Given Unit "B Blok 24" is TENANT_OCCUPIED with Owner "Kemal Ev Sahibi"
    When the Site Manager opens the unit workspace in information mode
    Then the operating dues balance and the capital balance are shown as separate rows
    And the manager returns to the unit list with the return button

  @SC-08-11-03 @layer:gui @pending @core @role_manager
  Scenario: Returning from unit workspace restores directory context and focus
    Given the Site Manager has filtered the unit directory
    When the manager opens the unit workspace from a directory row and returns
    Then the directory filter and search query are preserved
    And focus is restored to the initiating row action
