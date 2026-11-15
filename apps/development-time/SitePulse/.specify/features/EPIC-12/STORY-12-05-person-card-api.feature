@EPIC-12 @STORY-12-05
Feature: Person card API and reference-based commands
  @SC-12-05-01
  @layer:db
  @linked
  Scenario: Search offers people with role eligibility for the unit
    Given a site manager and a unit with an owner and a household member
    When the manager searches people for the tenant role on that unit
    Then the owner is returned as not eligible with code OWNER_CANNOT_BE_TENANT
    And people of other sites are never returned

  @SC-12-05-02
  @layer:db
  @linked
  Scenario: Creating a card reports possible duplicates unless confirmed
    Given a person with a phone number exists in the site
    When the manager creates a card with the same phone number
    Then the request is rejected with PERSON_POSSIBLE_DUPLICATE and the candidates
    And the same request with confirm_distinct creates the card

  @SC-12-05-03
  @layer:db
  @linked
  Scenario: Editing a card needs the current version
    Given a person card at version 3
    When the manager edits it with version 2
    Then the edit is rejected with PERSON_VERSION_CONFLICT

  @SC-12-05-04
  @layer:db
  @linked
  Scenario: Actions accept an existing person or a new card
    Given a unit with an active occupancy
    When the manager adds a household member by person reference
    Then the member links to that card and no second card is created

  @SC-12-05-05
  @layer:db
  @linked
  Scenario: The primary contact is selected by person
    Given a unit whose household includes a person
    When the manager selects that person as primary contact
    Then the unit stores the person as primary contact
    And a person who is not on the unit is refused

  @SC-12-05-06
  @layer:db
  @linked
  Scenario: Search accepts numeric paging query parameters
    Given a site manager and people in the site
    When the manager searches with q, context, unit_id, page=1 and limit=50 in the query string
    Then the request succeeds with the requested page
    And no query parameter the picker sends is rejected for its type
