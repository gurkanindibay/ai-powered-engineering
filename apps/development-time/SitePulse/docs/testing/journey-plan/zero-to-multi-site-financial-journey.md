# SitePulse journey analysis: from zero sites to reconciled balances

## Intent

Prove that a SitePulse operator can onboard multiple residential sites from an empty installation and run them through several billing periods without losing track of **who owes what, which site received the money, and what stays collectible when people move or sell**.

The test creates two sites through SaaS onboarding, then **creates all 88 units during the journey**: 24 in Site A and 64 in Site B. Once the units exist, each manager registers owners, tenants and household members attached to the person living in the unit. The managers accrue four periods and record a mix of full payments, partial payments and missed payments. At least one unit per site follows a paid, unpaid, unpaid, paid pattern that remains visible after April. After two periods, people move out, buyers take title, some homes remain empty, and other residents move in. By the final checkpoint, managers can explain every open balance by debtor, unit and period and reconcile each site's cash to its own posted receipts.

This is a proposal for review. The [existing journey plan](README.md) defines F0 as a site with a manager already present. Its billing and occupancy scenarios are useful references. This journey starts one step earlier and carries the same two sites through onboarding, billing, occupancy changes and reconciliation. The [integration contract](multi-site-integration-contract.md) describes how the component issues compose into one E2E attempt.

## Starting state and timeline

Use a dedicated, empty test installation or a uniquely scoped onboarding environment whose initial site list is empty. Start with a SaaS administrator and zero sites, units, residents, liabilities or cash. The attempt owns both sites and their managers. Create the sites through the supported onboarding flow and verify that both have zero units. Use each manager's normal site-scoped commands to create a block where required and add each unit below. Capture the creation steps and both site IDs in the existing attempt evidence.

| Site | Block the manager creates | Unit labels the manager creates | Units in block |
|---|---|---|---:|
| Site A | A | A-01 through A-24 | 24 |
| Site B | B1 | B1-01 through B1-32 | 32 |
| Site B | B2 | B2-01 through B2-32 | 32 |
| Total | 3 blocks | All units created in this attempt | 88 |

**Block and unit creation are required test steps.** Verify that both newly created sites have empty block and unit lists. Create all three blocks and all 88 units through the supported product flow. Before registering owners, tenants or household members, assert the exact labels and counts per block and per site: 24 units in Site A and 64 in Site B. Use the IDs returned by creation for later occupancy, billing and payment steps.

The scenario follows five units through the detailed occupancy and payment timeline below. Register a distinct owner-occupant in each of the other 83 units. Each of those owners pays the full tariff on the due date in all four periods. Those units must be billed, produce a posted receipt each month and finish with 0.00 open debt and fees. This adds 21 on-time receipts per period for Site A and 31 per block per period for Site B.

Use a controlled Europe/Istanbul clock. Accrue January through April 2027 on the first of each month, after that day's occupancy and title changes. Dues and payment checkpoints fall on the 10th. Use a fixed operating tariff per site, zero grace days, and the existing late-fee and payment-allocation rules. All amounts are TRY to two decimal places.

| Site / unit | January and February | Effective March 1, before accrual | Effective April 1, before accrual |
|---|---|---|---|
| A / A-01 | Ada owns and occupies, with a linked household member | Ada sells to Ben, who moves in | Ben remains in residence |
| A / A-02 | Cara owns, Dan rents and lives with a linked household member | Dan moves out, leaving the unit vacant | Eli moves in as tenant with a new household member |
| A / A-03 | Fay owns and occupies | Fay moves out and retains title | Unit stays vacant |
| B / B1-01 | Gus owns and occupies | Gus sells to Hana, who leaves the unit vacant | Hana moves in |
| B / B2-01 | Ivan owns, Juno rents | Juno remains in residence | Juno remains in residence |

