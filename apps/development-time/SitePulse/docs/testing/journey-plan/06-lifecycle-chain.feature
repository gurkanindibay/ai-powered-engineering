@EPIC-13 @STORY-13-06
Feature: One site from zero to a closed period (interconnected chain)
  Chain "site-lifecycle": the stages run in order on ONE site, and the end state of a stage is the
  start state of the next. Each stage ends with the ledger invariants. A failure names the stage.
  Layer is GUI because the point is that an admin can walk the whole path on screen.

  Background:
    Given the clock is frozen at "2026-09-01 09:00" Europe/Istanbul
    And a SaaS admin has onboarded a site "e2e-chain-lifecycle" with manager "manager@e2e.test"
    And the manager has signed in with a permanent password
    And proration is enabled for the site

  @SC-13-06-01 @J-13 @chain:site-lifecycle @stage:1 @state:F0 @layer:gui @smoke @role_manager @pending
  Scenario: Stage 1, a new site gets its structure (F0 to F1)
    Given the site is in state F0
    When the manager adds block "A Blok" with units A-1 to A-7 and tariffs 1500.00 (A-6: 2250.00)
    Then the site is equal to state F1
    And the ledger invariants hold

  @SC-13-06-02 @J-13 @chain:site-lifecycle @stage:2 @layer:gui @smoke @role_manager @pending
  Scenario: Stage 2, owners and tenants are added (F1 to F2)
    Given the previous stage passed
    When the manager adds the owners and tenants of state F2
    Then the site is equal to state F2
    And the ledger invariants hold

  @SC-13-06-03 @J-13 @chain:site-lifecycle @stage:3 @layer:gui @smoke @role_manager @pending
  Scenario: Stage 3, the first period is accrued
    Given the previous stage passed
    When the manager creates and accrues "Eylül 2026" due "2026-09-10"
    Then every charged unit owes its tariff and total outstanding is 9750.00 for A-1 to A-6
    And the ledger invariants hold

  @SC-13-06-04 @J-13 @chain:site-lifecycle @stage:4 @layer:gui @core @role_manager @pending
  Scenario: Stage 4, some residents pay and an advance appears
    Given the previous stage passed
    When "Ayşe Kaya" pays 1500.00 and "Elif Aydın" pays 8000.00 on "2026-09-01"
    Then "Ayşe Kaya" owes 0.00 and "Elif Aydın" holds an advance of 5750.00
    And the other units still owe their full tariff
    And the ledger invariants hold

  @SC-13-06-05 @J-13 @chain:site-lifecycle @stage:5 @layer:gui @core @role_manager @pending
  Scenario: Stage 5, time passes and the second and third periods accrue (F5 reached)
    Given the previous stage passed
    When the clock advances to "2026-11-19" and "Ekim 2026" and "Kasım 2026" are accrued
    And "Selin Demir" pays 1500.00 for "Eylül 2026" and "Ahmet Yılmaz" pays "Eylül 2026" and "Ekim 2026" for "A-4"
    Then the site balances equal state F5 where it applies, with the same late fees
    And the ledger invariants hold

  @SC-13-06-06 @J-13 @chain:site-lifecycle @stage:6 @layer:gui @core @role_manager @pending
  Scenario: Stage 6, a tenant changes and a title is transferred (F6 behaviour)
    Given the previous stage passed
    When tenant "Selin Demir" is replaced by "Mert Kılıç" on "2026-11-15" and "A-4" is sold to "Gül Tanrıverdi"
    Then "Selin Demir" keeps her old debt and "Mert Kılıç" starts at 0.00
    And "Gül Tanrıverdi" starts at 0.00 and "Ahmet Yılmaz" keeps his old debt
    And the ledger invariants hold

  @SC-13-06-07 @J-13 @chain:site-lifecycle @stage:7 @layer:gui @core @role_manager @pending
  Scenario: Stage 7, the oldest period is closed
    Given the previous stage passed
    When the manager closes period "Eylül 2026"
    Then it is CLOSED and a new accrual of it is refused
    And open debts of that period remain collectable
    And the ledger invariants hold

  @SC-13-06-08 @J-13 @chain:site-lifecycle @stage:8 @layer:gui @core @role_manager @pending
  Scenario: Stage 8, every surface agrees at the end of the chain
    Given the previous stage passed
    When the backend is restarted
    Then the admin dashboard, each unit workspace, each resident dashboard and the payment stream show the same balances as before the restart
    And each resident sees only their own data and the manager of another site sees none of it

  @SC-13-06-09 @J-13 @chain:site-lifecycle @stage:9 @layer:gui @core @role_manager @pending
  Scenario: Stage 9, teardown leaves nothing behind
    Given the previous stage passed
    When the journey teardown runs
    Then the site, its people, users, units, periods, liabilities and payments no longer exist
    And the shared seed data is unchanged
