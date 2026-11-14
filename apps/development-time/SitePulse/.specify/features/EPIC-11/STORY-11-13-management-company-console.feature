@EPIC-11 @STORY-11-13
Feature: Portfolio summary and fee invoices
  Portfolio summary and fee invoices.

  @SC-11-13-01 @layer:backend @linked
  Scenario: Each period is invoiced once and only members see the portfolio
    Given a management company with sites
    When fee invoices are generated for a period
    Then each period is invoiced once and only members see the portfolio
