@EPIC-11 @STORY-11-07
Feature: Vendors, invoices, ledger and yearly account report
  Vendors, invoices, ledger and yearly account report.

  @SC-11-07-01 @layer:backend @linked
  Scenario: Expense approval needs four eyes and the auditor threshold
    Given an expense entered by a manager
    When it is approved
    Then a second person is required and the auditor threshold applies

  @SC-11-07-02 @layer:backend @linked
  Scenario: Trial balance balances and receivables equal open dues
    Given a derived ledger
    When the trial balance is computed
    Then debits equal credits and receivables equal the open dues

  @SC-11-07-03 @layer:api @linked
  Scenario: Finance desk works over HTTP
    Given a running backend
    When the finance desk API check runs
    Then the ledger, dunning, analytics, four-eyes and isolation checks pass
