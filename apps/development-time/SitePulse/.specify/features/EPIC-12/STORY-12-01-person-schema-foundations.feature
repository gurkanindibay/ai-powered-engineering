@EPIC-12 @STORY-12-01
Feature: Person schema foundations
  @SC-12-01-01
  @layer:db
  @linked
  Scenario: Preserve person history while adding normalized identity references
    Given the database contains existing person, household, unit, and primary contact rows
    When the person schema migration is applied
    Then existing person and relationship rows remain available
    And normalized search keys and person versions are populated
    And the primary contact reference points to an eligible person when it can be matched safely
    And merged people are excluded from the active person card
