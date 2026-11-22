# Test run 20261122T200815Z-33a615d

- **Task:** master
- **Result:** DEFECT (1 DEFECT, 2 SKIPPED, 324 PASS)
- **Executed:** 327 tests in 3538s, covering 228 of 435 automated scenarios
- **Commit:** `33a615da98` on `master`
- **Started:** 2026-11-22T20:08:15Z (ci)

## Executed tests

| Scenario / GUI id | Status | Change | Time | Name |
|---|---|---|---|---|
| `SC-01-01-01` | PASS | new | 5.4s | Preserve kurus-level precision in dues calculation |
| `SC-01-02-01` | PASS |  | 5.4s | Calculate 10-day overdue statutory delay penalty |
| `SC-01-03-01` | PASS |  | 5.4s | Emit reactive state on dashboard launch |
| `SC-01-03-02` | PASS |  | 126.4s | Site announcement reaches the resident |
| `SC-01-04-01` | PASS |  | 5.4s | Render resident hero balance with overdue amount |
| `SC-01-04-02` | PASS |  | 6.2s | Render zero balance without overdue badge |
| `SC-01-04-03` | PASS | new | 6.2s | Action buttons meet touch target size and unapproved features are hidden |
| `SC-01-05-01` | PASS |  | 5.4s | View recent financial movements |
| `SC-01-06-01` | PASS |  | 7.2s | Display cached dues when network is offline |
| `SC-02-01-01` | PASS |  | 7.6s | Cockpit shows the accrued total before any payment |
| `SC-02-01-02` | PASS |  | 5.6s | Cockpit counts a payment as collected |
| `SC-02-01-03` | PASS |  | 5.5s | Cockpit amounts keep kurus |
| `SC-02-01-04` | PASS |  | 10.9s | House type tariff is saved and a negative amount is rejected |
| `SC-02-01-05` | PASS |  | 8.1s | House type tariff rejects more than two decimals |
| `SC-02-01-06` | PASS | new | 6.0s | Display complex collection progress with the unit status breakdown |
| `SC-02-02-01` | PASS |  | 7.7s | Overdue filter lists every overdue flat |
| `SC-02-03-01` | PASS |  | 20.4s | Manager adds a new home owner manually |
| `SC-02-03-02` | PASS |  | 12.9s | Adding a resident to an occupied unit warns and saves nothing |
| `SC-02-03-03` | PASS |  | 33.3s | A resident without ledger history can be deleted |
| `SC-02-03-04` | PASS |  | 10.1s | A refused delete keeps the resident card |
| `SC-02-04-01` | PASS |  | 129.2s | Reminder action is offered for overdue flats |
| `SC-02-05-01` | PASS |  | 10.6s | Manager creates an announcement |
| `SC-03-01-01` | PASS |  | 8.1s | Query operations strictly scoped by tenant |
| `SC-03-02-01` | PASS |  | 4.5s | SaaS Admin views portfolio overview |
| `SC-03-02-02` | PASS |  | 1.3s | Portfolio statistics agree with the site list |
| `SC-03-03-01` | PASS |  | 9.1s | SaaS Admin creates new site and provisions first Site Admin |
| `SC-03-04-01` | PASS |  | 9.1s | Generate temporary password for newly registered Site Admin |
| `SC-03-04-02` | PASS |  | 7.4s | New manager is forced to change the temporary password |
| `SC-03-06-01` | PASS |  | 11.7s | Delete site without any related actions |
| `SC-03-06-02` | PASS |  | 4.6s | Invariant prevents deletion of active site with transactions |
| `SC-03-07-01` | PASS |  | 10.2s | SaaS Admin renews temporary password for a site manager |
| `SC-03-07-02` | PASS | new | 1.8s | Password renewal fails for non-existent site |
| `SC-04-01-01` | PASS |  | 7.4s | Generate 7-day secure invite link |
| `SC-04-02-01` | PASS |  | 7.4s | Site Admin copies or shares invite link |
| `SC-04-02-02` | PASS | new | 5.2s | Empty approval queue shows an empty state |
| `SC-04-03-01` | PASS | new | 1.1s | Home owner submits online registration |
| `SC-04-04-01` | PASS |  | 9.6s | Site manager views pending applications |
| `SC-04-05-01` | PASS |  | 6.6s | Approve applicant and provision account |
| `SC-04-05-02` | PASS |  | 6.6s | Approved resident signs in with the issued password |
| `SC-04-06-01` | PASS |  | 8.3s | Reject unverified registration |
| `SC-04-07-01` | PASS |  | 7.2s | Home owner generates unit-scoped invitation link |
| `SC-04-07-01` | PASS |  | 6.8s | Home owner generates unit-scoped invitation link |
| `SC-04-07-02` | PASS | new | 4.8s | Co-resident registers with unit-scoped permissions |
| `SC-06-01-01` | PASS |  | 4.7s | Home resident is restricted from site-wide management |
| `SC-06-02-02` | PASS |  | 7.4s | Site manager signs in and reaches the cockpit |
| `SC-06-02-03` | PASS |  | 4.7s | Home owner signs in and reaches the resident dashboard |
| `SC-06-02-04` | PASS |  | 4.6s | Wrong password shows an error and stays on the login screen |
| `SC-06-02-05` | PASS |  | 4.2s | Clearing the login cache empties the credential fields |
| `SC-06-02-05` | PASS |  | 3.2s | Clearing the login cache empties the credential fields |
| `SC-06-02-06` | PASS |  | 5.2s | Empty password is rejected without a request |
| `SC-06-03-02` | SKIPPED |  | 2.3s | Google sign-in button starts the provider flow |
| `SC-06-04-02` | PASS |  | 16.5s | Home owner changes the password from the profile and signs in again |
| `SC-06-04-03` | PASS |  | 9.5s | Logout returns to the login screen |
| `SC-06-04-04` | PASS |  | 13.8s | Browser back after logout does not re-enter the session |
| `SC-06-04-05` | PASS |  | 6.0s | Manager switches between the cockpit and the own flat |
| `SC-06-04-06` | PASS |  | 9.8s | Cancelling the logout confirmation keeps the session |
| `SC-06-05-01` | SKIPPED |  | 2.3s | Google sign-in option is offered on the login screen |
| `SC-06-05-03` | PASS |  | 7.4s | Email and password sign-in opens the role dashboard |
| `SC-06-06-01` | PASS |  | 6.6s | SaaS admin with a temporary password is held at the password change screen |
| `SC-06-06-02` | PASS |  | 159.7s | Site manager with a temporary password is held at the password change screen |
| `SC-06-06-03` | PASS |  | 150.0s | Home owner with a temporary password is held at the password change screen |
| `SC-06-06-04` | PASS |  | 123.6s | Home resident with a temporary password is held at the password change screen |
| `SC-06-06-05` | PASS |  | 169.1s | Auditor with a temporary password is held at the password change screen |
| `SC-07-02-01` | PASS |  | 6.8s | Site manager uploads a bank statement Excel file |
| `SC-07-02-02` | PASS |  | 9.4s | Approving a matched row clears the resident's balance |
| `SC-07-02-04` | PASS |  | 9.3s | An unmatched row is assigned to a unit by hand |
| `SC-07-02-05` | PASS | new | 7.1s | A stored payer-name alias auto-matches a re-uploaded row |
| `SC-07-03-01` | PASS |  | 5.5s | Real-time incoming transfer clears dues once |
| `SC-07-04-01` | PASS |  | 8.2s | Resident chooses the FAST transfer payment method |
| `SC-07-04-02` | PASS |  | 5.1s | Copy button puts the unspaced IBAN on the clipboard |
| `SC-07-05-01` | PASS |  | 7.6s | Surplus transfer is allocated to the resident advance balance |
| `SC-07-06-02` | PASS |  | 16.3s | Wrong statement format is rejected and the matching format is accepted |
| `SC-07-06-03` | PASS | new | 7.2s | Excel upload offers a sample for each catalogued Excel bank |
| `SC-07-06-03` | PASS | new | 9.4s | Excel upload offers a sample for each catalogued Excel bank |
| `SC-07-06-04` | PASS | new | 6.2s | Excel sample options exclude banks without an Excel format |
| `SC-07-07-01` | PASS |  | 21.0s | Manager accrues a period once and the duplicate is blocked |
| `SC-07-07-04` | PASS | new | 14.7s | Manual accrual charges each unit its tariff, not a fixed amount |
| `SC-08-01-01` | PASS |  | 18.1s | Accrue monthly operational dues to tenant and capital project to owner |
| `SC-08-02-01` | PASS |  | 21.2s | Household members are bound to the active resident session |
| `SC-08-02-02` | PASS | new | 19.2s | Household members are archived when the resident moves out |
| `SC-08-03-01` | PASS |  | 9.3s | Move-out preserves historical payment receipts and unsettled debt |
| `SC-08-03-02` | PASS | new | 9.3s | Move-out can keep the advance without changing the balance |
| `SC-08-03-03` | PASS | new | 12.6s | Move-out payout is debited only after four-eyes approval |
| `SC-08-03-04` | PASS | new | 10.7s | Move-out transfer changes debtor only after four-eyes approval |
| `SC-08-04-01` | PASS |  | 7.5s | New tenant moves in and past occupancy history is retrievable |
| `SC-08-04-02` | PASS | new | 12.0s | Tenant move-in opens an active tenant session |
| `SC-08-05-01` | PASS |  | 14.4s | Change property owner upon title deed sale without affecting tenant |
| `SC-08-05-02` | PASS | new | 1.9s | Capital dues after the transfer are billed to the new owner |
| `SC-08-05-03` | PASS | new | 20.0s | Previous owner's advance is paid out or transferred only with a second approver |
| `SC-09-01-01` | PASS |  | 9.2s | Filter payment stream by tenant payments for current month |
| `SC-09-01-02` | PASS | new | 6.4s | Debt aging buckets total the overdue sum |
| `SC-09-02-01` | PASS |  | 9.3s | Settle delay penalty first, then oldest dues, then credit surplus as advance |
| `SC-09-02-03` | PASS | new | 3.2s | Owner payment never settles tenant operational dues without joint-liability opt-in |
| `SC-09-03-01` | PASS |  | 7.9s | Generate itemized sub-ledger statement for a tenant |
| `SC-09-03-02` | PASS |  | 7.2s | Resident statement ages an overdue due with its penalty |
| `SC-09-04-01` | PASS |  | 5.1s | Issue sequential payment receipt upon settlement |
| `SC-09-04-02` | PASS |  | 10.3s | Manager downloads the receipt PDF and reverses the receipt |
| `SC-09-04-03` | PASS |  | 9.3s | Receipt shows the penalty, principal and advance split |
| `SC-09-04-04` | PASS |  | 8.1s | Card payment on the provider page issues a receipt |
| `SC-10-01-01` | PASS |  | 11.9s | Budget is split by land share without rounding drift |
| `SC-10-01-02` | PASS |  | 11.5s | Equal allocation gives every unit the same share |
| `SC-10-02-01` | PASS |  | 13.6s | Accruing an installment charges owners only |
| `SC-10-03-01` | PASS |  | 6.2s | Owner FAST payment raises the collected amount of the project |
| `SC-10-03-02` | PASS |  | 9.5s | Tenant payment produces a TBK 314 rent-offset receipt |
| `SC-10-04-01` | PASS |  | 6.7s | Virman dialog offers the real advance balance of the unit |
| `SC-10-04-02` | PASS | new | 9.7s | Virman transfer clears a capital due from the advance balance |
| `SC-10-05-01` | PASS |  | 9.9s | Disbursement within collected cash updates the reserve |
| `SC-10-05-02` | PASS |  | 17.1s | Disbursement larger than collected cash is refused |
| `SC-10-06-01` | PASS |  | 4.8s | Owner dashboard shows capital dues separately |
| `SC-10-06-02` | PASS |  | 7.6s | Capital project is marked as the responsibility of the owner |
| `SC-10-07-01` | PASS |  | 146.4s | Capital segment offers project creation |
| `SC-12-02-03` | PASS | new | 11.3s | The directory pager adapts to a narrow viewport |
| `SC-12-02-05` | PASS |  | 11.3s | Unit search folds Turkish names and phone digits |
| `SC-12-02-06` | PASS |  | 11.3s | Unit rows expose distinct actions and details targets |
| `SC-12-02-07` | PASS |  | 11.3s | Compact unit rows adapt from phone to desktop widths |
| `SC-12-03-04` | PASS |  | 12.6s | Choose an existing person through the live search API |
| `SC-12-04-01` | PASS |  | 10.2s | People paging and activation filters use the server query |
| `SC-12-04-02` | PASS | new | 10.2s | People search and directory position survive restoration |
| `SC-12-06-04` | PASS | new | 14.4s | Unit actions started from the residents tab choose people through the person picker |
| `SC-13-01-01` | PASS | new | 22.7s | A site with no data shows empty states, not errors |
| `SC-13-01-02` | PASS | new | 2.3s | Accruing a period on a site with no units is refused with a clear reason |
| `SC-13-01-03` | PASS | new | 3.5s | A payment arriving at a site with no units is not lost |
| `SC-13-01-04` | PASS | new | 14.2s | Units with no people show as unassigned and cannot be billed to anyone |
| `SC-13-01-05` | PASS | new | 43.7s | The manager can add the first owner and tenant from an empty unit |
| `SC-13-01-06` | PASS | new | 17.1s | People without a billing period have no debt and a clear first action |
| `SC-13-01-07` | PASS | new | 2.6s | The first accrual charges each unit its tariff and the right debtor |
| `SC-13-01-08` | PASS | new | 2.6s | Units without an owner are reported separately from the accrual |
| `SC-13-01-09` | PASS | new | 3.1s | A period accrued before anyone lived in the units leaves nothing to collect |
| `SC-13-01-11` | PASS | new | 17.2s | Accruing the same period again after residents arrive is blocked, not doubled |
| `SC-13-01-12` | PASS | new | 121.0s | Growing the site from F0 to F2 through the screens keeps every page consistent |
| `SC-13-01-13` | PASS | new | 2.7s | Every starting state survives a backend restart unchanged |
| `SC-13-01-13` | PASS | new | 4.4s | Every starting state survives a backend restart unchanged |
| `SC-13-01-13` | PASS | new | 3.0s | Every starting state survives a backend restart unchanged |
| `SC-13-01-13` | PASS | new | 2.8s | Every starting state survives a backend restart unchanged |
| `SC-13-02-01` | PASS | new | 13.2s | Residents with a single accrual period show one debt each on every screen |
| `SC-13-02-02` | PASS | new | 13.8s | The resident sees exactly what the admin sees for the same unit |
| `SC-13-02-03` | PASS | new | 4.2s | The late fee follows the clock day by day |
| `SC-13-02-04` | PASS | new | 12.9s | Multiple periods with mixed debts add up per unit and per site |
| `SC-13-02-05` | PASS | new | 2.6s | A single debt in a previous month stays attached to that month |
| `SC-13-02-06` | PASS | new | 2.6s | A single debt in the current month is the only one in the youngest bucket |
| `SC-13-02-07` | PASS | new | 2.6s | Multiple debts across periods are listed oldest first with a fee each |
| `SC-13-02-08` | PASS | new | 2.7s | An advance balance has already offset later periods |
| `SC-13-02-09` | PASS | new | 4.0s | A fourth accrual adds exactly one liability per responsible debtor |
| `SC-13-02-10` | PASS | new | 2.8s | A closed period accepts no new accrual or edit but keeps its open debts |
| `SC-13-02-11` | PASS | new | 4.2s | A payment toward a closed period is still allocated to its oldest debt |
| `SC-13-03-01` | PASS | new | 3.5s | A mid-month move-in splits a period between owner and tenant |
| `SC-13-03-04` | PASS | new | 5.2s | A resident added after accruals is charged from their start residing date |
| `SC-13-03-08` | PASS | new | 2.7s | Proration respects month length and edge days |
| `SC-13-03-08` | PASS | new | 3.6s | Proration respects month length and edge days |
| `SC-13-03-08` | PASS | new | 2.7s | Proration respects month length and edge days |
| `SC-13-03-08` | PASS | new | 2.7s | Proration respects month length and edge days |
| `SC-13-03-08` | PASS | new | 3.0s | Proration respects month length and edge days |
| `SC-13-03-10` | PASS | new | 3.7s | One person who owns one unit and rents another is billed in each role |
| `SC-13-03-11` | PASS | new | 4.9s | The same national id entered twice does not create a second person |
| `SC-13-03-12` | PASS | new | 4.4s | Owner moves in after the tenant leaves and takes the operational dues back |
| `SC-13-03-13` | PASS | new | 2.2s | Switching proration changes responsibility for a mid-month move-in |
| `SC-13-03-13` | PASS | new | 3.5s | Switching proration changes responsibility for a mid-month move-in |
| `SC-13-03-15` | PASS | new | 2.7s | A unit created mid-month is billed for chargeable days only |
| `SC-13-03-17` | PASS | new | 3.3s | A share whose responsibility starts after the period due date is not late before it existed |
| `SC-13-03-17` | PASS | new | 3.3s | A share whose responsibility starts after the period due date is not late before it existed |
| `SC-13-03-17` | PASS | new | 5.1s | A share whose responsibility starts after the period due date is not late before it existed |
| `SC-13-03-17` | PASS | new | 3.3s | A share whose responsibility starts after the period due date is not late before it existed |
| `SC-13-03-18` | PASS | new | 2.7s | A sale of a tenant-occupied unit with the same tenant is not split |
| `SC-13-03-20` | PASS | new | 5.4s | A re-split share keeps an effective due date and a late fee that follow its creation |
| `SC-13-04-01` | PASS | new | 2.7s | A payment clears the oldest period first |
| `SC-13-04-02` | PASS | new | 3.0s | Paying exactly the whole debt leaves zero and no advance |
| `SC-13-04-03` | PASS | new | 3.0s | One kuruş short leaves one kuruş open |
| `SC-13-04-04` | PASS | new | 3.8s | An overpayment becomes an advance that offsets the next accrual |
| `SC-13-04-05` | PASS | new | 2.7s | Invalid payment amounts are rejected without any side effect |
| `SC-13-04-06` | PASS | new | 3.6s | The bank webhook matches a transfer to the unit and allocates it |
| `SC-13-04-07` | PASS | new | 3.8s | The same bank transaction sent twice is applied once |
| `SC-13-04-08` | PASS | new | 3.8s | Two transfers for one unit at the same moment are both applied |
| `SC-13-04-09` | PASS | new | 4.4s | A transfer matched to another site is applied only there |
| `SC-13-04-10` | PASS | new | 2.7s | The grace boundary decides whether a late fee is charged |
| `SC-13-04-10` | PASS | new | 4.2s | The grace boundary decides whether a late fee is charged |
| `SC-13-04-10` | PASS | new | 3.8s | The grace boundary decides whether a late fee is charged |
| `SC-13-04-10` | PASS | new | 3.0s | The grace boundary decides whether a late fee is charged |
| `SC-13-04-10` | PASS | new | 2.7s | The grace boundary decides whether a late fee is charged |
| `SC-13-04-11` | PASS | new | 3.2s | A correction after a partial payment moves the paid amount to the advance |
| `SC-13-04-12` | PASS | new | 2.8s | The requester of a correction cannot approve it |
| `SC-13-04-14` | PASS | new | 2.9s | A payment reversal restores the debt it settled and the fee it stopped |
| `SC-13-04-15` | PASS | new | 5.2s | A unit-level transfer on a unit with several debtors waits for the manager |
| `SC-13-04-15` | PASS | new | 4.0s | A unit-level transfer on a unit with several debtors waits for the manager |
| `SC-13-04-16` | PASS | new | 4.3s | A payment for a unit with no debt becomes the payer's advance |
| `SC-13-05-01` | PASS | new | 2.6s | Invalid accrual input is rejected and creates nothing |
| `SC-13-05-01` | PASS | new | 4.1s | Invalid accrual input is rejected and creates nothing |
| `SC-13-05-01` | PASS | new | 3.6s | Invalid accrual input is rejected and creates nothing |
| `SC-13-05-01` | PASS | new | 2.6s | Invalid accrual input is rejected and creates nothing |
| `SC-13-05-03` | PASS | new | 3.2s | A duplicate accrual with a different amount is still blocked |
| `SC-13-05-04` | PASS | new | 3.1s | Two admins accruing the same period at the same moment create one set of liabilities |
| `SC-13-05-05` | PASS | new | 3.5s | The scheduler catches up months that were missed |
| `SC-13-05-06` | PASS | new | 3.7s | Moving out with debt keeps the debt and the history |
| `SC-13-05-07` | PASS | new | 3.5s | Moving out with an advance requires a decision before the advance leaves |
| `SC-13-05-07` | PASS | new | 4.0s | Moving out with an advance requires a decision before the advance leaves |
| `SC-13-05-08` | PASS | new | 4.3s | Moving out twice and moving in on an occupied unit are refused |
| `SC-13-05-09` | PASS | new | 5.6s | A move-out recorded after accrual re-splits the open liability |
| `SC-13-05-11` | PASS | new | 3.8s | Merging two duplicate people keeps every liability and payment |
| `SC-13-05-12` | PASS | new | 3.9s | A resident cannot call manager actions |
| `SC-13-05-13` | PASS | new | 4.3s | A manager of another site sees nothing of this site |
| `SC-13-05-14` | PASS | new | 4.5s | The month boundary uses Istanbul time, not UTC |
| `SC-13-05-15` | PASS | new | 2.7s | A late fee never makes a settled liability reopen |
| `SC-13-05-16` | PASS | new | 4.7s | Balances are identical after a backend restart at any point of the history |
| `SC-13-05-16` | PASS | new | 4.5s | Balances are identical after a backend restart at any point of the history |
| `SC-13-05-16` | PASS | new | 3.3s | Balances are identical after a backend restart at any point of the history |
| `SC-13-05-16` | PASS | new | 5.1s | Balances are identical after a backend restart at any point of the history |
| `SC-13-05-18` | PASS | new | 3.7s | A tenant who left without notice is moved out at the real date and the owner takes over |
| `SC-13-05-18` | PASS | new | 5.2s | A tenant who left without notice is moved out at the real date and the owner takes over |
| `SC-13-07-01` | PASS | new | 5.0s | Every starting state can be built using the documented fixture path |
| `SC-13-07-01` | PASS | new | 6.7s | Every starting state can be built using the documented fixture path |
| `SC-13-07-01` | PASS | new | 5.2s | Every starting state can be built using the documented fixture path |
| `SC-13-07-01` | PASS | new | 4.6s | Every starting state can be built using the documented fixture path |
| `SC-13-07-01` | PASS | new | 7.5s | Every starting state can be built using the documented fixture path |
| `SC-13-07-01` | PASS | new | 5.7s | Every starting state can be built using the documented fixture path |
| `SC-13-07-04` | PASS | new | 13.3s | Teardown runs when the journey fails |
| `SC-13-07-05` | PASS | new | 5.3s | Teardown works after a half-built state |
| `SC-13-07-06` | PASS | new | 4.1s | Two active journeys do not see each other's data |
| `SC-13-07-08` | PASS | new | 4.8s | A leftover site from a crashed earlier run is cleaned before the next run starts |
| `SC-13-07-10` | PASS | new | 9.2s | Every historical starting state can be built using the documented fixture path |
| `SC-13-07-10` | PASS | new | 5.2s | Every historical starting state can be built using the documented fixture path |
| `SC-13-08-03` | PASS | new | 9.5s | A search with zero matches is recoverable without changing the site |
| `SC-13-08-05` | PASS | new | 15.8s | Cancelling accrual confirmation makes no financial change |
| `SC-13-09-02` | PASS | new | 3.9s | A partial payment reduces the principal used for later fees |
| `SC-13-09-03` | PASS | new | 3.8s | A backdated payment recalculates fees using its value date |
| `SC-13-09-06` | PASS | new | 2.7s | Concurrent deliveries of the same bank event are credited once |
| `SC-13-09-07` | PASS | new | 2.8s | An unmatched statement item can be approved exactly once |
| `SC-13-09-07` | PASS | new | 2.8s | An unmatched statement item can be approved exactly once |
| `SC-13-09-08` | PASS | new | 3.0s | Operational and capital balances stay separate for a tenant-occupied unit |
| `SC-13-09-09` | PASS | new | 2.6s | The aging bucket changes at each day boundary |
| `SC-13-09-09` | PASS | new | 3.4s | The aging bucket changes at each day boundary |
| `SC-13-09-09` | PASS | new | 2.6s | The aging bucket changes at each day boundary |
| `SC-13-09-09` | PASS | new | 2.5s | The aging bucket changes at each day boundary |
| `SC-13-09-09` | PASS | new | 4.0s | The aging bucket changes at each day boundary |
| `SC-13-09-09` | PASS | new | 3.6s | The aging bucket changes at each day boundary |
| `SC-13-09-09` | PASS | new | 2.9s | The aging bucket changes at each day boundary |
| `SC-13-09-09` | PASS | new | 2.5s | The aging bucket changes at each day boundary |
| `SC-13-10-01` | PASS | new | 4.0s | Manager lists, searches and aggregates use the authenticated site |
| `SC-13-10-02` | PASS | new | 4.8s | Direct reads and downloads require access to the requested site |
| `SC-13-10-03` | PASS | new | 5.5s | A site parameter cannot widen a manager's collection or export permissions |
| `SC-13-10-04` | PASS | new | 3.8s | A manager cannot mutate another site's records |
| `SC-13-10-05` | PASS | new | 3.6s | A resident cannot read another unit's financial records |
| `SC-13-10-06` | PASS | new | 3.2s | A tenant statement excludes the owner's private transactions for the same unit |
| `SC-13-10-07` | PASS | new | 4.7s | Replacing a tenant keeps each occupant's history and receipts private |
| `SC-13-11-01` | PASS | new | 2.7s | A liability moves through PENDING, OVERDUE, PAID and CANCELLED |
| `SC-13-11-01` | PASS | new | 3.3s | A liability moves through PENDING, OVERDUE, PAID and CANCELLED |
| `SC-13-11-01` | PASS | new | 3.6s | A liability moves through PENDING, OVERDUE, PAID and CANCELLED |
| `SC-13-11-01` | PASS | new | 2.7s | A liability moves through PENDING, OVERDUE, PAID and CANCELLED |
| `SC-13-11-01` | PASS | new | 2.6s | A liability moves through PENDING, OVERDUE, PAID and CANCELLED |
| `SC-13-11-01` | PASS | new | 4.1s | A liability moves through PENDING, OVERDUE, PAID and CANCELLED |
| `SC-13-11-01` | PASS | new | 3.7s | A liability moves through PENDING, OVERDUE, PAID and CANCELLED |
| `SC-13-11-01` | PASS | new | 3.0s | A liability moves through PENDING, OVERDUE, PAID and CANCELLED |
| `SC-13-11-01` | PASS | new | 2.6s | A liability moves through PENDING, OVERDUE, PAID and CANCELLED |
| `SC-13-11-02` | PASS | new | 3.5s | A settled or cancelled liability cannot be paid or corrected again |
| `SC-13-11-02` | PASS | new | 5.4s | A settled or cancelled liability cannot be paid or corrected again |
| `SC-13-11-02` | PASS | new | 4.2s | A settled or cancelled liability cannot be paid or corrected again |
| `SC-13-11-02` | PASS | new | 2.9s | A settled or cancelled liability cannot be paid or corrected again |
| `SC-13-11-03` | PASS | new | 3.2s | A reversal moves a PAID liability back to OVERDUE |
| `SC-13-11-04` | PASS | new | 2.8s | Each period status allows only its own commands |
| `SC-13-11-04` | PASS | new | 3.6s | Each period status allows only its own commands |
| `SC-13-11-04` | PASS | new | 2.7s | Each period status allows only its own commands |
| `SC-13-11-04` | PASS | new | 4.3s | Each period status allows only its own commands |
| `SC-13-11-04` | PASS | new | 4.0s | Each period status allows only its own commands |
| `SC-13-11-04` | PASS | new | 3.1s | Each period status allows only its own commands |
| `SC-13-11-04` | PASS | new | 2.7s | Each period status allows only its own commands |
| `SC-13-11-06` | PASS | new | 2.6s | A bank statement item reaches each reconciliation status |
| `SC-13-11-06` | PASS | new | 3.6s | A bank statement item reaches each reconciliation status |
| `SC-13-11-06` | PASS | new | 2.7s | A bank statement item reaches each reconciliation status |
| `SC-13-11-06` | PASS | new | 2.6s | A bank statement item reaches each reconciliation status |
| `SC-13-11-06` | PASS | new | 4.2s | A bank statement item reaches each reconciliation status |
| `SC-13-11-07` | PASS | new | 2.7s | A rejected or approved statement item cannot change status again |
| `SC-13-11-08` | PASS | new | 2.9s | Each unit occupancy state offers its own commands and refuses the rest |
| `SC-13-11-08` | PASS | new | 3.8s | Each unit occupancy state offers its own commands and refuses the rest |
| `SC-13-11-08` | PASS | new | 2.9s | Each unit occupancy state offers its own commands and refuses the rest |
| `SC-13-11-08` | PASS | new | 3.5s | Each unit occupancy state offers its own commands and refuses the rest |
| `SC-13-13-01` | PASS | new | 5.1s | Onboard two sites and create all eighty-eight units from zero |
| `SC-13-13-02` | PASS | new | 28.8s | Accrue four periods and verify mixed payment histories |
| `SC-13-13-02` | PASS | new | 10.9s | Accrue four periods and verify mixed payment histories |
| `SC-13-13-02` | PASS | new | 9.2s | Accrue four periods and verify mixed payment histories |
| `SC-13-14-01` | PASS | new | 6.9s | Titles and occupancies change on their effective dates |
| `SC-13-14-02` | PASS | new | 8.0s | March charges follow the new owners and the vacancies |
| `SC-13-14-03` | PASS | new | 5.3s | April move-ins redirect new charges and show only the current household |
| `SC-13-14-04` | PASS | new | 4.5s | Former owners and tenants remain collectible next to their successors |
| `SC-13-14-05` | PASS | new | 4.4s | Receipts before the changes settle the paying debtor's own periods |
| `SC-13-14-06` | PASS | new | 6.8s | A designated April receipt leaves February and March unpaid |
| `SC-13-14-07` | PASS | new | 6.0s | Title changes, vacancies and accruals move no cash between sites |
| `SC-13-14-08` | PASS | new | 5.9s | A successor's receipt settles only the successor's own charges |
| `SC-13-14-08` | PASS | new | 8.2s | A successor's receipt settles only the successor's own charges |
| `SC-13-14-08` | PASS | new | 5.6s | A successor's receipt settles only the successor's own charges |
| `SC-13-14-08` | PASS | new | 9.6s | A successor's receipt settles only the successor's own charges |
| `SC-13-14-09` | PASS | new | 8.9s | The final open debt stays with each former and current debtor |
| `SC-13-25-01` | PASS | new | 0.7s | Posted operating cash equals cumulative gross receipts at every checkpoint |
| `SC-13-25-01` | PASS | new | 1.1s | Posted operating cash equals cumulative gross receipts at every checkpoint |
| `SC-13-25-01` | PASS | new | 0.0s | Posted operating cash equals cumulative gross receipts at every checkpoint |
| `SC-13-25-01` | PASS | new | 0.5s | Posted operating cash equals cumulative gross receipts at every checkpoint |
| `SC-13-25-02` | PASS | new | 28.8s | Eleven open rows are matched by site, unit, primary debtor and period |
| `SC-13-25-02` | PASS | new | 0.5s | Eleven open rows are matched by site, unit, primary debtor and period |
| `SC-13-25-03` | PASS | new | 28.8s | Homeowner totals separate primary debt from joint exposure |
| `SC-13-25-03` | PASS | new | 1.0s | Homeowner totals separate primary debt from joint exposure |
| `SC-13-25-04` | PASS | new | 28.8s | Site totals are reconciled independently and count a joint receivable once |
| `SC-13-25-04` | PASS | new | 0.7s | Site totals are reconciled independently and count a joint receivable once |
| `SC-13-25-05` | PASS | new | 0.8s | Final period status distinguishes partial payment from a missed payment |
| `SC-13-25-06` | PASS | new | 28.8s | Site operating cash matches posted receipts and a Site A payment does not leak into Site B |
| `SC-13-25-07` | PASS | new | 28.8s | The manager statements match the eleven open rows and the site totals on 2027-04-10 |
| `SC-13-25-07` | DEFECT | new | 5.9s | The manager statements match the eleven open rows and the site totals on 2027-04-10 |
| `SC-13-26-01` | PASS | new | 2.4s | The onboarding attempt starts with no residential sites |
| `SC-13-26-02` | PASS | new | 28.8s | Two sites remain identifiable from onboarding through final reconciliation |
| `GUI-J-01` | PASS |  | 194.7s | test_saas_admin_journey[chromium] |
| `GUI-X-04` | PASS |  | 4.5s | test_mobile_viewport_login_and_dashboard[chromium-homeowner-ResidentHome] |
| `GUI-X-04` | PASS |  | 5.1s | test_mobile_viewport_login_and_dashboard[chromium-manager-ManagerCockpit] |
| `GUI-X-02` | PASS |  | 6.5s | test_theme_choice_on_login_screen_holds_after_login[chromium] |
| `GUI-03-05` | PASS |  | 6.7s | test_edit_site_updates_the_card[chromium] |
| `GUI-X-07` | PASS |  | 8.4s | test_each_tab_has_a_url_and_browser_back_returns_to_it[chromium] |
| `GUI-07-05` | PASS |  | 10.9s | test_confirming_matched_rows_keeps_the_unmatched_ones[chromium] |
| `GUI-07-03` | PASS |  | 11.1s | test_confirming_matched_rows_records_the_payment[chromium] |
| `GUI-07-11` | PASS | new | 10.0s | test_excel_bank_samples_download_as_parser_compatible_workbooks[chromium] |
| `GUI-07-05` | PASS |  | 13.4s | test_manual_assignment_records_the_payment[chromium] |
| `GUI-08-03` | PASS |  | 19.1s | test_household_members_survive_a_backend_restart[chromium] |
| `GUI-08-02` | PASS |  | 14.1s | test_owner_occupied_unit_operational_dues_go_to_the_owner[chromium] |
| `GUI-08-06` | PASS |  | 16.0s | test_ownership_transfer_records_the_previous_owners_period[chromium] |
| `-` | PASS | new | 0.8s | test_fixture_shape |
| `GUI-09-06` | PASS |  | 8.9s | test_debt_aging_buckets_add_up_to_the_grand_total[chromium] |
| `GUI-09-06` | PASS |  | 6.7s | test_debt_aging_total_matches_the_open_ledger[chromium] |
| `GUI-X-06` | PASS |  | 8.1s | test_every_amount_uses_the_turkish_format[chromium] |
| `GUI-01-06` | PASS |  | 7.8s | test_penalty_detail_shows_days_and_the_penalty_amount[chromium] |
| `GUI-X-05` | PASS |  | 5.9s | test_reload_never_leaves_a_broken_screen[chromium] |
| `GUI-08-08` | PASS |  | 8.4s | test_remove_tenant_only_keeps_the_owner[chromium] |
| `GUI-09-07` | PASS |  | 7.0s | test_virman_moves_advance_to_the_capital_due[chromium] |
| `GUI-02-06` | PASS |  | 7.4s | test_interim_operating_budget_becomes_the_legal_basis_of_accrued_dues[chromium] |

