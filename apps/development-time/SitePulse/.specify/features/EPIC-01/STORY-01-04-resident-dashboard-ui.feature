@EPIC-01 @STORY-01-04
Feature: Material 3 resident dashboard screens
  Hero balance card, overdue badge and quick actions.

  @SC-01-04-01 @GUI-01-01 @layer:gui @linked @smoke @role_homeowner
  Scenario: Render resident hero balance with overdue amount
    Given an overdue dues liability of 1400.00 that is 10 days past due
    When the resident launches the app
    Then the Hero Balance Card displays the backend total

  @SC-01-04-02 @GUI-01-02 @layer:gui @linked @smoke @role_homeowner
  Scenario: Render zero balance without overdue badge
    Given a resident with no dues
    When the resident launches the app
    Then the Hero Balance Card displays 0.00 and no overdue badge is shown

  @SC-01-04-03 @layer:gui @linked @core @role_homeowner
  Scenario: Action buttons meet touch target size and unapproved features are hidden
    When the resident launches the app
    Then all action buttons meet the 48dp touch target accessibility requirement
    And unapproved sub-meter features "Sayaç Gir" and "Rezervasyon" are hidden

  @SC-01-04-04 @layer:gui @linked @role_homeowner
  Scenario: Resident issue form text controls have accessible names
    When the resident opens the request form from the dashboard
    Then the issue description field exposes its visible label to assistive technology
