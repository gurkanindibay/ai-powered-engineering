@EPIC-02 @STORY-02-02
Feature: Flat-by-flat dues ledger and filtering
  The ledger lists every flat and can be filtered by overdue status.

  @SC-02-02-01 @GUI-02-02 @layer:gui @linked @core @role_manager
  Scenario: Overdue filter lists every overdue flat
    Given flats with overdue dues and a flat that paid
    And the Site Manager is on the dues center
    When the "Geciken" filter is selected
    Then only the overdue flats are listed and the filter count equals their number

  # Verified in the browser by test_overdue_badge_shows_the_exact_days_overdue.
  @SC-02-02-02 @GUI-02-02 @layer:gui @linked @core @role_manager
  Scenario: Overdue flats show the exact days overdue in a red badge
    Given the flat A Blok D:14 is 14 days overdue and B Blok D:3 is 8 days overdue
    When the "Geciken" filter is selected
    Then each overdue flat shows its exact days overdue with a red badge
