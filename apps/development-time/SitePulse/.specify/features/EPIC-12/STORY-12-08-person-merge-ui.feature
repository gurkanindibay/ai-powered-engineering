@EPIC-12 @STORY-12-08
Feature: Person card merge
  A manager merges a duplicate person card into another one from the card. The merge is step-up protected.

  @SC-12-08-01 @GUI-12-02 @layer:gui @linked @core @role_manager
  Scenario: Merge asks for a password check and then merges the card
    Given a person card "Kemal Ev Sahibi" and a duplicate card "Kemal Evsahibi"
    When the manager starts a merge from the duplicate card and selects "Kemal Ev Sahibi" and confirms
    And the server asks for a fresh password check and the manager verifies the password
    Then the merge is sent for the duplicate card with the version of the selected card
    And the manager sees that the card was merged

  @SC-12-08-02 @GUI-12-02 @layer:gui @linked @core @role_manager
  Scenario: A card cannot be merged into itself
    Given a person card "Kemal Ev Sahibi"
    When the manager starts a merge from the card and selects the same card
    Then no merge request is sent
    And the manager sees that a person cannot be merged into itself
