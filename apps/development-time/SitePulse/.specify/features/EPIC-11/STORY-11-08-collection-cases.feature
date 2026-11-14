@EPIC-11 @STORY-11-08
Feature: Collection case workflow, evidence pack and lawyer link
  Collection case workflow, evidence pack and lawyer link.

  @SC-11-08-01 @layer:backend @linked
  Scenario: Enforcement needs a legal basis and the lawyer reads the pack by token
    Given a collection case
    When it reaches enforcement
    Then a legal basis is required and the lawyer reads the evidence pack by token

  @SC-11-08-02 @layer:backend @linked
  Scenario: KMK 25 flag is raised after three enforcements in two years
    Given an owner enforced three times in two years
    When the case history is evaluated
    Then the KMK 25 flag is raised
