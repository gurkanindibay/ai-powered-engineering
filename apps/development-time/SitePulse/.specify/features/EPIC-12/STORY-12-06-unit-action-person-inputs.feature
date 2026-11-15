@EPIC-12 @STORY-12-06
Feature: Unit actions choose people through person cards
  Unit action pages hold no free-text person inputs. People are chosen or created through the shared person field.

  @SC-12-06-01 @layer:gui @linked @core
  Scenario: Register a unit with people chosen from person cards
    Given the manager opens the new unit registration
    When the manager chooses the owner, the tenant and a household member through the person field
    Then the registration request carries person references and no inline name, phone or email

  @SC-12-06-02 @layer:gui @linked @core
  Scenario: Edit a unit without retyping a person's identity
    Given the manager opens a unit for editing
    When the edit page is shown
    Then owner and tenant identity is read-only and opens the person card
    And the page has no person text inputs

  @SC-12-06-03 @layer:gui @linked @core
  Scenario: Choose the primary contact by person id
    Given a unit has an active owner on record
    When the manager chooses that owner as the primary contact
    Then the contact request carries the owner's person id
