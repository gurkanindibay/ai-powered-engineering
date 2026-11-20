@EPIC-08 @STORY-08-05
Feature: Title deed transfer and ownership sale handover
  A sale closes the previous owner's profile and leaves the tenant untouched.

  @SC-08-05-01 @GUI-08-06 @layer:gui @linked @core @role_manager
  Scenario: Change property owner upon title deed sale without affecting tenant
    Given Unit "A Blok D:14" has Tenant "Canan Kaya" and Owner "Ahmet Yılmaz"
    When the Site Manager registers a Title Deed Transfer to New Owner "Selim Evsahibi" effective 2026-10-28
    Then Ahmet Yılmaz is archived as historical property owner with closing balance
    And Selim Evsahibi becomes the active owner_person_id for Unit "A Blok D:14"
    And Canan Kaya remains the active tenant with zero interruption to her occupancy session

  @SC-08-05-02 @layer:gui @linked @core @role_manager
  Scenario: Capital dues after the transfer are billed to the new owner
    Given Unit "A Blok D:14" was transferred to "Selim Evsahibi" effective 2026-10-28
    When a capital assessment is accrued for the unit
    Then the CAPITAL_DUES liability is charged to Selim Evsahibi

  @SC-08-05-03 @GUI-08-15 @layer:gui @linked @role_manager
  Scenario: Previous owner's advance is paid out or transferred only with a second approver
    Given the previous owner has 800.00 in the unit's owner advance ledger
    When the Site Manager requests a 500.00 transfer of that advance to the tenant ledger
    Then the request stays pending until a different authorized person approves it
    And approval moves 500.00 from the owner advance to the tenant advance in one audited transaction

  @SC-08-05-04 @layer:backend @linked @core @role_manager
  Scenario: The sale clearance statement shows what stays with the seller and what goes to the buyer
    Given the seller owes "Kasım 2026" 1500.00 with fee 100.00, "Aralık 2026" 1500.00 with fee 25.00 and installment 1 of 2000.00 with fee 33.33
    And installments 2 and 3 of the capital project are not accrued
    When the manager opens the sale clearance of the unit effective 2026-12-20
    Then it shows open debt 5158.33 with principal 5000.00 and fee 158.33 apart, and the seller's advance
    And it lists installments 2 and 3 of 2000.00 each as not yet accrued
    And the total equals the sum of the seller's outstanding liabilities in the ledger
    And the statement can be downloaded as CSV

  @SC-08-05-05 @layer:backend @linked @core @role_manager
  Scenario: A mid-month sale of an owner-occupied unit splits that month by days through the split correction
    Given the unit is owner-occupied and "Aralık 2026" operational dues of 1500.00 are due 2026-12-10
    When the manager transfers title effective 2026-12-20 and the buyer moves in
    Then a four-eyes split correction proposes 919.35 to the seller and 580.65 to the buyer
    And approval by a different manager re-issues the two shares, the buyer's due 2026-12-20, adding up to 1500.00

  @SC-08-05-06 @layer:backend @linked @core @role_manager
  Scenario: Capital installments follow the owner at accrual unless a seller-pays override is approved
    Given the unit was sold and the buyer is the owner on record
    When an installment is accrued with no override, with a pending request or with a rejected request
    Then it is billed to the buyer
    When a different manager approves the seller-pays override and the next installment is accrued
    Then that installment is billed to the seller and earlier installments stay where they were

  @SC-08-05-07 @layer:backend @linked @edge @role_manager
  Scenario: The seller-pays override cannot be approved by its requester
    Given a seller-pays override request is pending
    When its requester tries to approve it
    Then it is refused and the request stays pending

  @SC-08-05-08 @layer:backend @linked @edge @role_manager
  Scenario: Invalid seller-pays override leaves the transfer unchanged
    Given the unit has a current seller and a different buyer
    When the manager transfers title with an override reason shorter than five characters
    Then the transfer is refused before ownership changes
    And no seller-pays override request is created

  @SC-08-05-09 @layer:backend @linked @edge @role_manager
  Scenario: A duplicate pending override leaves the seller in place
    Given a seller-pays override for the unit and buyer is already pending
    When the manager transfers title to that buyer with an override reason
    Then the request is refused with a conflict and the seller remains the owner
    And a transfer that fails after the request was stored discards that request again