Site A charges 1,000.00 per unit per period and Site B charges 750.00. Assert exactly 24 charges totalling 24,000.00 for Site A and 64 charges totalling 48,000.00 for Site B in each accrual. Check the initial owner, primary occupant and household relationship in the unit workspace. After a departure or sale closes the occupancy, check that its household is archived under the former occupancy. Eli's current roster contains only Eli's household, and linked household members receive no independent charge merely because they were added.

## Payment and cash checkpoints

Record each completed receipt against the listed unit and the named payer, who is also the primary debtor for that receipt. The table gives the **actual gross receipts** for the five detailed units, including any fee collected by the allocation waterfall. For every other unit, the registered owner-occupant pays that unit's own charge, totalling 21,000.00 per period in Site A and 46,500.00 per period in Site B. A dash means skip the payment. For example, Ada's February receipt of 831.00 pays 31.00 in fees and 600.00 toward January principal, then 200.00 toward February principal. Confirm the receipt and its allocations to the kuruş.

| Unit | January 10 | February 10 | March 10 | April 10 |
|---|---|---|---|---|
| A-01 | Ada · 400.00 | Ada · 831.00 | Ben · 500.00 | Ben · 1,025.83 |
| A-02 | — | Dan · 1,301.67 | — | Eli · 600.00 |
| A-03 | Fay · 1,000.00 | — | — | Fay · 1,000.00 (April only) |
| B1-01 | Gus · 750.00 | Gus · 250.00 | — | Hana · 1,038.75 |
| B2-01 | Juno · 750.00 | — | — | Juno · 750.00 (April only) |

Every allocation from a new owner or tenant's receipt must stay with that person's own charges. For Ben, Eli and Hana, verify the debtor on each allocation and compare the other debtors' principal, accrued fees and payment history immediately before and after posting at the same controlled date.

For A-03 and B2-01, pay January in full, skip February and March, then explicitly designate the April receipt to the April charge. Use the [supported payment designation](../../../.specify/features/EPIC-13/STORY-13-09-financial-state-transitions.feature) and verify that each receipt has exactly one allocation, to April. February and March must remain fully unpaid and accrue their own fees. On April 10, assert the exact open periods as well as the statuses of the paid periods. Other receipts follow the default allocation order.

For each of the two units, check period history after each payment checkpoint. January shows paid throughout. February appears as unpaid and stays unpaid. March adds a second consecutive unpaid period. April shows unpaid immediately before its designated receipt and paid immediately after. Check the final status of every detailed unit to distinguish partial payment from a missed payment or a later settlement. A-01 is partial for January at the January checkpoint and becomes paid after Ada’s February receipt.

**Final period status after the April 10 payments**

| Unit | January | February | March | April |
|---|---|---|---|---|
| A-01 | Paid | Partial | Paid | Partial |
| A-02 | Paid | Partial | Unpaid | Partial |
| A-03 | **Paid** | **Unpaid** | **Unpaid** | **Paid** |
| B1-01 | Paid | Partial | Paid | Partial |
| B2-01 | **Paid** | **Unpaid** | **Unpaid** | **Paid** |

For these assertions, paid means zero balance, partial means a principal payment posted and a balance remains, and unpaid means no payment was allocated and the full principal remains. Read period status from the unit statement or derive it from the charge and allocation rows if the statement uses a different label.

Define money remaining in the site fund for this proposal as **posted operating cash**. Opening cash is zero and the journey contains only collections, so expected cash equals cumulative gross receipts, including paid fees. Assert that accruals, occupancy changes and deed transfers create no cash movements. Reconcile the site-scoped operating balance against posted receipts after each period. Capture Site B before and after a Site A payment to catch cross-site posting even when the final system-wide total would agree.

| Checkpoint, after payments | Site A cash | Site B cash |
|---|---:|---:|
| Onboarding | 0.00 | 0.00 |
| January 10 | 22,400.00 | 48,000.00 |
| February 10 | 45,532.67 | 94,750.00 |
| March 10 | 67,032.67 | 141,250.00 |
| April 10 | **90,658.50** | **189,538.75** |

## Final debt checkpoint

