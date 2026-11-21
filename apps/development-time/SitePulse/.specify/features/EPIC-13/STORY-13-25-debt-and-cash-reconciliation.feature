@EPIC-13 @STORY-13-25
Feature: Reconcile homeowner debt and operating cash by site after four periods
  Journey analysis: docs/testing/journey-plan/zero-to-multi-site-financial-journey.md (issue #250).
  Two sites (A with 24 units, B with 64 units) are accrued for January to April 2027 on the first of each
  month and paid on the 10th. The clock is frozen on 2027-04-10 in Europe/Istanbul. Fee rule: 5% per
  30 days on outstanding principal, zero grace days, rounded per segment. Amounts are TRY.
  The @linked scenarios verify the expected values against an independent model derived only from the
  fixture inputs (e2e/support/journey_reconciliation.py): it uses no product code, counts a jointly
  liable receivable once and never reads a value from the system under test. The @pending scenarios
  compare a running system with that model and wait for the onboarding and history fixtures (#247, #248).

  @SC-13-25-01 @layer:harness @core @linked
  Scenario Outline: Posted operating cash equals cumulative gross receipts at every checkpoint
    Given the fixture timeline for sites "A" and "B" starts with 0.00 cash
    When the receipts up to <date> are posted, including paid fees
    Then the posted operating cash of Site A is <site_a> and of Site B is <site_b>
    And accruals, occupancy changes and title transfers add no cash

    Examples:
      | date       | site_a   | site_b    |
      | 2027-01-10 | 22400.00 | 48000.00  |
      | 2027-02-10 | 45532.67 | 94750.00  |
      | 2027-03-10 | 67032.67 | 141250.00 |
      | 2027-04-10 | 90658.50 | 189538.75 |

  @SC-13-25-02 @layer:harness @core @linked
  Scenario: Eleven open rows are matched by site, unit, primary debtor and period
    Given the clock is frozen on 2027-04-10 in Europe/Istanbul after the final receipts
    When the open receivables are derived from the fixture
    Then exactly these rows are open
      | site | unit  | debtor | period   | principal | fee   | joint owner |
      | A    | A-01  | Ada    | February | 800.00    | 78.67 |             |
      | A    | A-01  | Ben    | April    | 500.00    | 0.00  |             |
      | A    | A-02  | Dan    | February | 750.00    | 73.75 | Cara        |
      | A    | A-02  | Cara   | March    | 1000.00   | 51.67 |             |
      | A    | A-02  | Eli    | April    | 400.00    | 0.00  | Cara        |
      | A    | A-03  | Fay    | February | 1000.00   | 98.33 |             |
      | A    | A-03  | Fay    | March    | 1000.00   | 51.67 |             |
      | B    | B1-01 | Gus    | February | 500.00    | 49.17 |             |
      | B    | B1-01 | Hana   | April    | 500.00    | 0.00  |             |
      | B    | B2-01 | Juno   | February | 750.00    | 73.75 | Ivan        |
      | B    | B2-01 | Juno   | March    | 750.00    | 38.75 | Ivan        |
    And every other accrued charge is settled

  @SC-13-25-03 @layer:harness @core @linked
  Scenario: Homeowner totals separate primary debt from joint exposure
    Given the open receivables on 2027-04-10
    Then Fay has 2150.00 of open primary debt: 2000.00 principal and 150.00 fees
    And Cara has 1051.67 of open primary debt and joint exposure to 1223.75 of tenant debt
    And Ivan has 0.00 of open primary debt and joint exposure to 1612.50 of tenant debt
    And the former owners Ada and Gus have 878.67 and 549.17 of open primary debt
    And the current owners Ben and Hana have 500.00 each

  @SC-13-25-04 @layer:harness @core @linked
  Scenario: Site totals are reconciled independently and count a joint receivable once
    Given the fixture inputs and the late fee rule
    When accrued, collected and open principal and collected and open fees are computed per site
    Then Site A shows 96000.00 accrued, 90550.00 collected, 5450.00 open principal, 108.50 fees collected, 354.09 fees open and 5804.09 total debt open
    And Site B shows 192000.00 accrued, 189500.00 collected, 2500.00 open principal, 38.75 fees collected, 161.67 fees open and 2661.67 total debt open
    And collected principal plus collected fees equals the posted cash of each site

  @SC-13-25-05 @layer:harness @core @linked
  Scenario: Final period status distinguishes partial payment from a missed payment
    Given the open receivables on 2027-04-10
    Then the period statuses are
      | unit  | January | February | March  | April   |
      | A-01  | Paid    | Partial  | Paid   | Partial |
      | A-02  | Paid    | Partial  | Unpaid | Partial |
      | A-03  | Paid    | Unpaid   | Unpaid | Paid    |
      | B1-01 | Paid    | Partial  | Paid   | Partial |
      | B2-01 | Paid    | Unpaid   | Unpaid | Paid    |
    And A-01 is partial for January at the January 10 checkpoint

  @SC-13-25-06 @layer:backend @linked
  Scenario: Site operating cash matches posted receipts and a Site A payment does not leak into Site B
    Given the journey sites exist with 0.00 cash
    When Site B cash is captured immediately before and after a Site A payment
    Then Site B cash is unchanged and Site A cash grows by exactly the payment
    And at each checkpoint both sites' posted operating cash equals the independent reconciliation

  @SC-13-25-07 @layer:backend @linked
  Scenario: The manager statements match the eleven open rows and the site totals on 2027-04-10
    Given the journey is posted through the final receipts with the clock on 2027-04-10
    When the manager reads the unit statements including former debtors
    Then the eleven open rows and the Site A and Site B totals equal the independent reconciliation
    And a failure names the site, period, unit and debtor
