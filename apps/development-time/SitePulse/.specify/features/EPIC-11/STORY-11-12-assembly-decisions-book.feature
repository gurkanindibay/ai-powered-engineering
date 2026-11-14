@EPIC-11 @STORY-11-12
Feature: Meetings, quorum, votes and decisions book
  Meetings, quorum, votes and decisions book.

  @SC-11-12-01 @layer:backend @linked
  Scenario: Accepted budget item produces a numbered decision that approves the budget
    Given an assembly with quorum and a budget item
    When the assembly votes to accept it
    Then a numbered decision is recorded and approves the budget
