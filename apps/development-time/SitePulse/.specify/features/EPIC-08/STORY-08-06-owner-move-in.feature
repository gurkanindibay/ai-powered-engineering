@EPIC-08 @STORY-08-06
Feature: Owner move-in without ownership change
  A vacant unit still belongs to its owner; owner move-in changes no ownership.

  @SC-08-06-01 @GUI-08-09 @pending @smoke @role_manager
  Scenario: Owner moves into the unit after the tenant left
    Given Unit "B Blok D:12" is VACANT after Tenant "Zeynep Kaya" moved out, with Owner "Ahmet Yılmaz"
    When the Site Manager executes the owner move-in action
    Then the confirmation names Ahmet Yılmaz and offers no person input fields
    And a new active OWNER occupancy session is opened for Ahmet Yılmaz
    And Unit "B Blok D:12" status becomes OWNER_OCCUPIED
    And no unit_ownerships row is inserted, closed or modified

  @SC-08-06-02 @pending @edge @role_manager
  Scenario: Owner move-in for a person who is not the owner is rejected
    Given Unit "B Blok D:12" is VACANT with Owner "Ahmet Yılmaz"
    When an owner move-in is requested for "Mehmet Demir"
    Then the request is rejected with a validation error
    And the unit remains VACANT with Owner "Ahmet Yılmaz"

  @SC-08-06-03 @GUI-08-10 @pending @core @role_manager
  Scenario: Tenant move-in still accepts a new person
    Given Unit "B Blok D:12" is VACANT with Owner "Ahmet Yılmaz"
    When the Site Manager registers new Tenant "Mehmet Demir"
    Then Unit "B Blok D:12" status becomes TENANT_OCCUPIED
    And the owner of the unit is still Ahmet Yılmaz
