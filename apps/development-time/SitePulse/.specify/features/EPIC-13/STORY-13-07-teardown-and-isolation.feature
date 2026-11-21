@EPIC-13 @STORY-13-07
Feature: Journey setup, teardown and isolation
  The harness contract of README section 5, tested like product behaviour so a leaking fixture
  fails a named scenario. Run the harness contract as a separate CI test group. The group has no scenario-order dependency.

  @SC-13-07-01 @J-14 @depth:1 @layer:backend @smoke @core @linked
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

  # Pending: historical fixture construction is in progress; F6 and F7 need later journey fixture builders.
  @SC-13-07-10 @J-14 @depth:1 @layer:backend @pending
  Scenario Outline: Every historical starting state can be built using the documented fixture path
    When a site is created in state <state>
    Then its units, people, periods, liabilities, payments and balances equal the catalogue values of <state>
    And the ledger invariants hold

    Examples:
      | state |
      | F6    |
      | F7    |

  @SC-13-07-02 @J-14 @depth:1 @layer:backend @smoke @core @linked
  Scenario: Teardown removes every row of the site
    Given a site in state F5
    When the teardown runs
    Then every mutable table covered by the site teardown has 0 rows for it
    And no journey-exclusive user ID in the manifest exists
    And no person created for the journey exists

  @SC-13-07-03 @J-14 @depth:1 @layer:backend @core @linked
  Scenario: Teardown never touches shared seed data
    Given the checksum of the system seed and SaaS admin tables is recorded
    And a site in state F5
    When the teardown runs
    Then the checksum is unchanged

  @SC-13-07-04 @J-14 @depth:1 @layer:backend @core @linked
  Scenario: Teardown runs when the journey fails
    Given a site in state F5
    When a step of the journey raises an error
    Then the redacted site row counts and route/status network evidence are saved first
    And the teardown still removes the site

  # Pending: F6's multi-period fixture builder is not implemented yet.
  @SC-13-07-05 @J-14 @depth:1 @layer:backend @core @pending
  Scenario: Teardown works after a half-built state
    Given building state F6 fails after the second period was accrued
    When the teardown runs
    Then the partial site is removed completely

  @SC-13-07-06 @J-14 @depth:1 @layer:backend @core @linked
  Scenario: Two active journeys do not see each other's data
    Given site P1 in state F5 and site P2 in state F4 are active in separate attempts
    When each manager reads the collection dashboard
    Then site P1 shows 4567.50 and site P2 shows 8800.00 in overdue balances
    And neither list contains a unit, person or payment of the other

  @SC-13-07-07 @J-14 @depth:1 @layer:backend @core @linked
  Scenario: A finished run leaves the database as it started
    Given the database tables hold only the shared seed
    When this run finishes on an exclusive seeded stack and every teardown has finished
    Then no site ID recorded by this run exists
    And the row count of every mutable business table equals its count before the run
    And the backend has been restarted once after the last teardown

  @SC-13-07-08 @J-14 @depth:1 @layer:backend @edge @linked
  Scenario: A leftover site from a crashed earlier run is cleaned before the next run starts
    Given the manifests identify a crashed run and a second run that is still active
    When stale-run reclamation runs
    Then only the crashed run's site and journey-exclusive identities are removed
    And the active run's site, identities and balances remain unchanged

  @SC-13-07-09 @J-14 @depth:1 @layer:backend @edge @linked
  Scenario: Cleanup is safe to retry after an evidence capture failure
    Given an attempt has created a site and identities recorded in its manifest
    And another attempt on the same stack has its own site and identities
    When evidence capture fails and teardown executes twice using the first manifest
    Then both teardowns leave the first attempt fully removed
    And the original test failure remains visible alongside the evidence capture failure
    And the second attempt and shared seed are unchanged
