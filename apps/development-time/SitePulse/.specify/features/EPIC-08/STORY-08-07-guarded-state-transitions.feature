@EPIC-08 @STORY-08-07
Feature: Guarded state transitions
  Illegal occupancy commands are rejected with the current state and change no data.

  @SC-08-07-01 @GUI-08-11 @pending @edge @role_manager
  Scenario: move-out is rejected on a VACANT unit
    Given a unit in state VACANT
    When the Site Manager requests move-out
    Then the request is rejected and the unit remains in state VACANT
    And no occupancy or ownership row is inserted or modified

  @SC-08-07-02 @GUI-08-11 @pending @edge @role_manager
  Scenario: tenant move-in is rejected on a OWNER_OCCUPIED unit
    Given a unit in state OWNER_OCCUPIED
    When the Site Manager requests tenant move-in
    Then the request is rejected and the unit remains in state OWNER_OCCUPIED
    And no occupancy or ownership row is inserted or modified

  @SC-08-07-03 @GUI-08-11 @pending @edge @role_manager
  Scenario: owner move-in is rejected on a OWNER_OCCUPIED unit
    Given a unit in state OWNER_OCCUPIED
    When the Site Manager requests owner move-in
    Then the request is rejected and the unit remains in state OWNER_OCCUPIED
    And no occupancy or ownership row is inserted or modified

  @SC-08-07-04 @GUI-08-11 @pending @edge @role_manager
  Scenario: tenant move-in is rejected on a TENANT_OCCUPIED unit
    Given a unit in state TENANT_OCCUPIED
    When the Site Manager requests tenant move-in
    Then the request is rejected and the unit remains in state TENANT_OCCUPIED
    And no occupancy or ownership row is inserted or modified

  @SC-08-07-05 @GUI-08-11 @pending @edge @role_manager
  Scenario: owner move-in is rejected on a TENANT_OCCUPIED unit
    Given a unit in state TENANT_OCCUPIED
    When the Site Manager requests owner move-in
    Then the request is rejected and the unit remains in state TENANT_OCCUPIED
    And no occupancy or ownership row is inserted or modified

  @SC-08-07-06 @GUI-08-11 @pending @edge @role_manager
  Scenario: tenant move-in is rejected on a UNOWNED, VACANT unit
    Given a unit in state UNOWNED, VACANT
    When the Site Manager requests tenant move-in
    Then the request is rejected and the unit remains in state UNOWNED, VACANT
    And no occupancy or ownership row is inserted or modified

  @SC-08-07-07 @GUI-08-11 @pending @edge @role_manager
  Scenario: owner move-in is rejected on a UNOWNED, VACANT unit
    Given a unit in state UNOWNED, VACANT
    When the Site Manager requests owner move-in
    Then the request is rejected and the unit remains in state UNOWNED, VACANT
    And no occupancy or ownership row is inserted or modified

  @SC-08-07-08 @pending @edge @role_manager
  Scenario: Registration approval respects the unit state
    Given Unit "A Blok D:4" is TENANT_OCCUPIED with Tenant "Selin Demir"
    When a resident registration request for the same unit is approved as tenant
    Then the approval is rejected with the reason that the unit is occupied
    And Selin Demir remains the active tenant
