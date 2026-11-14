@EPIC-09 @STORY-09-03
Feature: Debt aging, delinquency tracking and sub-ledger statement
  Tenant and property owner each get a separate itemized sub-ledger statement,
  and overdue dues are aged into delinquency buckets.

  @SC-09-03-01 @GUI-09-03 @layer:gui @core @role_manager @linked
  Scenario: Generate itemized sub-ledger statement for a tenant
    Given tenant "Canan Kiracı" in "B Blok D:99"
    When the site manager requests the tenant sub-ledger statement
    Then the statement only includes operational dues, payments made by the tenant and delay interest
    And capital dues assessed to the property owner are excluded
    And the net balance is displayed with the statutory interest breakdown

  @SC-09-03-02 @GUI-09-03 @layer:gui @core @role_homeowner @linked
  Scenario: Resident statement ages an overdue due with its penalty
    Given a resident has an overdue operational due with a delay penalty
    When the resident opens the statement
    Then the overdue due is shown in its delinquency bucket together with the penalty
