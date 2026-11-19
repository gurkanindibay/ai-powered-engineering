@EPIC-13 @STORY-13-02
Feature: Accrual histories F4, F5 and F7
  One period, several periods with single or multiple debts, and a closed period.
  Balances are principal + KMK late fee at the frozen clock 2026-11-19 (README section 2).

  Background:
    Given the clock is frozen at "2026-11-19 12:00" Europe/Istanbul
    And a SaaS admin has onboarded a site "e2e-j02" with manager "manager@e2e.test"
    And the manager has signed in with a permanent password

  # ------------------------------------------------------ F4 SINGLE_PERIOD

  @SC-13-02-01 @J-07 @state:F4 @layer:gui @smoke @core @role_manager @pending
  Scenario: Residents with a single accrual period show one debt each on every screen
    Given the site is in state F4
    When the manager opens the collection tracking page
    Then total outstanding is 8800.00 and 5 units are overdue
    And unit "A-1" is paid and units A-2 to A-6 are overdue
    And the debtors are tenant "Selin Demir" 1600.00, owner "Burak Şahin" 1600.00, owner "Ahmet Yılmaz" 1600.00, tenant "Deniz Arslan" 1600.00, owner "Elif Aydın" 2400.00
    And the ledger invariants hold

  @SC-13-02-02 @J-07 @state:F4 @layer:gui @core @role_homeowner @pending
  Scenario: The resident sees exactly what the admin sees for the same unit
    Given the site is in state F4
    When tenant "Selin Demir" signs in
    Then her dashboard shows principal 1500.00, late fee 100.00, total 1600.00 and 40 days overdue
    And the admin unit workspace of "A-2" shows the same three numbers

  @SC-13-02-03 @J-07 @state:F4 @layer:backend @edge @role_manager @pending
  Scenario: The late fee follows the clock day by day
    Given the site is in state F4
    When the clock moves forward one day to "2026-11-20"
    Then the late fee for a 1500.00 liability is 102.50
    And the total outstanding is 8813.75, which is 8800.00 plus 4 x 2.50 and 1 x 3.75

  # -------------------------------------------------------- F5 MULTI_PERIOD

  @SC-13-02-04 @J-08 @state:F5 @layer:gui @smoke @core @role_manager @pending
  Scenario: Multiple periods with mixed debts add up per unit and per site
    Given the site is in state F5
    When the manager opens the collection tracking page
    Then total outstanding is 11117.50
    And the per-unit balance is A-1 0.00, A-2 3122.50, A-3 1675.00, A-4 1522.50, A-5 4797.50, A-6 0.00
    And unit "A-6" shows an advance balance of 1250.00
    And the ledger invariants hold

  @SC-13-02-05 @J-08 @state:F5 @layer:backend @core @role_manager @pending
  Scenario: A single debt in a previous month stays attached to that month
    Given the site is in state F5
    Then unit "A-3" has exactly one open liability: period "Eylül 2026", principal 1500.00, late fee 175.00
    And unit "A-3" has no open liability for "Ekim 2026" or "Kasım 2026"
    And the aging report puts 1675.00 in the "61 days and more" bucket

  @SC-13-02-06 @J-08 @state:F5 @layer:backend @core @role_manager @pending
  Scenario: A single debt in the current month is the only one in the youngest bucket
    Given the site is in state F5
    Then unit "A-4" has exactly one open liability: period "Kasım 2026", principal 1500.00, late fee 22.50
    And the aging report puts 1522.50 in the "0 to 30 days" bucket

  @SC-13-02-07 @J-08 @state:F5 @layer:backend @core @role_manager @pending
  Scenario: Multiple debts across periods are listed oldest first with a fee each
    Given the site is in state F5
    Then unit "A-5" has 3 open liabilities in the order Eylül 2026, Ekim 2026, Kasım 2026
    And their late fees are 175.00, 100.00 and 22.50
    And the total is 4797.50

  @SC-13-02-08 @J-08 @state:F5 @layer:backend @core @role_manager @pending
  Scenario: An advance balance has already offset later periods
    Given the site is in state F5
    Then unit "A-6" has 0 open liabilities, 3 settled liabilities and an advance of 1250.00
    When the manager accrues period "Aralık 2026" with the site tariffs and due date "2026-12-10"
    Then the advance of 1250.00 is applied to the "Aralık 2026" liability of 2250.00
    And the advance becomes 0.00 and 1000.00 of that liability remains open
    And the ledger invariants hold

  @SC-13-02-09 @J-08 @state:F5 @layer:backend @core @role_manager @pending
  Scenario: A fourth accrual adds exactly one liability per responsible debtor
    Given the site is in state F5
    When the manager accrues period "Aralık 2026" due "2026-12-10"
    Then every unit A-1 to A-6 gains exactly one liability and A-7 gains none
    And a repeated accrual of "Aralık 2026" adds nothing
    And the ledger invariants hold

  # ------------------------------------------------------ F7 CLOSED_HISTORY

  @SC-13-02-10 @J-09 @state:F7 @decision @layer:backend @core @role_manager @pending
  Scenario: A closed period accepts no new accrual or edit but keeps its open debts
    Given the site is in state F7
    Then period "Eylül 2026" is CLOSED
    When the manager accrues period "Eylül 2026" again
    Then the request is rejected because the period is closed
    And unit "A-3" still owes its "Eylül 2026" liability of 1500.00
    And its late fee keeps growing with the clock until it is paid

  @SC-13-02-11 @J-09 @state:F7 @layer:backend @edge @role_manager @pending
  Scenario: A payment toward a closed period is still allocated to its oldest debt
    Given the site is in state F7
    When the manager records a manual payment of 1675.00 for unit "A-3"
    Then the "Eylül 2026" liability is settled
    And the ledger invariants hold
