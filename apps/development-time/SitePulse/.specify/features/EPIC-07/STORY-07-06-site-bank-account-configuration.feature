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

  @SC-07-06-03 @GUI-07-11 @layer:gui @core @role_manager
  Scenario Outline: Excel upload offers a sample for each catalogued Excel bank
    Given the supported-bank catalogue contains bank "<bank_code>" with format "EXCEL"
    And the manager opens Excel / statement upload
    When the sample workbook options are displayed
    Then a downloadable sample workbook is shown for "<bank_name>"
    And the downloaded workbook is a valid Excel file with fictional transaction rows
    And uploading the sample does not settle or mutate real dues

    Examples:
      | bank_code  | bank_name                 |
      | KUVEYT_TURK | Kuveyt Türk Katılım Bankası |
      | YAPI_KREDI  | Yapı Kredi Bankası          |

  @SC-07-06-04 @GUI-07-12 @layer:gui @linked @edge @role_manager
  Scenario: Excel sample options exclude banks without an Excel format
    Given the supported-bank catalogue contains banks with CSV and MT940 formats
    And the manager opens Excel / statement upload
    When the sample workbook options are displayed
    Then no Excel sample is shown for any CSV or MT940 bank
    And no sample is shown for a bank absent from the supported-bank catalogue
    And the sample section is hidden when the catalogue has no Excel banks
