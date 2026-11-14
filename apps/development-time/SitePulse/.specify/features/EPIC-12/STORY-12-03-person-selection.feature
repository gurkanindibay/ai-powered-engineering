@EPIC-12 @STORY-12-03
Feature: Shared person selection components
  Person-aware flows reuse a searchable picker and one card form.

  @SC-12-03-01 @layer:gui @linked @core
  Scenario: Search through more than one hundred people
    Given the site has more than one hundred people
    When the manager pages through the person picker
    Then people beyond the first one hundred can be selected

  @SC-12-03-02 @layer:gui @linked @core
  Scenario: Explain why a person cannot take a role
    Given a matching person is ineligible for the selected unit role
    When the person appears in search results
    Then the row is disabled and explains the eligibility reason

  @SC-12-03-03 @layer:gui @linked @core
  Scenario: Explain duplicate candidates before creating a person
    Given the manager enters details matching an existing person
    When duplicate detection returns candidate reasons
    Then the form lists those reasons and requires explicit confirmation to create a distinct person
