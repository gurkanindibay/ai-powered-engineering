@EPIC-08 @STORY-08-05
Feature: Title deed transfer and ownership sale handover
  A sale closes the previous owner's profile and leaves the tenant untouched.

  @SC-08-05-01 @GUI-08-06 @layer:gui @linked @core @role_manager
  Scenario: Change property owner upon title deed sale without affecting tenant
    Given Unit "A Blok D:14" has Tenant "Canan Kaya" and Owner "Ahmet Yılmaz"
    When the Site Manager registers a Title Deed Transfer to New Owner "Selim Evsahibi" effective 2026-10-28
    Then Ahmet Yılmaz is archived as historical property owner with closing balance
    And Selim Evsahibi becomes the active owner_person_id for Unit "A Blok D:14"
    And Canan Kaya remains the active tenant with zero interruption to her occupancy session

  @SC-08-05-02 @pending @core @role_manager
  Scenario: Capital dues after the transfer are billed to the new owner
    Given Unit "A Blok D:14" was transferred to "Selim Evsahibi" effective 2026-10-28
    When a capital assessment is accrued for the unit
    Then the CAPITAL_DUES liability is charged to Selim Evsahibi
