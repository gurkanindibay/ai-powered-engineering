@EPIC-07 @STORY-07-04
Feature: Virtual IBAN and FAST payment resident experience
  Residents pay by FAST transfer to a clear, copyable virtual IBAN.

  @SC-07-04-01 @GUI-07-02 @layer:gui @linked @core @role_homeowner
  Scenario: Resident chooses the FAST transfer payment method
    Given resident "Ahmet Yılmaz" opens the "Hemen Öde" dialog
    When they select the FAST transfer option
    Then the dialog shows the dedicated virtual IBAN with the "no description needed" explanation

  @SC-07-04-02 @GUI-07-01 @layer:gui @linked @core @role_homeowner
  Scenario: Copy button puts the unspaced IBAN on the clipboard
    Given the resident dashboard shows the spaced 26-character virtual IBAN
    When the resident taps the copy button
    Then the clipboard holds the unspaced IBAN
    And a toast confirms the copy
