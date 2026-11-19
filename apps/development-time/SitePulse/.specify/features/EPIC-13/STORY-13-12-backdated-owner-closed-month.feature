@EPIC-13 @STORY-13-12
Feature: Back-dated owner into a closed month
  Supplementary charges posted for a back-dated owner count their late fee from creation.

  @SC-13-12-03 @layer:backend @linked @core @role_manager
  Scenario: Both supplementary charges of a back-dated owner count their fee from the creation date
    Given the month "Ekim 2026" is closed and "Kasım 2026" is open
    When the manager assigns an owner to unit "A-3" effective "2026-10-11" on "2026-11-19"
    Then both supplementary charges have effective due date "2026-11-19" and late fee 0.00
    And on "2026-11-29" their late fees are 16.94 and 25.00
