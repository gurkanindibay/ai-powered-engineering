@EPIC-02 @STORY-02-05
Feature: Site-wide announcement broadcasting
  The manager publishes announcements that reach the residents' feeds.

  @SC-02-05-01 @GUI-02-07 @layer:gui @linked @core @role_manager
  Scenario: Manager creates an announcement
    Given the Site Manager taps "Duyuru Yap"
    When entering title "Planlı Su Kesintisi" and details and publishing
    Then an ANNOUNCEMENT notification with that subject is stored

  # Verified in the browser by test_published_announcement_appears_on_the_resident_feed.
  @SC-02-05-02 @GUI-02-07 @layer:gui @linked @core @role_manager
  Scenario: Announcement appears on the resident feed
    Given the manager published "Planlı Su Kesintisi"
    When a resident opens the announcement feed
    Then the announcement is listed
