@EPIC-07 @STORY-07-05
Feature: Advance payment allocation, surplus balance and auto-offset
  Surplus transfers become an advance balance that offsets future dues (FIFO).

  @SC-07-05-01 @GUI-07-09 @layer:gui @linked @core @role_homeowner
  Scenario: Surplus transfer is allocated to the resident advance balance
    Given the resident has an outstanding due of 1400.00
    When the resident transfers 2860.67 via the virtual IBAN
    Then the debt is paid and the remainder is recorded as advance payment
    And the hero balance card shows the advance in the advance style with an advance pill

  @SC-07-05-02 @layer:gui @linked @core
  Scenario: A newly accrued period is offset by the advance balance
    Given a resident has an advance payment balance
    When a new dues period is accrued
    Then the new dues are automatically offset against the advance balance
