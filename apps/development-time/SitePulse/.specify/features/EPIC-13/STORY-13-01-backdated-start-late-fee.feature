@EPIC-13 @STORY-13-01
Feature: Back-dated start residing date and late fees
  A supplementary charge for days nobody was billed is created late, so its late fee counts from
  its creation date (its effective due date), not from the referred month's due date.

  @SC-13-01-14 @layer:backend @linked @edge @role_manager
  Scenario: A back-dated owner's supplementary charge owes no fee for days before it existed
    Given the site is in state F3
    When the manager assigns an owner to unit "A-3" effective "2026-10-11" on "2026-11-19"
    Then the supplementary charge of 1016.13 has period due date "2026-10-10" and effective due date "2026-11-19"
    And its late fee is 0.00 at creation and 16.94 on "2026-11-29"
