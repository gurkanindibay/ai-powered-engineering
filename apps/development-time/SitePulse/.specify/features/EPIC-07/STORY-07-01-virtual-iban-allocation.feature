@EPIC-07 @STORY-07-01
Feature: Flat-specific virtual IBAN allocation
  Every unit gets a unique virtual IBAN under the site's collection account,
  stored immutably and shown on the resident dashboard.

  @SC-07-01-01 @layer:gui @linked @core @role_manager
  Scenario: Automated allocation of a virtual IBAN upon unit setup
    Given a new flat "A Blok Daire 14" is registered in "Begonya Sitesi"
    When the virtual IBAN generation service is triggered
    Then a valid 26-character TR virtual IBAN with correct check digits is generated
    And the IBAN is unique and stored against the unit

  @SC-07-01-02 @layer:gui @linked @core @role_homeowner
  Scenario: Resident dashboard includes the allocated virtual IBAN
    Given unit "A Blok D:14" has an allocated virtual IBAN
    When the resident dashboard is queried
    Then the dashboard contains the dedicated virtual IBAN of the unit
