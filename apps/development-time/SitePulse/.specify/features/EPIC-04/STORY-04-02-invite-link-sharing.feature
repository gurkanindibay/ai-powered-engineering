@EPIC-04 @STORY-04-02
Feature: Quick action and modal bottom sheet link sharing
  The manager shares the invitation link by copying it or through WhatsApp.

  @SC-04-02-01 @GUI-04-01 @layer:gui @linked @core @role_manager
  Scenario: Site Admin copies or shares invite link
    Given the Site Manager taps "Davet Linki"
    When the modal opens
    Then display the invitation URL with copy and WhatsApp share buttons
    And tapping "Linki Kopyala" copies the URL to the clipboard with confirmation

  @SC-04-02-02 @GUI-04-08 @layer:gui @linked @edge @role_manager
  Scenario: Empty approval queue shows an empty state
    Given no pending registration requests
    When the site manager views the dashboard
    Then "Onay Bekleyen Başvuru Bulunmuyor" is displayed
