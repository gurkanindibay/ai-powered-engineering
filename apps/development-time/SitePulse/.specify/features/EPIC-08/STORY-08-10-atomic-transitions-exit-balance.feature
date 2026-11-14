@EPIC-08 @STORY-08-10
Feature: Atomic transitions, derived status and per-person exit balance
  Transitions are transactional, dated, and the exit balance is per person.

  @SC-08-10-01 @GUI-08-14 @pending @core @role_manager
  Scenario: Exit balance counts only the departing tenant's liabilities
    Given Unit "B Blok D:12" has 900.00 unpaid operational dues charged to Owner "Ahmet Yılmaz" from a vacant period
    And Tenant "Zeynep Kaya" has 1500.00 unpaid operational dues for the same unit
    When the Site Manager executes the move-out action for Zeynep Kaya
    Then the closed session has exit_balance = 1500.00

  @SC-08-10-02 @pending @edge @role_manager
  Scenario: Status cannot drift from the occupancy sessions
    Given any sequence of legal transitions on a unit
    Then occupancy_status equals the state implied by the unit's active occupancy session
    And the unit's owner equals the active unit_ownerships record

  @SC-08-10-03 @pending @edge @role_manager
  Scenario: A transition is all or nothing
    Given Unit "B Blok D:12" is TENANT_OCCUPIED
    When the move-out fails after the session is closed but before the unit is updated
    Then the session is still active and the unit is still TENANT_OCCUPIED

  @SC-08-10-04 @GUI-08-14 @pending @edge @role_manager
  Scenario: Effective date cannot be in the future
    Given Tenant "Zeynep Kaya" lives in Unit "B Blok D:12"
    When the Site Manager executes the move-out action with a date after today
    Then the request is rejected because the date is in the future

  @SC-08-10-05 @GUI-08-14 @pending @edge @role_manager
  Scenario: Effective date may precede the recorded session start
    Given Tenant "Zeynep Kaya" was registered for Unit "B Blok D:12" on 2026-11-14
    When the Site Manager executes the move-out action with effective date 2026-11-05
    Then the session is closed with end_date 2026-11-05
    And the session start_date is moved back to 2026-11-05

  @SC-08-10-06 @GUI-08-14 @pending @core @role_manager
  Scenario: The leave is recorded after the resident actually left
    Given Tenant "Zeynep Kaya" moved into Unit "B Blok D:12" on 2026-03-01
    When the Site Manager records the move-out on 2026-11-02 and sets the effective date to 2026-10-20
    Then the session is closed with end_date 2026-10-20
    And the exit balance is calculated as of the effective date
    And the move-out dialog offers the effective date, defaulting to today and not later than today
