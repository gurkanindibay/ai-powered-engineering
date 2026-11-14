@EPIC-11 @STORY-11-02
Feature: Privacy notice, channel consents and retention
  Privacy notice, channel consents and retention.

  @SC-11-02-01 @layer:backend @linked
  Scenario: Residents acknowledge the privacy notice and set channel consents
    Given a published privacy notice
    When a resident acknowledges it and sets channel consents
    Then the acknowledgement and each channel consent are stored

  @SC-11-02-02 @layer:backend @linked
  Scenario: Debtor exports are masked for non-staff roles and logged
    Given a debtor list containing personal data
    When a non-staff role exports the debtors
    Then names are masked and every export is logged

  @SC-11-02-03 @layer:backend @linked
  Scenario: Ledger records are kept ten years and old logs are purged
    Given records older than the retention horizon
    When retention is reviewed
    Then ledger records are kept for ten years and expired logs are purged

  @SC-11-02-04 @layer:flutter @linked
  Scenario: Privacy status lists consents per channel in the app
    Given a privacy status response with an SMS consent withdrawn
    When the Flutter domain parses it
    Then the notice version and each channel consent are exposed
