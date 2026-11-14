@EPIC-11 @STORY-11-11
Feature: Heating costs split by meter readings and area
  Heating costs split by meter readings and area.

  @SC-11-11-01 @layer:backend @linked
  Scenario: Approved heating period shares add up and the occupant is billed
    Given a heating period with meter readings and areas
    When the period is approved
    Then the shares add up to the total and the occupant is billed
