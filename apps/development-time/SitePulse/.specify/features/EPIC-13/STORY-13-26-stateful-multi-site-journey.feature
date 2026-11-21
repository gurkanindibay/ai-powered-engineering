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

  @SC-13-26-02 @J-14 @depth:1 @layer:gui @core @linked
  Scenario: Two sites remain identifiable from onboarding through final reconciliation
    Given an isolated E2E database with an empty residential site list
    When the manager onboards both sites, creates all 88 units through manager commands, and applies the four-period lifecycle
    Then every occupancy and payment checkpoint uses the IDs returned during onboarding
    And the unit statement and site-scoped cash view show the final manager evidence
    And the final site balances reconcile to the independent fixture totals

