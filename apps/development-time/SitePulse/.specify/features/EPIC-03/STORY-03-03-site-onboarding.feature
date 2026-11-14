@EPIC-03 @STORY-03-03
Feature: New site onboarding and tenant provisioning workflow
  A freshly signed site and its primary site admin are registered in one flow.

  @SC-03-03-01 @GUI-03-02 @layer:gui @linked @smoke @role_saas
  Scenario: SaaS Admin creates new site and provisions first Site Admin
    Given SaaS Admin fills onboarding form for "Palmiye Evleri Sitesi" (Kadıköy, İstanbul, 40 Daire, Pro Paket)
    And provides Primary Site Admin details ("Murat Yıldırım", "murat@palmiyesitesi.com", "0532 444 55 66")
    When submitting the registration
    Then a new site record is created with active status and unique slug "palmiye-evleri-sitesi"
    And a new user is created with role "SITE_MANAGER" bound to this site_id
    And the new site card appears in the SaaS admin portfolio list
