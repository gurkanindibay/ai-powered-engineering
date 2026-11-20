@EPIC-13 @STORY-13-14
Feature: Liability follows titles, vacancies and move-ins across four billing periods (issue #249)
  Five units on two sites follow the approved journey analysis
  (docs/testing/journey-plan/zero-to-multi-site-financial-journey.md): Site A charges 1,000.00 and Site B 750.00
  per period, accrued on the first of January to April 2027 (Europe/Istanbul) after that day's title and
  occupancy changes, with payments on the 10th. A-01 and B1-01 pass through successive OWNER debtors, A-02
  through successive TENANT debtors and an owner liability while vacant, A-03 stays with Fay when she moves out,
  B2-01 never changes. The 83 filler owner-occupants and zero-site onboarding are covered by #247 and #248.
  Executed by e2e/tests/test_journey_liability_changes.py on two isolated sites created in the test.

  Background:
    Given the scenario clock follows the fixture timeline in Europe/Istanbul
    And two isolated sites with the units "A-01", "A-02", "A-03", "B1-01" and "B2-01" and their owners and tenants

  @SC-13-14-01 @layer:backend @core @role_manager @linked
  Scenario: Titles and occupancies change on their effective dates
    Given the units were billed for "Ocak 2027" and "Şubat 2027"
    When on 2027-03-01 "A-01" is sold to "Ben Bilgin" who moves in and "B1-01" is sold to "Hana Hanci" who leaves it vacant
    And "Dan Demir" moves out of "A-02" and "Fay Fidan" moves out of "A-03" while keeping title
    Then the ownership of "A-01" and "B1-01" ends for the seller on 2027-03-01 and starts for the buyer on that date
    And the occupancies of "A-02" and "A-03" are closed on 2027-03-01 and the title of "A-03" stays with "Fay Fidan"
    And the household of "Ada Aksoy" and of "Dan Demir" is archived under their closed occupancies
    And the current rosters of "A-01" and "A-02" are empty and "B2-01" is unchanged

  @SC-13-14-02 @layer:backend @core @role_manager @linked
  Scenario: March charges follow the new owners and the vacancies
    Given the changes of 2027-03-01 were made
    When the manager accrues "Mart 2027"
    Then "A-01" is billed 1000.00 to its owner "Ben Bilgin", "A-02" and "A-03" 1000.00 to their owners "Cara Cetin" and "Fay Fidan"
    And "B1-01" is billed 750.00 to its owner "Hana Hanci" and "B2-01" 750.00 to its tenant "Juno Jale"
    And the February charges of "Ada Aksoy", "Dan Demir" and "Gus Gunes" keep their role and amount
    And the ledger invariants hold on both sites

  @SC-13-14-03 @layer:backend @core @role_manager @linked
  Scenario: April move-ins redirect new charges and show only the current household
    Given the March accrual was posted
    When on 2027-04-01 "Eli Erdem" and a linked household member move into "A-02" and "Hana Hanci" moves into "B1-01"
    And the manager accrues "Nisan 2027"
    Then "A-02" is billed 1000.00 to its tenant "Eli Erdem" and the current roster is only Eli's household
    And "B1-01" is billed to its owner "Hana Hanci" and "A-03" stays vacant and is billed to its owner "Fay Fidan"
    And the household archived under "Dan Demir" is unchanged and the added member receives no charge

  @SC-13-14-04 @layer:backend @core @role_manager @linked
  Scenario: Former owners and tenants remain collectible next to their successors
    Given the March accrual was posted and no March payment was made
    Then the statement of "A-01" lists 800.00 for "Şubat 2027" and 1000.00 for "Mart 2027"
    And the statement of "A-02" lists a tenant charge of 750.00 for "Şubat 2027" and an owner charge of 1000.00 for "Mart 2027"
    And the statement of "B1-01" lists 500.00 for "Şubat 2027" and 750.00 for "Mart 2027"
    And each overdue predecessor charge keeps accruing its late fee

  @SC-13-14-05 @layer:backend @core @role_manager @linked
  Scenario: Receipts before the changes settle the paying debtor's own periods
    When the receipts of January and February are posted by "Ada Aksoy", "Dan Demir" and "Gus Gunes"
    Then "Ada Aksoy" 831.00 pays 31.00 in fees and 600.00 of January and then 200.00 of February
    And "Dan Demir" 1301.67 pays 1000.00 and 51.67 of January and 250.00 of February
    And the posted operating cash of each site equals its cumulative gross receipts

  @SC-13-14-06 @layer:backend @core @role_manager @linked
  Scenario: A designated April receipt leaves February and March unpaid
    Given "Fay Fidan" and "Juno Jale" paid January and skipped February and March
    When each pays April with the receipt designated to "Nisan 2027"
    Then each receipt has exactly one allocation, to "Nisan 2027", with no fee
    And February and March stay fully unpaid and keep their own fees, 98.33 and 51.67 for "A-03", 73.75 and 38.75 for "B2-01"
    And the period history shows January paid, February and March unpaid, and April unpaid before and paid after its receipt

  @SC-13-14-07 @layer:backend @core @role_manager @linked
  Scenario: Title changes, vacancies and accruals move no cash between sites
    When the journey runs from January to the April 10 receipts
    Then the title transfers, move-outs and accruals change no cash balance
    And no receipt of one site changes the other site's posted operating cash

  # Defect #255: the receipt is allocated by debtor role, so it settles the predecessor's open charges first.
  # The linked tests are strict xfails that keep these expectations; they must be removed when #255 is fixed.
  @SC-13-14-08 @layer:backend @core @role_manager @linked @defect:255
  Scenario Outline: A successor's receipt settles only the successor's own charges
    Given all receipts before "<month>" 10 were posted
    When "<payer>" pays on 2027-<date> to "<unit>"
    Then every allocation of the receipt is a charge owed by "<payer>": <allocation>
    And the principal, fees and payment history of the other debtors of "<unit>" are identical before and after

    Examples:
      | unit  | payer | month | date  | allocation                                           |
      | A-01  | Ben   | Mart  | 03-10 | 500.00 of Mart 2027                                  |
      | A-01  | Ben   | Nisan | 04-10 | Mart 500.00 and 25.83 fee, Nisan 500.00              |
      | A-02  | Eli   | Nisan | 04-10 | Nisan 600.00                                         |
      | B1-01 | Hana  | Nisan | 04-10 | Mart 750.00 and 38.75 fee, Nisan 250.00              |

  # Defect #255: Ada's, Dan's and Gus's February charges are settled by their successors' receipts.
  @SC-13-14-09 @layer:backend @core @role_manager @linked @defect:255
  Scenario: The final open debt stays with each former and current debtor
    Given the April 10 receipts were posted
    Then the open principal and fee per unit and period are
      | unit  | period | principal | fee   |
      | A-01  | Şubat  | 800.00    | 78.67 |
      | A-01  | Nisan  | 500.00    | 0.00  |
      | A-02  | Şubat  | 750.00    | 73.75 |
      | A-02  | Mart   | 1000.00   | 51.67 |
      | A-02  | Nisan  | 400.00    | 0.00  |
      | A-03  | Şubat  | 1000.00   | 98.33 |
      | A-03  | Mart   | 1000.00   | 51.67 |
      | B1-01 | Şubat  | 500.00    | 49.17 |
      | B1-01 | Nisan  | 500.00    | 0.00  |
      | B2-01 | Şubat  | 750.00    | 73.75 |
      | B2-01 | Mart   | 750.00    | 38.75 |
    And Site A has 5450.00 principal and 354.09 fees open and Site B has 2500.00 principal and 161.67 fees open

  # Pending: the jointly liable owner (KMK m.22/1) of a tenant's charge is listed only for tenant rows that carry
  # a joint-liability record; the journey's accrual does not create one, so Cara's 1223.75 and Ivan's 1612.50
  # exposure cannot be asserted yet (see the pending joint liability scenarios of STORY-13-03).
  @SC-13-14-10 @layer:backend @core @role_manager @pending
  Scenario: Owners keep joint exposure to their tenants' open charges without double counting
    Given the April 10 receipts were posted
    Then "Cara Cetin" has 1051.67 of total open primary debt and joint exposure to 1223.75 of tenant debt
    And "Ivan Ilhan" has 0.00 of total open primary debt and joint exposure to 1612.50 of tenant debt
    And primary debt and joint exposure add to the site total only once