Keep the controlled Europe/Istanbul clock on April 10, 2027 while evaluating late fees and reading the final balances. After posting the April 10 payments, read the manager's unit statements, including former debtors, and check any aging report against the same date. Match on site, unit, debtor and period. Primary debt and an owner's joint exposure describe the same receivable and must contribute to site totals only once.

| Unit | Primary debtor | Open period | Principal | Open fee | Total open | Jointly liable owner |
|---|---|---|---:|---:|---:|---|
| A-01 | Ada, former owner | February | 800.00 | 78.67 | 878.67 | |
| A-01 | Ben, current owner | April | 500.00 | 0.00 | 500.00 | |
| A-02 | Dan, former tenant | February | 750.00 | 73.75 | 823.75 | Cara |
| A-02 | Cara, owner when vacant | March | 1,000.00 | 51.67 | 1,051.67 | |
| A-02 | Eli, current tenant | April | 400.00 | 0.00 | 400.00 | Cara |
| A-03 | Fay, owner of vacant unit | February | 1,000.00 | 98.33 | 1,098.33 | |
| A-03 | Fay, owner of vacant unit | March | 1,000.00 | 51.67 | 1,051.67 | |
| B1-01 | Gus, former owner | February | 500.00 | 49.17 | 549.17 | |
| B1-01 | Hana, current owner | April | 500.00 | 0.00 | 500.00 | |
| B2-01 | Juno, continuing tenant | February | 750.00 | 73.75 | 823.75 | Ivan |
| B2-01 | Juno, continuing tenant | March | 750.00 | 38.75 | 788.75 | Ivan |

Total open primary debt includes principal and fees. Cara has 1,051.67 of total open primary debt and joint exposure to 1,223.75 of tenant debt. Ivan has 0.00 of total open primary debt and joint exposure to 1,612.50 of tenant debt. Fay has 2,150.00 of total open primary debt across two periods, made up of 2,000.00 of principal and 150.00 of fees. Check the other current and former homeowners against their primary rows. Each accrued charge outside this table should be settled.

| Site | Principal accrued | Principal collected | Principal open | Fees collected | Fees open | Total debt open |
|---|---:|---:|---:|---:|---:|---:|
| A | 96,000.00 | 90,550.00 | 5,450.00 | 108.50 | 354.09 | **5,804.09** |
| B | 192,000.00 | 189,500.00 | 2,500.00 | 38.75 | 161.67 | **2,661.67** |

The amounts assume fees accrue at 5% per 30 days on outstanding principal, rounded by segment. Payments settle any designated charge first. The default waterfall clears outstanding fees before applying principal oldest first within the selected debtor and unit. Calculate expected amounts from the fixture dates and amounts independently of the response being checked. Each month, compare accrued amounts, payment allocations, ownership and occupancy history, and the site's open debt and cash. Report the site, period, unit and debtor when a checkpoint fails.

## Decisions for review

- **Fund scope.** Is posted operating cash sufficient for this journey, or should the same scenario include an expense and assert cash net of that expense? Reserve and capital funds have separate balances.
- **Billing boundaries.** The proposed changes occur on the first of the month before accrual so that a failure points to responsibility or history. Should the initial delivery also exercise a mid-period change and proration?
- **Test surfaces.** The proposal is one stateful Gherkin journey using supported commands for setup and deterministic checks for balances and isolation. Include browser checks for onboarding, block and unit counts, a household or title transition, and the final manager statements and cash view. Use supported product commands to create all units and record the routine payments. Confirm which balance and receipt surfaces managers should use and how the test runner can provide a genuinely empty site list without resetting shared state.

Related acceptance criteria cover [household scoping](../../../.specify/features/EPIC-08/STORY-08-02-occupancy-state-machine-household.feature), [title transfers](../../../.specify/features/EPIC-08/STORY-08-09-title-transfer-occupancy.feature) and [financial chains across occupancy changes](../../../.specify/features/EPIC-13/STORY-13-12-multi-depth-chains.feature).
