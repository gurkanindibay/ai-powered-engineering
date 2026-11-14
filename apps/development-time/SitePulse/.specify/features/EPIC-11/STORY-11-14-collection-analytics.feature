@EPIC-11 @STORY-11-14
Feature: Collection analytics and at-risk units
  Collection analytics and at-risk units.

  @SC-11-14-01 @layer:backend @linked
  Scenario: Analytics report rates, channels, forecast and risky units
    Given collections history for a site
    When analytics are computed
    Then rates, channel shares, the forecast and at-risk units are reported
