@EPIC-07 @STORY-07-06
Feature: Site bank account configuration and statement format enforcement
  The configured bank fixes the statement format; mismatching uploads are rejected.

  @SC-07-06-01 @layer:gui @linked @core @role_manager
  Scenario: Configuring the bank account sets the statement format automatically
    Given the site manager configures bank "KUVEYT_TURK" with a valid IBAN
    When the configuration is saved
    Then the active statement format is set by the bank

  @SC-07-06-02 @GUI-07-07 @layer:gui @linked @core @role_manager
  Scenario: Wrong statement format is rejected and the matching format is accepted
    Given the site statement format is EXCEL
    When the manager uploads an MT940 statement
    Then the upload is rejected with a format mismatch error and nothing is queued
    And uploading a matching Excel statement succeeds
