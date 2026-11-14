@EPIC-10 @STORY-10-07
Feature: Capital segment in the site manager cockpit
  The manager reaches capital projects from dues management and finds the
  project, disbursement and accrual actions there.

  @SC-10-07-01 @GUI-10-01 @layer:gui @linked
  Scenario: Capital segment offers project creation
    Given the site manager is on the dues management tab
    When the manager selects the capital projects segment
    Then the view displays:
      | Active capital projects summary (total budget, collected %, disbursed %) |
      | Unit-by-unit capital debt and payment status table                      |
      | Action button "Yeni Demirbaş Projesi Tanımla"                           |
      | Action button "Hakediş / Gider Çıkışı Yap"                              |
      | Action button "Taksit Tahakkuk Ettir"                                   |
