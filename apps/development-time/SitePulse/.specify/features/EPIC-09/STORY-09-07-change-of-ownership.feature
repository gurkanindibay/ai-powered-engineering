@EPIC-09 @STORY-09-07
Feature: Change of ownership and title deed financial handover
  A property sale freezes the old owner's liabilities and binds the new owner
  from the deed transfer date, leaving the tenancy untouched.

  @SC-09-07-01 @layer:gui @core @role_manager @pending
  Scenario: Property ownership transfer freezes old owner balance and binds new owner
    Given unit "B Blok D:10" is owned by "Ahmet Yılmaz" with 2500.00 unpaid capital dues
    When the site manager registers a title deed transfer to "Burak Demir" effective 2026-10-28
    Then the old owner's sub-ledger is frozen with 2500.00 historical capital liability
    And the new owner is assigned as current property owner from 2026-10-28 with 0.00 initial balance
    And all future capital dues and vacant period charges are billed to the new owner
    And active tenant records and operational dues remain unaffected
