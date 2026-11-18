@EPIC-02 @STORY-02-03
Feature: Manual unit and home owner registration
  The manager adds and removes residents from the residents module.

  @SC-02-03-01 @GUI-02-03 @layer:gui @linked @smoke @role_manager
  Scenario: Manager adds a new home owner manually
    Given the Site Manager opens the residents module
    When filling unit "25", resident "Fatma Şahin" and an email and saving
    Then a new unit card appears and the person and the unit exist in the database

  @SC-02-03-02 @GUI-02-04 @layer:gui @linked @edge @role_manager
  Scenario: Adding a resident to an occupied unit warns and saves nothing
    Given unit A Blok D:14 already has an owner
    When the manager fills the form for unit "14" and saves
    Then a confirmation warning is shown
    And cancelling saves nothing

  @SC-02-03-03 @GUI-02-05 @layer:gui @linked @core @role_manager
  Scenario: A resident without ledger history can be deleted
    Given a resident without ledger history
    When the manager deletes the resident and confirms
    Then the resident is removed

  @SC-02-03-04 @GUI-02-05 @layer:gui @linked @core @role_manager
  Scenario: A refused delete keeps the resident card
    Given a resident with ledger history
    When the manager deletes the resident and confirms
    Then the delete is refused and the resident card stays

  @SC-02-03-05 @layer:gui @linked @core @role_manager
  Scenario: Registration shows generated temporary credentials
    Given the Site Manager opens the add owner modal
    When saving a new owner with block "B", flat "25", resident "Fatma Şahin" and an email
    Then the unit count increments by one
    And a credentials dialog displays a generated temporary password
