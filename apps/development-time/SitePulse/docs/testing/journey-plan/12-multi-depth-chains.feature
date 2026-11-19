@EPIC-13 @STORY-13-12
Feature: Multi-depth chains across the decided responsibility rules
  Each scenario is a chain of 3 to 5 stages on one site. A stage starts from the exact end
  state of the previous one. Every stage ends with a numbered checkpoint and the ledger
  invariants, so a failure names the stage. Each rule used here also has a depth-1 scenario
  in files 01 to 11 (README section 6.1). Amounts use the effective due date of README section 2.

  Background:
    Given the scenario clock follows the fixture timeline in Europe/Istanbul
    And a SaaS admin has onboarded a site and manager unique to this scenario attempt
    And the manager has signed in with a permanent password
    And proration is enabled for the site

  @SC-13-12-01 @J-19 @depth:4 @chain:sale-then-silent-departure @state:F5 @layer:backend @core @role_manager @pending
  # Backend coverage: backend/tests/accrual_corrections_tests.rs and backend/tests/payments_phase2_tests.rs (late split correction, owner statement, and owner payment allocation).
  Scenario: A unit is sold with its tenant, the tenant leaves without notice and both owners are involved
    Given the site is in state F5
    # Stage 1: December is billed to the tenant
    When the clock advances to "2026-12-01" and the manager accrues "Aralık 2026" due "2026-12-10"
    Then checkpoint 1 shows "Selin Demir" with open principal 4500.00 on "A-2" for Ekim, Kasım and Aralık
    And "Ahmet Yılmaz" is shown as jointly liable for all three
    And the ledger invariants hold
    # Stage 2: the sale does not split a tenant-occupied month
    When the clock advances to "2026-12-15"
    And the manager transfers title of "A-2" from "Ahmet Yılmaz" to "Gül Tanrıverdi" effective "2026-12-15" with "Selin Demir" staying
    Then checkpoint 2 shows the "Aralık 2026" principal of 1500.00 still on "Selin Demir" alone
    And the jointly liable owner of that charge is "Ahmet Yılmaz" for days 1 to 14 and "Gül Tanrıverdi" for days 15 to 31
    And the Ekim and Kasım charges still name only "Ahmet Yılmaz" as jointly liable
    And the ledger invariants hold
    # Stage 3: the departure is recorded late, at its real date
    When the clock advances to "2027-01-05"
    And the manager records that "Selin Demir" left "A-2" effective "2026-12-20" without check-out
    And a different manager approves the resulting split correction
    Then checkpoint 3 shows the "Aralık 2026" principal as 919.35 to "Selin Demir" (days 1 to 19) and 580.65 to "Gül Tanrıverdi" (days 20 to 31)
    And Gül's new share has effective due date "2027-01-05" and late fee 0.00
    And Selin's reduced share keeps effective due date "2026-12-10"
    And the ledger invariants hold
    # A former owner remains liable for their ownership date range, but no longer has resident self-service access after title transfer; the manager records the payment.
    # Stage 4: the jointly liable former owner pays part of the tenant's debt
    When the manager records 1717.50 from payer "Ahmet Yılmaz" toward the debt of "Selin Demir" on "2027-01-05"
    Then checkpoint 4 shows Selin's "Ekim 2026" charge settled: principal 1500.00 and late fee 217.50 for 87 days
    And the receipt names payer "Ahmet Yılmaz" and debtor "Selin Demir"
    And "Selin Demir" still owes 2599.19: "Kasım 2026" 1640.00 and "Aralık 2026" 959.19 (919.35 plus fee 39.84)
    And "Gül Tanrıverdi" owes 580.65 and holds no part of Selin's debt
    And the ledger invariants hold

  @SC-13-12-02 @J-19 @depth:5 @chain:capital-across-sale @state:F5 @layer:backend @core @role_manager @pending
  Scenario Outline: A capital project runs across a sale with or without a seller-pays override
    Given the site is in state F5
    # Stage 1: operational and capital charges before the sale
    When the clock advances to "2026-12-01"
    And the manager accrues "Aralık 2026" and installment 1 of capital project "Cephe" (6000.00 for "A-4" in 3 installments, due on the 10th)
    Then checkpoint 1 shows "Ahmet Yılmaz" owing "Kasım 2026", "Aralık 2026" and installment 1 of 2000.00 on "A-4"
    And the ledger invariants hold
    # Stage 2: the clearance statement and the transfer
    When the clock advances to "2026-12-20" and the manager opens the sale clearance of "A-4"
    Then checkpoint 2 shows open debt 5158.33 and installments 2 and 3 not yet accrued
    When the manager transfers title of "A-4" to "Gül Tanrıverdi" effective "2026-12-20" and Gül moves in as owner-occupant
    And the seller-pays override is <override>
    And a different manager approves the "Aralık 2026" split correction on "2026-12-20"
    Then checkpoint 3 shows "Aralık 2026" as 919.35 to "Ahmet Yılmaz" (due "2026-12-10") and 580.65 to "Gül Tanrıverdi" (due "2026-12-20")
    And Ahmet's "Kasım 2026" and installment 1 stay with him
    And the ledger invariants hold
    # Stage 3: the next month and the next installment
    When the clock advances to "2027-01-01" and the manager accrues "Ocak 2027" and installment 2
    Then checkpoint 4 shows "Ocak 2027" of 1500.00 to "Gül Tanrıverdi" and installment 2 of 2000.00 to "<later_installments>"
    And the ledger invariants hold
    # Stage 4: the last installment
    When the clock advances to "2027-02-01" and the manager accrues installment 3
    Then checkpoint 5 shows installment 3 of 2000.00 to "<later_installments>"
    And the three installments add up to 6000.00 and no installment has two debtors
    And the ledger invariants hold

    Examples:
      | override                                   | later_installments |
      | not requested                              | Gül Tanrıverdi     |
      | requested and approved by a second manager | Ahmet Yılmaz       |
      | requested and rejected                     | Gül Tanrıverdi     |

  @SC-13-12-03 @J-19 @depth:5 @chain:backdated-owner-into-closed-month @state:F3 @layer:backend @core @role_manager @pending
  Scenario: An owner back-dated into a closed month gets supplementary charges without changing the snapshot
    Given the site is in state F3
    # Stage 1: November is billed to nobody
    When the clock is set to "2026-11-01" and the manager accrues "Kasım 2026" due "2026-11-10"
    Then checkpoint 1 shows 0 liabilities and A-1 to A-7 in the list "units without owner"
    And the ledger invariants hold
    # Stage 2: October is closed with nothing billed
    When the clock advances to "2026-11-19" and the manager closes "Ekim 2026"
    Then checkpoint 2 shows a CLOSED "Ekim 2026" snapshot with billed total 0.00
    And the ledger invariants hold
    # Stage 3: the back-dated owner
    When the manager assigns "Burak Şahin" as owner and primary resident of "A-3" effective "2026-10-11"
    Then checkpoint 3 shows two supplementary charges in the open period "Kasım 2026"
    And one refers to "Ekim 2026" with principal 1016.13 and one refers to "Kasım 2026" with principal 1500.00
    And both have effective due date "2026-11-19" and late fee 0.00
    And the "Ekim 2026" snapshot still shows billed total 0.00
    And the ledger invariants hold
    # Stage 4: fees, then full payment in FIFO order
    When the clock advances to "2026-11-29"
    Then checkpoint 4 shows late fees 16.94 and 25.00 and a total of 2558.07
    When "Burak Şahin" pays 2558.07
    Then checkpoint 5 shows the charge referring to "Ekim 2026" settled first, both charges settled and an advance of 0.00
    And the ledger invariants hold

  @SC-13-12-04 @J-19 @depth:5 @chain:catch-up-grace-reversal @state:F2 @layer:backend @core @role_manager @pending
  Scenario: Catch-up, a payment inside grace, a reversal and a final settlement
    Given the site is in state F2 with grace days 5 and the accrual scheduler disabled since "2026-09-01"
    # Stage 1: catch-up creates three months at once
    When the scheduler runs on "2026-11-19"
    Then checkpoint 1 shows "Deniz Arslan" with Eylül, Ekim and Kasım of 1500.00 each on "A-5", all with effective due date "2026-11-19"
    And the ledger invariants hold
    # Stage 2: a payment inside grace
    When "Deniz Arslan" pays 1500.00 on "2026-11-24"
    Then checkpoint 2 shows "Eylül 2026" settled with late fee 0.00
    And the ledger invariants hold
    # Stage 3: grace has ended
    When the clock advances to "2026-11-29"
    Then checkpoint 3 shows late fee 25.00 on each of Ekim and Kasım and a total of 3050.00
    And the admin aging report puts 3000.00 in bucket "1-30"
    And the ledger invariants hold
    # Stage 4: the earlier payment bounces
    When a staff user reverses the "2026-11-24" payment with reason "bounced transfer"
    Then checkpoint 4 shows "Eylül 2026" open again with late fee 25.00 and a total of 4575.00
    And the ledger invariants hold
    # Stage 5: final settlement one day later
    When the clock advances to "2026-11-30" and "Deniz Arslan" pays 4582.50
    Then checkpoint 5 shows all three months settled with late fee 27.50 each and an advance of 0.00
    And the payment stream lists the reversed payment once and the final payment once
    And the ledger invariants hold

  @SC-13-12-05 @J-19 @depth:3 @chain:multi-debtor-transfer @state:F6 @layer:backend @core @role_manager @pending
  # Backend coverage: backend/tests/bank_multi_debtor_tests.rs (SC-07-03-04)
  Scenario: An unmatched transfer on a unit with several debtors is assigned once and never applied twice
    Given the site is in state F6
    # Stage 1: no automatic match
    When the bank webhook sends 800.00 with transaction id "TX-A2-01" to the virtual IBAN of "A-2" with no payer identity
    Then checkpoint 1 shows the item UNMATCHED with reason "several open debtors" and no share reduced
    And the ledger invariants hold
    # Stage 2: the manager decides
    When the manager assigns the item to "Mert Kılıç" and approves it
    Then checkpoint 2 shows Mert's "Kasım 2026" share settled and the shares of "Ahmet Yılmaz" and "Selin Demir" unchanged
    And the ledger invariants hold
    # Stage 3: the bank sends the same event again
    When the bank webhook sends "TX-A2-01" again
    Then checkpoint 3 shows the delivery as ALREADY_PROCESSED with one payment, one receipt and no new queue item
    And the ledger invariants hold
