@EPIC-08 @STORY-08-04
Feature: Move-in and historical occupancy audit trail
  A move-in opens a new occupancy session and the history lists all occupants.

  @SC-08-04-01 @GUI-08-05 @layer:gui @linked @core @role_manager
  Scenario: New tenant moves in and past occupancy history is retrievable
    Given Unit "B Blok D:12" is VACANT with past tenant "Zeynep Kaya"
    When the Site Manager registers new Tenant "Mehmet Demir" starting 2026-11-01
    Then a new active occupancy session is opened for Mehmet Demir
    And Unit "B Blok D:12" status transitions to TENANT_OCCUPIED
    When the Site Manager views the occupancy history timeline
    Then the timeline lists Zeynep Kaya "Left with 1500.00" followed by Mehmet Demir "Active"

  @SC-08-04-02 @GUI-08-01 @layer:gui @linked @smoke @role_manager
  Scenario: Tenant move-in opens an active tenant session
    Given Unit "B Blok D:3" is VACANT of tenant
    When the Site Manager registers new Tenant "Selin Demir"
    Then an active TENANT occupancy session is opened for Selin Demir
