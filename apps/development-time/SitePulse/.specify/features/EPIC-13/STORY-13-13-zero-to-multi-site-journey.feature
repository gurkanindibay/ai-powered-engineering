@EPIC-13 @STORY-13-13
Feature: Zero to multi-site financial journey
  Prove that an operator can onboard multiple residential sites from an empty installation
  and manage them across four billing periods with mixed payment histories, designated payments,
  occupancy changes, and cash reconciliation.

  Background:
    Given the scenario clock follows the fixture timeline in Europe/Istanbul
    And a SaaS administrator and zero initial sites, liabilities or cash

  # Pending: Onboarding and block/unit creation journey is covered under Issue #247
  @SC-13-13-01 @J-17 @layer:backend @core @role_manager @pending
  Scenario: Onboard two sites and create all eighty-eight units from zero
    Given a SaaS administrator onboards Site A and Site B with zero initial units
    When the manager of Site A creates block "A" with 24 units labelled "A-01" through "A-24"
    And the manager of Site B creates block "B1" with 32 units and block "B2" with 32 units
    Then exactly 88 units exist across both sites before people are registered
    And initial owner-occupants and tenants are registered without unearned liabilities

  @SC-13-13-02 @J-17 @layer:backend @smoke @core @role_manager @linked
  Scenario: Accrue four periods and verify mixed payment histories
    Given Site A has 24 units at TRY 1000.00 and Site B has 64 units at TRY 750.00 with zero grace days
    When January through April 2027 are accrued on the first of each month
    And on the 10th of each month mixed receipts and routine owner-occupant receipts are posted
    Then unit "A-03" and unit "B2-01" follow a paid, unpaid, unpaid, paid history
    And designated April payments settle April principal without clearing February and March
    And the final period status matrix for all five detailed units distinguishes paid, partial and unpaid
    And all allocation amounts match expected values to the kuruş

  # Pending: Occupancy transitions and joint exposure are verified in Issue #249
  @SC-13-13-03 @J-17 @layer:backend @core @role_manager @pending
  Scenario: Occupancy transitions and title transfers isolate debtor balances
    Given four billing periods have been managed across moves and sales
    When former and new residents inspect their account statements
    Then liabilities remain attached to the responsible debtor
    And former owner joint exposure is reported separately without double counting

  # Pending: Reconciliation of operating cash and open debt is verified in Issue #250
  @SC-13-13-04 @J-17 @layer:backend @core @role_manager @pending
  Scenario: Reconcile posted operating cash and open debt by site
    Given four periods of collections have been posted across both sites
    When April 10 reconciliations are performed
    Then Site A posted operating cash reconciles to TRY 90658.50
    And Site B posted operating cash reconciles to TRY 189538.75
    And open primary debt with accrued fees matches TRY 5804.09 for Site A and TRY 2661.67 for Site B

  # Pending: GUI manager screens and statement views are verified in Issue #251
  @SC-13-13-05 @J-17 @layer:gui @core @role_manager @pending
  Scenario: Manager screens display consistent statements and collection summaries
    Given the four-period multi-site journey is complete
    When the site managers inspect unit statements and collection dashboards
    Then period histories, payer identities and cash totals match the ledger
