@EPIC-11 @STORY-11-09
Feature: Payer hints and daily bank reconciliation
  Payer hints and daily bank reconciliation.

  @SC-11-09-01 @layer:backend @linked
  Scenario: Transfer bypassing the virtual IBAN is ranked by phone and block-unit hints
    Given a transfer outside the virtual IBAN
    When hints are evaluated
    Then phone and block/unit hints rank the candidate units

  @SC-11-09-02 @layer:backend @linked
  Scenario: Daily reconciliation stores differences and unmatched lines
    Given a bank statement with differences
    When the daily reconciliation runs
    Then differences and unmatched lines are stored
