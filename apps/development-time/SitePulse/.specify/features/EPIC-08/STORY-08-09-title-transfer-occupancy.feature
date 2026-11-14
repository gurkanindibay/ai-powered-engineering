@EPIC-08 @STORY-08-09
Feature: Title deed transfer keeps occupancy consistent
  A transfer has a defined occupancy effect for each unit state.

  @SC-08-09-01 @GUI-08-13 @pending @core @role_manager
  Scenario: Selling an owner-occupied unit vacates it
    Given Unit "A Blok D:3" is OWNER_OCCUPIED by Owner "Ahmet Yılmaz"
    When the Site Manager registers a Title Deed Transfer to "Selim Evsahibi" effective 2026-10-28
    Then Ahmet Yılmaz's occupancy session is closed with end_date = 2026-10-28 and an exit balance
    And Unit "A Blok D:3" status becomes VACANT
    And Selim Evsahibi is the owner of the unit

  @SC-08-09-02 @GUI-08-13 @pending @core @role_manager
  Scenario: The new owner moves in at transfer
    Given Unit "A Blok D:3" is OWNER_OCCUPIED by Owner "Ahmet Yılmaz"
    When the Site Manager registers a Title Deed Transfer to "Selim Evsahibi" with "new owner moves in"
    Then an active OWNER session is opened for Selim Evsahibi
    And Unit "A Blok D:3" status is OWNER_OCCUPIED

  @SC-08-09-03 @pending @core @role_manager
  Scenario: The tenant buys the unit
    Given Unit "A Blok D:14" has Tenant "Canan Kaya" and Owner "Ahmet Yılmaz"
    When the Site Manager registers a Title Deed Transfer to Canan Kaya
    Then Canan Kaya's TENANT session is closed with an exit balance
    And an active OWNER session is opened for Canan Kaya
    And Unit "A Blok D:14" status becomes OWNER_OCCUPIED

  @SC-08-09-04 @pending @edge @role_manager
  Scenario: Selling a vacant unit leaves it vacant
    Given Unit "B Blok D:12" is VACANT with Owner "Ahmet Yılmaz"
    When the Site Manager registers a Title Deed Transfer to "Selim Evsahibi"
    Then Unit "B Blok D:12" status remains VACANT
    And Selim Evsahibi can move in through the owner move-in action
