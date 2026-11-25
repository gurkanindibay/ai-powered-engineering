@EPIC-13 @STORY-13-06
Feature: One site from zero to a closed period (interconnected chain)
  Run this as one scenario. Report each numbered checkpoint using the existing journey
  reporter. The fixture finalizer runs even if a checkpoint fails.

  @SC-13-06-01 @J-13 @GUI-13-17 @depth:8 @chain:site-lifecycle @state:F0 @layer:gui @smoke @core @role_manager @linked
  Scenario: A manager grows a new site, collects dues and closes a period
    Given the clock is set to "2026-09-01 09:00" Europe/Istanbul
    And a SaaS admin has onboarded a site and manager unique to this scenario attempt
    And the manager has signed in with a permanent password
    And proration is enabled for the site
    And the site is in state F0
    When the manager adds block "A Blok" with units A-1 to A-7 and tariffs 1500.00 (A-6: 2250.00)
    Then checkpoint 1 shows state F1 and the ledger invariants hold
    When the manager adds the owners and tenants of state F2
    Then checkpoint 2 shows state F2 and the ledger invariants hold
    When the manager creates and accrues "Eylül 2026" due "2026-09-10"
    Then checkpoint 3 shows 6 charged units and total outstanding 9750.00
    And the ledger invariants hold
    When "Ayşe Kaya" pays 1500.00 and "Elif Aydın" pays 8000.00 on "2026-09-01"
    Then checkpoint 4 shows "Ayşe Kaya" owes 0.00 and "Elif Aydın" holds advance 5750.00
    And the ledger invariants hold
    When the manager accrues October and November in order and the remaining F5 payments are made on their dates
    And the clock advances to "2026-11-19 12:00" Europe/Istanbul
    Then checkpoint 5 shows state F5 including outstanding 11117.50 and advance 1250.00
    And the ledger invariants hold
    When the manager closes "Eylül 2026"
    Then checkpoint 6 shows a saved CLOSED snapshot, rejects a second accrual and keeps September debt collectable
    And the ledger invariants hold
    When the clock advances to "2026-12-01" and tenant "Selin Demir" is replaced by "Mert Kılıç" in "A-2"
    And the manager transfers title of "A-4" from "Ahmet Yılmaz" to "Gül Tanrıverdi" with the same effective date
    Then checkpoint 7 shows the outgoing debtors' pre-December debts still attached to them
    And neither incoming debtor inherits the outgoing debtor's balance or advance
    And the closed snapshot is unchanged and the ledger invariants hold
    When the backend is restarted at the same clock instant
    Then checkpoint 8 shows the same scoped balances and close snapshot in the API and on the screens visited
    And separate sessions verify each resident sees only their own scope and another manager sees no site data