## Automated scenarios not executed in this run

`SC-02-04-02`, `SC-03-04-04`, `SC-03-05-01`, `SC-05-01-01`, `SC-05-03-01`, `SC-05-04-01`, `SC-05-05-01`, `SC-05-06-01`, `SC-06-02-01`, `SC-06-03-01`, `SC-06-04-01`, `SC-06-06-06`, `SC-07-01-01`, `SC-07-01-02`, `SC-07-02-03`, `SC-07-03-02`, `SC-07-03-03`, `SC-07-03-04`, `SC-07-05-02`, `SC-07-06-01`, `SC-07-07-02`, `SC-07-07-03`, `SC-07-08-01`, `SC-07-08-02`, `SC-07-08-03`, `SC-07-08-04`, `SC-07-09-01`, `SC-07-09-02`, `SC-07-09-03`, `SC-07-09-04`, `SC-07-09-05`, `SC-07-09-06`, `SC-07-09-07`, `SC-07-09-08`, `SC-07-09-09`, `SC-07-09-10`, `SC-07-10-01`, `SC-07-10-02`, `SC-07-10-03`, `SC-07-10-04`, `SC-07-10-05`, `SC-07-10-06`, `SC-07-10-07`, `SC-07-11-01`, `SC-07-11-02`, `SC-07-11-03`, `SC-07-11-04`, `SC-07-11-05`, `SC-07-12-01`, `SC-07-12-02`, `SC-07-12-03`, `SC-07-12-04`, `SC-07-12-05`, `SC-07-12-06`, `SC-07-12-07`, `SC-07-13-01`, `SC-07-13-02`, `SC-07-13-03`, `SC-07-13-04`, `SC-08-02-03`, `SC-08-05-04`, `SC-08-05-05`, `SC-08-05-06`, `SC-08-05-07`, `SC-08-05-08`, `SC-08-05-09`, `SC-08-06-01`, `SC-08-06-02`, `SC-08-06-03`, `SC-08-07-01`, `SC-08-07-02`, `SC-08-07-03`, `SC-08-07-04`, `SC-08-07-05`, `SC-08-07-06`, `SC-08-07-07`, `SC-08-07-08`, `SC-08-07-09`, `SC-08-07-10`, `SC-08-08-01`, `SC-08-08-02`, `SC-08-08-03`, `SC-08-09-01`, `SC-08-09-02`, `SC-08-09-03`, `SC-08-09-04`, `SC-08-10-01`, `SC-08-10-02`, `SC-08-10-03`, `SC-08-10-04`, `SC-08-10-05`, `SC-08-10-06`, `SC-08-11-01`, `SC-08-11-02`, `SC-08-11-03`, `SC-08-12-01`, `SC-08-12-02`, `SC-08-12-03`, `SC-08-12-04`, `SC-08-12-05`, `SC-08-12-06`, `SC-08-12-07`, `SC-08-12-08`, `SC-08-12-09`, `SC-08-12-10`, `SC-08-12-11`, `SC-08-12-12`, `SC-08-12-13`, `SC-09-02-02`, `SC-09-04-05`, `SC-09-04-06`, `SC-09-04-07`, `SC-09-05-01`, `SC-09-05-02`, `SC-09-05-03`, `SC-09-05-04`, `SC-09-05-05`, `SC-09-05-06`, `SC-09-06-01`, `SC-09-06-02`, `SC-09-06-03`, `SC-09-06-04`, `SC-09-07-01`, `SC-10-05-03`, `SC-11-01-01`, `SC-11-01-02`, `SC-11-02-01`, `SC-11-02-02`, `SC-11-02-03`, `SC-11-02-04`, `SC-11-03-01`, `SC-11-03-02`, `SC-11-04-01`, `SC-11-04-02`, `SC-11-04-03`, `SC-11-05-01`, `SC-11-05-02`, `SC-11-05-03`, `SC-11-05-04`, `SC-11-06-01`, `SC-11-06-02`, `SC-11-07-01`, `SC-11-07-02`, `SC-11-07-03`, `SC-11-08-01`, `SC-11-08-02`, `SC-11-09-01`, `SC-11-09-02`, `SC-11-10-01`, `SC-11-10-02`, `SC-11-11-01`, `SC-11-12-01`, `SC-11-13-01`, `SC-11-14-01`, `SC-12-01-01`, `SC-12-02-01`, `SC-12-02-02`, `SC-12-02-04`, `SC-12-02-08`, `SC-12-02-09`, `SC-12-03-01`, `SC-12-03-02`, `SC-12-03-03`, `SC-12-05-01`, `SC-12-05-02`, `SC-12-05-03`, `SC-12-05-04`, `SC-12-05-05`, `SC-12-05-06`, `SC-12-06-01`, `SC-12-06-02`, `SC-12-06-03`, `SC-12-07-01`, `SC-12-07-02`, `SC-12-07-03`, `SC-12-08-01`, `SC-12-08-02`, `SC-12-09-01`, `SC-12-09-02`, `SC-12-10-01`, `SC-12-10-02`, `SC-12-10-03`, `SC-12-10-04`, `SC-12-10-05`, `SC-12-10-06`, `SC-12-10-07`, `SC-12-10-08`, `SC-12-10-09`, `SC-12-10-10`, `SC-12-10-11`, `SC-13-01-14`, `SC-13-03-05`, `SC-13-03-16`, `SC-13-03-19`, `SC-13-05-02`, `SC-13-07-02`, `SC-13-07-03`, `SC-13-07-07`, `SC-13-07-09`, `SC-13-09-01`, `SC-13-09-04`, `SC-13-09-05`, `SC-13-12-01`, `SC-13-12-02`, `SC-13-12-03`, `SC-13-12-04`, `SC-13-12-05`
