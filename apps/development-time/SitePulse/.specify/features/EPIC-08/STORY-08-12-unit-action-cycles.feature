@EPIC-08 @STORY-08-12
Feature: Unit actions repeated in cycles keep status and history correct
  Every unit action is performed several times in a row. After each run the unit's status, its
  allowed commands, its occupancy history and its audit trail are checked, so a repeated action
  can neither lose a record nor leave a stale status behind.

  @SC-08-12-01 @layer:backend @linked @core @role_manager
  Scenario: Tenant move-in and move-out repeated three times keep one history row per tenant
    Given Unit "A Blok 14" is OWNER_OCCUPIED with Owner on record
    When the Site Manager moves the owner out and then runs tenant move-in and move-out three times with three different tenants
    Then after every move-in the unit is TENANT_OCCUPIED and after every move-out it is VACANT
    And the occupancy history lists the owner session and three closed tenant sessions in order
    And exactly one session is active after each move-in and none after each move-out
    And the owner on record never changes

  @SC-08-12-02 @layer:backend @linked @core @role_manager
  Scenario: Owner rents out and takes back repeatedly
    Given Unit "A Blok 14" is OWNER_OCCUPIED with Owner on record
    When the Site Manager runs "owner rents out" then "owner takes back" three times
    Then the status alternates TENANT_OCCUPIED and OWNER_OCCUPIED after each action
    And the occupancy history grows by one owner session and one tenant session per cycle
    And every closed session has an end date and the single open session matches the unit status

  @SC-08-12-03 @layer:backend @linked @core @role_manager
  Scenario: Replacing the tenant repeatedly settles each outgoing tenant once
    Given Unit "A Blok 14" is TENANT_OCCUPIED with a tenant who owes 1500.00
    When the Site Manager replaces the tenant three times
    Then the unit stays TENANT_OCCUPIED after every replacement
    And each outgoing tenant's session is closed once with its own exit balance
    And the history lists every tenant exactly once and only the latest tenant is active

  @SC-08-12-04 @layer:backend @linked @core @role_manager
  Scenario: Owner move-in and move-out repeated keep the owner and the deed unchanged
    Given Unit "A Blok 14" is OWNER_OCCUPIED with Owner on record
    When the Site Manager runs owner move-out and owner move-in three times
    Then the status alternates VACANT and OWNER_OCCUPIED after each action
    And the ownership rows are never inserted, closed or modified
    And the history shows one closed owner session per completed cycle

  @SC-08-12-05 @layer:backend @linked @core @role_manager
  Scenario: Title transfer repeated keeps every previous owner in the ownership history
    Given Unit "A Blok 14" is OWNER_OCCUPIED with Owner on record
    When the Site Manager transfers the title three times to three different buyers
    Then the current owner is always the latest buyer
    And every previous owner has a closed ownership period with an end date
    And the status follows the transition table after each transfer
    And no person card is deleted

  @SC-08-12-06 @layer:backend @linked @core @role_manager
  Scenario: Every executed command is audited in order
    Given Unit "A Blok 14" has gone through move-out, tenant move-in, replace tenant, owner takes back and title transfer
    When the Site Manager reads the transition audit of the unit
    Then it lists each command with its from-state and to-state in the order performed
    And each audited to-state equals the from-state of the next entry

  @SC-08-12-07 @layer:backend @linked @edge @role_manager
  Scenario: A repeated command that is no longer legal is rejected and changes nothing
    Given Unit "A Blok 14" is VACANT after a move-out
    When the Site Manager sends the same move-out again and then a second owner takes back
    Then each request is rejected naming the current state
    And the occupancy history, ownership rows, status and audit trail are unchanged

  @SC-08-12-08 @layer:backend @linked @core @role_manager
  Scenario: Household members added, updated and removed repeatedly keep the roster and the primary contact correct
    Given Unit "A Blok 14" is OWNER_OCCUPIED with Owner on record
    When the Site Manager adds a household member, edits the member, sets the member as primary contact and removes the member, three times
    Then the roster is empty after every removal and holds only the member in between
    And the primary contact is cleared when the member is removed
    And the same person is never duplicated by adding it again

  @SC-08-12-09 @layer:backend @linked @core @role_manager
  Scenario: Move-out archives the household of the closed session each time
    Given Unit "A Blok 14" is TENANT_OCCUPIED with a household member
    When the Site Manager moves the tenant out, moves a new tenant in and adds a member, twice
    Then the live roster holds only the current session's member
    And the archived members of every closed session are still on record

  @SC-08-12-10 @layer:backend @linked @core @role_manager
  Scenario: When a tenant moves out, all of the tenant's dependents move out with them
    Given Unit "A Blok 14" is TENANT_OCCUPIED with a tenant who has a spouse and two children as household members
    When the Site Manager moves the tenant out
    Then the unit is VACANT and the live household roster of the unit is empty
    And the spouse and both children are archived against the closed tenant session
    And the unit no longer lists any of them as a resident or as the primary contact
    And the occupancy history shows the tenant session closed with its dependents attached

  @SC-08-12-11 @layer:backend @linked @core @role_manager
  Scenario: When an owner who lives in the unit moves out, the owner's dependents move out with them
    Given Unit "A Blok 14" is OWNER_OCCUPIED with Owner on record and two household members
    When the Site Manager moves the owner out
    Then the unit is VACANT and the live household roster is empty
    And the owner remains the owner on record and the dependents are archived against the closed owner session

  @SC-08-12-12 @layer:backend @linked @core @role_manager
  Scenario: Dependents follow every action that closes a session, repeated
    Given Unit "A Blok 14" is TENANT_OCCUPIED with a tenant who has two household members
    When the Site Manager runs replace tenant, owner takes back and title transfer, adding two household members before each action
    Then after each action the live roster contains none of the previous session's dependents
    And each closed session keeps its own archived dependents and no dependent is attached to two sessions

  @SC-08-12-13 @layer:backend @linked @edge @role_manager
  Scenario: A dependent who is also a person card keeps the card when moved out
    Given a household member linked to person card "Zeynep Aydin"
    When the Site Manager moves the tenant out
    Then the member leaves the roster but the person card still exists
    And the card lists the household relation as closed with an end date
    And the same card can be added as a household member of a new session afterwards
