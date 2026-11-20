@EPIC-09 @STORY-09-07
Feature: Change of ownership and title deed financial handover
  A property sale freezes the old owner's liabilities and binds the new owner
  from the deed transfer date, leaving the tenancy untouched.

  @SC-09-07-01 @layer:gui @core @role_manager @linked
  Scenario: Property ownership transfer freezes old owner balance and binds new owner
    Given unit "B Blok D:10" is owned by "Ahmet Yılmaz" with 2500.00 unpaid capital dues
    When the site manager registers a title deed transfer to "Burak Demir" effective 2026-10-28
    Then the old owner's sub-ledger is frozen with 2500.00 historical capital liability
    And the new owner is assigned as current property owner from 2026-10-28 with 0.00 initial balance
    And all future capital dues and vacant period charges are billed to the new owner
    And active tenant records and operational dues remain unaffected

  @SC-09-07-02 @layer:backend @core @role_manager @linked
  Scenario: A successor's receipt cannot settle a predecessor's same-role liability
    Given the predecessor and successor have separate owner liabilities for the same unit
    When the successor pays an undesignated receipt
    Then the receipt settles only liabilities belonging to the successor
    And the predecessor's principal, fees and payment history remain unchanged

  @SC-09-07-03 @layer:backend @core @role_manager @linked
  Scenario: A former owner's receipt requires designation before allocation
    Given the former and current owners have separate open liabilities for the same unit
    When the former owner submits a receipt without a liability designation
    Then the receipt is rejected without changing either owner's balance
    When the former owner resubmits with the former liability explicitly designated
    Then the receipt settles only the designated former owner's liability
    And the current owner's balance remains unchanged

  @SC-09-07-04 @layer:backend @core @role_manager @linked
  Scenario: A former tenant's receipt requires designation before allocation
    Given the former and current tenants have separate open liabilities for the same unit
    When the former tenant submits a receipt without a liability designation
    Then the receipt is rejected without changing either tenant's balance
    When the former tenant resubmits with the former liability explicitly designated
    Then the receipt settles only the designated former tenant's liability
    And the current tenant's balance remains unchanged
