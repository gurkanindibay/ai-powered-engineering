@EPIC-02 @STORY-02-04
Feature: Targeted payment reminder and resident direct messaging
  The manager reminds overdue residents from the payment tracking view.

  @SC-02-04-01 @GUI-02-06 @layer:gui @linked @core @role_manager
  Scenario: Reminder action is offered for overdue flats
    Given an overdue flat A Blok D:14 in the manager ledger
    When the manager opens the aging segment
    Then a reminder button is shown

  @SC-02-04-02 @pending @core @role_manager
  Scenario: Send reminder to overdue resident
    Given an overdue flat A Blok D:14 in the manager ledger
    When the manager taps "Hatırlat" and confirms the notice
    Then an in-app confirmation tells the manager the notice was dispatched
