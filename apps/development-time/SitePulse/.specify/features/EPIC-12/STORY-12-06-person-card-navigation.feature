@EPIC-12 @STORY-12-06
Feature: Person card and cross-navigation
  The person card edits the person once, shows every unit role, and links back to the units.

  @SC-12-06-01 @GUI-12-02 @layer:gui @linked @core @role_manager
  Scenario: Unit to person to unit navigation keeps list state and focus
    Given Unit "B Blok 24" is OWNER_OCCUPIED with Owner "Kemal Ev Sahibi" and the unit list is searched for "Kemal"
    When the manager opens the owner's person card from the unit workspace and opens the unit from the card
    And the manager returns through the card to the unit list
    Then the unit list still shows the search "Kemal"
    And focus is back on the unit's actions button

  @SC-12-06-02 @GUI-12-02 @layer:gui @linked @core @role_manager
  Scenario: A card edit updates every visible unit role
    Given Unit "B Blok 24" is OWNER_OCCUPIED with Owner "Kemal Ev Sahibi"
    When the manager edits the owner's name on the person card and saves
    Then the unit workspace shows the new name for the owner role
    And the card edit is sent as a version-checked PATCH to the person

  @SC-12-06-03 @GUI-12-02 @layer:gui @linked @core @role_manager
  Scenario: Login and role actions start from the person card
    Given a person without a login who owns Unit "B Blok 24"
    When the manager opens a login from the person card
    Then the login request is sent for that person
    When the manager starts the tenant role action and selects Unit "B Blok 24"
    Then the unit workspace opens with the person kept as the starting point
