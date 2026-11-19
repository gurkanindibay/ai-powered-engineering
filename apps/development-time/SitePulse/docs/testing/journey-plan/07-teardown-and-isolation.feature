@EPIC-13 @STORY-13-07
Feature: Journey setup, teardown and isolation
  The harness contract of README section 5, tested like product behaviour so a leaking fixture
  fails a named scenario. Run the harness contract as a separate CI test group. The group has no scenario-order dependency.

  @SC-13-07-01 @J-14 @layer:backend @smoke @core @pending
  Scenario Outline: Every starting state can be built using the documented fixture path
    When a site is created in state <state>
    Then its units, people, periods, liabilities, payments and balances equal the catalogue values of <state>
    And the ledger invariants hold

    Examples:
      | state |
      | F0    |
      | F1    |
      | F2    |
      | F3    |
      | F4    |
      | F5    |
      | F6    |
      | F7    |

  @SC-13-07-02 @J-14 @layer:backend @smoke @core @pending
  Scenario: Teardown removes every row of the site
    Given a site in state F5
    When the teardown runs
    Then every table keyed by the site id has 0 rows for it
    And no journey-exclusive user ID in the manifest exists
    And no person created for the journey exists

  @SC-13-07-03 @J-14 @layer:backend @core @pending
  Scenario: Teardown never touches shared seed data
    Given the checksum of the system seed and SaaS admin tables is recorded
    And a site in state F6
    When the teardown runs
    Then the checksum is unchanged

  @SC-13-07-04 @J-14 @layer:backend @core @pending
  Scenario: Teardown runs when the journey fails
    Given a site in state F5
    When a step of the journey raises an error
    Then the redacted site snapshot and redacted network evidence are saved first
    And the teardown still removes the site

  @SC-13-07-05 @J-14 @layer:backend @core @pending
  Scenario: Teardown works after a half-built state
    Given building state F6 fails after the second period was accrued
    When the teardown runs
    Then the partial site is removed completely

  @SC-13-07-06 @J-14 @layer:backend @core @pending
  Scenario: Two journeys in parallel do not see each other's data
    Given site P1 in state F5 and site P2 in state F4 are built by two attempts at the same time
    When each manager reads the collection dashboard
    Then site P1 shows 11117.50 and site P2 shows 8800.00
    And neither list contains a unit, person or payment of the other

  @SC-13-07-07 @J-14 @layer:backend @core @pending
  Scenario: A finished run leaves the database as it started
    Given the database tables hold only the shared seed
    When this run finishes on an exclusive seeded stack and every teardown has finished
    Then no site ID recorded by this run exists
    And the row count of every table equals its count before the run
    And the backend has been restarted once after the last teardown

  @SC-13-07-08 @J-14 @layer:backend @edge @pending
  Scenario: A leftover site from a crashed earlier run is cleaned before the next run starts
    Given the manifests identify a crashed run and a second run that is still active
    When stale-run reclamation runs
    Then only the crashed run's site and journey-exclusive identities are removed
    And the active run's site, identities and balances remain unchanged

  @SC-13-07-09 @J-14 @layer:backend @edge @pending
  Scenario: Cleanup is safe to retry after an evidence capture failure
    Given an attempt has created a site and identities recorded in its manifest
    And another attempt on the same stack has its own site and identities
    When evidence capture fails and teardown executes twice using the first manifest
    Then both teardowns leave the first attempt fully removed
    And the original test failure remains visible alongside the evidence capture failure
    And the second attempt and shared seed are unchanged
