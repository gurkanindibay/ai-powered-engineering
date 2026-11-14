@EPIC-04 @STORY-04-01
Feature: Tokenized invitation link generation API
  The site manager obtains a time-limited, URL-safe, unique invitation link for the site.

  @SC-04-01-01 @GUI-04-01 @layer:gui @linked @smoke @role_manager
  Scenario: Generate 7-day secure invite link
    Given an authenticated Site Manager for "Begonya Sitesi" (slug: "begonya-sitesi")
    When requesting an invitation link
    Then generate a token with 7-day expiry
    And return URL formatted as "https://sitepulse.app/join/begonya-sitesi?token=SP-INV-XXXX"
