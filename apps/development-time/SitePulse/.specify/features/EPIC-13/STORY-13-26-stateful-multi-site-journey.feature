@EPIC-13 @STORY-13-26
Feature: Stateful zero-to-multi-site financial journey
  One disposable E2E attempt carries the same two newly onboarded sites and their IDs through
  unit creation, occupancy changes, four billing periods, receipts and manager reconciliation.

  @SC-13-26-01 @J-14 @depth:1 @layer:backend @smoke @core @linked
  Scenario: The onboarding attempt starts with no residential sites
    Given an isolated E2E database with system configuration and a SaaS administrator
    When the administrator requests the site list
    Then the site list is empty
    And no shared development or production data has been reset

  # The integrated journey is automated after the onboarding and lifecycle builders from #247 and #248 land.
  @SC-13-26-02 @J-14 @depth:1 @layer:gui @core @pending
  Scenario: Two sites remain identifiable from onboarding through final reconciliation
    Given an empty site list and the approved two-site financial journey
    When the manager creates all 88 units, registers their owners and occupants, and applies the four-period lifecycle
    Then every onboarding, occupancy, payment, statement and site-cash checkpoint uses the same returned site and unit IDs
    And the manager's browser evidence agrees with the independently calculated site balances

