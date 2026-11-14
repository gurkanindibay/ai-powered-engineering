@EPIC-04 @STORY-04-05
Feature: One-tap approval and resident credential provisioning
  Approving an applicant activates the account and issues a resident password.

  @SC-04-05-01 @GUI-04-03 @layer:gui @linked @smoke @role_manager
  Scenario: Approve applicant and provision account
    Given pending application for "Kerem Yılmaz" (B Blok D:18)
    When Site Manager taps "✓ Onayla & Şifre Üret"
    Then account is activated with generated password "SP-SAKIN-XXXX"
    And confirmation dialog displays credentials
    And Kerem Yılmaz appears in the site dues ledger
    And pending badge decrements from 2 to 1

  @SC-04-05-02 @GUI-04-05 @layer:gui @linked @core @role_resident
  Scenario: Approved resident signs in with the issued password
    Given the applicant "Kerem Yılmaz" was approved with a generated password
    When the resident logs in with the issued password
    Then a password change is forced
    And the dashboard for B Blok D:18 is shown
