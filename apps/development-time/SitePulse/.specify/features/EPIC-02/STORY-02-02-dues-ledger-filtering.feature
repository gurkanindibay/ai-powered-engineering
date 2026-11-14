@EPIC-02 @STORY-02-02
Feature: Flat-by-flat dues ledger and filtering
  The ledger lists every flat and can be filtered by overdue status.

  @SC-02-02-01 @GUI-02-02 @layer:gui @linked @core @role_manager
  Scenario: Overdue filter lists every overdue flat
    Given flats with overdue dues and a flat that paid
    And the Site Manager is on the dues center
    When the "Geciken" filter is selected
    Then only the overdue flats are listed and the filter count equals their number

  @SC-02-02-02 @pending @core @role_manager
  Scenario: Overdue flats show the exact days overdue in a red badge
    Given the flat A Blok D:14 is 14 days overdue and B Blok D:8 is 8 days overdue
    When the "Gecikmede" filter is selected
    Then each overdue flat shows its exact days overdue with a red badge
