@EPIC-12 @STORY-12-09
Feature: Person import from Excel
  A site manager registers many owners from an Excel (.xlsx) or CSV file and starts from a downloadable template.

  @SC-12-09-01 @layer:gui @linked @core @role_manager
  Scenario: The Excel template matches the import columns
    Given the manager opens the person import page
    When the manager downloads the Excel template
    Then the workbook holds the import columns in order and one example row

  @SC-12-09-02 @layer:gui @linked @core @role_manager
  Scenario: A file that is not an Excel workbook is rejected
    Given the manager picks a file named like an Excel workbook that is not one
    When the file is read
    Then the import page shows an error and keeps the previous content
