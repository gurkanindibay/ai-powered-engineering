@EPIC-13 @STORY-13-07
Feature: Journey setup, teardown and isolation
  The harness contract of README section 5, tested like product behaviour so a leaking fixture
  fails a named scenario. These run before any other EPIC-13 scenario in CI.

  @SC-13-07-01 @J-14 @layer:backend @smoke @core @pending
  Scenario Outline: Every starting state can be created through the public API and is what the catalogue says
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
    And no user with an "@e2e.test" email exists
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
    Then a SQL dump of the site and the network log are saved as artifacts first
    And the teardown still removes the site

  @SC-13-07-05 @J-14 @layer:backend @core @pending
  Scenario: Teardown works after a half-built state
    Given building state F6 fails after the second period was accrued
    When the teardown runs
    Then the partial site is removed completely

  @SC-13-07-06 @J-14 @layer:backend @core @pending
  Scenario: Two journeys in parallel do not see each other's data
    Given a site "e2e-par-a" in state F5 and a site "e2e-par-b" in state F4 running at the same time
    When each manager reads the collection dashboard
    Then "e2e-par-a" shows 11117.50 and "e2e-par-b" shows 8800.00
    And neither list contains a unit, person or payment of the other

  @SC-13-07-07 @J-14 @layer:backend @core @pending
  Scenario: A finished run leaves the database as it started
    Given the database tables hold only the shared seed
    When the whole EPIC-13 suite has run and every teardown has finished
    Then no site whose slug starts with "e2e-" exists
    And the row count of every table equals its count before the run
    And the backend has been restarted once after the last teardown

  @SC-13-07-08 @J-14 @layer:backend @edge @pending
  Scenario: A leftover site from a crashed earlier run is cleaned before the next run starts
    Given a site "e2e-stale-1" from an earlier crashed run exists
    When the next run starts
    Then the leftover site is removed and reported in the run log
