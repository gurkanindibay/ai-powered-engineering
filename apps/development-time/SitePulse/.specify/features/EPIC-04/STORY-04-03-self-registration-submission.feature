@EPIC-04 @STORY-04-03
Feature: Resident public self-registration submission API
  A prospective resident submits a registration through a valid invitation link.

  @SC-04-03-01 @layer:gui @linked @core
  Scenario: Home owner submits online registration
    Given a valid site invitation link
    When the home owner fills "Kerem Yılmaz", "B Blok D:18", "kerem.yilmaz@gmail.com"
    And submits the form
    Then return 201 Created with status "PENDING"
    And assign a unique requestId
