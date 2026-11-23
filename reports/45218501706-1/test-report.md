# Test run 20261123T164731Z-721d2d4

- **Task:** master
- **Result:** DEFECT (1 DEFECT, 2 SKIPPED, 324 PASS)
- **Executed:** 327 tests in 3583s, covering 228 of 435 automated scenarios
- **Commit:** `721d2d47bb` on `master`
- **Started:** 2026-11-23T16:47:31Z (ci)

## Executed tests

| Scenario / GUI id | Status | Change | Time | Name |
|---|---|---|---|---|
| `SC-01-01-01` | PASS | new | 7.7s | Preserve kurus-level precision in dues calculation |
| `SC-01-02-01` | PASS |  | 7.7s | Calculate 10-day overdue statutory delay penalty |
| `SC-01-03-01` | PASS |  | 7.7s | Emit reactive state on dashboard launch |
| `SC-01-03-02` | PASS |  | 121.3s | Site announcement reaches the resident |
| `SC-01-04-01` | PASS |  | 7.7s | Render resident hero balance with overdue amount |
| `SC-01-04-02` | PASS |  | 6.5s | Render zero balance without overdue badge |
| `SC-01-04-03` | PASS | new | 6.9s | Action buttons meet touch target size and unapproved features are hidden |
| `SC-01-05-01` | PASS |  | 5.2s | View recent financial movements |
| `SC-01-06-01` | PASS |  | 8.3s | Display cached dues when network is offline |
| `SC-02-01-01` | PASS |  | 5.4s | Cockpit shows the accrued total before any payment |
| `SC-02-01-02` | PASS |  | 8.0s | Cockpit counts a payment as collected |
| `SC-02-01-03` | PASS |  | 5.5s | Cockpit amounts keep kurus |
| `SC-02-01-04` | PASS |  | 12.0s | House type tariff is saved and a negative amount is rejected |
| `SC-02-01-05` | PASS |  | 10.7s | House type tariff rejects more than two decimals |
| `SC-02-01-06` | PASS | new | 8.3s | Display complex collection progress with the unit status breakdown |
| `SC-02-02-01` | PASS |  | 7.9s | Overdue filter lists every overdue flat |
| `SC-02-03-01` | PASS |  | 21.7s | Manager adds a new home owner manually |
| `SC-02-03-02` | PASS |  | 15.3s | Adding a resident to an occupied unit warns and saves nothing |
| `SC-02-03-03` | PASS |  | 36.2s | A resident without ledger history can be deleted |
| `SC-02-03-04` | PASS |  | 11.2s | A refused delete keeps the resident card |
| `SC-02-04-01` | PASS |  | 139.2s | Reminder action is offered for overdue flats |
| `SC-02-05-01` | PASS |  | 7.7s | Manager creates an announcement |
| `SC-03-01-01` | PASS |  | 8.4s | Query operations strictly scoped by tenant |
| `SC-03-02-01` | PASS |  | 4.5s | SaaS Admin views portfolio overview |
| `SC-03-02-02` | PASS |  | 1.1s | Portfolio statistics agree with the site list |
| `SC-03-03-01` | PASS |  | 8.9s | SaaS Admin creates new site and provisions first Site Admin |
| `SC-03-04-01` | PASS |  | 8.9s | Generate temporary password for newly registered Site Admin |
| `SC-03-04-02` | PASS |  | 7.8s | New manager is forced to change the temporary password |
| `SC-03-06-01` | PASS |  | 12.4s | Delete site without any related actions |
| `SC-03-06-02` | PASS |  | 4.5s | Invariant prevents deletion of active site with transactions |
| `SC-03-07-01` | PASS |  | 8.1s | SaaS Admin renews temporary password for a site manager |
| `SC-03-07-02` | PASS | new | 1.2s | Password renewal fails for non-existent site |
| `SC-04-01-01` | PASS |  | 9.7s | Generate 7-day secure invite link |
| `SC-04-02-01` | PASS |  | 9.7s | Site Admin copies or shares invite link |
| `SC-04-02-02` | PASS | new | 5.5s | Empty approval queue shows an empty state |
| `SC-04-03-01` | PASS | new | 1.4s | Home owner submits online registration |
| `SC-04-04-01` | PASS |  | 8.0s | Site manager views pending applications |
| `SC-04-05-01` | PASS |  | 7.7s | Approve applicant and provision account |
| `SC-04-05-02` | PASS |  | 6.7s | Approved resident signs in with the issued password |
| `SC-04-06-01` | PASS |  | 8.3s | Reject unverified registration |
| `SC-04-07-01` | PASS |  | 7.8s | Home owner generates unit-scoped invitation link |
| `SC-04-07-01` | PASS |  | 7.4s | Home owner generates unit-scoped invitation link |
| `SC-04-07-02` | PASS | new | 6.0s | Co-resident registers with unit-scoped permissions |
| `SC-06-01-01` | PASS |  | 4.7s | Home resident is restricted from site-wide management |
| `SC-06-02-02` | PASS |  | 5.4s | Site manager signs in and reaches the cockpit |
| `SC-06-02-03` | PASS |  | 6.9s | Home owner signs in and reaches the resident dashboard |
| `SC-06-02-04` | PASS |  | 4.4s | Wrong password shows an error and stays on the login screen |
| `SC-06-02-05` | PASS |  | 3.2s | Clearing the login cache empties the credential fields |
| `SC-06-02-05` | PASS |  | 3.9s | Clearing the login cache empties the credential fields |
| `SC-06-02-06` | PASS |  | 5.6s | Empty password is rejected without a request |
| `SC-06-03-02` | SKIPPED |  | 2.3s | Google sign-in button starts the provider flow |
| `SC-06-04-02` | PASS |  | 14.3s | Home owner changes the password from the profile and signs in again |
| `SC-06-04-03` | PASS |  | 9.7s | Logout returns to the login screen |
| `SC-06-04-04` | PASS |  | 14.2s | Browser back after logout does not re-enter the session |
| `SC-06-04-05` | PASS |  | 8.4s | Manager switches between the cockpit and the own flat |
| `SC-06-04-06` | PASS |  | 12.1s | Cancelling the logout confirmation keeps the session |
| `SC-06-05-01` | SKIPPED |  | 2.3s | Google sign-in option is offered on the login screen |
| `SC-06-05-03` | PASS |  | 5.4s | Email and password sign-in opens the role dashboard |
| `SC-06-06-01` | PASS |  | 6.3s | SaaS admin with a temporary password is held at the password change screen |
| `SC-06-06-02` | PASS |  | 197.8s | Site manager with a temporary password is held at the password change screen |
| `SC-06-06-03` | PASS |  | 144.8s | Home owner with a temporary password is held at the password change screen |
| `SC-06-06-04` | PASS |  | 148.7s | Home resident with a temporary password is held at the password change screen |
| `SC-06-06-05` | PASS |  | 164.7s | Auditor with a temporary password is held at the password change screen |
| `SC-07-02-01` | PASS |  | 7.8s | Site manager uploads a bank statement Excel file |
| `SC-07-02-02` | PASS |  | 11.7s | Approving a matched row clears the resident's balance |
| `SC-07-02-04` | PASS |  | 9.1s | An unmatched row is assigned to a unit by hand |
| `SC-07-02-05` | PASS | new | 8.0s | A stored payer-name alias auto-matches a re-uploaded row |
| `SC-07-03-01` | PASS |  | 5.5s | Real-time incoming transfer clears dues once |
| `SC-07-04-01` | PASS |  | 6.2s | Resident chooses the FAST transfer payment method |
| `SC-07-04-02` | PASS |  | 5.1s | Copy button puts the unspaced IBAN on the clipboard |
| `SC-07-05-01` | PASS |  | 5.3s | Surplus transfer is allocated to the resident advance balance |
| `SC-07-06-02` | PASS |  | 16.0s | Wrong statement format is rejected and the matching format is accepted |
| `SC-07-06-03` | PASS | new | 7.4s | Excel upload offers a sample for each catalogued Excel bank |
| `SC-07-06-03` | PASS | new | 10.0s | Excel upload offers a sample for each catalogued Excel bank |
| `SC-07-06-04` | PASS | new | 6.1s | Excel sample options exclude banks without an Excel format |
| `SC-07-07-01` | PASS |  | 19.1s | Manager accrues a period once and the duplicate is blocked |
| `SC-07-07-04` | PASS | new | 14.7s | Manual accrual charges each unit its tariff, not a fixed amount |
| `SC-08-01-01` | PASS |  | 19.6s | Accrue monthly operational dues to tenant and capital project to owner |
| `SC-08-02-01` | PASS |  | 19.5s | Household members are bound to the active resident session |
| `SC-08-02-02` | PASS | new | 22.2s | Household members are archived when the resident moves out |
| `SC-08-03-01` | PASS |  | 9.0s | Move-out preserves historical payment receipts and unsettled debt |
| `SC-08-03-02` | PASS | new | 9.1s | Move-out can keep the advance without changing the balance |
| `SC-08-03-03` | PASS | new | 10.7s | Move-out payout is debited only after four-eyes approval |
| `SC-08-03-04` | PASS | new | 11.3s | Move-out transfer changes debtor only after four-eyes approval |
| `SC-08-04-01` | PASS |  | 7.5s | New tenant moves in and past occupancy history is retrievable |
| `SC-08-04-02` | PASS | new | 14.2s | Tenant move-in opens an active tenant session |
| `SC-08-05-01` | PASS |  | 14.1s | Change property owner upon title deed sale without affecting tenant |
| `SC-08-05-02` | PASS | new | 2.1s | Capital dues after the transfer are billed to the new owner |
| `SC-08-05-03` | PASS | new | 17.4s | Previous owner's advance is paid out or transferred only with a second approver |
| `SC-09-01-01` | PASS |  | 9.7s | Filter payment stream by tenant payments for current month |
| `SC-09-01-02` | PASS | new | 6.3s | Debt aging buckets total the overdue sum |
| `SC-09-02-01` | PASS |  | 7.6s | Settle delay penalty first, then oldest dues, then credit surplus as advance |
| `SC-09-02-03` | PASS | new | 3.2s | Owner payment never settles tenant operational dues without joint-liability opt-in |
| `SC-09-03-01` | PASS |  | 8.1s | Generate itemized sub-ledger statement for a tenant |
| `SC-09-03-02` | PASS |  | 5.7s | Resident statement ages an overdue due with its penalty |
| `SC-09-04-01` | PASS |  | 5.2s | Issue sequential payment receipt upon settlement |
| `SC-09-04-02` | PASS |  | 10.5s | Manager downloads the receipt PDF and reverses the receipt |
| `SC-09-04-03` | PASS |  | 7.6s | Receipt shows the penalty, principal and advance split |
| `SC-09-04-04` | PASS |  | 8.0s | Card payment on the provider page issues a receipt |
| `SC-10-01-01` | PASS |  | 12.4s | Budget is split by land share without rounding drift |
| `SC-10-01-02` | PASS |  | 10.9s | Equal allocation gives every unit the same share |
| `SC-10-02-01` | PASS |  | 11.8s | Accruing an installment charges owners only |
| `SC-10-03-01` | PASS |  | 6.5s | Owner FAST payment raises the collected amount of the project |
| `SC-10-03-02` | PASS |  | 7.2s | Tenant payment produces a TBK 314 rent-offset receipt |
| `SC-10-04-01` | PASS |  | 6.9s | Virman dialog offers the real advance balance of the unit |
| `SC-10-04-02` | PASS | new | 12.6s | Virman transfer clears a capital due from the advance balance |
| `SC-10-05-01` | PASS |  | 9.6s | Disbursement within collected cash updates the reserve |
| `SC-10-05-02` | PASS |  | 14.7s | Disbursement larger than collected cash is refused |
| `SC-10-06-01` | PASS |  | 6.9s | Owner dashboard shows capital dues separately |
| `SC-10-06-02` | PASS |  | 6.0s | Capital project is marked as the responsibility of the owner |
| `SC-10-07-01` | PASS |  | 117.8s | Capital segment offers project creation |
| `SC-12-02-03` | PASS | new | 9.1s | The directory pager adapts to a narrow viewport |
| `SC-12-02-05` | PASS |  | 9.1s | Unit search folds Turkish names and phone digits |
| `SC-12-02-06` | PASS |  | 9.1s | Unit rows expose distinct actions and details targets |
| `SC-12-02-07` | PASS |  | 9.1s | Compact unit rows adapt from phone to desktop widths |
| `SC-12-03-04` | PASS |  | 12.3s | Choose an existing person through the live search API |
| `SC-12-04-01` | PASS |  | 10.3s | People paging and activation filters use the server query |
| `SC-12-04-02` | PASS | new | 10.3s | People search and directory position survive restoration |
| `SC-12-06-04` | PASS | new | 14.1s | Unit actions started from the residents tab choose people through the person picker |
| `SC-13-01-01` | PASS | new | 19.4s | A site with no data shows empty states, not errors |
| `SC-13-01-02` | PASS | new | 2.8s | Accruing a period on a site with no units is refused with a clear reason |
| `SC-13-01-03` | PASS | new | 2.6s | A payment arriving at a site with no units is not lost |
| `SC-13-01-04` | PASS | new | 15.3s | Units with no people show as unassigned and cannot be billed to anyone |
| `SC-13-01-05` | PASS | new | 43.2s | The manager can add the first owner and tenant from an empty unit |
| `SC-13-01-06` | PASS | new | 16.8s | People without a billing period have no debt and a clear first action |
| `SC-13-01-07` | PASS | new | 2.6s | The first accrual charges each unit its tariff and the right debtor |
| `SC-13-01-08` | PASS | new | 2.6s | Units without an owner are reported separately from the accrual |
| `SC-13-01-09` | PASS | new | 3.7s | A period accrued before anyone lived in the units leaves nothing to collect |
| `SC-13-01-11` | PASS | new | 15.8s | Accruing the same period again after residents arrive is blocked, not doubled |
| `SC-13-01-12` | PASS | new | 122.2s | Growing the site from F0 to F2 through the screens keeps every page consistent |
| `SC-13-01-13` | PASS | new | 3.7s | Every starting state survives a backend restart unchanged |
| `SC-13-01-13` | PASS | new | 3.0s | Every starting state survives a backend restart unchanged |
| `SC-13-01-13` | PASS | new | 2.8s | Every starting state survives a backend restart unchanged |
| `SC-13-01-13` | PASS | new | 3.4s | Every starting state survives a backend restart unchanged |
| `SC-13-02-01` | PASS | new | 10.3s | Residents with a single accrual period show one debt each on every screen |
| `SC-13-02-02` | PASS | new | 16.2s | The resident sees exactly what the admin sees for the same unit |
| `SC-13-02-03` | PASS | new | 2.9s | The late fee follows the clock day by day |
| `SC-13-02-04` | PASS | new | 12.9s | Multiple periods with mixed debts add up per unit and per site |
| `SC-13-02-05` | PASS | new | 2.6s | A single debt in a previous month stays attached to that month |
| `SC-13-02-06` | PASS | new | 2.6s | A single debt in the current month is the only one in the youngest bucket |
| `SC-13-02-07` | PASS | new | 4.2s | Multiple debts across periods are listed oldest first with a fee each |
| `SC-13-02-08` | PASS | new | 2.7s | An advance balance has already offset later periods |
| `SC-13-02-09` | PASS | new | 2.8s | A fourth accrual adds exactly one liability per responsible debtor |
| `SC-13-02-10` | PASS | new | 4.4s | A closed period accepts no new accrual or edit but keeps its open debts |
| `SC-13-02-11` | PASS | new | 3.0s | A payment toward a closed period is still allocated to its oldest debt |
| `SC-13-03-01` | PASS | new | 4.5s | A mid-month move-in splits a period between owner and tenant |
| `SC-13-03-04` | PASS | new | 3.8s | A resident added after accruals is charged from their start residing date |
| `SC-13-03-08` | PASS | new | 2.7s | Proration respects month length and edge days |
| `SC-13-03-08` | PASS | new | 4.2s | Proration respects month length and edge days |
| `SC-13-03-08` | PASS | new | 4.2s | Proration respects month length and edge days |
| `SC-13-03-08` | PASS | new | 2.6s | Proration respects month length and edge days |
| `SC-13-03-08` | PASS | new | 2.7s | Proration respects month length and edge days |
| `SC-13-03-10` | PASS | new | 6.0s | One person who owns one unit and rents another is billed in each role |
| `SC-13-03-11` | PASS | new | 3.6s | The same national id entered twice does not create a second person |
| `SC-13-03-12` | PASS | new | 3.6s | Owner moves in after the tenant leaves and takes the operational dues back |
| `SC-13-03-13` | PASS | new | 2.2s | Switching proration changes responsibility for a mid-month move-in |
| `SC-13-03-13` | PASS | new | 2.5s | Switching proration changes responsibility for a mid-month move-in |
| `SC-13-03-15` | PASS | new | 3.8s | A unit created mid-month is billed for chargeable days only |
| `SC-13-03-17` | PASS | new | 3.3s | A share whose responsibility starts after the period due date is not late before it existed |
| `SC-13-03-17` | PASS | new | 3.3s | A share whose responsibility starts after the period due date is not late before it existed |
| `SC-13-03-17` | PASS | new | 3.8s | A share whose responsibility starts after the period due date is not late before it existed |
| `SC-13-03-17` | PASS | new | 4.2s | A share whose responsibility starts after the period due date is not late before it existed |
| `SC-13-03-18` | PASS | new | 3.6s | A sale of a tenant-occupied unit with the same tenant is not split |
| `SC-13-03-20` | PASS | new | 3.8s | A re-split share keeps an effective due date and a late fee that follow its creation |
| `SC-13-04-01` | PASS | new | 3.3s | A payment clears the oldest period first |
| `SC-13-04-02` | PASS | new | 2.7s | Paying exactly the whole debt leaves zero and no advance |
| `SC-13-04-03` | PASS | new | 2.6s | One kuruş short leaves one kuruş open |
| `SC-13-04-04` | PASS | new | 2.8s | An overpayment becomes an advance that offsets the next accrual |
| `SC-13-04-05` | PASS | new | 3.4s | Invalid payment amounts are rejected without any side effect |
| `SC-13-04-06` | PASS | new | 4.2s | The bank webhook matches a transfer to the unit and allocates it |
| `SC-13-04-07` | PASS | new | 4.3s | The same bank transaction sent twice is applied once |
| `SC-13-04-08` | PASS | new | 2.7s | Two transfers for one unit at the same moment are both applied |
| `SC-13-04-09` | PASS | new | 6.2s | A transfer matched to another site is applied only there |
| `SC-13-04-10` | PASS | new | 4.3s | The grace boundary decides whether a late fee is charged |
| `SC-13-04-10` | PASS | new | 3.0s | The grace boundary decides whether a late fee is charged |
| `SC-13-04-10` | PASS | new | 2.7s | The grace boundary decides whether a late fee is charged |
| `SC-13-04-10` | PASS | new | 2.7s | The grace boundary decides whether a late fee is charged |
| `SC-13-04-10` | PASS | new | 3.4s | The grace boundary decides whether a late fee is charged |
| `SC-13-04-11` | PASS | new | 4.0s | A correction after a partial payment moves the paid amount to the advance |
| `SC-13-04-12` | PASS | new | 2.8s | The requester of a correction cannot approve it |
| `SC-13-04-14` | PASS | new | 2.9s | A payment reversal restores the debt it settled and the fee it stopped |
| `SC-13-04-15` | PASS | new | 3.8s | A unit-level transfer on a unit with several debtors waits for the manager |
| `SC-13-04-15` | PASS | new | 3.6s | A unit-level transfer on a unit with several debtors waits for the manager |
| `SC-13-04-16` | PASS | new | 3.2s | A payment for a unit with no debt becomes the payer's advance |
| `SC-13-05-01` | PASS | new | 2.6s | Invalid accrual input is rejected and creates nothing |
| `SC-13-05-01` | PASS | new | 3.1s | Invalid accrual input is rejected and creates nothing |
| `SC-13-05-01` | PASS | new | 2.6s | Invalid accrual input is rejected and creates nothing |
| `SC-13-05-01` | PASS | new | 3.4s | Invalid accrual input is rejected and creates nothing |
| `SC-13-05-03` | PASS | new | 2.8s | A duplicate accrual with a different amount is still blocked |
| `SC-13-05-04` | PASS | new | 3.1s | Two admins accruing the same period at the same moment create one set of liabilities |
| `SC-13-05-05` | PASS | new | 4.6s | The scheduler catches up months that were missed |
| `SC-13-05-06` | PASS | new | 4.5s | Moving out with debt keeps the debt and the history |
| `SC-13-05-07` | PASS | new | 5.5s | Moving out with an advance requires a decision before the advance leaves |
| `SC-13-05-07` | PASS | new | 3.5s | Moving out with an advance requires a decision before the advance leaves |
| `SC-13-05-08` | PASS | new | 3.1s | Moving out twice and moving in on an occupied unit are refused |
| `SC-13-05-09` | PASS | new | 4.1s | A move-out recorded after accrual re-splits the open liability |
| `SC-13-05-11` | PASS | new | 4.3s | Merging two duplicate people keeps every liability and payment |
| `SC-13-05-12` | PASS | new | 2.8s | A resident cannot call manager actions |
| `SC-13-05-13` | PASS | new | 4.4s | A manager of another site sees nothing of this site |
| `SC-13-05-14` | PASS | new | 4.9s | The month boundary uses Istanbul time, not UTC |
| `SC-13-05-15` | PASS | new | 2.7s | A late fee never makes a settled liability reopen |
| `SC-13-05-16` | PASS | new | 4.7s | Balances are identical after a backend restart at any point of the history |
| `SC-13-05-16` | PASS | new | 5.2s | Balances are identical after a backend restart at any point of the history |
| `SC-13-05-16` | PASS | new | 3.4s | Balances are identical after a backend restart at any point of the history |
| `SC-13-05-16` | PASS | new | 3.7s | Balances are identical after a backend restart at any point of the history |
| `SC-13-05-18` | PASS | new | 3.7s | A tenant who left without notice is moved out at the real date and the owner takes over |
| `SC-13-05-18` | PASS | new | 6.0s | A tenant who left without notice is moved out at the real date and the owner takes over |
| `SC-13-07-01` | PASS | new | 5.0s | Every starting state can be built using the documented fixture path |
| `SC-13-07-01` | PASS | new | 7.9s | Every starting state can be built using the documented fixture path |
| `SC-13-07-01` | PASS | new | 8.3s | Every starting state can be built using the documented fixture path |
| `SC-13-07-01` | PASS | new | 4.6s | Every starting state can be built using the documented fixture path |
| `SC-13-07-01` | PASS | new | 5.1s | Every starting state can be built using the documented fixture path |
| `SC-13-07-01` | PASS | new | 5.1s | Every starting state can be built using the documented fixture path |
| `SC-13-07-04` | PASS | new | 21.4s | Teardown runs when the journey fails |
| `SC-13-07-05` | PASS | new | 6.8s | Teardown works after a half-built state |
| `SC-13-07-06` | PASS | new | 3.7s | Two active journeys do not see each other's data |
| `SC-13-07-08` | PASS | new | 3.7s | A leftover site from a crashed earlier run is cleaned before the next run starts |
| `SC-13-07-10` | PASS | new | 6.6s | Every historical starting state can be built using the documented fixture path |
| `SC-13-07-10` | PASS | new | 6.6s | Every historical starting state can be built using the documented fixture path |
| `SC-13-08-03` | PASS | new | 9.9s | A search with zero matches is recoverable without changing the site |
| `SC-13-08-05` | PASS | new | 18.6s | Cancelling accrual confirmation makes no financial change |
| `SC-13-09-02` | PASS | new | 2.7s | A partial payment reduces the principal used for later fees |
| `SC-13-09-03` | PASS | new | 4.4s | A backdated payment recalculates fees using its value date |
| `SC-13-09-06` | PASS | new | 4.4s | Concurrent deliveries of the same bank event are credited once |
| `SC-13-09-07` | PASS | new | 3.4s | An unmatched statement item can be approved exactly once |
| `SC-13-09-07` | PASS | new | 4.5s | An unmatched statement item can be approved exactly once |
| `SC-13-09-08` | PASS | new | 2.6s | Operational and capital balances stay separate for a tenant-occupied unit |
| `SC-13-09-09` | PASS | new | 2.5s | The aging bucket changes at each day boundary |
| `SC-13-09-09` | PASS | new | 4.0s | The aging bucket changes at each day boundary |
| `SC-13-09-09` | PASS | new | 4.0s | The aging bucket changes at each day boundary |
| `SC-13-09-09` | PASS | new | 2.6s | The aging bucket changes at each day boundary |
| `SC-13-09-09` | PASS | new | 2.9s | The aging bucket changes at each day boundary |
| `SC-13-09-09` | PASS | new | 2.6s | The aging bucket changes at each day boundary |
| `SC-13-09-09` | PASS | new | 2.5s | The aging bucket changes at each day boundary |
| `SC-13-09-09` | PASS | new | 3.2s | The aging bucket changes at each day boundary |
| `SC-13-10-01` | PASS | new | 3.6s | Manager lists, searches and aggregates use the authenticated site |
| `SC-13-10-02` | PASS | new | 5.6s | Direct reads and downloads require access to the requested site |
| `SC-13-10-03` | PASS | new | 3.9s | A site parameter cannot widen a manager's collection or export permissions |
| `SC-13-10-04` | PASS | new | 5.8s | A manager cannot mutate another site's records |
| `SC-13-10-05` | PASS | new | 4.6s | A resident cannot read another unit's financial records |
| `SC-13-10-06` | PASS | new | 3.2s | A tenant statement excludes the owner's private transactions for the same unit |
| `SC-13-10-07` | PASS | new | 3.5s | Replacing a tenant keeps each occupant's history and receipts private |
| `SC-13-11-01` | PASS | new | 2.6s | A liability moves through PENDING, OVERDUE, PAID and CANCELLED |
| `SC-13-11-01` | PASS | new | 3.2s | A liability moves through PENDING, OVERDUE, PAID and CANCELLED |
| `SC-13-11-01` | PASS | new | 4.2s | A liability moves through PENDING, OVERDUE, PAID and CANCELLED |
| `SC-13-11-01` | PASS | new | 4.3s | A liability moves through PENDING, OVERDUE, PAID and CANCELLED |
| `SC-13-11-01` | PASS | new | 2.6s | A liability moves through PENDING, OVERDUE, PAID and CANCELLED |
| `SC-13-11-01` | PASS | new | 3.0s | A liability moves through PENDING, OVERDUE, PAID and CANCELLED |
| `SC-13-11-01` | PASS | new | 2.7s | A liability moves through PENDING, OVERDUE, PAID and CANCELLED |
| `SC-13-11-01` | PASS | new | 2.7s | A liability moves through PENDING, OVERDUE, PAID and CANCELLED |
| `SC-13-11-01` | PASS | new | 3.3s | A liability moves through PENDING, OVERDUE, PAID and CANCELLED |
| `SC-13-11-02` | PASS | new | 3.5s | A settled or cancelled liability cannot be paid or corrected again |
| `SC-13-11-02` | PASS | new | 3.9s | A settled or cancelled liability cannot be paid or corrected again |
| `SC-13-11-02` | PASS | new | 3.0s | A settled or cancelled liability cannot be paid or corrected again |
| `SC-13-11-02` | PASS | new | 3.7s | A settled or cancelled liability cannot be paid or corrected again |
| `SC-13-11-03` | PASS | new | 2.8s | A reversal moves a PAID liability back to OVERDUE |
| `SC-13-11-04` | PASS | new | 2.8s | Each period status allows only its own commands |
| `SC-13-11-04` | PASS | new | 4.4s | Each period status allows only its own commands |
| `SC-13-11-04` | PASS | new | 2.7s | Each period status allows only its own commands |
| `SC-13-11-04` | PASS | new | 3.1s | Each period status allows only its own commands |
| `SC-13-11-04` | PASS | new | 2.8s | Each period status allows only its own commands |
| `SC-13-11-04` | PASS | new | 2.8s | Each period status allows only its own commands |
| `SC-13-11-04` | PASS | new | 4.1s | Each period status allows only its own commands |
| `SC-13-11-06` | PASS | new | 2.7s | A bank statement item reaches each reconciliation status |
| `SC-13-11-06` | PASS | new | 4.2s | A bank statement item reaches each reconciliation status |
| `SC-13-11-06` | PASS | new | 4.2s | A bank statement item reaches each reconciliation status |
| `SC-13-11-06` | PASS | new | 2.7s | A bank statement item reaches each reconciliation status |
| `SC-13-11-06` | PASS | new | 3.0s | A bank statement item reaches each reconciliation status |
| `SC-13-11-07` | PASS | new | 4.3s | A rejected or approved statement item cannot change status again |
| `SC-13-11-08` | PASS | new | 2.8s | Each unit occupancy state offers its own commands and refuses the rest |
| `SC-13-11-08` | PASS | new | 4.6s | Each unit occupancy state offers its own commands and refuses the rest |
| `SC-13-11-08` | PASS | new | 4.3s | Each unit occupancy state offers its own commands and refuses the rest |
| `SC-13-11-08` | PASS | new | 2.9s | Each unit occupancy state offers its own commands and refuses the rest |
| `SC-13-13-01` | PASS | new | 4.3s | Onboard two sites and create all eighty-eight units from zero |
| `SC-13-13-02` | PASS | new | 29.4s | Accrue four periods and verify mixed payment histories |
| `SC-13-13-02` | PASS | new | 12.8s | Accrue four periods and verify mixed payment histories |
| `SC-13-13-02` | PASS | new | 9.0s | Accrue four periods and verify mixed payment histories |
| `SC-13-14-01` | PASS | new | 7.6s | Titles and occupancies change on their effective dates |
| `SC-13-14-02` | PASS | new | 5.5s | March charges follow the new owners and the vacancies |
| `SC-13-14-03` | PASS | new | 8.7s | April move-ins redirect new charges and show only the current household |
| `SC-13-14-04` | PASS | new | 5.8s | Former owners and tenants remain collectible next to their successors |
| `SC-13-14-05` | PASS | new | 4.4s | Receipts before the changes settle the paying debtor's own periods |
| `SC-13-14-06` | PASS | new | 5.9s | A designated April receipt leaves February and March unpaid |
| `SC-13-14-07` | PASS | new | 5.9s | Title changes, vacancies and accruals move no cash between sites |
| `SC-13-14-08` | PASS | new | 5.8s | A successor's receipt settles only the successor's own charges |
| `SC-13-14-08` | PASS | new | 9.4s | A successor's receipt settles only the successor's own charges |
| `SC-13-14-08` | PASS | new | 5.7s | A successor's receipt settles only the successor's own charges |
| `SC-13-14-08` | PASS | new | 6.5s | A successor's receipt settles only the successor's own charges |
| `SC-13-14-09` | PASS | new | 6.0s | The final open debt stays with each former and current debtor |
| `SC-13-25-01` | PASS | new | 0.7s | Posted operating cash equals cumulative gross receipts at every checkpoint |
| `SC-13-25-01` | PASS | new | 1.3s | Posted operating cash equals cumulative gross receipts at every checkpoint |
| `SC-13-25-01` | PASS | new | 0.0s | Posted operating cash equals cumulative gross receipts at every checkpoint |
| `SC-13-25-01` | PASS | new | 1.1s | Posted operating cash equals cumulative gross receipts at every checkpoint |
| `SC-13-25-02` | PASS | new | 29.4s | Eleven open rows are matched by site, unit, primary debtor and period |
| `SC-13-25-02` | PASS | new | 0.3s | Eleven open rows are matched by site, unit, primary debtor and period |
| `SC-13-25-03` | PASS | new | 29.4s | Homeowner totals separate primary debt from joint exposure |
| `SC-13-25-03` | PASS | new | 0.4s | Homeowner totals separate primary debt from joint exposure |
| `SC-13-25-04` | PASS | new | 29.4s | Site totals are reconciled independently and count a joint receivable once |
| `SC-13-25-04` | PASS | new | 0.4s | Site totals are reconciled independently and count a joint receivable once |
| `SC-13-25-05` | PASS | new | 0.8s | Final period status distinguishes partial payment from a missed payment |
| `SC-13-25-06` | PASS | new | 29.4s | Site operating cash matches posted receipts and a Site A payment does not leak into Site B |
| `SC-13-25-07` | PASS | new | 29.4s | The manager statements match the eleven open rows and the site totals on 2027-04-10 |
| `SC-13-25-07` | DEFECT | new | 9.7s | The manager statements match the eleven open rows and the site totals on 2027-04-10 |
| `SC-13-26-01` | PASS | new | 1.9s | The onboarding attempt starts with no residential sites |
| `SC-13-26-02` | PASS | new | 29.4s | Two sites remain identifiable from onboarding through final reconciliation |
| `GUI-J-01` | PASS |  | 188.3s | test_saas_admin_journey[chromium] |
| `GUI-X-04` | PASS |  | 6.6s | test_mobile_viewport_login_and_dashboard[chromium-homeowner-ResidentHome] |
| `GUI-X-04` | PASS |  | 4.6s | test_mobile_viewport_login_and_dashboard[chromium-manager-ManagerCockpit] |
| `GUI-X-02` | PASS |  | 6.2s | test_theme_choice_on_login_screen_holds_after_login[chromium] |
| `GUI-03-05` | PASS |  | 6.9s | test_edit_site_updates_the_card[chromium] |
| `GUI-X-07` | PASS |  | 6.4s | test_each_tab_has_a_url_and_browser_back_returns_to_it[chromium] |
| `GUI-07-05` | PASS |  | 11.6s | test_confirming_matched_rows_keeps_the_unmatched_ones[chromium] |
| `GUI-07-03` | PASS |  | 9.4s | test_confirming_matched_rows_records_the_payment[chromium] |
| `GUI-07-11` | PASS | new | 7.3s | test_excel_bank_samples_download_as_parser_compatible_workbooks[chromium] |
| `GUI-07-05` | PASS |  | 12.7s | test_manual_assignment_records_the_payment[chromium] |
| `GUI-08-03` | PASS |  | 21.5s | test_household_members_survive_a_backend_restart[chromium] |
| `GUI-08-02` | PASS |  | 14.0s | test_owner_occupied_unit_operational_dues_go_to_the_owner[chromium] |
| `GUI-08-06` | PASS |  | 14.2s | test_ownership_transfer_records_the_previous_owners_period[chromium] |
| `-` | PASS | new | 1.1s | test_fixture_shape |
| `GUI-09-06` | PASS |  | 6.8s | test_debt_aging_buckets_add_up_to_the_grand_total[chromium] |
| `GUI-09-06` | PASS |  | 8.7s | test_debt_aging_total_matches_the_open_ledger[chromium] |
| `GUI-X-06` | PASS |  | 6.6s | test_every_amount_uses_the_turkish_format[chromium] |
| `GUI-01-06` | PASS |  | 6.0s | test_penalty_detail_shows_days_and_the_penalty_amount[chromium] |
| `GUI-X-05` | PASS |  | 6.8s | test_reload_never_leaves_a_broken_screen[chromium] |
| `GUI-08-08` | PASS |  | 8.4s | test_remove_tenant_only_keeps_the_owner[chromium] |
| `GUI-09-07` | PASS |  | 6.8s | test_virman_moves_advance_to_the_capital_due[chromium] |
| `GUI-02-06` | PASS |  | 7.4s | test_interim_operating_budget_becomes_the_legal_basis_of_accrued_dues[chromium] |

## Automated scenarios not executed in this run

`SC-02-04-02`, `SC-03-04-04`, `SC-03-05-01`, `SC-05-01-01`, `SC-05-03-01`, `SC-05-04-01`, `SC-05-05-01`, `SC-05-06-01`, `SC-06-02-01`, `SC-06-03-01`, `SC-06-04-01`, `SC-06-06-06`, `SC-07-01-01`, `SC-07-01-02`, `SC-07-02-03`, `SC-07-03-02`, `SC-07-03-03`, `SC-07-03-04`, `SC-07-05-02`, `SC-07-06-01`, `SC-07-07-02`, `SC-07-07-03`, `SC-07-08-01`, `SC-07-08-02`, `SC-07-08-03`, `SC-07-08-04`, `SC-07-09-01`, `SC-07-09-02`, `SC-07-09-03`, `SC-07-09-04`, `SC-07-09-05`, `SC-07-09-06`, `SC-07-09-07`, `SC-07-09-08`, `SC-07-09-09`, `SC-07-09-10`, `SC-07-10-01`, `SC-07-10-02`, `SC-07-10-03`, `SC-07-10-04`, `SC-07-10-05`, `SC-07-10-06`, `SC-07-10-07`, `SC-07-11-01`, `SC-07-11-02`, `SC-07-11-03`, `SC-07-11-04`, `SC-07-11-05`, `SC-07-12-01`, `SC-07-12-02`, `SC-07-12-03`, `SC-07-12-04`, `SC-07-12-05`, `SC-07-12-06`, `SC-07-12-07`, `SC-07-13-01`, `SC-07-13-02`, `SC-07-13-03`, `SC-07-13-04`, `SC-08-02-03`, `SC-08-05-04`, `SC-08-05-05`, `SC-08-05-06`, `SC-08-05-07`, `SC-08-05-08`, `SC-08-05-09`, `SC-08-06-01`, `SC-08-06-02`, `SC-08-06-03`, `SC-08-07-01`, `SC-08-07-02`, `SC-08-07-03`, `SC-08-07-04`, `SC-08-07-05`, `SC-08-07-06`, `SC-08-07-07`, `SC-08-07-08`, `SC-08-07-09`, `SC-08-07-10`, `SC-08-08-01`, `SC-08-08-02`, `SC-08-08-03`, `SC-08-09-01`, `SC-08-09-02`, `SC-08-09-03`, `SC-08-09-04`, `SC-08-10-01`, `SC-08-10-02`, `SC-08-10-03`, `SC-08-10-04`, `SC-08-10-05`, `SC-08-10-06`, `SC-08-11-01`, `SC-08-11-02`, `SC-08-11-03`, `SC-08-12-01`, `SC-08-12-02`, `SC-08-12-03`, `SC-08-12-04`, `SC-08-12-05`, `SC-08-12-06`, `SC-08-12-07`, `SC-08-12-08`, `SC-08-12-09`, `SC-08-12-10`, `SC-08-12-11`, `SC-08-12-12`, `SC-08-12-13`, `SC-09-02-02`, `SC-09-04-05`, `SC-09-04-06`, `SC-09-04-07`, `SC-09-05-01`, `SC-09-05-02`, `SC-09-05-03`, `SC-09-05-04`, `SC-09-05-05`, `SC-09-05-06`, `SC-09-06-01`, `SC-09-06-02`, `SC-09-06-03`, `SC-09-06-04`, `SC-09-07-01`, `SC-10-05-03`, `SC-11-01-01`, `SC-11-01-02`, `SC-11-02-01`, `SC-11-02-02`, `SC-11-02-03`, `SC-11-02-04`, `SC-11-03-01`, `SC-11-03-02`, `SC-11-04-01`, `SC-11-04-02`, `SC-11-04-03`, `SC-11-05-01`, `SC-11-05-02`, `SC-11-05-03`, `SC-11-05-04`, `SC-11-06-01`, `SC-11-06-02`, `SC-11-07-01`, `SC-11-07-02`, `SC-11-07-03`, `SC-11-08-01`, `SC-11-08-02`, `SC-11-09-01`, `SC-11-09-02`, `SC-11-10-01`, `SC-11-10-02`, `SC-11-11-01`, `SC-11-12-01`, `SC-11-13-01`, `SC-11-14-01`, `SC-12-01-01`, `SC-12-02-01`, `SC-12-02-02`, `SC-12-02-04`, `SC-12-02-08`, `SC-12-02-09`, `SC-12-03-01`, `SC-12-03-02`, `SC-12-03-03`, `SC-12-05-01`, `SC-12-05-02`, `SC-12-05-03`, `SC-12-05-04`, `SC-12-05-05`, `SC-12-05-06`, `SC-12-06-01`, `SC-12-06-02`, `SC-12-06-03`, `SC-12-07-01`, `SC-12-07-02`, `SC-12-07-03`, `SC-12-08-01`, `SC-12-08-02`, `SC-12-09-01`, `SC-12-09-02`, `SC-12-10-01`, `SC-12-10-02`, `SC-12-10-03`, `SC-12-10-04`, `SC-12-10-05`, `SC-12-10-06`, `SC-12-10-07`, `SC-12-10-08`, `SC-12-10-09`, `SC-12-10-10`, `SC-12-10-11`, `SC-13-01-14`, `SC-13-03-05`, `SC-13-03-16`, `SC-13-03-19`, `SC-13-05-02`, `SC-13-07-02`, `SC-13-07-03`, `SC-13-07-07`, `SC-13-07-09`, `SC-13-09-01`, `SC-13-09-04`, `SC-13-09-05`, `SC-13-12-01`, `SC-13-12-02`, `SC-13-12-03`, `SC-13-12-04`, `SC-13-12-05`

## CI suite collection

Run `45218501706` attempt `1` at `721d2d47bbbde915f3985e31a1c1208ed8ac65c6`.

| Suite | Runner | Producer | Status | Cases | Missing shards |
|---|---|---|---:|---:|---|
| e2e | pytest-playwright | e2e | collected | 307 | — |

**e2e shard evidence**

| Shard | Status | Attempt | JUnit files | Cases |
|---|---|---:|---:|---:|
| 1/8 | passed | 1 | 1 | 38 |
| 2/8 | passed | 1 | 1 | 38 |
| 3/8 | passed | 1 | 1 | 38 |
| 4/8 | passed | 1 | 1 | 38 |
| 5/8 | passed | 1 | 1 | 38 |
| 6/8 | passed | 1 | 1 | 39 |
| 7/8 | passed | 1 | 1 | 39 |
| 8/8 | passed | 1 | 1 | 39 |

| rust | cargo | rust | incomplete | 0 | — |
| rust-db-test | cargo | rust | collected | 64 | — |
| rust-db-opt-in | cargo | rust | collected | 2 | — |
| flutter | flutter | flutter | incomplete | 0 | — |
| money-fixtures | cargo | flutter | collected | 4 | — |
| money-fixtures | flutter | flutter | collected | 7 | — |
| harness-selftest | unittest | lint | collected | 726 | — |
| api-system | sitepulse-check | rust | collected | 39 | — |
| schema-integrity | sitepulse-check | rust | collected | 94 | — |

### Producer jobs

| Job | Result | Source attempt | Artifact |
|---|---|---:|---|
| e2e | success | 1 | e2e-shard-6-attempt-1, e2e-shard-8-attempt-1, e2e-shard-4-attempt-1, e2e-shard-7-attempt-1, e2e-shard-2-attempt-1, e2e-shard-5-attempt-1, e2e-shard-3-attempt-1, e2e-shard-1-attempt-1 |
| flutter | success | 1 | sitepulse-suite-flutter-attempt-1 |
| lint | success | 1 | sitepulse-suite-lint-attempt-1 |
| rust | success | 1 | sitepulse-suite-rust-attempt-1 |
| verify | success | 1 | sitepulse-suite-verify-attempt-1 |

### Gates

| Gate | Status | Duration | Exit | Source attempt |
|---|---|---:|---:|---:|
| api-system | passed | 27.699s | 0 | 1 |
| fake-fail | failed | 0.008s | 3 | 1 |
| fake-pass | passed | 0.009s | 0 | 1 |
| feature-traceability | passed | 2.466s | 0 | 1 |
| flutter-analyze | passed | 10.962s | 0 | 1 |
| flutter-reuse | passed | 0.656s | 0 | 1 |
| flutter-test | passed | 73.105s | 0 | 1 |
| gui-e2e | passed (reused) | 3380.656s | 0, 0, 0, 0, 0, 0, 0, 0 | 6/8=1, 8/8=1, 4/8=1, 7/8=1, 2/8=1, 5/8=1, 3/8=1, 1/8=1 |
| harness-selftest | passed | 11.971s | 0 | 1 |
| lock-lint | passed | 0.121s | 0 | 1 |
| logging-standards-lint | passed | 1.175s | 0 | 1 |
| money-fixtures | passed | 55.043s | 0, 0 | 1 |
| persistence-lint | passed | 0.064s | 0 | 1 |
| rust-build | incomplete | 95.836s | 0 | 1 |
| rust-clippy | incomplete | 27.806s | 0 | 1 |
| rust-db-test | passed | 72.83s | 0, 0, 0 | 1 |
| rust-standards-lint | passed | 10.803s | 0 | 1 |
| rust-test | passed | 12.863s | 0 | 1 |
| schema-integrity | passed | 16.871s | 0 | 1 |
| security-lint | passed | 1.139s | 0 | 1 |
| tenant-lint | passed | 0.102s | 0 | 1 |
| test-run-recorded | passed | 2.955s | 0 | 1 |
| testid-lint | passed | 0.101s | 0 | 1 |
| ui-style-lint | passed | 0.46s | 0 | 1 |
| unittest-case-results | passed | 0.0s | — | 1 |

### Cases

| Runner | Suite | Native ID | Example | Status | Duration | Source |
|---|---|---|---|---|---:|---|
| sitepulse-check | api-system | unauthenticated_routes_rejected | — | passed | — | rust |
| sitepulse-check | api-system | forged_token_rejected | — | passed | — | rust |
| sitepulse-check | api-system | cross_site_forbidden | — | passed | — | rust |
| sitepulse-check | api-system | webhook_signature_enforced | — | passed | — | rust |
| sitepulse-check | api-system | concurrent_receipts_unique | — | passed | — | rust |
| sitepulse-check | api-system | idempotent_payment_retry | — | passed | — | rust |
| sitepulse-check | api-system | restart_persistence | — | passed | — | rust |
| sitepulse-check | api-system | sequences_survive_restart | — | passed | — | rust |
| sitepulse-check | api-system | match_all_settles_in_place | — | passed | — | rust |
| sitepulse-check | api-system | payer_identity_recorded | — | passed | — | rust |
| sitepulse-check | api-system | site_purge_is_atomic | — | passed | — | rust |
| sitepulse-check | api-system | tenant_surplus_virman | — | passed | — | rust |
| sitepulse-check | api-system | reversal_restores_ledger | — | passed | — | rust |
| sitepulse-check | api-system | webhook_claim_scoped | — | passed | — | rust |
| sitepulse-check | api-system | issuer_snapshot_on_receipt | — | passed | — | rust |
| sitepulse-check | api-system | debt_aging_snapshot_persisted | — | passed | — | rust |
| sitepulse-check | api-system | virman_reversal_restores_advance | — | passed | — | rust |
| sitepulse-check | api-system | resident_statement_scoped | — | passed | — | rust |
| sitepulse-check | api-system | receipt_pdf_and_verification | — | passed | — | rust |
| sitepulse-check | api-system | card_payment_via_provider | — | passed | — | rust |
| sitepulse-check | api-system | budget_accrual_legal_basis | — | passed | — | rust |
| sitepulse-check | api-system | ledger_integrity_clean | — | passed | — | rust |
| sitepulse-check | api-system | security_session_lifecycle | — | passed | — | rust |
| sitepulse-check | api-system | transactional_audit | — | passed | — | rust |
| sitepulse-check | api-system | audit_scope_and_privileges | — | passed | — | rust |
| sitepulse-check | api-system | registration_repository_scope | — | passed | — | rust |
| sitepulse-check | api-system | support_grant_lifecycle | — | passed | — | rust |
| sitepulse-check | api-system | household_members_persisted | — | passed | — | rust |
| sitepulse-check | api-system | invitation_atomic_registration | — | passed | — | rust |
| sitepulse-check | api-system | finance_desk_over_http | — | passed | — | rust |
| sitepulse-check | api-system | exit_settlement_self_approval_audited | — | passed | — | rust |
| sitepulse-check | api-system | late_fee_reconciliation_http | — | passed | — | rust |
| sitepulse-check | api-system | accrual_schedule_http | — | passed | — | rust |
| sitepulse-check | api-system | accrual_corrections_http | — | passed | — | rust |
| sitepulse-check | api-system | billing_period_lifecycle_http | — | passed | — | rust |
| sitepulse-check | api-system | person_tenant_isolation | — | passed | — | rust |
| sitepulse-check | api-system | person_activation_lifecycle | — | passed | — | rust |
| sitepulse-check | api-system | person_directory_and_export | — | passed | — | rust |
| sitepulse-check | api-system | person_records_and_import | — | passed | — | rust |
| cargo | rust-db-test | a_failure_partway_through_a_batch_writes_nothing_and_a_rerun_links_every_liability | — | passed | — | rust |
| cargo | rust-db-test | another_spelling_of_an_accrued_month_creates_nothing_in_the_database | — | passed | — | rust |
| cargo | rust-db-test | joint_liability_owner_intervals_do_not_overlap_on_transfer_day_and_exclude_day_one_seller | — | passed | — | rust |
| cargo | rust-db-test | a_first_accrual_batch_keeps_both_debtor_shares_and_blocks_a_rerun | — | passed | — | rust |
| cargo | rust-db-test | skipped_units_are_recorded_where_the_manager_can_read_them | — | passed | — | rust |
| cargo | rust-db-test | two_sites_accrue_in_a_row_each_with_its_own_period_row | — | passed | — | rust |
| cargo | rust-db-test | v43_period_close_snapshot_and_four_eyes_reopen_round_trip_with_rls | — | passed | — | rust |
| cargo | rust-db-test | v40_late_fee_rows_and_v42_schedule_survive_database_reload | — | passed | — | rust |
| cargo | rust-db-test | v38_corrections_and_v41_reevaluation_adjustments_round_trip_with_rls | — | passed | — | rust |
| cargo | rust-db-test | exit_settlement_payout_transfer_and_stale_balance_are_atomic | — | passed | — | rust |
| cargo | rust-db-test | when_registration_is_approved_on_an_occupied_unit_then_it_is_rejected | — | passed | — | rust |
| cargo | rust-db-test | when_an_owner_is_registered_then_t1_records_ownership_and_the_unit_can_be_archived | — | passed | — | rust |
| cargo | rust-db-test | when_owner_move_in_names_someone_else_then_it_is_rejected | — | passed | — | rust |
| cargo | rust-db-test | when_command_is_illegal_for_the_state_then_nothing_changes | — | passed | — | rust |
| cargo | rust-db-test | when_status_or_sessions_are_written_by_hand_then_the_model_holds | — | passed | — | rust |
| cargo | rust-db-test | when_state_is_read_then_allowed_commands_follow_the_table | — | passed | — | rust |
| cargo | rust-db-test | when_tenant_is_replaced_then_outgoing_tenant_is_settled | — | passed | — | rust |
| cargo | rust-db-test | when_tenant_leaves_and_owner_moves_in_then_owner_is_unchanged | — | passed | — | rust |
| cargo | rust-db-test | when_title_is_transferred_then_occupancy_follows_the_state_table | — | passed | — | rust |
| cargo | rust-db-test | household_by_reference_and_primary_contact_by_person | — | passed | — | rust |
| cargo | rust-db-test | person_cards_are_created_edited_and_stay_in_their_site | — | passed | — | rust |
| cargo | rust-db-test | registration_accepts_person_references_for_owner_and_members | — | passed | — | rust |
| cargo | rust-db-test | logins_open_with_an_activation_link_and_removal_needs_step_up | — | passed | — | rust |
| cargo | rust-db-test | role_free_card_has_no_stored_role_and_leaves_the_ledger_intact | — | passed | — | rust |
| cargo | rust-db-test | search_reports_role_eligibility_for_a_unit | — | passed | — | rust |
| cargo | rust-db-test | title_transfer_honors_new_owner_reference_and_clears_the_old_primary_contact | — | passed | — | rust |
| cargo | rust-db-test | merge_leaves_payment_ledger_ids_intact | — | passed | — | rust |
| cargo | rust-db-test | concurrent_merges_of_one_card_apply_once | — | passed | — | rust |
| cargo | rust-db-test | a_foreign_site_card_cannot_be_merged | — | passed | — | rust |
| cargo | rust-db-test | merge_is_refused_when_roles_conflict_on_a_unit | — | passed | — | rust |
| cargo | rust-db-test | merge_repoints_relationships_and_leaves_a_tombstone | — | passed | — | rust |
| cargo | rust-db-test | merge_needs_step_up_and_refuses_self_and_merged_cards | — | passed | — | rust |
| cargo | rust-db-test | reconciliation_assignment_is_persisted_for_its_site_only | — | passed | — | rust |
| cargo | rust-db-test | household_members_round_trip_and_stay_in_their_site | — | passed | — | rust |
| cargo | rust-db-test | financial_reads_fail_loudly_when_the_database_is_gone | — | passed | — | rust |
| cargo | rust-db-test | get_views_never_change_the_ledger_and_accrual_offsets_transactionally | — | passed | — | rust |
| cargo | rust-db-test | rls_hides_other_tenants_inside_a_bound_transaction | — | passed | — | rust |
| cargo | rust-db-test | responsible_contact_persists_without_changing_owner_or_tenant | — | passed | — | rust |
| cargo | rust-db-test | sender_ibans_are_persisted_for_their_unit | — | passed | — | rust |
| cargo | rust-db-test | tenant_data_never_crosses_sites | — | passed | — | rust |
| cargo | rust-db-test | a_repeated_command_that_is_no_longer_legal_is_rejected_and_changes_nothing | — | passed | — | rust |
| cargo | rust-db-test | a_dependent_with_a_person_card_keeps_the_card_when_moved_out | — | passed | — | rust |
| cargo | rust-db-test | a_persons_move_out_also_moves_out_their_dependents_and_the_cards_show_it | — | passed | — | rust |
| cargo | rust-db-test | a_persons_card_follows_the_unit_actions_and_keeps_the_relation_history | — | passed | — | rust |
| cargo | rust-db-test | creating_the_same_person_repeatedly_never_produces_a_second_card | — | passed | — | rust |
| cargo | rust-db-test | contact_preferences_saved_repeatedly_keep_the_last_values | — | passed | — | rust |
| cargo | rust-db-test | choosing_the_same_existing_person_repeatedly_creates_no_new_card | — | passed | — | rust |
| cargo | rust-db-test | dependents_follow_every_action_that_closes_a_session | — | passed | — | rust |
| cargo | rust-db-test | editing_a_card_repeatedly_raises_the_version_once_per_edit | — | passed | — | rust |
| cargo | rust-db-test | every_executed_command_is_audited_in_order | — | passed | — | rust |
| cargo | rust-db-test | duplicate_cards_are_merged_and_the_survivor_keeps_the_history | — | passed | — | rust |
| cargo | rust-db-test | household_members_added_edited_and_removed_repeatedly_keep_roster_and_contact | — | passed | — | rust |
| cargo | rust-db-test | opening_the_login_twice_in_a_row_reuses_the_same_account | — | passed | — | rust |
| cargo | rust-db-test | move_out_archives_the_household_of_the_closed_session_each_time | — | passed | — | rust |
| cargo | rust-db-test | opening_and_removing_a_login_repeatedly_keeps_the_login_status_correct | — | passed | — | rust |
| cargo | rust-db-test | owner_move_out_and_move_in_repeated_keep_the_owner_and_the_deed | — | passed | — | rust |
| cargo | rust-db-test | owner_rents_out_and_takes_back_repeatedly | — | passed | — | rust |
| cargo | rust-db-test | person_actions_of_another_site_are_refused_every_time | — | passed | — | rust |
| cargo | rust-db-test | replacing_the_tenant_repeatedly_settles_each_outgoing_tenant_once | — | passed | — | rust |
| cargo | rust-db-test | setting_the_national_id_repeatedly_keeps_it_masked_and_unique | — | passed | — | rust |
| cargo | rust-db-test | title_transfer_repeated_keeps_every_previous_owner_in_the_history | — | passed | — | rust |
| cargo | rust-db-test | tenant_move_in_and_move_out_repeated_keep_one_history_row_per_tenant | — | passed | — | rust |
| cargo | rust-db-test | when_a_tenant_moves_out_all_dependents_move_out_with_them | — | passed | — | rust |
| cargo | rust-db-test | when_an_owner_who_lives_in_the_unit_moves_out_their_dependents_move_out_too | — | passed | — | rust |
| cargo | rust-db-opt-in | corrections_round_trip_through_postgresql | — | passed | — | rust |
| cargo | rust-db-opt-in | every_spec009_record_round_trips_through_postgresql | — | passed | — | rust |
| cargo | rust-test | lib::audit::client_ip_tests::ignores_forwarded_header_from_untrusted_peer | — | passed | — | rust |
| cargo | rust-test | lib::audit::client_ip_tests::takes_rightmost_untrusted_entry_from_trusted_proxy | — | passed | — | rust |
| cargo | rust-test | lib::auth::password_policy_tests::rejects_identity_and_common_passwords | — | passed | — | rust |
| cargo | rust-test | lib::auth::tests::a_password_of_exactly_the_minimum_length_is_accepted | — | passed | — | rust |
| cargo | rust-test | lib::auth::tests::an_unsalted_sha256_digest_is_not_a_usable_plaintext_password | — | passed | — | rust |
| cargo | rust-test | lib::auth::tests::access_tokens_live_at_most_the_ttl | — | passed | — | rust |
| cargo | rust-test | lib::auth::tests::query_decoding | — | passed | — | rust |
| cargo | rust-test | lib::auth::tests::token_round_trip_and_tamper_detection | — | passed | — | rust |
| cargo | rust-test | lib::auth::tests::webhook_signature | — | passed | — | rust |
| cargo | rust-test | lib::authorization::tests::require_refuses_a_permission_the_caller_does_not_hold | — | passed | — | rust |
| cargo | rust-test | lib::authorization::tests::require_refuses_another_sites_resource_even_with_the_permission | — | passed | — | rust |
| cargo | rust-test | lib::domain::accrual_schedule::tests::before_the_accrual_day_the_current_month_is_not_yet_accrued | — | passed | — | rust |
| cargo | rust-test | lib::domain::accrual_schedule::tests::catch_up_lists_missing_periods_oldest_first | — | passed | — | rust |
| cargo | rust-test | lib::domain::accrual_schedule::tests::catch_up_stops_at_the_limit | — | passed | — | rust |
| cargo | rust-test | lib::domain::accrual_schedule::tests::due_day_beyond_month_end_falls_on_last_day | — | passed | — | rust |
| cargo | rust-test | lib::domain::accrual_schedule::tests::invalid_values_are_rejected | — | passed | — | rust |
| cargo | rust-test | lib::domain::apportionment::tests::all_zero_weights_split_equally | — | passed | — | rust |
| cargo | rust-test | lib::domain::apportionment::tests::equal_weights_split_with_deterministic_leftover | — | passed | — | rust |
| cargo | rust-test | lib::domain::apportionment::tests::leftover_goes_to_largest_remainder_not_first_position | — | passed | — | rust |
| cargo | rust-test | lib::domain::apportionment::tests::rejects_invalid_input | — | passed | — | rust |
| cargo | rust-test | lib::domain::apportionment::tests::shares_always_sum_to_total | — | passed | — | rust |
| cargo | rust-test | lib::domain::apportionment::tests::ties_prefer_larger_weight | — | passed | — | rust |
| cargo | rust-test | lib::domain::assembly_vote::tests::first_call_needs_count_and_share_majorities | — | passed | — | rust |
| cargo | rust-test | lib::domain::assembly_vote::tests::rules_and_votes_parse | — | passed | — | rust |
| cargo | rust-test | lib::domain::assembly_vote::tests::rules_count_votes_and_land_share | — | passed | — | rust |
| cargo | rust-test | lib::domain::billing_period::tests::due_date_must_be_in_the_month_or_the_grace_days_after | — | passed | — | rust |
| cargo | rust-test | lib::domain::billing_period::tests::every_spelling_of_a_month_resolves_to_one_key | — | passed | — | rust |
| cargo | rust-test | lib::domain::billing_period::tests::unparseable_text_is_rejected | — | passed | — | rust |
| cargo | rust-test | lib::domain::clock::tests::an_unknown_time_zone_falls_back_to_istanbul | — | passed | — | rust |
| cargo | rust-test | lib::domain::clock::tests::istanbul_month_boundary_is_three_hours_before_utc_midnight | — | passed | — | rust |
| cargo | rust-test | lib::domain::clock::tests::local_midnight_starts_the_new_day_exactly | — | passed | — | rust |
| cargo | rust-test | lib::domain::clock::tests::the_system_clock_follows_the_wall_clock | — | passed | — | rust |
| cargo | rust-test | lib::domain::collection_metrics::tests::rates_and_dso_are_amount_weighted | — | passed | — | rust |
| cargo | rust-test | lib::domain::collection_metrics::tests::risk_tiers_follow_the_debt | — | passed | — | rust |
| cargo | rust-test | lib::domain::double_entry::tests::chart_codes_are_unique_and_categories_map_to_expenses | — | passed | — | rust |
| cargo | rust-test | lib::domain::double_entry::tests::manual_entries_must_balance_on_known_accounts | — | passed | — | rust |
| cargo | rust-test | lib::domain::double_entry::tests::sub_kurus_precision_is_rejected_on_either_side | — | passed | — | rust |
| cargo | rust-test | lib::domain::double_entry::tests::trial_balance_balances_and_uses_the_normal_side | — | passed | — | rust |
| cargo | rust-test | lib::domain::dunning::tests::only_reminders_respect_an_opt_out | — | passed | — | rust |
| cargo | rust-test | lib::domain::dunning::tests::policies_are_validated | — | passed | — | rust |
| cargo | rust-test | lib::domain::dunning::tests::the_latest_passed_step_runs_once | — | passed | — | rust |
| cargo | rust-test | lib::domain::email::tests::normalizes_case_and_surrounding_whitespace | — | passed | — | rust |
| cargo | rust-test | lib::domain::email::tests::rejects_structurally_invalid_addresses | — | passed | — | rust |
| cargo | rust-test | lib::domain::email::tests::same_email_normalizes_both_sides | — | passed | — | rust |
| cargo | rust-test | lib::domain::fingerprint::tests::hmac_round_trip_and_rejections | — | passed | — | rust |
| cargo | rust-test | lib::domain::fingerprint::tests::receipt_hash_v2_is_a_persisted_contract | — | passed | — | rust |
| cargo | rust-test | lib::domain::fingerprint::tests::receipt_v1_golden | — | passed | — | rust |
| cargo | rust-test | lib::domain::fingerprint::tests::transfer_v1_golden | — | passed | — | rust |
| cargo | rust-test | lib::domain::heat_share::tests::shares_add_up_and_follow_consumption_and_area | — | passed | — | rust |
| cargo | rust-test | lib::domain::heat_share::tests::without_any_consumption_the_area_decides_and_bad_input_is_refused | — | passed | — | rust |
| cargo | rust-test | lib::domain::household_relationship::tests::codes_round_trip | — | passed | — | rust |
| cargo | rust-test | lib::domain::household_relationship::tests::legacy_turkish_labels_map_to_codes | — | passed | — | rust |
| cargo | rust-test | lib::domain::household_relationship::tests::unknown_text_is_refused | — | passed | — | rust |
| cargo | rust-test | lib::domain::iban::tests::accepts_published_examples_in_any_spacing_and_case | — | passed | — | rust |
| cargo | rust-test | lib::domain::iban::tests::an_iban_longer_than_26_characters_is_not_turkish | — | passed | — | rust |
| cargo | rust-test | lib::domain::iban::tests::check_digits_round_trip_and_reject_non_digits | — | passed | — | rust |
| cargo | rust-test | lib::domain::iban::tests::groups_for_display | — | passed | — | rust |
| cargo | rust-test | lib::domain::iban::tests::multibyte_input_never_panics | — | passed | — | rust |
| cargo | rust-test | lib::domain::iban::tests::normalizes_bank_codes | — | passed | — | rust |
| cargo | rust-test | lib::domain::iban::tests::rejects_bad_checksum_and_structure | — | passed | — | rust |
| cargo | rust-test | lib::domain::installments::tests::a_plan_breaks_only_after_the_grace_days | — | passed | — | rust |
| cargo | rust-test | lib::domain::installments::tests::instalments_add_up_and_leftover_goes_first | — | passed | — | rust |
| cargo | rust-test | lib::domain::joint_liability::tests::an_ended_lease_stops_accruing_rent | — | passed | — | rust |
| cargo | rust-test | lib::domain::joint_liability::tests::the_cap_is_the_unpaid_rent_plus_the_next_instalment | — | passed | — | rust |
| cargo | rust-test | lib::domain::kvkk::tests::channels_round_trip | — | passed | — | rust |
| cargo | rust-test | lib::domain::kvkk::tests::debt_notices_never_reach_group_channels | — | passed | — | rust |
| cargo | rust-test | lib::domain::kvkk::tests::names_and_identifiers_are_masked | — | passed | — | rust |
| cargo | rust-test | lib::domain::kvkk::tests::opt_out_stops_reminders_but_not_legal_notices | — | passed | — | rust |
| cargo | rust-test | lib::domain::limitation::tests::status_moves_from_running_to_expired | — | passed | — | rust |
| cargo | rust-test | lib::domain::occupancy_proration::tests::a_negative_monthly_amount_is_rejected_with_and_without_proration | — | passed | — | rust |
| cargo | rust-test | lib::domain::occupancy_proration::tests::disabled_proration_keeps_the_current_full_month_rule | — | passed | — | rust |
| cargo | rust-test | lib::domain::occupancy_proration::tests::mid_month_move_in_splits_by_actual_october_days | — | passed | — | rust |
| cargo | rust-test | lib::domain::occupancy_proration::tests::move_out_end_date_is_exclusive_and_first_share_rounds_half_away | — | passed | — | rust |
| cargo | rust-test | lib::domain::occupancy_proration::tests::split_shares_always_add_up_to_the_prorated_total | — | passed | — | rust |
| cargo | rust-test | lib::domain::occupancy_proration::tests::unbilled_days_after_the_month_charge_nothing | — | passed | — | rust |
| cargo | rust-test | lib::domain::occupancy_proration::tests::unbilled_days_before_the_month_charge_the_whole_month | — | passed | — | rust |
| cargo | rust-test | lib::domain::occupancy_proration::tests::unbilled_days_respect_the_unit_creation_date | — | passed | — | rust |
| cargo | rust-test | lib::domain::occupancy_proration::tests::unbilled_days_run_from_the_start_date_to_the_month_end | — | passed | — | rust |
| cargo | rust-test | lib::domain::occupancy_proration::tests::unit_creation_limits_charge_to_the_remaining_calendar_days | — | passed | — | rust |
| cargo | rust-test | lib::domain::occupancy_proration::tests::without_proration_an_unoccupied_day_is_billed_to_the_owner | — | passed | — | rust |
| cargo | rust-test | lib::domain::payer_match::tests::a_valid_national_id_is_found_and_an_invalid_one_ignored | — | passed | — | rust |
| cargo | rust-test | lib::domain::payer_match::tests::block_and_unit_references_are_read | — | passed | — | rust |
| cargo | rust-test | lib::domain::payer_match::tests::mobile_numbers_are_normalized | — | passed | — | rust |
| cargo | rust-test | lib::domain::payer_match::tests::patterns_compile | — | passed | — | rust |
| cargo | rust-test | lib::domain::sale_clearance::tests::csv_cells_are_quoted_and_formula_safe | — | passed | — | rust |
| cargo | rust-test | lib::domain::sale_clearance::tests::no_split_on_the_first_day | — | passed | — | rust |
| cargo | rust-test | lib::domain::sale_clearance::tests::only_an_approved_override_moves_the_installment_to_the_seller | — | passed | — | rust |
| cargo | rust-test | lib::domain::sale_clearance::tests::splits_a_thirty_day_month | — | passed | — | rust |
| cargo | rust-test | lib::domain::sale_clearance::tests::splits_a_thirty_one_day_month_with_the_remainder_to_the_buyer | — | passed | — | rust |
| cargo | rust-test | lib::domain::tax_id::tests::a_ten_digit_number_with_a_wrong_check_digit_is_not_a_vkn | — | passed | — | rust |
| cargo | rust-test | lib::domain::tax_id::tests::parse_tells_vkn_from_tckn | — | passed | — | rust |
| cargo | rust-test | lib::domain::tax_id::tests::valid_tckn_is_accepted_and_altered_digits_are_rejected | — | passed | — | rust |
| cargo | rust-test | lib::domain::tax_id::tests::valid_vkn_is_accepted_and_altered_digits_are_rejected | — | passed | — | rust |
| cargo | rust-test | lib::domain::text::tests::folds_decomposed_input_like_composed_input | — | passed | — | rust |
| cargo | rust-test | lib::domain::text::tests::folds_turkish_letters_in_both_cases | — | passed | — | rust |
| cargo | rust-test | lib::domain::text::tests::keeps_punctuation_and_whitespace | — | passed | — | rust |
| cargo | rust-test | lib::domain::unit_state::tests::a_legacy_tenant_without_owner_can_only_move_out | — | passed | — | rust |
| cargo | rust-test | lib::domain::unit_state::tests::a_tenant_move_in_without_an_owner_names_the_missing_owner | — | passed | — | rust |
| cargo | rust-test | lib::domain::unit_state::tests::allowed_commands_follow_the_transition_table | — | passed | — | rust |
| cargo | rust-test | lib::domain::unit_state::tests::compound_transitions_close_then_open | — | passed | — | rust |
| cargo | rust-test | lib::domain::unit_state::tests::effective_date_cannot_be_in_the_future_but_may_precede_the_session | — | passed | — | rust |
| cargo | rust-test | lib::domain::unit_state::tests::illegal_commands_from_story_08_07_are_rejected | — | passed | — | rust |
| cargo | rust-test | lib::domain::unit_state::tests::new_owner_moving_in_at_transfer_needs_an_owner_occupied_unit | — | passed | — | rust |
| cargo | rust-test | lib::domain::unit_state::tests::occupancy_is_derived_from_the_active_session | — | passed | — | rust |
| cargo | rust-test | lib::domain::unit_state::tests::t1_register_owner_opens_ownership_and_optional_residence | — | passed | — | rust |
| cargo | rust-test | lib::domain::unit_state::tests::t2_tenant_move_in_opens_a_tenant_session_without_ownership_change | — | passed | — | rust |
| cargo | rust-test | lib::domain::unit_state::tests::t3_owner_move_in_uses_the_owner_on_record | — | passed | — | rust |
| cargo | rust-test | lib::domain::unit_state::tests::t4_and_t5_move_out_close_the_active_session | — | passed | — | rust |
| cargo | rust-test | lib::domain::unit_state::tests::t6_title_transfer_by_occupancy | — | passed | — | rust |
| cargo | rust-test | lib::e2e_clock::configuration_tests::startup_leaves_e2e_mode_disabled_by_default | — | passed | — | rust |
| cargo | rust-test | lib::e2e_clock::configuration_tests::startup_rejects_an_e2e_flag_without_the_e2e_build_feature | — | passed | — | rust |
| cargo | rust-test | lib::e2e_clock::configuration_tests::startup_rejects_e2e_mode_in_production | — | passed | — | rust |
| cargo | rust-test | lib::error::tests::app_error_from_finance_error | — | passed | — | rust |
| cargo | rust-test | lib::error::tests::error_envelope_serializes_cleanly | — | passed | — | rust |
| cargo | rust-test | lib::handlers::dashboard::tests::collected_never_exceeds_the_billed_principal | — | passed | — | rust |
| cargo | rust-test | lib::handlers::dashboard::tests::fully_paid_due_remains_in_period_collection_totals | — | passed | — | rust |
| cargo | rust-test | lib::handlers::dashboard::tests::paid_or_not_yet_due_items_have_no_overdue_days | — | passed | — | rust |
| cargo | rust-test | lib::handlers::dashboard::tests::site_id_matching_does_not_treat_unparseable_ids_as_equal | — | passed | — | rust |
| cargo | rust-test | lib::handlers::dashboard::tests::unpaid_due_calculates_days_from_its_due_date | — | passed | — | rust |
| cargo | rust-test | lib::handlers::site_admin::person_search_params_tests::empty_query_string_uses_defaults | — | passed | — | rust |
| cargo | rust-test | lib::handlers::site_admin::person_search_params_tests::numeric_paging_fields_parse_from_query_string | — | passed | — | rust |
| cargo | rust-test | lib::migrations::tests::every_migration_file_is_registered_in_order | — | passed | — | rust |
| cargo | rust-test | lib::auth::tests::passwords_only_verify_against_argon2 | — | passed | — | rust |
| cargo | rust-test | lib::services::account_activation_service::tests::invalid_token_message_is_the_public_constant | — | passed | — | rust |
| cargo | rust-test | lib::services::account_activation_service::tests::link_carries_the_token_under_the_public_url | — | passed | — | rust |
| cargo | rust-test | lib::services::account_activation_service::tests::purpose_round_trips | — | passed | — | rust |
| cargo | rust-test | lib::services::account_activation_service::tests::tokens_are_256_bit_hex_and_unique | — | passed | — | rust |
| cargo | rust-test | lib::services::advance_exit_settlement_service::tests::invalid_kind_and_debtor_are_rejected | — | passed | — | rust |
| cargo | rust-test | lib::services::advance_exit_settlement_service::tests::payout_forbids_target_and_transfer_requires_distinct_target | — | passed | — | rust |
| cargo | rust-test | lib::services::advance_exit_settlement_service::tests::request_rejects_unknown_kind_or_source | — | passed | — | rust |
| cargo | rust-test | lib::services::advance_exit_settlement_service::tests::request_requires_a_bounded_beneficiary_name | — | passed | — | rust |
| cargo | rust-test | lib::services::advance_exit_settlement_service::tests::request_requires_a_bounded_idempotency_key | — | passed | — | rust |
| cargo | rust-test | lib::services::advance_exit_settlement_service::tests::request_requires_departing_beneficiary_identity | — | passed | — | rust |
| cargo | rust-test | lib::services::advance_exit_settlement_service::tests::request_requires_positive_amount_with_at_most_two_decimal_places | — | passed | — | rust |
| cargo | rust-test | lib::services::advance_exit_settlement_service::tests::same_person_cannot_satisfy_the_four_eyes_check | — | passed | — | rust |
| cargo | rust-test | lib::services::advance_exit_settlement_service::tests::settlement_kind_and_debtor_inputs_are_normalized | — | passed | — | rust |
| cargo | rust-test | lib::services::bank_statement_parser::pattern_tests::all_patterns_compile | — | passed | — | rust |
| cargo | rust-test | lib::services::dues_calculation_service::tests::a_charge_created_late_owes_no_fee_for_days_before_it_existed | — | passed | — | rust |
| cargo | rust-test | lib::services::dues_calculation_service::tests::a_paid_liability_never_accrues_a_new_penalty | — | passed | — | rust |
| cargo | rust-test | lib::services::dues_calculation_service::tests::grace_and_status_count_from_the_effective_due_date | — | passed | — | rust |
| cargo | rust-test | lib::services::dues_calculation_service::tests::no_penalty_and_no_accrual_date_before_the_due_date | — | passed | — | rust |
| cargo | rust-test | lib::services::dues_calculation_service::tests::paid_penalty_never_disappears_and_accrual_stops_when_principal_is_paid | — | passed | — | rust |
| cargo | rust-test | lib::services::dues_calculation_service::tests::payments_dated_on_every_cursor_position_terminate_and_are_applied_once | — | passed | — | rust |
| cargo | rust-test | lib::services::dues_calculation_service::tests::penalty_accrues_only_on_unpaid_principal_after_partial_payment | — | passed | — | rust |
| cargo | rust-test | lib::services::dues_calculation_service::tests::penalty_through_charges_only_the_days_before_a_backdated_payment | — | passed | — | rust |
| cargo | rust-test | lib::services::dues_calculation_service::tests::penalty_through_follows_partial_payments_in_date_order | — | passed | — | rust |
| cargo | rust-test | lib::services::dues_calculation_service::tests::recalculation_is_stable_after_partial_payment | — | passed | — | rust |
| cargo | rust-test | lib::services::dues_calculation_service::tests::the_effective_due_date_is_never_before_the_period_due_date | — | passed | — | rust |
| cargo | rust-test | lib::services::dues_ledger::tests::a_negative_settlement_changes_nothing | — | passed | — | rust |
| cargo | rust-test | lib::services::dues_ledger::tests::a_tenant_may_not_settle_capital_dues_but_may_settle_tenant_operational_dues | — | passed | — | rust |
| cargo | rust-test | lib::services::dues_ledger::tests::allocations_sum_to_the_payment_and_surplus_is_returned | — | passed | — | rust |
| cargo | rust-test | lib::services::dues_ledger::tests::bank_narrative_designates_the_named_period | — | passed | — | rust |
| cargo | rust-test | lib::services::dues_ledger::tests::debtor_isolation_prevents_cross_role_settlement_without_opt_in | — | passed | — | rust |
| cargo | rust-test | lib::services::dues_ledger::tests::designated_period_is_settled_before_older_dues | — | passed | — | rust |
| cargo | rust-test | lib::services::dues_ledger::tests::designation_never_lets_a_tenant_pay_owner_capital | — | passed | — | rust |
| cargo | rust-test | lib::services::dues_ledger::tests::designation_remainder_falls_back_to_oldest_first | — | passed | — | rust |
| cargo | rust-test | lib::services::dues_ledger::tests::overpaid_principal_is_never_negative_outstanding | — | passed | — | rust |
| cargo | rust-test | lib::services::dues_ledger::tests::owner_payment_settles_operational_dues_before_capital_dues | — | passed | — | rust |
| cargo | rust-test | lib::services::dues_ledger::tests::payer_filter_fails_closed_when_only_one_side_is_known | — | passed | — | rust |
| cargo | rust-test | lib::services::dues_ledger::tests::payment_records_paid_amounts_and_never_reduces_the_debt | — | passed | — | rust |
| cargo | rust-test | lib::services::dues_ledger::tests::reversal_on_the_due_date_is_pending_and_the_day_after_is_overdue | — | passed | — | rust |
| cargo | rust-test | lib::services::dues_ledger::tests::settle_single_liability_penalty_first | — | passed | — | rust |
| cargo | rust-test | lib::services::dues_ledger::tests::successor_payment_isolates_from_predecessor_charges | — | passed | — | rust |
| cargo | rust-test | lib::services::dues_ledger::tests::turkish_folding_matches_upper_and_ascii_forms | — | passed | — | rust |
| cargo | rust-test | lib::openapi::tests::person_api_schemas_are_registered_in_openapi_components | — | passed | — | rust |
| cargo | rust-test | lib::services::person_directory_service::tests::csv_cells_are_quoted_and_formulas_neutralized | — | passed | — | rust |
| cargo | rust-test | lib::services::person_directory_service::tests::filters_are_validated_and_paging_is_bounded | — | passed | — | rust |
| cargo | rust-test | lib::services::person_import_service::tests::missing_required_columns_are_named | — | passed | — | rust |
| cargo | rust-test | lib::services::person_import_service::tests::rows_report_field_errors_and_duplicates_inside_the_file | — | passed | — | rust |
| cargo | rust-test | lib::services::person_import_service::tests::semicolon_files_with_bom_quotes_and_crlf_are_read | — | passed | — | rust |
| cargo | rust-test | lib::services::person_import_service::tests::unterminated_quotes_and_empty_files_are_refused | — | passed | — | rust |
| cargo | rust-test | lib::services::person_record_service::tests::edit_distance_of_one_is_detected | — | passed | — | rust |
| cargo | rust-test | lib::services::person_record_service::tests::identifier_and_name_matches_are_reported | — | passed | — | rust |
| cargo | rust-test | lib::services::person_record_service::tests::names_ignore_case_diacritics_and_word_order | — | passed | — | rust |
| cargo | rust-test | lib::services::person_record_service::tests::phone_numbers_compare_by_their_last_ten_digits | — | passed | — | rust |
| cargo | rust-test | lib::services::person_record_service::tests::preferences_are_normalized_and_validated | — | passed | — | rust |
| cargo | rust-test | lib::services::person_service::tests::names_are_collapsed_and_validated | — | passed | — | rust |
| cargo | rust-test | lib::services::person_service::tests::owner_cannot_be_tenant_of_the_same_unit | — | passed | — | rust |
| cargo | rust-test | lib::services::person_service::tests::primary_contact_must_be_on_the_unit | — | passed | — | rust |
| cargo | rust-test | lib::services::person_service::tests::unrelated_person_may_be_added_as_member | — | passed | — | rust |
| cargo | rust-test | lib::services::mt940_engine::pattern_tests::all_patterns_compile | — | passed | — | rust |
| cargo | rust-test | lib::services::reconciliation_service::pattern_tests::all_patterns_compile | — | passed | — | rust |
| cargo | rust-test | lib::auth::throttle_tests::one_client_cannot_lock_out_another_clients_account | — | passed | — | rust |
| cargo | rust-test | lib::auth::throttle_tests::varying_the_account_does_not_evade_the_address_limit | — | passed | — | rust |
| cargo | rust-test | lib::services::virtual_iban_service::tests::documented_prefix_collisions_are_real | — | passed | — | rust |
| cargo | rust-test | lib::services::virtual_iban_service::tests::generated_identifiers_are_stable | — | passed | — | rust |
| cargo | rust-test | lib::services::virtual_iban_service::tests::generator_rejects_invalid_input_and_never_overflows | — | passed | — | rust |
| cargo | rust-test | lib::services::virtual_iban_service::tests::test_format_for_display | — | passed | — | rust |
| cargo | rust-test | lib::services::virtual_iban_service::tests::test_unique_virtual_ibans_for_different_flats | — | passed | — | rust |
| cargo | rust-test | lib::services::virtual_iban_service::tests::test_validates_generated_virtual_iban | — | passed | — | rust |
| cargo | rust-test | lib::services::virtual_iban_service::tests::validation_never_panics_on_multibyte_input | — | passed | — | rust |
| cargo | rust-test | lib::state::fixture_detection_tests::pending_exit_reservations_reduce_only_spendable_advance | — | passed | — | rust |
| cargo | rust-test | lib::state::fixture_detection_tests::when_binary_is_the_server_or_another_suite_then_fixtures_are_not_seeded | — | passed | — | rust |
| cargo | rust-test | lib::state::fixture_detection_tests::when_test_binary_uses_either_cargo_layout_then_fixtures_are_seeded | — | passed | — | rust |
| cargo | rust-test | lib::tenancy::tests::a_site_scope_never_allows_an_empty_or_zero_site | — | passed | — | rust |
| cargo | rust-test | lib::tenancy::tests::an_unit_id_never_passes_as_a_site_id | — | passed | — | rust |
| cargo | rust-test | lib::tenancy::tests::empty_site_claim_fails_closed | — | passed | — | rust |
| cargo | rust-test | lib::tenancy::tests::platform_keeps_its_request_and_must_name_a_site_to_resolve | — | passed | — | rust |
| cargo | rust-test | lib::tenancy::tests::site_scope_pins_missing_and_refuses_foreign_sites | — | passed | — | rust |
| cargo | rust-test | lib::services::site_admin_service::tests::when_registering_home_owner_then_does_not_create_due_liability | — | passed | — | rust |
| cargo | rust-test | lib::services::site_admin_service::tests::when_updating_unit_monthly_dues_then_tariff_override_is_updated | — | passed | — | rust |
| cargo | rust-test | lib::services::site_admin_service::tests::when_registering_with_default_house_type_tariff_then_no_override_is_pinned | — | passed | — | rust |
| cargo | rust-test | main::a_signed_token_without_a_session_is_rejected | — | passed | — | rust |
| cargo | rust-test | main::mandatory_password_change_and_step_up_are_server_enforced | — | passed | — | rust |
| cargo | rust-test | main::route_inventory_and_permission_matrix_are_explicit | — | passed | — | rust |
| cargo | rust-test | main::logout_immediately_invalidates_a_copied_access_token | — | passed | — | rust |
| cargo | rust-test | main::platform_administrators_do_not_inherit_tenant_permissions | — | passed | — | rust |
| cargo | rust-test | main::stale_unit_relationship_is_not_authorized_by_the_token | — | passed | — | rust |
| cargo | rust-test | main::refresh_reuse_revokes_the_entire_session | — | passed | — | rust |
| cargo | rust-test | main::suspension_and_role_changes_invalidate_access | — | passed | — | rust |
| cargo | rust-test | main::unknown_routes_and_cross_tenant_access_fail_closed | — | passed | — | rust |
| cargo | rust-test | main::when_password_change_required_then_business_routes_are_blocked | — | passed | — | rust |
| cargo | rust-test | main::a_correction_needs_a_reason_and_only_one_may_wait_per_liability | — | passed | — | rust |
| cargo | rust-test | main::a_rejected_correction_leaves_the_liability_as_it_was_and_a_cancelled_one_cannot_be_corrected_again | — | passed | — | rust |
| cargo | rust-test | main::corrections_round_trip_through_postgresql | — | passed | — | rust |
| cargo | rust-test | main::the_credit_note_plan_rounds_the_remaining_late_fee_half_away_from_zero | — | passed | — | rust |
| cargo | rust-test | main::a_credit_note_beyond_what_was_paid_moves_the_excess_to_the_advance_balance | — | passed | — | rust |
| cargo | rust-test | main::a_cancelled_payment_credit_is_offset_against_the_debtors_other_open_liabilities | — | passed | — | rust |
| cargo | rust-test | main::approving_the_same_correction_twice_concurrently_applies_it_once | — | passed | — | rust |
| cargo | rust-test | main::when_a_credit_note_is_approved_then_the_amount_and_the_late_fee_drop_in_proportion | — | passed | — | rust |
| cargo | rust-test | main::when_a_credit_note_is_approved_then_the_resident_statement_shows_it_with_the_reason | — | passed | — | rust |
| cargo | rust-test | main::when_a_liability_is_reissued_then_the_original_is_cancelled_and_the_new_one_refers_to_it | — | passed | — | rust |
| cargo | rust-test | main::when_a_liability_with_a_payment_is_cancelled_then_the_payment_moves_to_the_advance_balance | — | passed | — | rust |
| cargo | rust-test | main::when_the_requester_approves_their_own_correction_then_it_is_forbidden_and_nothing_changes | — | passed | — | rust |
| cargo | rust-test | main::when_a_paid_month_is_split_then_approval_reissues_both_roles_and_credits_the_excess | — | passed | — | rust |
| cargo | rust-test | main::when_tenant_leaves_without_notice_then_split_and_later_accrual_corrections_are_requested | — | passed | — | rust |
| cargo | rust-test | main::when_a_charge_is_created_after_its_due_date_then_the_fee_counts_from_its_creation | — | passed | — | rust |
| cargo | rust-test | main::when_a_backdated_payment_is_inside_the_grace_period_then_the_reevaluated_fee_is_zero | — | passed | — | rust |
| cargo | rust-test | main::when_day_rows_are_rewritten_then_they_honour_the_grace_period | — | passed | — | rust |
| cargo | rust-test | main::when_catch_up_reaches_the_limit_then_older_periods_are_reported_not_accrued | — | passed | — | rust |
| cargo | rust-test | main::when_a_backdated_payment_settles_a_charged_liability_inside_grace_then_the_fee_is_reversed | — | passed | — | rust |
| cargo | rust-test | main::when_paid_inside_the_grace_period_then_the_late_fee_is_zero | — | passed | — | rust |
| cargo | rust-test | main::when_the_grace_period_has_ended_then_the_late_fee_runs_from_the_due_date | — | passed | — | rust |
| cargo | rust-test | main::when_the_due_day_is_5_then_every_liability_of_the_period_is_due_on_the_5th | — | passed | — | rust |
| cargo | rust-test | main::when_the_grace_period_changes_then_accrued_liabilities_keep_theirs | — | passed | — | rust |
| cargo | rust-test | main::when_the_scheduler_was_off_then_it_accrues_the_missed_periods_oldest_first | — | passed | — | rust |
| cargo | rust-test | main::when_the_due_day_is_beyond_the_month_end_then_it_falls_on_the_last_day | — | passed | — | rust |
| cargo | rust-test | main::cors_preflight_allows_the_client_correlation_header | — | passed | — | rust |
| cargo | rust-test | main::capital_projects_are_confined_to_their_site | — | passed | — | rust |
| cargo | rust-test | main::forged_and_unsigned_tokens_are_rejected | — | passed | — | rust |
| cargo | rust-test | main::homeowner_payment_records_are_confined_to_their_site | — | passed | — | rust |
| cargo | rust-test | main::profile_comes_from_the_token_not_the_query | — | passed | — | rust |
| cargo | rust-test | main::profile_reports_role_unit_and_permissions_of_the_signed_in_owner | — | passed | — | rust |
| cargo | rust-test | main::public_routes_stay_reachable | — | passed | — | rust |
| cargo | rust-test | main::residents_cannot_reach_admin_or_other_units | — | passed | — | rust |
| cargo | rust-test | main::site_managers_are_confined_to_their_site | — | passed | — | rust |
| cargo | rust-test | main::system_routes_are_not_routed_unless_explicitly_enabled | — | passed | — | rust |
| cargo | rust-test | main::every_protected_route_returns_401_without_a_token | — | passed | — | rust |
| cargo | rust-test | main::test_cross_tenant_reconciliation_confirmation_blocked | — | passed | — | rust |
| cargo | rust-test | main::test_payment_stream_pagination | — | passed | — | rust |
| cargo | rust-test | main::test_recursive_body_inspection_rejects_nested_foreign_tenant | — | passed | — | rust |
| cargo | rust-test | main::test_cross_tenant_registration_approval_blocked | — | passed | — | rust |
| cargo | rust-test | main::test_reject_registration_already_processed_blocked | — | passed | — | rust |
| cargo | rust-test | main::when_held_transfer_approved_by_person_name_then_settles_that_person | — | passed | — | rust |
| cargo | rust-test | main::when_held_transfer_approved_for_tenant_then_settles_active_tenant_charges | — | passed | — | rust |
| cargo | rust-test | main::when_held_transfer_is_delivered_again_then_it_is_a_duplicate_and_adds_no_queue_item | — | passed | — | rust |
| cargo | rust-test | main::when_debtor_assignment_is_invalid_or_unknown_then_rejected_and_match_remains_unmatched | — | passed | — | rust |
| cargo | rust-test | main::when_manual_payment_requests_unrelated_person_then_payer_person_id_is_not_trusted | — | passed | — | rust |
| cargo | rust-test | main::when_unassigned_confirmation_has_unrecognized_sender_and_person_stamped_charge_then_preserves_debtor_identity | — | passed | — | rust |
| cargo | rust-test | main::when_unit_has_duplicate_tenant_names_then_assigning_by_person_id_settles_the_intended_person | — | passed | — | rust |
| cargo | rust-test | main::when_unit_has_one_open_debtor_then_transfer_still_matches_automatically | — | passed | — | rust |
| cargo | rust-test | main::when_unit_has_several_open_debtors_then_transfer_is_held_unmatched_and_assigned_once | — | passed | — | rust |
| cargo | rust-test | main::active_periods_use_the_open_contract_while_accepting_legacy_active_values | — | passed | — | rust |
| cargo | rust-test | main::accrual_into_a_closed_period_is_rejected_as_a_conflict | — | passed | — | rust |
| cargo | rust-test | main::closing_a_period_returns_the_summary_and_freezes_its_snapshot | — | passed | — | rust |
| cargo | rust-test | main::a_closed_period_still_accepts_payment_and_books_it_on_its_receipt_date | — | passed | — | rust |
| cargo | rust-test | main::a_correction_to_a_closed_period_posts_later_and_preserves_the_close_report | — | passed | — | rust |
| cargo | rust-test | main::reopening_requires_a_second_manager_and_keeps_an_audit_record | — | passed | — | rust |
| cargo | rust-test | main::when_accrual_amount_is_zero_or_negative_then_it_is_rejected_and_creates_nothing | — | passed | — | rust |
| cargo | rust-test | main::when_accrual_amount_is_omitted_or_none_then_it_accrues_from_tariffs | — | passed | — | rust |
| cargo | rust-test | main::when_a_unit_has_no_tariff_then_it_is_listed_as_skipped_with_the_reason | — | passed | — | rust |
| cargo | rust-test | main::when_a_period_is_not_a_month_then_the_request_is_rejected | — | passed | — | rust |
| cargo | rust-test | main::when_the_scheduler_runs_for_a_month_a_manager_accrued_then_nothing_is_charged_twice | — | passed | — | rust |
| cargo | rust-test | main::when_the_due_date_is_outside_the_period_then_nothing_is_written | — | passed | — | rust |
| cargo | rust-test | main::when_another_spelling_of_an_accrued_month_is_accrued_then_it_is_a_duplicate | — | passed | — | rust |
| cargo | rust-test | main::when_accruing_installment_then_only_project_site_units_are_charged | — | passed | — | rust |
| cargo | rust-test | main::when_units_have_negative_land_share_then_apportionment_is_rejected | — | passed | — | rust |
| cargo | rust-test | main::when_summarizing_shares_then_matches_accrued_amounts_and_sums_to_budget | — | passed | — | rust |
| cargo | rust-test | main::when_summarizing_then_other_projects_dues_are_not_attributed | — | passed | — | rust |
| cargo | rust-test | main::a_failure_partway_through_a_batch_writes_nothing_and_a_rerun_links_every_liability | — | skipped | — | rust |
| cargo | rust-test | main::a_first_accrual_batch_keeps_both_debtor_shares_and_blocks_a_rerun | — | skipped | — | rust |
| cargo | rust-test | main::another_spelling_of_an_accrued_month_creates_nothing_in_the_database | — | skipped | — | rust |
| cargo | rust-test | main::joint_liability_owner_intervals_do_not_overlap_on_transfer_day_and_exclude_day_one_seller | — | skipped | — | rust |
| cargo | rust-test | main::skipped_units_are_recorded_where_the_manager_can_read_them | — | skipped | — | rust |
| cargo | rust-test | main::two_sites_accrue_in_a_row_each_with_its_own_period_row | — | skipped | — | rust |
| cargo | rust-test | main::v38_corrections_and_v41_reevaluation_adjustments_round_trip_with_rls | — | skipped | — | rust |
| cargo | rust-test | main::v40_late_fee_rows_and_v42_schedule_survive_database_reload | — | skipped | — | rust |
| cargo | rust-test | main::v43_period_close_snapshot_and_four_eyes_reopen_round_trip_with_rls | — | skipped | — | rust |
| cargo | rust-test | main::exit_settlement_payout_transfer_and_stale_balance_are_atomic | — | skipped | — | rust |
| cargo | rust-test | main::when_an_owner_is_registered_then_t1_records_ownership_and_the_unit_can_be_archived | — | skipped | — | rust |
| cargo | rust-test | main::when_command_is_illegal_for_the_state_then_nothing_changes | — | skipped | — | rust |
| cargo | rust-test | main::when_owner_move_in_names_someone_else_then_it_is_rejected | — | skipped | — | rust |
| cargo | rust-test | main::when_registration_is_approved_on_an_occupied_unit_then_it_is_rejected | — | skipped | — | rust |
| cargo | rust-test | main::when_state_is_read_then_allowed_commands_follow_the_table | — | skipped | — | rust |
| cargo | rust-test | main::when_status_or_sessions_are_written_by_hand_then_the_model_holds | — | skipped | — | rust |
| cargo | rust-test | main::when_tenant_is_replaced_then_outgoing_tenant_is_settled | — | skipped | — | rust |
| cargo | rust-test | main::when_tenant_leaves_and_owner_moves_in_then_owner_is_unchanged | — | skipped | — | rust |
| cargo | rust-test | main::when_title_is_transferred_then_occupancy_follows_the_state_table | — | skipped | — | rust |
| cargo | rust-test | main::household_by_reference_and_primary_contact_by_person | — | skipped | — | rust |
| cargo | rust-test | main::logins_open_with_an_activation_link_and_removal_needs_step_up | — | skipped | — | rust |
| cargo | rust-test | main::person_cards_are_created_edited_and_stay_in_their_site | — | skipped | — | rust |
| cargo | rust-test | main::registration_accepts_person_references_for_owner_and_members | — | skipped | — | rust |
| cargo | rust-test | main::role_free_card_has_no_stored_role_and_leaves_the_ledger_intact | — | skipped | — | rust |
| cargo | rust-test | main::search_reports_role_eligibility_for_a_unit | — | skipped | — | rust |
| cargo | rust-test | main::title_transfer_honors_new_owner_reference_and_clears_the_old_primary_contact | — | skipped | — | rust |
| cargo | rust-test | main::a_foreign_site_card_cannot_be_merged | — | skipped | — | rust |
| cargo | rust-test | main::concurrent_merges_of_one_card_apply_once | — | skipped | — | rust |
| cargo | rust-test | main::merge_is_refused_when_roles_conflict_on_a_unit | — | skipped | — | rust |
| cargo | rust-test | main::merge_leaves_payment_ledger_ids_intact | — | skipped | — | rust |
| cargo | rust-test | main::merge_needs_step_up_and_refuses_self_and_merged_cards | — | skipped | — | rust |
| cargo | rust-test | main::merge_repoints_relationships_and_leaves_a_tombstone | — | skipped | — | rust |
| cargo | rust-test | main::financial_reads_fail_loudly_when_the_database_is_gone | — | skipped | — | rust |
| cargo | rust-test | main::get_views_never_change_the_ledger_and_accrual_offsets_transactionally | — | skipped | — | rust |
| cargo | rust-test | main::household_members_round_trip_and_stay_in_their_site | — | skipped | — | rust |
| cargo | rust-test | main::reconciliation_assignment_is_persisted_for_its_site_only | — | skipped | — | rust |
| cargo | rust-test | main::responsible_contact_persists_without_changing_owner_or_tenant | — | skipped | — | rust |
| cargo | rust-test | main::rls_hides_other_tenants_inside_a_bound_transaction | — | skipped | — | rust |
| cargo | rust-test | main::sender_ibans_are_persisted_for_their_unit | — | skipped | — | rust |
| cargo | rust-test | main::tenant_data_never_crosses_sites | — | skipped | — | rust |
| cargo | rust-test | main::a_dependent_with_a_person_card_keeps_the_card_when_moved_out | — | skipped | — | rust |
| cargo | rust-test | main::a_persons_card_follows_the_unit_actions_and_keeps_the_relation_history | — | skipped | — | rust |
| cargo | rust-test | main::a_persons_move_out_also_moves_out_their_dependents_and_the_cards_show_it | — | skipped | — | rust |
| cargo | rust-test | main::a_repeated_command_that_is_no_longer_legal_is_rejected_and_changes_nothing | — | skipped | — | rust |
| cargo | rust-test | main::choosing_the_same_existing_person_repeatedly_creates_no_new_card | — | skipped | — | rust |
| cargo | rust-test | main::contact_preferences_saved_repeatedly_keep_the_last_values | — | skipped | — | rust |
| cargo | rust-test | main::creating_the_same_person_repeatedly_never_produces_a_second_card | — | skipped | — | rust |
| cargo | rust-test | main::dependents_follow_every_action_that_closes_a_session | — | skipped | — | rust |
| cargo | rust-test | main::duplicate_cards_are_merged_and_the_survivor_keeps_the_history | — | skipped | — | rust |
| cargo | rust-test | main::editing_a_card_repeatedly_raises_the_version_once_per_edit | — | skipped | — | rust |
| cargo | rust-test | main::every_executed_command_is_audited_in_order | — | skipped | — | rust |
| cargo | rust-test | main::household_members_added_edited_and_removed_repeatedly_keep_roster_and_contact | — | skipped | — | rust |
| cargo | rust-test | main::move_out_archives_the_household_of_the_closed_session_each_time | — | skipped | — | rust |
| cargo | rust-test | main::opening_and_removing_a_login_repeatedly_keeps_the_login_status_correct | — | skipped | — | rust |
| cargo | rust-test | main::opening_the_login_twice_in_a_row_reuses_the_same_account | — | skipped | — | rust |
| cargo | rust-test | main::owner_move_out_and_move_in_repeated_keep_the_owner_and_the_deed | — | skipped | — | rust |
| cargo | rust-test | main::owner_rents_out_and_takes_back_repeatedly | — | skipped | — | rust |
| cargo | rust-test | main::person_actions_of_another_site_are_refused_every_time | — | skipped | — | rust |
| cargo | rust-test | main::replacing_the_tenant_repeatedly_settles_each_outgoing_tenant_once | — | skipped | — | rust |
| cargo | rust-test | main::setting_the_national_id_repeatedly_keeps_it_masked_and_unique | — | skipped | — | rust |
| cargo | rust-test | main::tenant_move_in_and_move_out_repeated_keep_one_history_row_per_tenant | — | skipped | — | rust |
| cargo | rust-test | main::title_transfer_repeated_keeps_every_previous_owner_in_the_history | — | skipped | — | rust |
| cargo | rust-test | main::when_a_tenant_moves_out_all_dependents_move_out_with_them | — | skipped | — | rust |
| cargo | rust-test | main::when_an_owner_who_lives_in_the_unit_moves_out_their_dependents_move_out_too | — | skipped | — | rust |
| cargo | rust-test | main::finance_error_maps_cleanly_to_app_error_response | — | passed | — | rust |
| cargo | rust-test | main::app_error_produces_standardized_json_envelope | — | passed | — | rust |
| cargo | rust-test | main::response_includes_matching_x_request_id_header | — | passed | — | rust |
| cargo | rust-test | main::correlate_middleware_propagates_client_request_id | — | passed | — | rust |
| cargo | rust-test | main::security_error_maps_cleanly_with_trace_id | — | passed | — | rust |
| cargo | rust-test | main::every_spec009_record_round_trips_through_postgresql | — | passed | — | rust |
| cargo | rust-test | main::allocation_cases_match_the_fixture | — | passed | — | rust |
| cargo | rust-test | main::penalty_keeps_kurus_precision_and_does_not_drift_across_recalculations | — | passed | — | rust |
| cargo | rust-test | main::penalty_cases_match_the_fixture | — | passed | — | rust |
| cargo | rust-test | main::waterfall_properties_hold_for_random_inputs | — | passed | — | rust |
| cargo | rust-test | main::payment_date_violation_is_deterministic_for_a_given_window | — | passed | — | rust |
| cargo | rust-test | main::flutter_reconciliation_payload_uses_backend_enum_contract | — | passed | — | rust |
| cargo | rust-test | main::when_accruing_capital_installment_then_reconciles_penny_drift_exactly | — | passed | — | rust |
| cargo | rust-test | main::when_bank_statement_line_is_older_than_the_window_then_it_is_accepted | — | passed | — | rust |
| cargo | rust-test | main::when_bank_line_is_dated_today_local_at_utc_midnight_then_it_is_not_treated_as_future | — | passed | — | rust |
| cargo | rust-test | main::when_approving_pending_registration_then_provisions_user_and_returns_credentials | — | passed | — | rust |
| cargo | rust-test | main::when_bank_webhook_delivers_virtual_iban_payment_then_clears_dues_and_generates_receipt | — | passed | — | rust |
| cargo | rust-test | main::when_calculating_debt_aging_then_categorizes_into_current_30_60_and_90_brackets | — | passed | — | rust |
| cargo | rust-test | main::when_changing_password_then_policy_is_uniform_and_errors_do_not_enumerate_users | — | passed | — | rust |
| cargo | rust-test | main::when_confirming_reconciliation_batch_then_updates_dues_and_ledger | — | passed | — | rust |
| cargo | rust-test | main::when_confirming_reconciliation_with_optional_message_then_reports_notification_sent | — | passed | — | rust |
| cargo | rust-test | main::when_confirming_reconciliation_with_surplus_or_zero_debt_then_credits_advance_payments | — | passed | — | rust |
| cargo | rust-test | main::when_contractor_disbursement_recorded_then_updates_fund_balance | — | passed | — | rust |
| cargo | rust-test | main::when_create_units_block_name_empty_then_rejected | — | passed | — | rust |
| cargo | rust-test | main::when_create_units_duplicate_then_conflict_returned | — | passed | — | rust |
| cargo | rust-test | main::when_create_units_exceeds_500_then_rejected | — | passed | — | rust |
| cargo | rust-test | main::when_create_units_foreign_site_then_tenant_denied | — | passed | — | rust |
| cargo | rust-test | main::when_create_units_list_validation_then_rejected | — | passed | — | rust |
| cargo | rust-test | main::when_create_units_start_greater_than_end_then_rejected | — | passed | — | rust |
| cargo | rust-test | main::when_create_units_unit_zero_then_rejected | — | passed | — | rust |
| cargo | rust-test | main::when_creating_capital_project_with_installments_then_calculates_plan_correctly | — | passed | — | rust |
| cargo | rust-test | main::when_deleting_site_with_active_units_or_actions_then_strictly_rejected | — | passed | — | rust |
| cargo | rust-test | main::when_dues_period_already_accrued_then_duplicate_accrual_is_prevented | — | passed | — | rust |
| cargo | rust-test | main::when_duplicate_email_for_home_owner_then_throws_exception | — | passed | — | rust |
| cargo | rust-test | main::when_deleting_action_free_site_then_succeeds_and_removes_site | — | passed | — | rust |
| cargo | rust-test | main::when_duplicate_email_for_home_resident_then_throws_exception | — | passed | — | rust |
| cargo | rust-test | main::when_duplicate_email_then_throws_exception | — | passed | — | rust |
| cargo | rust-test | main::when_excess_or_multiple_payments_delivered_then_credited_as_advance_payment | — | passed | — | rust |
| cargo | rust-test | main::when_generating_invite_link_then_returns_valid_url_and_token | — | passed | — | rust |
| cargo | rust-test | main::when_generating_unit_invite_for_unknown_unit_then_returns_not_found | — | passed | — | rust |
| cargo | rust-test | main::when_generating_unit_invite_link_then_returns_unit_scoped_url_and_token | — | passed | — | rust |
| cargo | rust-test | main::when_home_owner_role_then_has_invite_and_household_permissions | — | passed | — | rust |
| cargo | rust-test | main::when_get_units_foreign_site_then_tenant_denied | — | passed | — | rust |
| cargo | rust-test | main::when_getting_resident_dashboard_then_returns_real_time_calculated_dues | — | passed | — | rust |
| cargo | rust-test | main::when_google_token_is_unsigned_then_account_takeover_is_impossible | — | passed | — | rust |
| cargo | rust-test | main::when_homeowner_or_tenant_manually_adds_household_member_then_stored_and_returned | — | passed | — | rust |
| cargo | rust-test | main::when_homeowner_manages_matching_criteria_then_criteria_can_be_viewed_added_and_deleted | — | passed | — | rust |
| cargo | rust-test | main::when_homeowner_records_payment_exceeding_debt_then_clears_debt_and_credits_surplus_as_advance | — | passed | — | rust |
| cargo | rust-test | main::when_homeowner_records_payment_with_existing_debt_then_clears_debt | — | passed | — | rust |
| cargo | rust-test | main::when_homeowner_records_payment_with_no_debt_then_matches_as_advance_payment | — | passed | — | rust |
| cargo | rust-test | main::when_house_type_selected_then_sets_monthly_dues_from_tariff | — | passed | — | rust |
| cargo | rust-test | main::when_inter_ledger_transfer_executed_then_deducts_advance_credits_capital_and_issues_receipt | — | passed | — | rust |
| cargo | rust-test | main::when_invalid_bank_code_or_iban_then_configuration_fails_validation | — | passed | — | rust |
| cargo | rust-test | main::when_invalid_email_or_phone_then_registration_rejected_with_validation_error | — | passed | — | rust |
| cargo | rust-test | main::when_managing_blocks_then_can_list_and_create | — | passed | — | rust |
| cargo | rust-test | main::when_managing_dues_periods_then_can_list_and_create_period_in_separate_table | — | passed | — | rust |
| cargo | rust-test | main::when_managing_home_owners_then_can_delete_home_owner | — | passed | — | rust |
| cargo | rust-test | main::when_managing_house_types_then_can_list_create_and_delete | — | passed | — | rust |
| cargo | rust-test | main::when_managing_occupancy_lifecycle_then_can_move_out_and_move_in_without_losing_history | — | passed | — | rust |
| cargo | rust-test | main::when_not_overdue_then_penalty_remains_zero | — | passed | — | rust |
| cargo | rust-test | main::when_overdue_by_10_days_then_calculates_exact_5_percent_pro_rated_penalty | — | passed | — | rust |
| cargo | rust-test | main::when_match_all_homeowner_payments_called_then_collects_and_matches_all_payments_with_debts_and_advance | — | passed | — | rust |
| cargo | rust-test | main::when_milestone_disbursement_recorded_then_keeps_invoice_and_accumulates_disbursed | — | passed | — | rust |
| cargo | rust-test | main::when_new_dues_period_accrued_and_resident_has_advance_payment_then_automatically_offsets_debt | — | passed | — | rust |
| cargo | rust-test | main::when_parsing_bank_statement_then_enforces_active_bank_format_and_permits_new_format_after_change | — | passed | — | rust |
| cargo | rust-test | main::when_parsing_mt940_statement_then_extracts_transactions_and_matches_due | — | passed | — | rust |
| cargo | rust-test | main::when_parsing_turkish_bank_excel_then_matches_flat_and_amount | — | passed | — | rust |
| cargo | rust-test | main::when_payment_date_is_beyond_the_backdating_window_then_it_is_rejected | — | passed | — | rust |
| cargo | rust-test | main::when_payment_date_is_in_the_future_then_it_is_rejected | — | passed | — | rust |
| cargo | rust-test | main::when_probing_kuveyt_turk_sandbox_status_then_reports_keys_loaded | — | passed | — | rust |
| cargo | rust-test | main::when_payment_date_is_within_the_backdating_window_then_it_is_accepted | — | passed | — | rust |
| cargo | rust-test | main::when_payment_is_allocated_then_amount_owed_is_preserved_and_penalty_is_recorded | — | passed | — | rust |
| cargo | rust-test | main::when_property_ownership_transferred_then_old_owner_debt_frozen_and_tenant_lease_preserved | — | passed | — | rust |
| cargo | rust-test | main::when_posting_valid_site_onboarding_then_returns_201_with_credentials | — | passed | — | rust |
| cargo | rust-test | main::when_purge_site_cascade_invoked_then_site_and_associated_units_and_residents_are_removed | — | passed | — | rust |
| cargo | rust-test | main::when_querying_payment_stream_then_returns_filtered_entries_and_volume_kpis | — | passed | — | rust |
| cargo | rust-test | main::when_querying_resident_dashboard_then_includes_allocated_virtual_iban | — | passed | — | rust |
| cargo | rust-test | main::when_querying_resident_dashboard_then_separates_capital_dues_by_project | — | passed | — | rust |
| cargo | rust-test | main::when_recording_payment_with_penalty_then_amortizes_penalty_first_per_tbk100_and_surplus_to_advance | — | passed | — | rust |
| cargo | rust-test | main::when_registering_co_resident_then_attached_to_household_and_does_not_alter_dues_primary_payer | — | passed | — | rust |
| cargo | rust-test | main::when_registering_home_owner_then_sends_activation_instead_of_a_password | — | passed | — | rust |
| cargo | rust-test | main::when_registering_new_owner_or_tenant_to_existing_unit_then_archives_previous_occupant_in_history | — | passed | — | rust |
| cargo | rust-test | main::when_registering_home_resident_then_assigns_home_resident_role_and_unit_scope | — | passed | — | rust |
| cargo | rust-test | main::when_provisioning_12_units_for_site_then_creates_residents_and_virtual_ibans | — | passed | — | rust |
| cargo | rust-test | main::when_registering_new_site_then_provisions_site_and_manager_with_temporary_password | — | passed | — | rust |
| cargo | rust-test | main::when_registering_without_invite_or_with_unknown_invite_then_rejected | — | passed | — | rust |
| cargo | rust-test | main::when_registering_site_with_blocks_then_blocks_are_stored | — | passed | — | rust |
| cargo | rust-test | main::when_resident_role_then_has_unit_restricted_permissions | — | passed | — | rust |
| cargo | rust-test | main::when_reset_demo_data_invoked_then_payments_and_dues_are_restored_to_clean_slate | — | passed | — | rust |
| cargo | rust-test | main::when_resetting_admin_password_for_non_existent_site_then_fails | — | passed | — | rust |
| cargo | rust-test | main::when_sender_iban_is_remembered_subsequent_blank_desc_payment_auto_matches | — | passed | — | rust |
| cargo | rust-test | main::when_scheduler_batch_runs_then_accrues_and_prevents_duplicate_accrual | — | passed | — | rust |
| cargo | rust-test | main::when_resetting_admin_password_then_generates_new_temporary_password_and_forces_change | — | passed | — | rust |
| cargo | rust-test | main::when_site_edit_drops_an_occupied_block_then_nothing_changes | — | passed | — | rust |
| cargo | rust-test | main::when_site_edit_keeps_manager_email_with_person_shadow_then_it_succeeds | — | passed | — | rust |
| cargo | rust-test | main::when_statement_contains_virtual_iban_then_matches_flat_with_100_percent_confidence | — | passed | — | rust |
| cargo | rust-test | main::when_site_edit_resends_existing_blocks_then_block_ids_are_kept | — | passed | — | rust |
| cargo | rust-test | main::when_site_manager_changes_bank_account_then_previous_account_deactivated_and_new_format_set | — | passed | — | rust |
| cargo | rust-test | main::when_site_manager_configures_bank_account_then_format_is_automatically_set_by_bank | — | passed | — | rust |
| cargo | rust-test | main::when_submitting_self_registration_then_creates_pending_request | — | passed | — | rust |
| cargo | rust-test | main::when_tenant_moves_out_then_household_members_are_archived_and_cleared_from_active_unit | — | passed | — | rust |
| cargo | rust-test | main::when_tenant_payment_is_explicitly_designated_for_capital_dues_then_rent_offset_is_eligible | — | passed | — | rust |
| cargo | rust-test | main::when_unit_created_then_generates_unique_sanal_iban | — | passed | — | rust |
| cargo | rust-test | main::when_tenant_pays_without_capital_intent_then_owner_capital_dues_are_untouched | — | passed | — | rust |
| cargo | rust-test | main::when_transfer_cannot_be_matched_then_enters_unmatched_pool_successfully | — | passed | — | rust |
| cargo | rust-test | main::when_utc_is_late_evening_then_accrual_uses_the_site_local_date | — | passed | — | rust |
| cargo | rust-test | main::when_transferring_property_ownership_then_freezes_old_debt_and_creates_occupancy_history | — | passed | — | rust |
| cargo | rust-test | main::when_updating_site_then_site_details_and_admin_info_are_updated | — | passed | — | rust |
| cargo | rust-test | main::when_valid_google_id_token_then_authenticates_and_links_account | — | passed | — | rust |
| cargo | rust-test | main::when_using_former_backdoor_or_placeholder_passwords_then_login_fails | — | passed | — | rust |
| cargo | rust-test | main::when_webhook_currency_is_not_try_then_it_is_rejected | — | passed | — | rust |
| cargo | rust-test | main::when_webhook_is_unsigned_or_forged_then_it_is_rejected | — | passed | — | rust |
| cargo | rust-test | main::when_valid_password_registration_then_can_authenticate | — | passed | — | rust |
| cargo | rust-test | main::when_wrong_password_then_throws_exception | — | passed | — | rust |
| cargo | rust-test | main::when_wipe_all_data_invoked_then_all_sites_units_and_residents_are_purged | — | passed | — | rust |
| cargo | rust-test | main::when_zero_data_for_site_dues_and_homeowner_then_guidance_provided | — | passed | — | rust |
| cargo | rust-test | main::when_a_payment_ends_a_segment_then_the_next_segment_starts_from_its_total | — | passed | — | rust |
| cargo | rust-test | main::when_the_job_has_run_then_the_ledger_books_each_day_and_agrees_with_the_evaluation | — | passed | — | rust |
| cargo | rust-test | main::when_catch_up_runs_after_close_then_fee_is_booked_open_and_balances_match_dashboard | — | passed | — | rust |
| cargo | rust-test | main::when_the_job_runs_on_the_tenth_day_then_the_fee_is_the_evaluation_for_that_day | — | passed | — | rust |
| cargo | rust-test | main::when_the_job_runs_every_day_then_the_fee_is_rounded_once_per_segment | — | passed | — | rust |
| cargo | rust-test | main::when_a_credit_note_follows_daily_accruals_then_the_trial_balance_matches_the_liability | — | passed | — | rust |
| cargo | rust-test | main::when_the_job_has_not_run_yet_then_the_trial_balance_still_matches_the_evaluation | — | passed | — | rust |
| cargo | rust-test | main::when_the_job_runs_the_day_after_a_credit_note_then_the_fee_matches_the_evaluation | — | passed | — | rust |
| cargo | rust-test | main::when_the_job_runs_twice_on_one_day_then_nothing_changes | — | passed | — | rust |
| cargo | rust-test | main::when_the_stored_fee_differs_from_the_evaluation_then_the_check_reports_the_liability | — | passed | — | rust |
| cargo | rust-test | main::when_the_daily_job_already_ran_then_stored_fee_day_rows_and_ledger_stay_consistent | — | passed | — | rust |
| cargo | rust-test | main::when_a_payment_is_dated_after_the_accrual_then_late_fee_is_untouched | — | passed | — | rust |
| cargo | rust-test | main::when_a_backdated_payment_is_partial_then_late_fee_keeps_accruing_on_the_rest | — | passed | — | rust |
| cargo | rust-test | main::when_a_bank_statement_line_is_backdated_then_late_fee_is_recalculated_the_same_way | — | passed | — | rust |
| cargo | rust-test | main::when_a_payment_is_backdated_then_late_fee_is_recalculated_and_the_excess_reversed | — | passed | — | rust |
| cargo | rust-test | main::when_backdated_payment_reverses_fee_from_closed_month_then_adjustment_is_booked_today | — | passed | — | rust |
| cargo | rust-test | main::when_penalty_is_fully_covered_by_reevaluation_but_principal_remains_unpaid_status_stays_overdue | — | passed | — | rust |
| cargo | rust-test | main::when_penalty_was_already_paid_then_the_excess_moves_to_the_payers_advance | — | passed | — | rust |
| cargo | rust-test | main::production_refuses_a_plain_http_gateway_and_never_prints_credentials | — | passed | — | rust |
| cargo | rust-test | main::when_a_reminder_is_delivered_then_the_gateway_receives_it_once_and_failures_are_recorded | — | passed | — | rust |
| cargo | rust-test | main::when_manual_accrual_runs_then_it_uses_the_same_occupancy_shares_as_the_scheduler | — | passed | — | rust |
| cargo | rust-test | main::when_a_unit_is_created_mid_month_then_scheduler_charges_only_remaining_days | — | passed | — | rust |
| cargo | rust-test | main::when_a_tenant_moves_in_mid_month_then_scheduler_splits_by_actual_days | — | passed | — | rust |
| cargo | rust-test | main::when_proration_is_disabled_then_scheduler_keeps_the_full_month_rule | — | passed | — | rust |
| cargo | rust-test | main::when_manual_accrual_retries_after_tenant_moves_in_then_existing_unit_charge_blocks_rerun | — | passed | — | rust |
| cargo | rust-test | main::when_site_manager_enables_proration_then_policy_is_saved_for_accrual | — | passed | — | rust |
| cargo | rust-test | main::when_scheduler_retries_after_tenant_moves_in_then_existing_unit_charge_blocks_rerun | — | passed | — | rust |
| cargo | rust-test | main::effective_date_cannot_be_in_future | — | passed | — | rust |
| cargo | rust-test | main::effective_date_may_precede_recorded_session_start | — | passed | — | rust |
| cargo | rust-test | main::failed_second_step_preserves_unit_state_and_is_not_allowed_on_vacant | — | passed | — | rust |
| cargo | rust-test | main::leave_recorded_after_resident_actually_left | — | passed | — | rust |
| cargo | rust-test | main::move_out_is_rejected_on_vacant_unit | — | passed | — | rust |
| cargo | rust-test | main::exit_balance_counts_only_departing_tenants_liabilities | — | passed | — | rust |
| cargo | rust-test | main::new_owner_moves_in_at_transfer | — | passed | — | rust |
| cargo | rust-test | main::owner_move_in_is_rejected_on_owner_occupied_unit | — | passed | — | rust |
| cargo | rust-test | main::owner_move_in_is_rejected_on_tenant_occupied_unit | — | passed | — | rust |
| cargo | rust-test | main::owner_move_in_is_rejected_on_unowned_vacant_unit | — | passed | — | rust |
| cargo | rust-test | main::owner_move_in_only_allows_owner_on_record | — | passed | — | rust |
| cargo | rust-test | main::owner_moves_into_unit_after_tenant_left | — | passed | — | rust |
| cargo | rust-test | main::owner_takes_unit_back_from_tenant | — | passed | — | rust |
| cargo | rust-test | main::registration_approval_respects_unit_state | — | passed | — | rust |
| cargo | rust-test | main::replacing_tenant_settles_outgoing_and_opens_new_tenant | — | passed | — | rust |
| cargo | rust-test | main::resident_move_out_closes_session_and_vacates_unit | — | passed | — | rust |
| cargo | rust-test | main::selling_vacant_unit_leaves_it_vacant | — | passed | — | rust |
| cargo | rust-test | main::status_cannot_drift_from_occupancy_sessions | — | passed | — | rust |
| cargo | rust-test | main::tenant_buys_unit_becomes_owner_occupied | — | passed | — | rust |
| cargo | rust-test | main::tenant_move_in_is_rejected_on_owner_occupied_unit | — | passed | — | rust |
| cargo | rust-test | main::tenant_move_in_is_rejected_on_tenant_occupied_unit | — | passed | — | rust |
| cargo | rust-test | main::tenant_move_in_is_rejected_on_unowned_vacant_unit | — | passed | — | rust |
| cargo | rust-test | main::tenant_move_in_still_accepts_new_person | — | passed | — | rust |
| cargo | rust-test | main::selling_owner_occupied_unit_vacates_it | — | passed | — | rust |
| cargo | rust-test | main::title_deed_transfer_binds_new_owner_for_future_dues | — | passed | — | rust |
| cargo | rust-test | main::transition_is_all_or_nothing | — | passed | — | rust |
| cargo | rust-test | main::when_spec_is_generated_then_all_registered_routes_are_covered | — | passed | — | rust |
| cargo | rust-test | main::when_scalar_is_requested_then_scalar_html_page_is_returned | — | passed | — | rust |
| cargo | rust-test | main::when_swagger_ui_is_requested_then_interactive_html_page_is_returned | — | passed | — | rust |
| cargo | rust-test | main::when_openapi_aliases_are_requested_then_same_spec_is_returned | — | passed | — | rust |
| cargo | rust-test | main::when_openapi_json_is_requested_then_valid_spec_is_returned | — | passed | — | rust |
| cargo | rust-test | main::successor_owner_payment_does_not_settle_predecessor_charges | — | passed | — | rust |
| cargo | rust-test | main::when_debt_aging_is_computed_then_it_uses_outstanding_amounts_and_the_liabilitys_debtor | — | passed | — | rust |
| cargo | rust-test | main::when_bank_webhook_is_redelivered_then_only_one_receipt_exists | — | passed | — | rust |
| cargo | rust-test | main::when_a_statement_line_is_confirmed_twice_then_it_is_settled_once | — | passed | — | rust |
| cargo | rust-test | main::when_identified_owner_pays_tenanted_unit_with_only_tenant_debt_then_tenant_debt_is_untouched_and_advances_to_owner | — | passed | — | rust |
| cargo | rust-test | main::when_match_all_settles_a_pending_payment_then_no_duplicate_ledger_row_is_created | — | passed | — | rust |
| cargo | rust-test | main::when_no_designation_is_given_then_the_oldest_due_is_settled_first | — | passed | — | rust |
| cargo | rust-test | main::when_overdue_due_is_paid_by_webhook_then_penalty_is_collected_first_with_a_tah_receipt | — | passed | — | rust |
| cargo | rust-test | main::when_payer_designates_a_period_then_that_due_is_settled_before_older_dues | — | passed | — | rust |
| cargo | rust-test | main::when_payment_channel_is_unknown_then_the_payment_is_rejected | — | passed | — | rust |
| cargo | rust-test | main::when_tenant_webhook_mentions_capital_then_it_waits_for_manager_review | — | passed | — | rust |
| cargo | rust-test | main::when_unmatched_sender_pays_tenanted_unit_with_only_tenant_debt_then_it_settles_tenant_debt | — | passed | — | rust |
| cargo | rust-test | main::when_unmatched_sender_statement_line_confirmed_on_tenanted_unit_with_only_tenant_debt_then_it_settles_tenant_debt | — | passed | — | rust |
| cargo | rust-test | main::when_a_settled_payment_is_reversed_then_dues_reopen_the_advance_is_refunded_and_an_iad_receipt_is_issued | — | passed | — | rust |
| cargo | rust-test | main::when_a_payment_is_reversed_twice_then_the_first_reversal_is_returned | — | passed | — | rust |
| cargo | rust-test | main::when_a_transaction_id_is_reused_with_other_content_then_the_payload_hash_differs | — | passed | — | rust |
| cargo | rust-test | main::when_a_bank_reference_is_given_then_it_is_the_receipts_channel_reference | — | passed | — | rust |
| cargo | rust-test | main::when_a_reversal_has_no_reason_or_targets_a_reversal_then_it_is_rejected | — | passed | — | rust |
| cargo | rust-test | main::when_a_site_tax_id_is_not_10_or_11_digits_then_the_update_is_rejected | — | passed | — | rust |
| cargo | rust-test | main::when_a_virman_receipt_is_reversed_then_the_dues_reopen_and_the_source_advance_is_restored | — | passed | — | rust |
| cargo | rust-test | main::when_advances_are_offset_then_each_due_is_paid_only_from_its_own_debtors_advance | — | passed | — | rust |
| cargo | rust-test | main::when_aging_is_snapshotted_then_one_row_per_unit_and_debtor_is_produced | — | passed | — | rust |
| cargo | rust-test | main::when_an_idempotent_payment_is_retried_then_the_key_is_not_stored_in_channel_reference | — | passed | — | rust |
| cargo | rust-test | main::when_capital_keyword_is_not_confirmed_then_tenant_pays_only_operational_dues | — | passed | — | rust |
| cargo | rust-test | main::when_manager_explicitly_designates_tenant_payment_for_owner_capital_dues | — | passed | — | rust |
| cargo | rust-test | main::when_reconciliation_status_is_stored_then_one_english_vocabulary_round_trips | — | passed | — | rust |
| cargo | rust-test | main::when_debt_aging_report_is_fetched_then_buckets_total_the_overdue_sum | — | passed | — | rust |
| cargo | rust-test | main::when_owner_pays_operational_due_is_settled_before_capital_due | — | passed | — | rust |
| cargo | rust-test | main::when_ownership_transfers_old_owner_balance_freezes_and_new_owner_binds | — | passed | — | rust |
| cargo | rust-test | main::when_tenant_moves_out_balance_is_frozen_and_future_dues_shift_to_owner | — | passed | — | rust |
| cargo | rust-test | main::when_tenant_overpays_owner_capital_dues_then_surplus_stays_in_owner_advance | — | passed | — | rust |
| cargo | rust-test | main::when_tenant_overpays_then_the_surplus_is_credited_to_the_tenant_advance_only | — | passed | — | rust |
| cargo | rust-test | main::when_tenant_surplus_is_transferred_to_owner_capital_then_the_tenant_advance_pays_on_behalf_of_the_owner | — | passed | — | rust |
| cargo | rust-test | main::when_the_credited_advance_was_already_used_then_the_reversal_is_rejected | — | passed | — | rust |
| cargo | rust-test | main::when_the_site_has_a_tax_id_then_new_receipts_snapshot_the_issuer | — | passed | — | rust |
| cargo | rust-test | main::when_virman_debtor_is_unknown_then_the_transfer_is_rejected | — | passed | — | rust |
| cargo | rust-test | main::sample_receipt_pdf | — | skipped | — | rust |
| cargo | rust-test | main::when_a_card_payment_is_captured_then_it_is_recorded_once_through_the_ingestion_path | — | passed | — | rust |
| cargo | rust-test | main::when_a_card_receipt_is_reversed_then_the_intent_is_refunded | — | passed | — | rust |
| cargo | rust-test | main::when_a_provider_body_is_signed_then_only_that_body_verifies | — | passed | — | rust |
| cargo | rust-test | main::when_a_draft_budget_is_created_then_unit_shares_follow_land_share_and_equal_keys | — | passed | — | rust |
| cargo | rust-test | main::when_a_budget_is_in_force_then_dues_are_accrued_from_unit_shares_with_the_budget_as_legal_basis | — | passed | — | rust |
| cargo | rust-test | main::when_a_site_requires_a_budget_and_none_is_in_force_then_accrual_is_refused | — | passed | — | rust |
| cargo | rust-test | main::when_a_tenant_liability_has_an_owner_link_then_owner_sees_only_its_joint_balance | — | passed | — | rust |
| cargo | rust-test | main::when_amounts_are_formatted_then_turkish_grouping_is_used | — | passed | — | rust |
| cargo | rust-test | main::when_an_amount_is_split_by_weight_then_the_parts_add_up_to_the_kurus | — | passed | — | rust |
| cargo | rust-test | main::when_a_statement_is_built_then_items_are_aged_and_each_debtor_sees_only_their_own | — | passed | — | rust |
| cargo | rust-test | main::when_a_receipt_pdf_is_rendered_and_verified_then_the_public_check_discloses_no_payer | — | passed | — | rust |
| cargo | rust-test | main::when_a_unit_has_no_tariff_then_manual_accrual_skips_it_instead_of_charging_a_fixed_amount | — | passed | — | rust |
| cargo | rust-test | main::when_an_interim_budget_exceeds_the_revaluation_rate_then_it_is_refused_and_the_assembly_can_approve_it | — | passed | — | rust |
| cargo | rust-test | main::when_an_approved_budget_is_served_and_the_window_closes_then_it_becomes_final_unless_an_objection_is_upheld | — | passed | — | rust |
| cargo | rust-test | main::when_an_interim_budget_is_within_the_cap_then_it_is_in_force_with_a_three_month_deadline | — | passed | — | rust |
| cargo | rust-test | main::when_an_owner_pays_a_linked_tenant_liability_then_the_receipt_names_payer_and_debtor | — | passed | — | rust |
| cargo | rust-test | main::when_an_owner_card_payment_targets_a_joint_tenant_balance_then_only_that_debt_is_paid | — | passed | — | rust |
| cargo | rust-test | main::when_no_budget_exists_then_legacy_tariff_accrual_carries_a_kmk37_warning | — | passed | — | rust |
| cargo | rust-test | main::when_receipt_viewer_shares_a_name_but_not_person_id_then_receipt_is_hidden | — | passed | — | rust |
| cargo | rust-test | main::when_the_provider_amount_differs_or_a_resident_pays_another_debtor_then_it_is_refused | — | passed | — | rust |
| cargo | rust-test | main::when_a_card_is_declined_then_the_due_stays_open_and_is_retried_and_an_expired_card_suspends_the_mandate | — | passed | — | rust |
| cargo | rust-test | main::when_a_debt_notice_targets_a_group_channel_then_it_is_blocked_and_logged | — | passed | — | rust |
| cargo | rust-test | main::when_a_budget_line_uses_house_type_or_meter_keys_then_shares_follow_the_weights | — | passed | — | rust |
| cargo | rust-test | main::when_a_case_reaches_enforcement_then_it_needs_a_legal_basis_and_the_lawyer_reads_the_pack_by_token | — | passed | — | rust |
| cargo | rust-test | main::when_a_dispute_is_resolved_then_dunning_resumes | — | passed | — | rust |
| cargo | rust-test | main::when_a_management_company_invoices_its_sites_then_each_period_is_invoiced_once_and_only_members_see_the_portfolio | — | passed | — | rust |
| cargo | rust-test | main::when_a_heating_period_is_approved_then_shares_add_up_and_the_occupant_is_billed | — | passed | — | rust |
| cargo | rust-test | main::when_a_non_staff_role_exports_debtors_then_names_are_masked_and_every_export_is_logged | — | passed | — | rust |
| cargo | rust-test | main::when_a_run_is_just_after_local_midnight_then_the_site_day_is_the_new_local_day | — | passed | — | rust |
| cargo | rust-test | main::when_a_plan_is_kept_it_completes_and_waives_the_penalty_and_when_late_it_breaks | — | passed | — | rust |
| cargo | rust-test | main::when_a_resident_opts_out_of_sms_then_reminders_are_blocked_but_legal_notices_go_out | — | passed | — | rust |
| cargo | rust-test | main::when_a_privacy_notice_is_published_then_residents_acknowledge_it_and_set_channel_consents | — | passed | — | rust |
| cargo | rust-test | main::when_a_site_announcement_is_published_then_residents_can_read_it | — | passed | — | rust |
| cargo | rust-test | main::when_a_tenant_has_a_lease_then_owner_operational_debts_are_claimable_up_to_the_unpaid_rent | — | passed | — | rust |
| cargo | rust-test | main::when_a_site_requiring_a_budget_is_in_transition_then_the_tariff_accrues_and_is_reported_without_basis | — | passed | — | rust |
| cargo | rust-test | main::when_a_tenant_pays_owner_capital_dues_then_the_receipt_cites_kmk22_and_a_rent_certificate_is_issued | — | passed | — | rust |
| cargo | rust-test | main::when_a_tenant_requests_a_virman_and_staff_approve_then_the_owner_debt_is_settled_from_the_tenant_advance | — | passed | — | rust |
| cargo | rust-test | main::when_a_waiver_is_approved_by_a_second_person_then_what_is_owed_drops_and_the_ledger_still_balances | — | passed | — | rust |
| cargo | rust-test | main::when_a_transfer_bypasses_the_virtual_iban_then_phone_and_block_unit_hints_rank_the_units | — | passed | — | rust |
| cargo | rust-test | main::when_an_expense_is_approved_then_four_eyes_and_the_auditor_threshold_apply | — | passed | — | rust |
| cargo | rust-test | main::when_an_owner_was_enforced_three_times_in_two_years_then_the_kmk25_flag_is_raised | — | passed | — | rust |
| cargo | rust-test | main::when_analytics_are_computed_then_rates_channels_forecast_and_risky_units_are_reported | — | passed | — | rust |
| cargo | rust-test | main::when_another_site_acts_then_it_never_sees_or_changes_this_sites_records | — | passed | — | rust |
| cargo | rust-test | main::when_autopay_runs_then_due_items_are_charged_once_through_the_ingestion_path | — | passed | — | rust |
| cargo | rust-test | main::when_dunning_runs_then_the_due_step_is_sent_once_and_disputed_items_are_paused | — | passed | — | rust |
| cargo | rust-test | main::when_retention_is_reviewed_then_ledger_records_keep_ten_years_and_old_logs_are_purged | — | passed | — | rust |
| cargo | rust-test | main::when_the_assembly_accepts_a_budget_item_then_a_numbered_decision_approves_the_budget | — | passed | — | rust |
| cargo | rust-test | main::when_the_daily_collections_job_runs_then_every_step_completes_without_error | — | passed | — | rust |
| cargo | rust-test | main::when_the_daily_reconciliation_runs_then_differences_and_unmatched_lines_are_stored | — | passed | — | rust |
| cargo | rust-test | main::when_the_ledger_is_derived_then_the_trial_balance_balances_and_receivables_equal_open_dues | — | passed | — | rust |
| cargo | rust-test | main::a_commit_registers_the_rows_and_a_second_import_is_refused_row_by_row | — | passed | — | rust |
| cargo | rust-test | main::a_dry_run_checks_every_row_and_changes_nothing | — | passed | — | rust |
| cargo | rust-test | main::duplicates_are_found_by_phone_email_and_name | — | passed | — | rust |
| cargo | rust-test | main::a_national_id_change_needs_identity_rights_and_a_step_up | — | passed | — | rust |
| cargo | rust-test | main::one_bad_row_blocks_the_whole_commit | — | passed | — | rust |
| cargo | rust-test | main::the_import_route_answers_a_manager_with_a_report | — | passed | — | rust |
| cargo | rust-test | main::residents_cannot_import_people_or_edit_preferences | — | passed | — | rust |
| cargo | rust-test | main::a_contact_edit_does_not_need_identity_rights_but_a_login_change_does | — | passed | — | rust |
| cargo | rust-test | main::an_email_change_token_cannot_activate_an_account | — | passed | — | rust |
| cargo | rust-test | main::f3_land_share_parsing | — | passed | — | rust |
| cargo | rust-test | main::a_newer_activation_token_voids_the_older_one | — | passed | — | rust |
| cargo | rust-test | main::activation_token_sets_the_password_exactly_once | — | passed | — | rust |
| cargo | rust-test | main::email_change_to_an_address_in_use_is_refused | — | passed | — | rust |
| cargo | rust-test | main::f3_the_given_land_share_is_stored_and_a_missing_one_is_flagged | — | passed | — | rust |
| cargo | rust-test | main::f5_household_relationship_is_stored_as_a_code_and_unknown_text_is_refused | — | passed | — | rust |
| cargo | rust-test | main::f4_a_defaulted_dues_amount_is_reported_not_silent | — | passed | — | rust |
| cargo | rust-test | main::login_email_change_waits_for_confirmation_from_the_new_address | — | passed | — | rust |
| cargo | rust-test | main::registration_never_returns_or_stores_a_known_password | — | passed | — | rust |
| cargo | rust-test | main::routes::occupancy_changes_need_occupancy_rights | — | passed | — | rust |
| cargo | rust-test | main::resend_activation_issues_a_link_until_the_account_is_active | — | passed | — | rust |
| cargo | rust-test | main::routes::s6_a_resident_cannot_change_the_units_payment_profile_but_the_owner_can | — | passed | — | rust |
| cargo | rust-test | main::tenant_gets_an_own_account_without_the_owners_password | — | passed | — | rust |
| cargo | rust-test | main::updating_an_unknown_unit_fails_instead_of_inventing_a_response | — | passed | — | rust |
| cargo | rust-test | main::when_debtor_role_is_not_owner_or_tenant_then_the_body_is_unprocessable | — | passed | — | rust |
| cargo | rust-test | main::when_the_assignment_route_is_looked_up_then_it_requires_reconciliation_confirm | — | passed | — | rust |
| cargo | rust-test | main::when_the_match_has_no_site_then_assignment_is_forbidden | — | passed | — | rust |
| cargo | rust-test | main::when_assignment_targets_an_automatically_matched_item_then_it_is_conflict | — | passed | — | rust |
| cargo | rust-test | main::when_assignment_is_invalid_then_it_is_refused_and_leaves_no_state | — | passed | — | rust |
| cargo | rust-test | main::when_assignment_targets_an_approved_match_then_it_is_conflict | — | passed | — | rust |
| cargo | rust-test | main::when_unmatched_item_is_assigned_then_confirm_settles_it_exactly_once | — | passed | — | rust |
| cargo | rust-test | main::when_the_unit_has_no_open_debt_for_the_assigned_role_then_it_is_unprocessable | — | passed | — | rust |
| cargo | rust-test | main::a_rejected_override_request_leaves_the_seller_as_the_owner | — | skipped | — | rust |
| cargo | rust-test | main::only_an_approved_override_makes_the_seller_pay_later_installments | — | skipped | — | rust |
| cargo | rust-test | main::mid_month_sale_splits_the_month_by_days_through_a_four_eyes_correction | — | passed | — | rust |
| cargo | rust-test | main::split_shares_of_one_role_must_name_distinct_people | — | passed | — | rust |
| cargo | rust-test | main::sale_split_is_skipped_without_one_open_liability_or_on_the_first_day | — | passed | — | rust |
| cargo | rust-test | main::statement_itemizes_seller_debt_advance_and_installments_not_yet_accrued | — | passed | — | rust |
| cargo | rust-test | main::statement_leaves_out_paid_and_cancelled_liabilities_and_counts_the_advance | — | passed | — | rust |
| cargo | rust-test | main::statement_of_a_unit_of_another_site_is_not_found | — | passed | — | rust |
| cargo | rust-test | main::when_slugging_dotted_capital_i_then_no_stray_hyphen_is_produced | — | passed | — | rust |
| cargo | rust-test | main::when_matching_upper_case_bank_narrative_then_dotted_i_names_match | — | passed | — | rust |
| cargo | rust-test | main::when_tabular_rows_lack_amount_or_date_then_rows_are_reported_and_fallback_date_is_used | — | passed | — | rust |
| cargo | rust-test | main::when_mt940_contains_debits_and_reversals_then_only_credits_are_imported_and_rest_reported | — | passed | — | rust |
| cargo | rust-test | main::when_stored_email_has_surrounding_whitespace_then_login_still_finds_user | — | passed | — | rust |
| cargo | rust-test | main::when_proration_is_disabled_then_no_charge_is_posted | — | passed | — | rust |
| cargo | rust-test | main::when_a_supplementary_charge_refers_to_an_older_month_then_fifo_settles_it_first | — | passed | — | rust |
| cargo | rust-test | main::when_no_period_can_take_the_charge_then_the_handler_refuses_before_the_transition | — | passed | — | rust |
| cargo | rust-test | main::when_the_charge_is_created_late_then_its_late_fee_counts_from_the_creation_date | — | passed | — | rust |
| cargo | rust-test | main::when_the_current_period_is_also_closed_then_posting_is_refused | — | passed | — | rust |
| cargo | rust-test | main::when_a_month_was_already_billed_then_nothing_is_posted_and_a_repeat_is_idempotent | — | passed | — | rust |
| cargo | rust-test | main::when_the_month_is_closed_then_the_charge_refers_to_it_but_is_posted_in_the_current_period | — | passed | — | rust |
| cargo | rust-test | main::when_the_month_is_open_then_the_charge_is_posted_in_that_month | — | passed | — | rust |
| cargo | rust-test | doc-sitepulse_backend::src/db/tenant_guard.rs - db::tenant_guard::begin_tenant_read (line 86) | — | skipped | — | rust |
| sitepulse-check | schema-integrity | seed: repeated load preserves identity rows | — | passed | — | rust |
| sitepulse-check | schema-integrity | seed: email case changes reuse existing people and accounts | — | passed | — | rust |
| sitepulse-check | schema-integrity | seed: archived identities stay unchanged and unreferenced | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: person_type domain | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: dues expense_type domain | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: unit site must match block site | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: active occupancy cannot be ended | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: liability cannot be overpaid | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: duplicate capital installment | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: receipt allocation must equal total | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: receipt sequence unique per site | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: bank IBAN format | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: one active bank account per site | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: payment_entries rejects phantom unit | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: advance_balances rejects phantom unit | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: capital_projects rejects phantom site | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: capital dues cannot be debtor_type TENANT | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: occupancy_members rejects phantom occupancy | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: occupancy_members rejects phantom resident user | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: dues_liabilities rejects phantom unit (H11) | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: blocks rejects phantom site (H11) | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: unit with financial history cannot be deleted (H12) | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: sites.status vocabulary (M3) | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: payment channel vocabulary (M3) | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: paid_amount must equal paid_principal + paid_penalty (M4) | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: advance balance cannot be negative (M4) | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: e-mail uniqueness is case-insensitive (M8) | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: receipt counter cannot go negative (H3) | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: receipts are append-only: UPDATE (V16 P-06) | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: receipts are append-only: DELETE (V16 P-06) | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: advance ledger is append-only (V16 P-06) | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: a SETTLED entry needs a receipt (V16 P-03) | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: entry amount is immutable (V16 P-06) | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: UNMATCHED cannot become SETTLED without a receipt (V16 P-06) | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: entries are append-only: DELETE (V16 P-06) | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: one entry per receipt (V16 P-04) | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: penalty accrual date cannot precede the due date (V16 P-01) | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: a reversal receipt names its original (V17 O-2) | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: a receipt is reversed at most once (V17 O-2) | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: a contra entry needs a reason (V17 O-2) | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: SETTLED -> REVERSED needs a contra entry (V17 O-2) | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: a contra entry's reason is immutable (V17 O-2) | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: a receipt with advance names the advance debtor (V17 O-1) | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: site tax id is 10 or 11 digits (V17 O-5) | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: one claim per (bank account, transaction) (V17 O-3) | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: webhook payload hash is a SHA-256 hex digest (V17 O-3) | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: reconciliation status has one vocabulary (V17 O-7) | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: a bank account with statement history cannot be deleted (V17 O-7) | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: PAID requires the liability to be fully paid (V17 O-6) | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: a fully paid liability cannot stay open (V17 O-6) | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: payer_role has no silent default (V17 O-10) | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: audit events reject UPDATE | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: audit events reject DELETE | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: audit events reject TRUNCATE | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: support grants reject self approval | — | passed | — | rust |
| sitepulse-check | schema-integrity | rejects: support grants reject excessive duration | — | passed | — | rust |
| sitepulse-check | schema-integrity | enforces: deleted site slug can be reused (V29) | — | passed | — | rust |
| sitepulse-check | schema-integrity | enforces: audit projection removes credentials and preserves decimal amounts | — | passed | — | rust |
| sitepulse-check | schema-integrity | enforces: national id is never stored in clear text (M6) | — | passed | — | rust |
| sitepulse-check | schema-integrity | enforces: person search names use shared Turkish folding (V33) | — | passed | — | rust |
| sitepulse-check | schema-integrity | enforces: person search phones use last-ten digits (V33) | — | passed | — | rust |
| sitepulse-check | schema-integrity | enforces: person card excludes merged tombstones (V33) | — | passed | — | rust |
| sitepulse-check | schema-integrity | enforces: unit and person views expose scoped relationships and selected contact (V33) | — | passed | — | rust |
| sitepulse-check | schema-integrity | enforces: person integrity view reports site-less legacy rows (V33) | — | passed | — | rust |
| sitepulse-check | schema-integrity | enforces: person integrity view reports unresolved legacy contacts (V33) | — | passed | — | rust |
| sitepulse-check | schema-integrity | enforces: unit owner follows the ownership history (M1) | — | passed | — | rust |
| sitepulse-check | schema-integrity | enforces: an UNMATCHED entry settles in place with its receipt (V16 P-06) | — | passed | — | rust |
| sitepulse-check | schema-integrity | enforces: payer identity is resolved from the ownership history (V16 P-02) | — | passed | — | rust |
| sitepulse-check | schema-integrity | enforces: the purge switch lifts the ledger guard for one transaction only (V16 P-06) | — | passed | — | rust |
| sitepulse-check | schema-integrity | enforces: a reversal restores the paid amounts and keeps the drift views clean (V17 O-2) | — | passed | — | rust |
| sitepulse-check | schema-integrity | enforces: TAH and IAD series number independently per site (V17 O-2) | — | passed | — | rust |
| sitepulse-check | schema-integrity | enforces: the same transaction id is accepted for another bank account or site (V17 O-3) | — | passed | — | rust |
| sitepulse-check | schema-integrity | enforces: the effective status of an unpaid past-due liability is OVERDUE (V17 O-6) | — | passed | — | rust |
| sitepulse-check | schema-integrity | enforces: no integrity violations on seeded data (M4) | — | passed | — | rust |
| sitepulse-check | schema-integrity | upgrade: V7-era rows load | — | passed | — | rust |
| sitepulse-check | schema-integrity | upgrade: V8..V51 apply on existing rows | — | passed | — | rust |
| sitepulse-check | schema-integrity | upgrade: legacy rows survive the upgrade | — | passed | — | rust |
| sitepulse-check | schema-integrity | upgrade: paid_penalty backfilled consistently | — | passed | — | rust |
| sitepulse-check | schema-integrity | upgrade: legacy person_type translated (V8) | — | passed | — | rust |
| sitepulse-check | schema-integrity | upgrade: legacy person search keys backfilled (V33) | — | passed | — | rust |
| sitepulse-check | schema-integrity | upgrade: legacy person and unit views are available (V33) | — | passed | — | rust |
| sitepulse-check | schema-integrity | upgrade: legacy primary contact is backfilled to a same-site person (V33) | — | passed | — | rust |
| sitepulse-check | schema-integrity | upgrade: person_type is nullable for role-free cards (V35) | — | passed | — | rust |
| sitepulse-check | schema-integrity | upgrade: legacy national id no longer in clear text (V15) | — | passed | — | rust |
| sitepulse-check | schema-integrity | upgrade: e-mails lower-cased (V14) | — | passed | — | rust |
| sitepulse-check | schema-integrity | upgrade: created_at is never NULL | — | passed | — | rust |
| sitepulse-check | schema-integrity | upgrade: every constraint is validated | — | passed | — | rust |
| sitepulse-check | schema-integrity | upgrade: open overdue penalties carry their accrual date (V16 P-01) | — | passed | — | rust |
| sitepulse-check | schema-integrity | upgrade: legacy IDEMPOTENCY:<key> references carried into payment_idempotency_keys (V17 O-4) | — | passed | — | rust |
| sitepulse-check | schema-integrity | upgrade: legacy reconciliation statuses translated, status_code dropped (V17 O-7) | — | passed | — | rust |
| sitepulse-check | schema-integrity | upgrade: legacy partially paid liability carries a consistent status (V17 O-6) | — | passed | — | rust |
| sitepulse-check | schema-integrity | upgrade: legacy receipts default to the collection series (V17 O-2) | — | passed | — | rust |
| sitepulse-check | schema-integrity | upgrade: ledger triggers installed (V16 P-06) | — | passed | — | rust |
| sitepulse-check | schema-integrity | upgrade: upgraded schema equals a fresh install | — | passed | — | rust |
| flutter | flutter-test | flutter/test/sp_directory_scaffold_test.dart::when a directory page advances then it shows the next page range | — | passed | 3.842 | flutter |
| flutter | flutter-test | flutter/test/widget_test.dart::SitePulseApp renders LoginScreen when unauthenticated and displays test personas | — | passed | 3.911 | flutter |
| flutter | flutter-test | flutter/test/sp_directory_scaffold_test.dart::when page density changes then the directory page count updates | — | passed | 4.056 | flutter |
| flutter | flutter-test | flutter/test/sp_directory_scaffold_test.dart::when the app restores then the selected directory page and density persist | — | passed | 4.353 | flutter |
| flutter | flutter-test | flutter/test/sp_directory_scaffold_test.dart::when the viewport is narrow then the pager wraps without overflow | — | passed | 4.432 | flutter |
| flutter | flutter-test | flutter/test/sp_directory_scaffold_test.dart::when a directory contains one or ten thousand units then only visible rows are built | — | passed | 4.572 | flutter |
| flutter | flutter-test | flutter/test/widget_test.dart::Selecting Site Admin shows dual path options and logging in as Kat Maliki enters own flat view | — | passed | 5.114 | flutter |
| flutter | flutter-test | flutter/test/bank_statement_reconciliation_test.dart::Bank Statement Parser & Automated Reconciliation Tests (STORY-07-02) when parsing turkish bank excel line then identifies unit A Blok D:14 with 100 percent confidence and exact amount | — | passed | 5.179 | flutter |
| flutter | flutter-test | flutter/test/bank_statement_reconciliation_test.dart::Bank Statement Parser & Automated Reconciliation Tests (STORY-07-02) when parsing swift mt940 statement with MT940 bank configured then extracts transaction and matches flat | — | passed | 5.189 | flutter |
| flutter | flutter-test | flutter/test/bank_statement_reconciliation_test.dart::Bank Statement Parser & Automated Reconciliation Tests (STORY-07-02) when file format does not match active bank format then parseBankStatementFile strictly rejects it | — | passed | 5.2 | flutter |
| flutter | flutter-test | flutter/test/bank_statement_reconciliation_test.dart::Bank Statement Parser & Automated Reconciliation Tests (STORY-07-02) when confirming reconciliation then marks flat as paid and updates collection summary | — | passed | 5.218 | flutter |
| flutter | flutter-test | flutter/test/bank_statement_reconciliation_test.dart::Bank Statement Parser & Automated Reconciliation Tests (STORY-07-02) when refreshing the live queue then retains imported unmatched transactions | — | passed | 5.233 | flutter |
| flutter | flutter-test | flutter/test/widget_test.dart::Logging in as Site Admin with Cockpit path displays complex collection cockpit | — | passed | 5.571 | flutter |
| flutter | flutter-test | flutter/test/widget_test.dart::SitePulseApp renders Home Owner dashboard cleanly without Virtual IBAN cluttering home screen | — | passed | 5.763 | flutter |
| flutter | flutter-test | flutter/test/widget_test.dart::Tapping Hemen Öde opens PaymentCheckoutDialog with method selection between Card and Virtual IBAN | — | passed | 6.243 | flutter |
| flutter | flutter-test | flutter/test/widget_test.dart::Tapping Duyurular and Talep / Arıza action buttons opens respective dialogs | — | passed | 6.641 | flutter |
| flutter | flutter-test | flutter/test/bank_statement_reconciliation_test.dart::Bank Statement Parser & Automated Reconciliation Tests (STORY-07-02) BankStatementReconciliationPage renders presets, parses statement, and allows batch confirmation | — | passed | 6.702 | flutter |
| flutter | flutter-test | flutter/test/bank_statement_reconciliation_test.dart::Bank Statement Parser & Automated Reconciliation Tests (STORY-07-02) when transaction is unmatched, allows manually assigning flat and confirms payment | — | passed | 6.717 | flutter |
| flutter | flutter-test | flutter/test/bank_statement_reconciliation_test.dart::Bank Statement Parser & Automated Reconciliation Tests (STORY-07-02) BankStatementReconciliationPage displays intermediate breakdown report and filter tabs | — | passed | 6.911 | flutter |
| flutter | flutter-test | flutter/test/bank_statement_reconciliation_test.dart::Bank Statement Parser & Automated Reconciliation Tests (STORY-07-02) when transaction belongs to already paid flat then marks status as ZATEN_YUKLENDI and prevents double collection | — | passed | 6.92 | flutter |
| flutter | flutter-test | flutter/test/bank_statement_reconciliation_test.dart::Bank Statement Parser & Automated Reconciliation Tests (STORY-07-02) when flat is confirmed in one statement, subsequent statement with same unit is flagged as ZATEN_YUKLENDI | — | passed | 6.927 | flutter |
| flutter | flutter-test | flutter/test/bank_statement_reconciliation_test.dart::Bank Statement Parser & Automated Reconciliation Tests (STORY-07-02) when confirming reconciliation with optional message then records host notification message | — | passed | 6.932 | flutter |
| flutter | flutter-test | flutter/test/widget_test.dart::Manager can publish an announcement from the full-screen composer | — | passed | 6.987 | flutter |
| flutter | flutter-test | flutter/test/bank_statement_reconciliation_test.dart::Bank Statement Parser & Automated Reconciliation Tests (STORY-07-02) when matching host in ManualUnitAssignmentPage, requires confirmation and optional message request | — | passed | 7.201 | flutter |
| flutter | flutter-test | flutter/test/bank_statement_reconciliation_test.dart::Bank Statement Parser & Automated Reconciliation Tests (STORY-07-02) fetchBankAccount loads site bank account from API and sets siteBankAccount | — | passed | 7.214 | flutter |
| flutter | flutter-test | flutter/test/widget_test.dart::Tapping Dekontlar action button opens receipts dialog aligned with account transactions and allows opening receipt detail | — | passed | 7.279 | flutter |
| flutter | flutter-test | flutter/test/widget_test.dart::Tapping Hesap Özeti button when debt is zero and advance is present opens dynamic account balance summary dialog | — | passed | 7.491 | flutter |
| flutter | flutter-test | flutter/test/widget_test.dart::SitePulseApp switches to Site Manager view and displays collection cockpit | — | passed | 7.669 | flutter |
| flutter | flutter-test | flutter/test/widget_test.dart::SitePulseApp switches to SaaS SuperAdmin view and displays platform tenants | — | passed | 7.894 | flutter |
| flutter | flutter-test | flutter/test/widget_test.dart::SitePulseApp toggles theme mode between Dark and Light correctly | — | passed | 8.413 | flutter |
| flutter | flutter-test | flutter/test/widget_test.dart::SitePulseApp opens Yeni Site dialog, submits and closes popup cleanly | — | passed | 8.82 | flutter |
| flutter | flutter-test | flutter/test/widget_test.dart::SitePulseApp allows deleting an action-free site with confirmation dialog | — | passed | 9.056 | flutter |
| flutter | flutter-test | flutter/test/widget_test.dart::SitePulseApp allows renewing temporary management password with confirmation dialog | — | passed | 9.339 | flutter |
| flutter | flutter-test | flutter/test/person_card_navigation_test.dart::Person card cross-navigation unit to person to unit keeps list state and returns focus to the unit row | — | passed | 9.486 | flutter |
| flutter | flutter-test | flutter/test/widget_test.dart::SitePulseApp allows editing site information from SaaS Admin view | — | passed | 9.999 | flutter |
| flutter | flutter-test | flutter/test/widget_test.dart::Selecting Kat Maliki Girişi tab renders dedicated Homeowner Login Screen and allows login | — | passed | 10.306 | flutter |
| flutter | flutter-test | flutter/test/person_card_navigation_test.dart::Person card cross-navigation a card edit updates the owner role shown on the unit | — | passed | 10.351 | flutter |
| flutter | flutter-test | flutter/test/widget_test.dart::Selecting Site Yöneticisi Girişi tab renders dedicated Site Manager Login Screen with dual path selector | — | passed | 10.639 | flutter |
| flutter | flutter-test | flutter/test/person_card_navigation_test.dart::Person card cross-navigation a person without a login can be given one from the card | — | passed | 10.894 | flutter |
| flutter | flutter-test | flutter/test/widget_test.dart::When homeowner is newly registered, LoginScreen displays quick login card and logs into their unit | — | passed | 11.083 | flutter |
| flutter | flutter-test | flutter/test/widget_test.dart::When site is newly registered, LoginScreen displays quick login card and logs into their site | — | passed | 11.371 | flutter |
| flutter | flutter-test | flutter/test/person_card_navigation_test.dart::Person card cross-navigation person-first role action selects the unit and opens its workspace | — | passed | 11.426 | flutter |
| flutter | flutter-test | flutter/test/widget_test.dart::When homeowner logs in, they can manually add and delete household co-residents via UI | — | passed | 11.817 | flutter |
| flutter | flutter-test | flutter/test/financial_fixture_test.dart::Shared financial fixture: penalty cases 10 days overdue on 1400.00 | — | passed | 11.828 | flutter |
| flutter | flutter-test | flutter/test/financial_fixture_test.dart::Shared financial fixture: penalty cases not yet due | — | passed | 11.83 | flutter |
| flutter | flutter-test | flutter/test/financial_fixture_test.dart::Shared financial fixture: penalty cases due today | — | passed | 11.832 | flutter |
| flutter | flutter-test | flutter/test/financial_fixture_test.dart::Shared financial fixture: penalty cases one full month | — | passed | 11.835 | flutter |
| flutter | flutter-test | flutter/test/financial_fixture_test.dart::Shared financial fixture: penalty cases half-cent tie rounds up (1.005) | — | passed | 11.838 | flutter |
| flutter | flutter-test | flutter/test/financial_fixture_test.dart::Shared financial fixture: penalty cases half-cent tie rounds up (2.675) | — | passed | 11.84 | flutter |
| flutter | flutter-test | flutter/test/financial_fixture_test.dart::Shared financial fixture: penalty cases one day on one kurus | — | passed | 11.843 | flutter |
| flutter | flutter-test | flutter/test/widget_test.dart::When tenant (homeResident) logs in, they also have manual add resident and invite permissions | — | passed | 12.094 | flutter |
| flutter | flutter-test | flutter/test/resident_directory_test.dart::when unit rows are sorted then numeric unit order and Turkish search are preserved | — | passed | 12.268 | flutter |
| flutter | flutter-test | flutter/test/resident_directory_test.dart::when a unit filter is active then only matching occupancy remains | — | passed | 12.27 | flutter |
| flutter | flutter-test | flutter/test/widget_test.dart::When user taps Temizle on Site Manager login screen, clears login cache and form inputs | — | passed | 12.288 | flutter |
| flutter | flutter-test | flutter/test/widget_test.dart::When login has empty inputs or fails, displays visible error banner and feedback | — | passed | 12.548 | flutter |
| flutter | flutter-test | flutter/test/session_security_test.dart::roles are exact and unknown roles never gain owner authority | — | passed | 12.717 | flutter |
| flutter | flutter-test | flutter/test/session_security_test.dart::concurrent expired requests share one refresh | — | passed | 12.769 | flutter |
| flutter | flutter-test | flutter/test/session_security_test.dart::protected authentication actions renew expired access | — | passed | 12.776 | flutter |
| flutter | flutter-test | flutter/test/session_security_test.dart::invalid login credentials do not renew an existing session | — | passed | 12.78 | flutter |
| flutter | flutter-test | flutter/test/session_security_test.dart::403 never refreshes or signs out | — | passed | 12.783 | flutter |
| flutter | flutter-test | flutter/test/session_security_test.dart::a late renewal cannot resurrect a logged out session | — | passed | 12.787 | flutter |
| flutter | flutter-test | flutter/test/session_security_test.dart::a delayed request cannot retry under another signed-in identity | — | passed | 12.791 | flutter |
| flutter | flutter-test | flutter/test/session_security_test.dart::unknown server roles never install credentials or enter demo fallback | — | passed | 12.806 | flutter |
| flutter | flutter-test | flutter/test/payments_phase3_test.dart::SPEC-009 models the auditor role is recognised; unknown roles still fail | — | passed | 13.015 | flutter |
| flutter | flutter-test | flutter/test/payments_phase3_test.dart::SPEC-009 models expense, case and plan views read the flattened backend JSON with Decimal money | — | passed | 13.024 | flutter |
| flutter | flutter-test | flutter/test/payments_phase3_test.dart::SPEC-009 models the privacy status lists consents per channel | — | passed | 13.027 | flutter |
| flutter | flutter-test | flutter/test/payments_phase3_test.dart::SPEC-009 models exit settlement response keeps beneficiary and decimal amount | — | passed | 13.029 | flutter |
| flutter | flutter-test | flutter/test/payments_phase3_test.dart::SPEC-009 models the designated amount is the sum of the selected items only | — | passed | 13.033 | flutter |
| flutter | flutter-test | flutter/test/payments_phase3_test.dart::advance exit settlement request sends the named beneficiary and debtor disposition | — | passed | 13.053 | flutter |
| flutter | flutter-test | flutter/test/session_security_test.dart::residents see verification but no tenant audit access | — | passed | 13.332 | flutter |
| flutter | flutter-test | flutter/test/payments_phase3_test.dart::the text prompt returns the trimmed text and needs the minimum length | — | passed | 13.865 | flutter |
| flutter | flutter-test | flutter/test/payments_phase3_test.dart::the finance hub lists expenses and hides changes in the auditor view | — | passed | 14.062 | flutter |
| flutter | flutter-test | flutter/test/payments_phase3_test.dart::selecting open items enables a designated card payment | — | passed | 14.181 | flutter |
| flutter | flutter-test | flutter/test/person_components_test.dart::PersonRef encodes existing and draft references in the API contract shape | — | passed | 14.626 | flutter |
| flutter | flutter-test | flutter/test/block_units_create_test.dart::Block and units creation from the manager screens (#285) the residents screen offers btn_add_block and opens the form | — | passed | 14.897 | flutter |
| flutter | flutter-test | flutter/test/block_units_create_test.dart::Block and units creation from the manager screens (#285) submitting without a block name or unit count shows field errors | — | passed | 15.272 | flutter |
| flutter | flutter-test | flutter/test/block_units_create_test.dart::Block and units creation from the manager screens (#285) a tariff without a house type is refused before any call | — | passed | 15.674 | flutter |
| flutter | flutter-test | flutter/test/block_units_create_test.dart::Block and units creation from the manager screens (#285) an existing house type with a different tariff is refused without repricing | — | passed | 16.016 | flutter |
| flutter | flutter-test | flutter/test/person_components_test.dart::picker pages through people beyond the first one hundred | — | passed | 16.405 | flutter |
| flutter | flutter-test | flutter/test/block_units_create_test.dart::Block and units creation from the manager screens (#285) an existing house type at the same tariff is reused, not rewritten | — | passed | 16.466 | flutter |
| flutter | flutter-test | flutter/test/person_components_test.dart::picker shows an ineligible result with its reason and keeps it unselectable | — | passed | 16.525 | flutter |
| flutter | flutter-test | flutter/test/person_components_test.dart::form explains duplicate reasons and asks before confirming a distinct person | — | passed | 16.657 | flutter |
| flutter | flutter-test | flutter/test/block_units_create_test.dart::Block and units creation from the manager screens (#285) a successful create adds the block, seven units and the tariff | — | passed | 16.834 | flutter |
| flutter | flutter-test | flutter/test/person_components_test.dart::form blocks a duplicate email and offers the existing person | — | passed | 16.835 | flutter |
| flutter | flutter-test | flutter/test/block_units_create_test.dart::Block and units creation from the manager screens (#285) the command posts block, tariff and units, then reloads the directory | — | passed | 16.858 | flutter |
| flutter | flutter-test | flutter/test/block_units_create_test.dart::Block and units creation from the manager screens (#285) the command sends no tariff when none was entered | — | passed | 16.864 | flutter |
| flutter | flutter-test | flutter/test/block_units_create_test.dart::Block and units creation from the manager screens (#285) an existing tariff at the same amount is reused without a tariff write | — | passed | 16.876 | flutter |
| flutter | flutter-test | flutter/test/block_units_create_test.dart::Block and units creation from the manager screens (#285) an existing tariff at a different amount is refused before any write | — | passed | 16.884 | flutter |
| flutter | flutter-test | flutter/test/block_units_create_test.dart::Block and units creation from the manager screens (#285) refuses when no managed site is loaded instead of posting to site 1 | — | passed | 16.893 | flutter |
| flutter | flutter-test | flutter/test/block_units_create_test.dart::Block and units creation from the manager screens (#285) a refused create keeps the form open and shows the server reason | — | passed | 17.239 | flutter |
| flutter | flutter-test | flutter/test/responsible_contact_selection_test.dart::failed contact save never reports success or changes the card | — | passed | 18.516 | flutter |
| flutter | flutter-test | flutter/test/responsible_contact_selection_test.dart::choosing the current contact explains the unchanged selection | — | passed | 18.652 | flutter |
| flutter | flutter-test | flutter/test/responsible_contact_selection_test.dart::successful save uses the returned contact without changing identity | — | passed | 18.66 | flutter |
| flutter | flutter-test | flutter/test/responsible_contact_selection_test.dart::choosing a contact sends the person card id | — | passed | 18.791 | flutter |
| flutter | flutter-test | flutter/test/page_layout_test.dart::manager destinations share top context and boxed identity at 320.0 | — | passed | 18.902 | flutter |
| flutter | flutter-test | flutter/test/page_layout_test.dart::manager destinations share top context and boxed identity at 390.0 | — | passed | 19.548 | flutter |
| flutter | flutter-test | flutter/test/payment_tracking_and_aging_test.dart::Payment Tracking & Debt Aging Module Tests when fetching payment stream in test mode then returns mock stream entries and KPIs | — | passed | 19.88 | flutter |
| flutter | flutter-test | flutter/test/payment_tracking_and_aging_test.dart::Payment Tracking & Debt Aging Module Tests payment stream query includes selected filters and search term | — | passed | 19.896 | flutter |
| flutter | flutter-test | flutter/test/payment_tracking_and_aging_test.dart::Payment Tracking & Debt Aging Module Tests when fetching debt aging report then returns brackets with 0-30, 31-60, and 60+ days | — | passed | 19.903 | flutter |
| flutter | flutter-test | flutter/test/payment_tracking_and_aging_test.dart::Payment Tracking & Debt Aging Module Tests when recording manual cash payment then returns receipt and updates stream | — | passed | 19.912 | flutter |
| flutter | flutter-test | flutter/test/payment_tracking_and_aging_test.dart::Payment Tracking & Debt Aging Module Tests when executing inter-ledger transfer then returns success and receipt number | — | passed | 19.923 | flutter |
| flutter | flutter-test | flutter/test/payment_tracking_and_aging_test.dart::Payment Tracking & Debt Aging Module Tests when transferring property ownership then records new owner and freezes old liabilities | — | passed | 19.929 | flutter |
| flutter | flutter-test | flutter/test/page_layout_test.dart::manager destinations share top context and boxed identity at 1400.0 | — | passed | 20.197 | flutter |
| flutter | flutter-test | flutter/test/payments_phase2_models_test.dart::A resident statement parses buckets, open items and receipts as Decimal | — | passed | 20.588 | flutter |
| flutter | flutter-test | flutter/test/payments_phase2_models_test.dart::A payment intent reports when it is finished | — | passed | 20.591 | flutter |
| flutter | flutter-test | flutter/test/payments_phase2_models_test.dart::A budget line serializes the amount with two decimals | — | passed | 20.597 | flutter |
| flutter | flutter-test | flutter/test/payment_tracking_and_aging_test.dart::Payment Tracking & Debt Aging Module Tests PaymentTrackingPage renders stream items, aging tabs, and search bar | — | passed | 20.911 | flutter |
| flutter | flutter-test | flutter/test/payment_tracking_and_aging_test.dart::Payment Tracking & Debt Aging Module Tests PaymentTrackingPage renders unmatched bank transactions banner and opens reconciliation | — | passed | 21.257 | flutter |
| flutter | flutter-test | flutter/test/payment_tracking_and_aging_test.dart::Payment Tracking & Debt Aging Module Tests manual cash collection validates the amount and issues a receipt | — | passed | 21.986 | flutter |
| flutter | flutter-test | flutter/test/unit_workspace_test.dart::Unit workspace actions follow the allowed commands of a tenant-occupied unit in one tap | — | passed | 22.389 | flutter |
| flutter | flutter-test | flutter/test/payment_tracking_and_aging_test.dart::Payment Tracking & Debt Aging Module Tests payment stream filters and search can be changed and cleared | — | passed | 22.732 | flutter |
| flutter | flutter-test | flutter/test/payment_tracking_and_aging_test.dart::Payment Tracking & Debt Aging Module Tests DuesManagementView contains Tahsilat & Kasa Takibi action button | — | passed | 23.007 | flutter |
| flutter | flutter-test | flutter/test/payment_tracking_and_aging_test.dart::Payment Tracking & Debt Aging Module Tests ManagerCockpitView provides navigation to unified dues and cash management | — | passed | 23.122 | flutter |
| flutter | flutter-test | flutter/test/unit_workspace_test.dart::Unit workspace details opens information mode directly, shows ledgers and returns to the list | — | passed | 23.127 | flutter |
| flutter | flutter-test | flutter/test/unit_workspace_test.dart::Unit workspace restores filter, search query, and focus on return at desktop and phone widths | — | passed | 23.634 | flutter |
| flutter | flutter-test | flutter/test/house_type_tariff_and_validation_test.dart::House Type & Tariff Configuration Tests HouseTypeTariff serialization and deserialization roundtrip | — | passed | 23.752 | flutter |
| flutter | flutter-test | flutter/test/house_type_tariff_and_validation_test.dart::House Type & Tariff Configuration Tests DashboardController initializes with default site tariffs | — | passed | 23.767 | flutter |
| flutter | flutter-test | flutter/test/house_type_tariff_and_validation_test.dart::House Type & Tariff Configuration Tests DashboardController can add, update, and delete house types in test mode | — | passed | 23.771 | flutter |
| flutter | flutter-test | flutter/test/unit_workspace_test.dart::Unit workspace phone width (<720px) opens unit workspace and returns cleanly | — | passed | 24.1 | flutter |
| flutter | flutter-test | flutter/test/calculate_dues_usecase_test.dart::CalculateDuesUseCase KMK Delay Penalty Tests when dues are overdue by 10 days, calculates exact 5 percent pro-rated KMK penalty | — | passed | 24.459 | flutter |
| flutter | flutter-test | flutter/test/calculate_dues_usecase_test.dart::CalculateDuesUseCase KMK Delay Penalty Tests when dues are not overdue, penalty remains zero | — | passed | 24.462 | flutter |
| flutter | flutter-test | flutter/test/person_directory_repository_test.dart::search sends integer page and limit with context and unit | — | passed | 24.864 | flutter |
| flutter | flutter-test | flutter/test/person_directory_repository_test.dart::search omits empty text and optional scope | — | passed | 24.869 | flutter |
| flutter | flutter-test | flutter/test/house_type_tariff_and_validation_test.dart::Add Resident Dialog Validation & House Type Selection UI Tests Manuel Sakin Ekle opens the module registration with a person picker | — | passed | 25.045 | flutter |
| flutter | flutter-test | flutter/test/house_type_tariff_and_validation_test.dart::Add Resident Dialog Validation & House Type Selection UI Tests Opening Konut Tipleri & Tarifeler dialog displays tariffs and allows management | — | passed | 25.309 | flutter |
| flutter | flutter-test | flutter/test/ux_shell_and_navigation_test.dart::URL per role and tab (finding 5) every role has its own paths | — | passed | 25.445 | flutter |
| flutter | flutter-test | flutter/test/ux_shell_and_navigation_test.dart::URL per role and tab (finding 5) a URL selects the tab and the manager path; another role's URL is refused | — | passed | 25.452 | flutter |
| flutter | flutter-test | flutter/test/ux_shell_and_navigation_test.dart::URL per role and tab (finding 5) router keeps the tab in its URL and applies a deep link after login | — | passed | 25.463 | flutter |
| flutter | flutter-test | flutter/test/ux_shell_and_navigation_test.dart::URL per role and tab (finding 5) switching the manager path starts again on Home (no silent tab change) | — | passed | 25.472 | flutter |
| flutter | flutter-test | flutter/test/house_type_tariff_and_validation_test.dart::Add Resident Dialog Validation & House Type Selection UI Tests house type management validates, creates, and deletes a tariff through the UI | — | passed | 25.985 | flutter |
| flutter | flutter-test | flutter/test/house_type_tariff_and_validation_test.dart::Add Resident Dialog Validation & House Type Selection UI Tests Manuel Sakin Ekle registration presents blocks in a dropdown | — | passed | 26.495 | flutter |
| flutter | flutter-test | flutter/test/ux_shell_and_navigation_test.dart::URL per role and tab (finding 5) the app shell is router-based and shows login when signed out | — | passed | 26.834 | flutter |
| flutter | flutter-test | flutter/test/house_type_tariff_and_validation_test.dart::Add Resident Dialog Validation & House Type Selection UI Tests SaaS Add Site Dialog allows defining blocks list for new site | — | passed | 26.98 | flutter |
| flutter | flutter-test | flutter/test/ux_shell_and_navigation_test.dart::App bar and navigation (findings 7, 8, 9) Profile is not a tab; the app bar keeps only the avatar | — | passed | 27.13 | flutter |
| flutter | flutter-test | flutter/test/household_relationship_test.dart::codes and labels round-trip, older labels are read, unknown text is OTHER | — | passed | 27.493 | flutter |
| flutter | flutter-test | flutter/test/household_relationship_test.dart::labels: a code shows its Turkish label; other text is shown as it is | — | passed | 27.496 | flutter |
| flutter | flutter-test | flutter/test/ux_shell_and_navigation_test.dart::App bar and navigation (findings 7, 8, 9) logout asks first; cancelling keeps the session | — | passed | 27.711 | flutter |
| flutter | flutter-test | flutter/test/household_relationship_test.dart::the picker offers exactly the five codes and accepts a stored code | — | passed | 27.968 | flutter |
| flutter | flutter-test | flutter/test/ux_shell_and_navigation_test.dart::App bar and navigation (findings 7, 8, 9) logout through the profile sheet with confirmation signs out | — | passed | 28.247 | flutter |
| flutter | flutter-test | flutter/test/capital_projects_view_test.dart::EPIC-10: Capital Expenditure & Fixtures (Demirbaş Yönetimi) UI Tests when fetching mock capital projects then loads active project, installments, and shares | — | passed | 28.506 | flutter |
| flutter | flutter-test | flutter/test/ux_shell_and_navigation_test.dart::App bar and navigation (findings 7, 8, 9) theme and the dev-only offline simulator live in the profile sheet | — | passed | 28.707 | flutter |
| flutter | flutter-test | flutter/test/ux_shell_and_navigation_test.dart::App bar and navigation (findings 7, 8, 9) going offline shows an inline banner and keeps the balance | — | passed | 29.012 | flutter |
| flutter | flutter-test | flutter/test/ux_shell_and_navigation_test.dart::App bar and navigation (findings 7, 8, 9) switching manager path without a router resets to Home | — | passed | 29.345 | flutter |
| flutter | flutter-test | flutter/test/ux_shell_and_navigation_test.dart::Responsive layout (finding 11) wide screens get a navigation rail and capped content | — | passed | 29.495 | flutter |
| flutter | flutter-test | flutter/test/ux_shell_and_navigation_test.dart::Responsive layout (finding 11) phone width (375 dp) renders homeOwner home without overflow | — | passed | 29.642 | flutter |
| flutter | flutter-test | flutter/test/ux_shell_and_navigation_test.dart::Responsive layout (finding 11) phone width (375 dp) renders siteManager home without overflow | — | passed | 29.771 | flutter |
| flutter | flutter-test | flutter/test/ux_shell_and_navigation_test.dart::Responsive layout (finding 11) phone width (375 dp) renders saasAdmin home without overflow | — | passed | 29.84 | flutter |
| flutter | flutter-test | flutter/test/capital_projects_view_test.dart::EPIC-10: Capital Expenditure & Fixtures (Demirbaş Yönetimi) UI Tests DashboardScreen renders Demirbaş tab and displays Reserve Fund KPIs | — | passed | 29.908 | flutter |
| flutter | flutter-test | flutter/test/ux_shell_and_navigation_test.dart::Responsive layout (finding 11) long site names ellipsize in the manager path switch | — | passed | 29.966 | flutter |
| flutter | flutter-test | flutter/test/ux_shell_and_navigation_test.dart::Accessibility (findings 1, 2, 10) manager path switch announces selected state | — | passed | 30.093 | flutter |
| flutter | flutter-test | flutter/test/capital_projects_view_test.dart::EPIC-10: Capital Expenditure & Fixtures (Demirbaş Yönetimi) UI Tests CapitalProjectsView switches subtabs to show Kat Malikleri and Hakedişler | — | passed | 30.104 | flutter |
| flutter | flutter-test | flutter/test/ux_shell_and_navigation_test.dart::Accessibility (findings 1, 2, 10) login role tabs announce selected state | — | passed | 30.241 | flutter |
| flutter | flutter-test | flutter/test/capital_projects_view_test.dart::EPIC-10: Capital Expenditure & Fixtures (Demirbaş Yönetimi) UI Tests CapitalProjectWizardPage validates input and creates new capital project | — | passed | 30.555 | flutter |
| flutter | flutter-test | flutter/test/ux_shell_and_navigation_test.dart::Accessibility (findings 1, 2, 10) login fields support password managers and Enter to submit | — | passed | 30.575 | flutter |
| flutter | flutter-test | flutter/test/ux_shell_and_navigation_test.dart::Accessibility (findings 1, 2, 10) resident home meets text contrast and labelled tap target guidelines | — | passed | 30.762 | flutter |
| flutter | flutter-test | flutter/test/capital_projects_view_test.dart::EPIC-10: Capital Expenditure & Fixtures (Demirbaş Yönetimi) UI Tests CapitalProjectWizardPage rejects missing title and non-positive budget | — | passed | 30.795 | flutter |
| flutter | flutter-test | flutter/test/ux_shell_and_navigation_test.dart::Accessibility (findings 1, 2, 10) login screen meets text contrast guideline in light and dark | — | passed | 31.039 | flutter |
| flutter | flutter-test | flutter/test/ux_shell_and_navigation_test.dart::Accessibility (findings 1, 2, 10) fixtures still describe the resident used above | — | passed | 31.042 | flutter |
| flutter | flutter-test | flutter/test/dashboard_controller_test.dart::DashboardController Unit & Integration Tests when initialized, then default role is homeOwner with Begonya Sitesi unit scope | — | passed | 31.329 | flutter |
| flutter | flutter-test | flutter/test/dashboard_controller_test.dart::DashboardController Unit & Integration Tests when login as site manager, then sets siteManager role and complex scope permissions | — | passed | 31.336 | flutter |
| flutter | flutter-test | flutter/test/dashboard_controller_test.dart::DashboardController Unit & Integration Tests when login as saas admin, then sets saasAdmin role and tenant management permissions | — | passed | 31.344 | flutter |
| flutter | flutter-test | flutter/test/dashboard_controller_test.dart::DashboardController Unit & Integration Tests when login with Google, then authenticates as homeOwner with Google provider | — | passed | 31.351 | flutter |
| flutter | flutter-test | flutter/test/dashboard_controller_test.dart::DashboardController Unit & Integration Tests when register new site, then provisions credentials and adds site to tenant list | — | passed | 31.362 | flutter |
| flutter | flutter-test | flutter/test/dashboard_controller_test.dart::DashboardController Unit & Integration Tests when updating site information, then persists updated values and notifies listeners | — | passed | 31.37 | flutter |
| flutter | flutter-test | flutter/test/dashboard_controller_test.dart::DashboardController Unit & Integration Tests when register home owner by manager, then adds flat and reports an activation link, never a password | — | passed | 31.378 | flutter |
| flutter | flutter-test | flutter/test/dashboard_controller_test.dart::DashboardController Unit & Integration Tests when approve registration request, then removes from pending queue and generates credentials | — | passed | 31.383 | flutter |
| flutter | flutter-test | flutter/test/dashboard_controller_test.dart::DashboardController Unit & Integration Tests when generate unit invite link in preview, then produces unit-scoped URL | — | passed | 31.389 | flutter |
| flutter | flutter-test | flutter/test/dashboard_controller_test.dart::DashboardController Unit & Integration Tests when switch session role, then role and session update immediately | — | passed | 31.395 | flutter |
| flutter | flutter-test | flutter/test/dashboard_controller_test.dart::DashboardController Unit & Integration Tests when toggle theme, updates isDarkMode flag | — | passed | 31.399 | flutter |
| flutter | flutter-test | flutter/test/dashboard_controller_test.dart::DashboardController Unit & Integration Tests when filter flats, applies OVERDUE and PAID filters | — | passed | 31.404 | flutter |
| flutter | flutter-test | flutter/test/dashboard_controller_test.dart::DashboardController Unit & Integration Tests when delete action-free site, then removes site successfully | — | passed | 31.409 | flutter |
| flutter | flutter-test | flutter/test/dashboard_controller_test.dart::DashboardController Unit & Integration Tests when delete site with active units or dues, then rejects deletion and preserves site | — | passed | 31.414 | flutter |
| flutter | flutter-test | flutter/test/dashboard_controller_test.dart::DashboardController Unit & Integration Tests when reset site manager password, generates new temporary password and sets credentials | — | passed | 31.42 | flutter |
| flutter | flutter-test | flutter/test/dashboard_controller_test.dart::DashboardController Unit & Integration Tests when reset password for non-existent site, returns false | — | passed | 31.424 | flutter |
| flutter | flutter-test | flutter/test/dashboard_controller_test.dart::DashboardController Unit & Integration Tests when loginAs called with test personas, updates session and sets isAuthenticated true | — | passed | 31.438 | flutter |
| flutter | flutter-test | flutter/test/dashboard_controller_test.dart::DashboardController Unit & Integration Tests when initialized, then accountTransactions contains initial transactions and formats amounts correctly | — | passed | 31.445 | flutter |
| flutter | flutter-test | flutter/test/dashboard_controller_test.dart::DashboardController Unit & Integration Tests when recordHomeownerPayment with exact debt amount, clears debt and marks flat as paid | — | passed | 31.451 | flutter |
| flutter | flutter-test | flutter/test/dashboard_controller_test.dart::DashboardController Unit & Integration Tests when recordHomeownerPayment with surplus, clears debt and credits surplus to advance payment | — | passed | 31.456 | flutter |
| flutter | flutter-test | flutter/test/dashboard_controller_test.dart::DashboardController Unit & Integration Tests when recordHomeownerPayment on unit with zero debt, credits entire amount to advance payment | — | passed | 31.459 | flutter |
| flutter | flutter-test | flutter/test/dashboard_controller_test.dart::DashboardController Unit & Integration Tests when recordHomeownerPayment with partial amount, reduces debt without advance credit | — | passed | 31.462 | flutter |
| flutter | flutter-test | flutter/test/dashboard_controller_test.dart::DashboardController Unit & Integration Tests when confirmReconciliation with payment surplus, credits surplus to advance payment | — | passed | 31.47 | flutter |
| flutter | flutter-test | flutter/test/dashboard_controller_test.dart::DashboardController Unit & Integration Tests when a statement sender matches a registered payer alias, matches the unit | — | passed | 31.473 | flutter |
| flutter | flutter-test | flutter/test/dashboard_controller_test.dart::DashboardController Unit & Integration Tests when confirmReconciliation for flat with no debt, credits full payment to advance payment | — | passed | 31.481 | flutter |
| flutter | flutter-test | flutter/test/sale_clearance_test.dart::the statement is read with Decimal money | — | passed | 31.503 | flutter |
| flutter | flutter-test | flutter/test/sale_clearance_test.dart::the panel shows debt apart, the advance and the installments not yet accrued | — | passed | 31.937 | flutter |
| flutter | flutter-test | flutter/test/sale_clearance_test.dart::the download button asks the downloader for this unit | — | passed | 32.088 | flutter |
| flutter | flutter-test | flutter/test/sale_clearance_test.dart::a pending request is approved from the queue with the decision note | — | passed | 32.362 | flutter |
| flutter | flutter-test | flutter/test/person_import_xlsx_test.dart::the Excel template reads back as the import columns plus one example row | — | passed | 32.806 | flutter |
| flutter | flutter-test | flutter/test/person_import_xlsx_test.dart::a file that is not a workbook is rejected | — | passed | 32.811 | flutter |
| flutter | flutter-test | flutter/test/person_import_xlsx_test.dart::only .xlsx names are treated as Excel | — | passed | 32.813 | flutter |
| flutter | flutter-test | flutter/test/dues_models_penalty_row_test.dart::an overdue principal row is not shown as a credit | — | passed | 33.137 | flutter |
| flutter | flutter-test | flutter/test/dues_models_penalty_row_test.dart::the itemised delay penalty row is shown with a plus sign | — | passed | 33.139 | flutter |
| flutter | flutter-test | flutter/test/unit_directory_row_test.dart::unit directory row adapts from 320 to 1440 pixels | — | passed | 33.967 | flutter |
| flutter | flutter-test | flutter/test/capital_expenditure_and_dues_e2e_test.dart::EPIC-10: Capital Expenditure & Coordinated Dues Systems End-to-End (E2E) On-Screen Tests E2E On-Screen Journey 1: Capital Project Full Lifecycle with Positive & Valid Test Data | — | passed | 37.005 | flutter |
| flutter | flutter-test | flutter/test/capital_expenditure_and_dues_e2e_test.dart::EPIC-10: Capital Expenditure & Coordinated Dues Systems End-to-End (E2E) On-Screen Tests E2E On-Screen Journey 2: Wizard and Disbursement Form Negative & Boundary Validation | — | passed | 37.877 | flutter |
| flutter | flutter-test | flutter/test/capital_expenditure_and_dues_e2e_test.dart::EPIC-10: Capital Expenditure & Coordinated Dues Systems End-to-End (E2E) On-Screen Tests E2E On-Screen Journey 3: Multi-Persona Statutory Isolation (Kat Maliki vs Kiracı KMK 20/b & TBK 314) | — | passed | 38.638 | flutter |
| flutter | flutter-test | flutter/test/capital_expenditure_and_dues_e2e_test.dart::EPIC-10: Capital Expenditure & Coordinated Dues Systems End-to-End (E2E) On-Screen Tests E2E On-Screen Journey 4: Strict Test Data Clearance & Pristine State Verification | — | passed | 38.998 | flutter |
| flutter | flutter-test | flutter/test/force_password_change_test.dart::ApiClient.passwordChangeRequired fires on 403 PASSWORD_CHANGE_REQUIRED only | — | passed | 39.488 | flutter |
| flutter | flutter-test | flutter/test/force_password_change_test.dart::saasAdmin with a temporary password signs in to the change screen without loading any business data | — | passed | 39.504 | flutter |
| flutter | flutter-test | flutter/test/force_password_change_test.dart::saasAdmin with a temporary password deep links wait until the password is changed, then open the role home | — | passed | 39.515 | flutter |
| flutter | flutter-test | flutter/test/force_password_change_test.dart::saasAdmin with a temporary password router shows only the change screen; logout returns to login | — | passed | 40.297 | flutter |
| flutter | flutter-test | flutter/test/force_password_change_test.dart::siteManager with a temporary password signs in to the change screen without loading any business data | — | passed | 40.304 | flutter |
| flutter | flutter-test | flutter/test/force_password_change_test.dart::siteManager with a temporary password deep links wait until the password is changed, then open the role home | — | passed | 40.314 | flutter |
| flutter | flutter-test | flutter/test/dashboard_controller_test.dart::DashboardController Unit & Integration Tests when managing unit matching criteria, allows viewing, adding IBAN, deleting IBAN, and updating names | — | passed | 40.497 | flutter |
| flutter | flutter-test | flutter/test/force_password_change_test.dart::siteManager with a temporary password router shows only the change screen; logout returns to login | — | passed | 40.502 | flutter |
| flutter | flutter-test | flutter/test/force_password_change_test.dart::homeOwner with a temporary password signs in to the change screen without loading any business data | — | passed | 40.508 | flutter |
| flutter | flutter-test | flutter/test/force_password_change_test.dart::homeOwner with a temporary password deep links wait until the password is changed, then open the role home | — | passed | 40.521 | flutter |
| flutter | flutter-test | flutter/test/force_password_change_test.dart::homeOwner with a temporary password router shows only the change screen; logout returns to login | — | passed | 40.678 | flutter |
| flutter | flutter-test | flutter/test/force_password_change_test.dart::homeResident with a temporary password signs in to the change screen without loading any business data | — | passed | 40.685 | flutter |
| flutter | flutter-test | flutter/test/force_password_change_test.dart::homeResident with a temporary password deep links wait until the password is changed, then open the role home | — | passed | 40.692 | flutter |
| flutter | flutter-test | flutter/test/force_password_change_test.dart::homeResident with a temporary password router shows only the change screen; logout returns to login | — | passed | 40.84 | flutter |
| flutter | flutter-test | flutter/test/force_password_change_test.dart::auditor with a temporary password signs in to the change screen without loading any business data | — | passed | 40.846 | flutter |
| flutter | flutter-test | flutter/test/force_password_change_test.dart::auditor with a temporary password deep links wait until the password is changed, then open the role home | — | passed | 40.852 | flutter |
| flutter | flutter-test | flutter/test/force_password_change_test.dart::auditor with a temporary password router shows only the change screen; logout returns to login | — | passed | 40.985 | flutter |
| flutter | flutter-test | flutter/test/force_password_change_test.dart::a 403 PASSWORD_CHANGE_REQUIRED during a session returns to the change screen | — | passed | 40.994 | flutter |
| flutter | flutter-test | flutter/test/force_password_change_test.dart::the form validates before calling the server | — | passed | 41.335 | flutter |
| flutter | flutter-test | flutter/test/person_merge_test.dart::merge asks for a password check and then sends the target version | — | passed | 42.886 | flutter |
| flutter | flutter-test | flutter/test/person_merge_test.dart::a card cannot be merged into itself | — | passed | 43.121 | flutter |
| flutter | flutter-test | flutter/test/person_merge_test.dart::mergePerson posts the target and the expected version | — | passed | 43.128 | flutter |
| flutter | flutter-test | flutter/test/bank_statement_sample_generator_test.dart::generates a parser-compatible fictional workbook for KUVEYT_TURK | — | passed | 43.523 | flutter |
| flutter | flutter-test | flutter/test/bank_statement_sample_generator_test.dart::generates a parser-compatible fictional workbook for YAPI_KREDI | — | passed | 43.527 | flutter |
| flutter | flutter-test | flutter/test/bank_statement_sample_generator_test.dart::rejects a bank that does not use Excel statements | — | passed | 43.529 | flutter |
| flutter | flutter-test | flutter/test/unit_directory_benchmark_test.dart::benchmark local directory search and sort at 1k and 10k units | — | passed | 44.575 | flutter |
| flutter | flutter-test | flutter/test/card_payment_panel_test.dart::hosted card payment opens, polls, and reports capture | — | passed | 45.455 | flutter |
| flutter | flutter-test | flutter/test/dashboard_controller_test.dart::DashboardController Unit & Integration Tests when resetAllDemoData invoked, clears advance payments, dues, and transactions for a clean slate | — | passed | 45.511 | flutter |
| flutter | flutter-test | flutter/test/dashboard_controller_test.dart::DashboardController Unit & Integration Tests when accruing a new month after reset, preserves exactly 12 flats and accurate dues calculation without defaulting to 24 units or 96000 collected | — | passed | 45.518 | flutter |
| flutter | flutter-test | flutter/test/dashboard_controller_test.dart::DashboardController Unit & Integration Tests when logout is invoked, thoroughly purges all in-memory domain, tenant, and financial state | — | passed | 45.525 | flutter |
| flutter | flutter-test | flutter/test/dashboard_controller_test.dart::DashboardController Unit & Integration Tests when attachActiveUnitForUser has no matching resident email, does not default to first unit of prior session | — | passed | 45.532 | flutter |
| flutter | flutter-test | flutter/test/bank_file_parser_test.dart::Real Bank Statement Ingestion Tests (Kuveyt Turk & Is Bankasi) parses Kuveyt Turk XLSX and matches resident flats with high confidence | — | passed | 45.875 | flutter |
| flutter | flutter-test | flutter/test/bank_file_parser_test.dart::Real Bank Statement Ingestion Tests (Kuveyt Turk & Is Bankasi) parses Is Bankasi statement CSV/XLS and extracts operations | — | passed | 45.883 | flutter |
| flutter | flutter-test | flutter/test/home_owner_directory_and_edit_test.dart::Home Owner Directory & Edit Screen Tests HomeOwnerItem model serializes and deserializes correctly | — | passed | 46.314 | flutter |
| flutter | flutter-test | flutter/test/home_owner_directory_and_edit_test.dart::Home Owner Directory & Edit Screen Tests DashboardController fetchHomeOwners deduplicates duplicate units properly | — | passed | 46.343 | flutter |
| flutter | flutter-test | flutter/test/home_owner_directory_and_edit_test.dart::Home Owner Directory & Edit Screen Tests DashboardController updateHomeOwner updates resident in-place and updates flats list | — | passed | 46.349 | flutter |
| flutter | flutter-test | flutter/test/home_owner_directory_and_edit_test.dart::Home Owner Directory & Edit Screen Tests DashboardController deleteHomeOwner removes homeowner and matching flats locally | — | passed | 46.354 | flutter |
| flutter | flutter-test | flutter/test/home_owner_directory_and_edit_test.dart::Home Owner Directory & Edit Screen Tests DashboardController updateHomeOwner updates tenant and homeowner independently | — | passed | 46.359 | flutter |
| flutter | flutter-test | flutter/test/home_owner_directory_and_edit_test.dart::Home Owner Directory & Edit Screen Tests DashboardController updateHomeOwner with removeTenant clears tenant | — | passed | 46.368 | flutter |
| flutter | flutter-test | flutter/test/home_owner_directory_and_edit_test.dart::Home Owner Directory & Edit Screen Tests DashboardController deleteHouseholdMember removes member from unit | — | passed | 46.374 | flutter |
| flutter | flutter-test | flutter/test/home_owner_directory_and_edit_test.dart::Home Owner Directory & Edit Screen Tests Residents tab lists units and opens their actions in the module workspace | — | passed | 47.837 | flutter |
| flutter | flutter-test | flutter/test/home_owner_directory_and_edit_test.dart::Home Owner Directory & Edit Screen Tests Residents tab details open the unit information in the module workspace | — | passed | 48.317 | flutter |
| flutter | flutter-test | flutter/test/home_owner_directory_and_edit_test.dart::Home Owner Directory & Edit Screen Tests Site Manager deletes a unit from the module workspace opened on the residents tab | — | passed | 49.033 | flutter |
| flutter | flutter-test | flutter/test/home_owner_directory_and_edit_test.dart::Home Owner Directory & Edit Screen Tests Resident search clear button resets field text and filter query | — | passed | 49.51 | flutter |
| flutter | flutter-test | flutter/test/money_format_test.dart::toTurkishString formats exact Decimal amounts in Turkish locale | — | passed | 49.856 | flutter |
| flutter | flutter-test | flutter/test/money_format_test.dart::kuruş-level balances are not lost to floating point | — | passed | 49.858 | flutter |
| flutter | flutter-test | flutter/test/account_link_screen_test.dart::the person sets their own password and the token goes to the server once | — | passed | 51.061 | flutter |
| flutter | flutter-test | flutter/test/account_link_screen_test.dart::a short or mismatched password is caught before anything is sent | — | passed | 51.234 | flutter |
| flutter | flutter-test | flutter/test/account_link_screen_test.dart::an expired link says what to do next instead of showing the form again | — | passed | 51.365 | flutter |
| flutter | flutter-test | flutter/test/account_link_screen_test.dart::an email confirmation link is applied on open | — | passed | 51.429 | flutter |
| flutter | flutter-test | flutter/test/account_link_screen_test.dart::a link without a token is refused without a request | — | passed | 51.459 | flutter |
| flutter | flutter-test | flutter/test/owners_residents_module_test.dart::Owners & Residents Module Dedicated Tests OwnersResidentsModulePage renders KPIs, filter chips, and unit cards | — | passed | 52.9 | flutter |
| flutter | flutter-test | flutter/test/owners_residents_module_test.dart::Owners & Residents Module Dedicated Tests unit directory row exposes separate actions and details targets | — | passed | 53.153 | flutter |
| flutter | flutter-test | flutter/test/owners_residents_module_test.dart::Owners & Residents Module Dedicated Tests OwnersResidentsModulePage restores the unit directory search query | — | passed | 53.545 | flutter |
| flutter | flutter-test | flutter/test/owners_residents_module_test.dart::Owners & Residents Module Dedicated Tests Site Manager can navigate to Sakinler & Malikler tab via Cockpit button | — | passed | 53.966 | flutter |
| flutter | flutter-test | flutter/test/owners_residents_module_test.dart::Owners & Residents Module Dedicated Tests Site Manager can open OwnersResidentsModulePage from Yönetim tab header button | — | passed | 54.403 | flutter |
| flutter | flutter-test | flutter/test/owners_residents_module_test.dart::Owners & Residents Module Dedicated Tests OwnersResidentsModulePage supports designating primary responsible resident | — | passed | 54.919 | flutter |
| flutter | flutter-test | flutter/test/owners_residents_module_test.dart::Owners & Residents Module Dedicated Tests OwnersResidentsModulePage tab switching toggles Sakinler and Kat Maliki views | — | passed | 55.272 | flutter |
| flutter | flutter-test | flutter/test/owners_residents_module_test.dart::Owners & Residents Module Dedicated Tests OwnersResidentsModulePage allows adding co-resident and shows occupancy history | — | passed | 55.69 | flutter |
| flutter | flutter-test | flutter/test/owners_residents_module_test.dart::Owners & Residents Module Dedicated Tests OwnersResidentsModulePage keeps move-in action with the occupancy that needs it | — | passed | 56.003 | flutter |
| flutter | flutter-test | flutter/test/owners_residents_module_test.dart::Owners & Residents Module Dedicated Tests OwnersResidentsModulePage allows defining Kat Maliki (Owner) vs Kiracı (Renter) when adding new resident | — | passed | 56.671 | flutter |
| flutter | flutter-test | flutter/test/owners_residents_module_test.dart::Owners & Residents Module Dedicated Tests Resident details show occupancy without allowing a transition | — | passed | 57.049 | flutter |
| flutter | flutter-test | flutter/test/owners_residents_module_test.dart::Owners & Residents Module Dedicated Tests Owner details cannot change occupancy for OWNER_OCCUPIED | — | passed | 57.325 | flutter |
| flutter | flutter-test | flutter/test/owners_residents_module_test.dart::Owners & Residents Module Dedicated Tests Owner details cannot change occupancy for VACANT | — | passed | 57.571 | flutter |
| flutter | flutter-test | flutter/test/owners_residents_module_test.dart::Owners & Residents Module Dedicated Tests OwnersResidentsModulePage vacant unit offers tenant move-in and owner move-in separately | — | passed | 57.918 | flutter |
| flutter | flutter-test | flutter/test/owners_residents_module_test.dart::Owners & Residents Module Dedicated Tests OwnersResidentsModulePage enforces resident owner exclusivity and saves dynamic co-residents on add form | — | passed | 58.512 | flutter |
| flutter | flutter-test | flutter/test/dashboard_controller_test.dart::DashboardController Unit & Integration Tests when !isTestMode and API calls fail, does not fabricate fake in-memory receipts or projects | — | passed | 58.546 | flutter |
| flutter | flutter-test | flutter/test/role_scoped_fetch_test.dart::HOME_OWNER never requests the site manager directory or overview | — | passed | 58.946 | flutter |
| flutter | flutter-test | flutter/test/role_scoped_fetch_test.dart::HOME_RESIDENT never requests the site manager directory or overview | — | passed | 58.958 | flutter |
| flutter | flutter-test | flutter/test/role_scoped_fetch_test.dart::AUDITOR never requests the site manager directory or overview | — | passed | 58.966 | flutter |
| flutter | flutter-test | flutter/test/role_scoped_fetch_test.dart::a resident does not request the household list; the owner does | — | passed | 58.986 | flutter |
| flutter | flutter-test | flutter/test/role_scoped_fetch_test.dart::the site manager still loads its directory and overview | — | passed | 59.0 | flutter |
| flutter | flutter-test | flutter/test/standardized_logging_test.dart::Standardized Logging - Flutter Tests AppLogger records logs across all severity levels | — | passed | 59.411 | flutter |
| flutter | flutter-test | flutter/test/standardized_logging_test.dart::Standardized Logging - Flutter Tests AppLogger respects minLevel threshold | — | passed | 59.414 | flutter |
| flutter | flutter-test | flutter/test/standardized_logging_test.dart::Standardized Logging - Flutter Tests AppLogger.redact masks sensitive fields recursively | — | passed | 59.417 | flutter |
| flutter | flutter-test | flutter/test/standardized_logging_test.dart::Standardized Logging - Flutter Tests AppLogger.newTraceId generates valid UUIDv4 format | — | passed | 59.42 | flutter |
| flutter | flutter-test | flutter/test/standardized_logging_test.dart::Standardized Logging - Flutter Tests LogRecord formats structured string output correctly | — | passed | 59.424 | flutter |
| flutter | flutter-test | flutter/test/standardized_logging_test.dart::Standardized Logging - Flutter Tests ApiClient automatically injects x-request-id and logs network requests | — | passed | 59.434 | flutter |
| flutter | flutter-test | flutter/test/standardized_logging_test.dart::Standardized Logging - Flutter Tests ApiClient.decode captures traceId from x-request-id and logs API error | — | passed | 59.437 | flutter |
| flutter | flutter-test | flutter/test/standardized_logging_test.dart::Standardized Logging - Flutter Tests ApiClient.decode fallbacks to x-request-id header when body has no trace_id | — | passed | 59.439 | flutter |
| flutter | flutter-test | flutter/test/unit_registration_person_refs_test.dart::registering a unit sends person references instead of inline identity | — | passed | 59.855 | flutter |
| flutter | flutter-test | flutter/test/people_directory_test.dart::pages through the directory and filters people waiting for activation | — | passed | 60.099 | flutter |
| flutter | flutter-test | flutter/test/people_directory_test.dart::search waits for typing to pause before asking the server | — | passed | 60.325 | flutter |
| flutter | flutter-test | flutter/test/people_directory_test.dart::restores search query and directory page position across restoration | — | passed | 60.638 | flutter |
| flutter | flutter-test | flutter/test/people_directory_test.dart::export asks for the password when the server requires it | — | passed | 60.965 | flutter |
| flutter | flutter-test | flutter/test/people_directory_test.dart::profile shows the unit timeline and resends a pending activation link | — | passed | 61.11 | flutter |
| flutter | flutter-test | flutter/test/people_directory_test.dart::shows empty state guidance with action when no residents or owners exist | — | passed | 61.224 | flutter |
| flutter | flutter-test | flutter/test/people_directory_test.dart::shows empty state when directory has zero people | — | passed | 61.324 | flutter |
| flutter | flutter-test | flutter/test/unit_state_test.dart::allowedOccupancyCommands a vacant owned unit takes a tenant or the owner on record | — | passed | 61.767 | flutter |
| flutter | flutter-test | flutter/test/unit_state_test.dart::allowedOccupancyCommands an owner-occupied unit can be vacated or rented out, not moved into | — | passed | 61.769 | flutter |
| flutter | flutter-test | flutter/test/unit_state_test.dart::allowedOccupancyCommands a tenant-occupied unit offers the compound moves | — | passed | 61.772 | flutter |
| flutter | flutter-test | flutter/test/unit_state_test.dart::allowedOccupancyCommands a unit without an owner on record takes no move-in (decision A2) | — | passed | 61.774 | flutter |
| flutter | flutter-test | flutter/test/unit_state_test.dart::UnitOccupancyState reads the server response | — | passed | 61.781 | flutter |
| flutter | flutter-test | flutter/test/design_system_test.dart::MoneyFormatter (finding 3: one format, Decimal only) formats Turkish Lira with dot grouping and comma kuruş | — | passed | 62.281 | flutter |
| flutter | flutter-test | flutter/test/design_system_test.dart::MoneyFormatter (finding 3: one format, Decimal only) keeps precision on amounts a double cannot hold | — | passed | 62.286 | flutter |
| flutter | flutter-test | flutter/test/design_system_test.dart::MoneyFormatter (finding 3: one format, Decimal only) rounds half kuruş away from zero, without double drift | — | passed | 62.291 | flutter |
| flutter | flutter-test | flutter/test/design_system_test.dart::MoneyFormatter (finding 3: one format, Decimal only) formats negatives and signed ledger values | — | passed | 62.294 | flutter |
| flutter | flutter-test | flutter/test/design_system_test.dart::MoneyFormatter (finding 3: one format, Decimal only) parses what people type | — | passed | 62.297 | flutter |
| flutter | flutter-test | flutter/test/design_system_test.dart::MoneyFormatter (finding 3: one format, Decimal only) format and parse round-trip | — | passed | 62.299 | flutter |
| flutter | flutter-test | flutter/test/design_system_test.dart::Colour tokens reach WCAG AA 4.5:1 (finding 2) solid fills carry white text | — | passed | 62.303 | flutter |
| flutter | flutter-test | flutter/test/design_system_test.dart::Colour tokens reach WCAG AA 4.5:1 (finding 2) status text on light surfaces | — | passed | 62.305 | flutter |
| flutter | flutter-test | flutter/test/design_system_test.dart::Colour tokens reach WCAG AA 4.5:1 (finding 2) status text on dark surfaces | — | passed | 62.306 | flutter |
| flutter | flutter-test | flutter/test/design_system_test.dart::Colour tokens reach WCAG AA 4.5:1 (finding 2) the old bright tones are kept for icons and fills only (they fail as text on white) | — | passed | 62.308 | flutter |
| flutter | flutter-test | flutter/test/design_system_test.dart::Colour tokens reach WCAG AA 4.5:1 (finding 2) theme colour schemes use the accessible pairs | — | passed | 62.341 | flutter |
| flutter | flutter-test | flutter/test/design_system_test.dart::Type scale (finding 4) no text style in the theme is below 12 px | — | passed | 62.345 | flutter |
| flutter | flutter-test | flutter/test/design_system_test.dart::Toasts (finding 12: errors never look like success) kind comes from colour, then from wording | — | passed | 62.348 | flutter |
| flutter | flutter-test | flutter/test/design_system_test.dart::Toasts (finding 12: errors never look like success) each kind has its own fill and icon; errors stay until dismissed | — | passed | 62.356 | flutter |
| flutter | flutter-test | flutter/test/design_system_test.dart::Toasts (finding 12: errors never look like success) a toast announces its kind to screen readers | — | passed | 62.836 | flutter |
| flutter | flutter-test | flutter/test/e2e_quality_verification_test.dart::SitePulse End-to-End (E2E) App Quality Verification Tests E2E Journey 1: SaaS SuperAdmin Site Lifecycle (Provision, Reset Password, Safe Deletion) | — | passed | 62.884 | flutter |
| flutter | flutter-test | flutter/test/dues_management_view_test.dart::Dues Management Dedicated Tab & Unmatched Bank Pool Tests when switching dues month then recalculates and displays monthly paid and overdue counts | — | passed | 63.387 | flutter |
| flutter | flutter-test | flutter/test/dues_management_view_test.dart::Dues Management Dedicated Tab & Unmatched Bank Pool Tests reconciliation queue identifies unmatched bank transactions in pool | — | passed | 63.395 | flutter |
| flutter | flutter-test | flutter/test/dues_management_view_test.dart::Dues Management Dedicated Tab & Unmatched Bank Pool Tests DashboardScreen renders Aidat Yönetimi bottom tab for Site Manager and switches view | — | passed | 64.661 | flutter |
| flutter | flutter-test | flutter/test/e2e_quality_verification_test.dart::SitePulse End-to-End (E2E) App Quality Verification Tests E2E Journey 2: Site Manager Cockpit, Dues Accrual & Automated Reconciliation Flow | — | passed | 64.838 | flutter |
| flutter | flutter-test | flutter/test/dues_management_view_test.dart::Dues Management Dedicated Tab & Unmatched Bank Pool Tests DuesManagementView opens intermediate import summary dialog when importing bank file | — | passed | 64.949 | flutter |
| flutter | flutter-test | flutter/test/dues_management_view_test.dart::Dues Management Dedicated Tab & Unmatched Bank Pool Tests DuesManagementView opens Toplu Aidat Tahakkuku confirmation dialog with duplicate prevention note | — | passed | 65.391 | flutter |
| flutter | flutter-test | flutter/test/e2e_quality_verification_test.dart::SitePulse End-to-End (E2E) App Quality Verification Tests E2E Journey 3: Home Owner Dues Inspection, Payment Checkout & Co-Resident Link Flow | — | passed | 65.764 | flutter |
| flutter | flutter-test | flutter/test/occupancy_lifecycle_and_dual_ledger_test.dart::Occupancy Lifecycle and Dual Ledger Domain Model Tests HomeOwnerItem deserializes occupancy status and dual-ledger balances correctly | — | passed | 65.993 | flutter |
| flutter | flutter-test | flutter/test/occupancy_lifecycle_and_dual_ledger_test.dart::Occupancy Lifecycle and Dual Ledger Domain Model Tests OccupancyHistoryItem deserializes timeline correctly | — | passed | 65.997 | flutter |
| flutter | flutter-test | flutter/test/occupancy_lifecycle_and_dual_ledger_test.dart::Occupancy Lifecycle and Dual Ledger Domain Model Tests Move-out records the effective date chosen by the manager | — | passed | 66.033 | flutter |
| flutter | flutter-test | flutter/test/occupancy_lifecycle_and_dual_ledger_test.dart::Occupancy Lifecycle and Dual Ledger Domain Model Tests Controller handles move-out and move-in in local fallback mode | — | passed | 66.039 | flutter |
| flutter | flutter-test | flutter/test/e2e_quality_verification_test.dart::SitePulse End-to-End (E2E) App Quality Verification Tests E2E Journey 4: Site Manager Dual-Path Security Isolation (Cockpit vs My Flat) | — | passed | 66.187 | flutter |
| flutter | flutter-test | flutter/test/e2e_quality_verification_test.dart::SitePulse End-to-End (E2E) App Quality Verification Tests E2E Journey 5: Zero-Data Resiliency and Graceful Recovery | — | passed | 66.482 | flutter |
| flutter | flutter-test | flutter/test/occupancy_lifecycle_and_dual_ledger_test.dart::Dashboard HomeOwnerCard Occupancy & Dues Breakdown UI Widget Tests Renders occupancy status badge and dual ledger breakdown chips | — | passed | 67.208 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::page header wraps actions at 320.0 in Brightness.light | — | passed | 67.575 | flutter |
| flutter | flutter-test | flutter/test/occupancy_lifecycle_and_dual_ledger_test.dart::Dashboard HomeOwnerCard Occupancy & Dues Breakdown UI Widget Tests Tapping history in the unit workspace opens Daire Sakin & İkamet Tarihçesi | — | passed | 68.049 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::person components remain usable at 320.0 and 2x text in Brightness.light | — | passed | 68.05 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::person card stays readable at 320.0 and 2x text in Brightness.light | — | passed | 68.091 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::page header wraps actions at 1200.0 in Brightness.light | — | passed | 68.119 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::person components remain usable at 1200.0 and 2x text in Brightness.light | — | passed | 68.327 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::person card stays readable at 1200.0 and 2x text in Brightness.light | — | passed | 68.358 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::page header wraps actions at 320.0 in Brightness.dark | — | passed | 68.39 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::person components remain usable at 320.0 and 2x text in Brightness.dark | — | passed | 68.561 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::person card stays readable at 320.0 and 2x text in Brightness.dark | — | passed | 68.591 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::page header wraps actions at 1200.0 in Brightness.dark | — | passed | 68.625 | flutter |
| flutter | flutter-test | flutter/test/occupancy_lifecycle_and_dual_ledger_test.dart::Dashboard HomeOwnerCard Occupancy & Dues Breakdown UI Widget Tests Tapping move-out in the unit workspace opens Sakin Ayrılışı without layout errors | — | passed | 68.74 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::person components remain usable at 1200.0 and 2x text in Brightness.dark | — | passed | 68.796 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::person card stays readable at 1200.0 and 2x text in Brightness.dark | — | passed | 68.827 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::fullscreen content begins at the top, scrollable=true | — | passed | 68.852 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::fullscreen content begins at the top, scrollable=false | — | passed | 68.872 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::MoneyFormatter.tryParse (the single amount-input rule) accepts Turkish grouping, plain comma or dot decimals and the lira symbol | — | passed | 68.876 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::MoneyFormatter.tryParse (the single amount-input rule) without a comma, a dot is grouping only when followed by exactly three digits | — | passed | 68.877 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::MoneyFormatter.tryParse (the single amount-input rule) rejects text that is not an amount | — | passed | 68.879 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::MoneyFormatter.tryParse (the single amount-input rule) keeps large amounts exact (no double conversion) | — | passed | 68.881 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::validateMoneyInput / MoneyInput keeps empty, invalid and zero distinct | — | passed | 68.885 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::validateMoneyInput / MoneyInput custom messages and caller rules are layered on top | — | passed | 68.887 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::validateMoneyInput / MoneyInput SpMoneyFormField reports the parsed Decimal and validates inline | — | passed | 68.962 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::readDecimal parses strings and numbers through their string form | — | passed | 68.966 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::readDecimal missing values use the fallback; malformed values are reported | — | passed | 68.97 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::BankFileParser MT940 parses every transaction with date, direction, amount and reference | — | passed | 68.973 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::BankFileParser MT940 parseText delegates MT940 content so files and pasted text agree | — | passed | 68.975 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::BankFileParser MT940 statement amounts share the MoneyFormatter rule | — | passed | 68.977 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::resident directory block codes normalise and blocks de-duplicate case-insensitively | — | passed | 68.979 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::resident directory filters by block, occupancy and free text (including e-mail) | — | passed | 68.985 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::resident directory occupancy stats and rate match the previous one-decimal formula | — | passed | 68.987 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::resident directory ResidentSummary renders both variants without a controller | — | passed | 69.018 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::design-system widgets SpMetricValue and SpIconMetric show label and value | — | passed | 69.038 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::design-system widgets widgets lay out at 2x text scale in light theme | — | passed | 69.068 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::design-system widgets widgets lay out at 2x text scale in dark theme | — | passed | 69.091 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::design-system widgets SpGuidanceCard shows optional action and tip | — | passed | 69.114 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::design-system widgets SpFilterChip reports selection and exposes selected state | — | passed | 69.152 | flutter |
| flutter | flutter-test | flutter/test/person_records_test.dart::national ID check digits match the server rule | — | passed | 69.198 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::design-system widgets SpDirectoryScaffold shows rows in a bounded, paged layout | — | passed | 69.282 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::design-system widgets SpDirectoryScaffold requests server pages and page sizes | — | passed | 69.356 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::clipboard normalizeIban removes grouping whitespace only | — | passed | 69.358 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::clipboard SpIbanCopyRow copies the IBAN without spaces and confirms | — | passed | 69.419 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::clipboard an empty IBAN shows the empty label and no copy action | — | passed | 69.438 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::clipboard spCopyToClipboard keeps text exactly, and reports failures | — | passed | 69.488 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::showSpSelection returns the chosen option, or null when the user goes back | — | passed | 69.619 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::AdvanceExitSettlementFields offers keep, payout and transfer choices (light, 2x text) | — | passed | 69.71 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::AdvanceExitSettlementFields offers keep, payout and transfer choices (dark, 2x text) | — | passed | 69.771 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::StepUpPromptPage states the reason and verifies the password (light, 2x text) | — | passed | 69.922 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::StepUpPromptPage states the reason and verifies the password (dark, 2x text) | — | passed | 70.023 | flutter |
| flutter | flutter-test | flutter/test/person_records_test.dart::import stays disabled until a clean dry run of the same text | — | passed | 70.071 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::StepUpPromptPage runWithStepUp asks for the password and retries the action once | — | passed | 70.124 | flutter |
| flutter | flutter-test | flutter/test/reusable_components_test.dart::StepUpPromptPage a wrong password keeps the page open and says so | — | passed | 70.203 | flutter |
| flutter | flutter-test | flutter/test/person_records_test.dart::a dry run with errors lists them and allows no import | — | passed | 70.265 | flutter |
| flutter | flutter-test | flutter/test/person_records_test.dart::the template has every column the server reads | — | passed | 70.27 | flutter |
| flutter | flutter-test | flutter/test/person_records_test.dart::profile shows the masked national ID, preferences and read-only consents | — | passed | 70.368 | flutter |
| flutter | flutter-test | flutter/test/person_records_test.dart::recording a national ID asks for the password when the server requires it | — | passed | 70.685 | flutter |
| flutter | flutter-test | flutter/test/home_owner_registration_test.dart::a refused registration changes nothing locally and localizes the server reason | — | passed | 70.742 | flutter |
| flutter | flutter-test | flutter/test/home_owner_registration_test.dart::an unreachable server is reported and no record or password is invented | — | passed | 70.754 | flutter |
| flutter | flutter-test | flutter/test/home_owner_registration_test.dart::a server error is shown generically with its reference, not raw text | — | passed | 70.761 | flutter |
| flutter | flutter-test | flutter/test/home_owner_registration_test.dart::a confirmed registration reports the activation link, never a password | — | passed | 70.772 | flutter |
| flutter | flutter-test | flutter/test/home_owner_registration_test.dart::F3/F4: the entered land share is sent and no dues are invented without a tariff | — | passed | 70.777 | flutter |
| flutter | flutter-test | flutter/test/person_records_test.dart::preferences are edited on their own page and shown after saving | — | passed | 71.006 | flutter |
| flutter | flutter-test | flutter/test/person_records_test.dart::duplicate check asks the server with a POST and reads the reasons | — | passed | 71.031 | flutter |
| flutter | flutter-test | flutter/test/person_records_test.dart::duplicate check a failed check never blocks a registration | — | passed | 71.036 | flutter |
| flutter | flutter-test | flutter/test/standardized_error_management_test.dart::site form retains localized error after toast consumption (400) | — | passed | 71.547 | flutter |
| flutter | flutter-test | flutter/test/standardized_error_management_test.dart::site form retains localized error after toast consumption (409) | — | passed | 71.553 | flutter |
| flutter | flutter-test | flutter/test/standardized_error_management_test.dart::resident details use the server day count rather than the device calendar | — | passed | 71.567 | flutter |
| flutter | flutter-test | flutter/test/standardized_error_management_test.dart::Standardized Error Management - Flutter Tests ApiException correctly identifies error categories and details | — | passed | 71.57 | flutter |
| flutter | flutter-test | flutter/test/standardized_error_management_test.dart::Standardized Error Management - Flutter Tests ApiClient.decode successfully parses 2xx JSON payload | — | passed | 71.573 | flutter |
| flutter | flutter-test | flutter/test/standardized_error_management_test.dart::Standardized Error Management - Flutter Tests ApiClient.decode throws ApiException for standardized error envelope | — | passed | 71.577 | flutter |
| flutter | flutter-test | flutter/test/standardized_error_management_test.dart::Standardized Error Management - Flutter Tests ApiClient.decode gracefully handles legacy or plain text error responses | — | passed | 71.579 | flutter |
| flutter | flutter-test | flutter/test/standardized_error_management_test.dart::Standardized Error Management - Flutter Tests PaymentsPhase2Api backwards compatibility with ApiFailure | — | passed | 71.581 | flutter |
| flutter | flutter-test | flutter/test/standardized_error_management_test.dart::Standardized Error Management - Flutter Tests AppStrings.localizedErrorMessage translates standard codes to Turkish | — | passed | 71.583 | flutter |
| flutter | flutter-test | flutter/test/standardized_error_management_test.dart::Standardized Error Management - Flutter Tests duplicate identity errors are localized for code and plain-text responses | — | passed | 71.585 | flutter |
| flutter | flutter-test | flutter/test/zero_data_guidance_test.dart::Zero Data Guidance Tests (Periodic Payment, Homeowner, Site) DuesManagementView requires units before starting the first dues period | — | passed | 71.907 | flutter |
| flutter | flutter-test | flutter/test/zero_data_guidance_test.dart::Zero Data Guidance Tests (Periodic Payment, Homeowner, Site) DuesManagementView displays guidance when no homeowner / units exist in site | — | passed | 72.005 | flutter |
| flutter | flutter-test | flutter/test/standardized_error_management_test.dart::Standardized Error Management - Flutter Tests SpErrorState displays message and calls retry callback | — | passed | 72.014 | flutter |
| flutter | flutter-test | flutter/test/zero_data_guidance_test.dart::Zero Data Guidance Tests (Periodic Payment, Homeowner, Site) ManagerCockpitView displays guidance when no periodic payment / dues exist | — | passed | 72.078 | flutter |
| flutter | flutter-test | flutter/test/zero_data_guidance_test.dart::Zero Data Guidance Tests (Periodic Payment, Homeowner, Site) ManagerCockpitView displays guidance when no site exists in the system | — | passed | 72.125 | flutter |
| flutter | flutter-test | flutter/test/standardized_error_management_test.dart::Standardized Error Management - Flutter Tests SpToast.exception displays translated error message | — | passed | 72.128 | flutter |
| flutter | flutter-test | flutter/test/zero_data_guidance_test.dart::Zero Data Guidance Tests (Periodic Payment, Homeowner, Site) DashboardScreen displays guidance when Home Owner has no assigned unit | — | passed | 72.246 | flutter |
| flutter | flutter-test | flutter/test/zero_data_guidance_test.dart::Zero Data Guidance Tests (Periodic Payment, Homeowner, Site) HeroBalanceCard displays reassuring zero debt guidance when no dues exist | — | passed | 72.283 | flutter |
| flutter | flutter-test | flutter/test/zero_data_guidance_test.dart::Zero Data Guidance Tests (Periodic Payment, Homeowner, Site) HeroBalanceCard shows capital dues separately by project | — | passed | 72.314 | flutter |
| flutter | flutter-test | flutter/test/zero_data_guidance_test.dart::Zero Data Guidance Tests (Periodic Payment, Homeowner, Site) HeroBalanceCard displays actual overdue days in badge | — | passed | 72.344 | flutter |
| cargo | money-fixtures | penalty_keeps_kurus_precision_and_does_not_drift_across_recalculations | — | passed | — | flutter |
| cargo | money-fixtures | allocation_cases_match_the_fixture | — | passed | — | flutter |
| cargo | money-fixtures | penalty_cases_match_the_fixture | — | passed | — | flutter |
| cargo | money-fixtures | waterfall_properties_hold_for_random_inputs | — | passed | — | flutter |
| flutter | money-fixtures | flutter/test/financial_fixture_test.dart::Shared financial fixture: penalty cases 10 days overdue on 1400.00 | — | passed | 7.354 | flutter |
| flutter | money-fixtures | flutter/test/financial_fixture_test.dart::Shared financial fixture: penalty cases not yet due | — | passed | 7.357 | flutter |
| flutter | money-fixtures | flutter/test/financial_fixture_test.dart::Shared financial fixture: penalty cases due today | — | passed | 7.359 | flutter |
| flutter | money-fixtures | flutter/test/financial_fixture_test.dart::Shared financial fixture: penalty cases one full month | — | passed | 7.361 | flutter |
| flutter | money-fixtures | flutter/test/financial_fixture_test.dart::Shared financial fixture: penalty cases half-cent tie rounds up (1.005) | — | passed | 7.364 | flutter |
| flutter | money-fixtures | flutter/test/financial_fixture_test.dart::Shared financial fixture: penalty cases half-cent tie rounds up (2.675) | — | passed | 7.366 | flutter |
| flutter | money-fixtures | flutter/test/financial_fixture_test.dart::Shared financial fixture: penalty cases one day on one kurus | — | passed | 7.367 | flutter |
| unittest | harness-selftest | test_api_system_check.PublicRouteMirrorTests.test_drift_reports_both_directions | — | passed | — | lint |
| unittest | harness-selftest | test_api_system_check.PublicRouteMirrorTests.test_parser_reads_only_public_policy | — | passed | — | lint |
| unittest | harness-selftest | test_api_system_check.PublicRouteMirrorTests.test_public_routes_mirror_matches_app_rs | — | passed | — | lint |
| unittest | harness-selftest | test_ci_case_results.CaseAdapterTests.test_api_and_schema_json_rows_become_cases | — | passed | — | lint |
| unittest | harness-selftest | test_ci_case_results.CaseAdapterTests.test_cargo_parser_keeps_doctest_names_and_ignored_status | — | passed | — | lint |
| unittest | harness-selftest | test_ci_case_results.CaseAdapterTests.test_expected_manifest_includes_eight_shards_and_opt_in_database_cases | — | passed | — | lint |
| unittest | harness-selftest | test_ci_case_results.CaseAdapterTests.test_flutter_ids_include_file_path_and_malformed_json_is_ignored | — | passed | — | lint |
| unittest | harness-selftest | test_ci_case_results.CaseAdapterTests.test_flutter_parser_maps_results_and_runner_error | — | passed | — | lint |
| unittest | harness-selftest | test_ci_case_results.CaseAdapterTests.test_junit_failure_and_error_elements_are_handled_and_bad_times_are_null | — | passed | — | lint |
| unittest | harness-selftest | test_ci_case_results.CaseAdapterTests.test_junit_rows_include_parameterized_names_and_skips | — | passed | — | lint |
| unittest | harness-selftest | test_ci_case_results.CaseAdapterTests.test_unittest_parser_retains_fail_error_and_skip | — | passed | — | lint |
| unittest | harness-selftest | test_ci_case_results.GateCaptureTests.test_process_exit_code_is_preserved_in_gate_and_artifact | — | passed | — | lint |
| unittest | harness-selftest | test_ci_case_results.GateCaptureTests.test_sidecar_write_failure_does_not_change_native_gate_outcome | — | passed | — | lint |
| unittest | harness-selftest | test_ci_case_results.GateCaptureTests.test_unittest_sidecar_failure_keeps_success_exit_status | — | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_ci_ignores_only_the_linked_file | — | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_harness_linked_scenarios', command='<python> -m unittest discover -s harness/tests' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic07_rust_linked_scenarios', command='cargo test --locked --test integration_tests' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic07_billing_period_linked_scenarios', command='cargo test --locked --test billing_period_tests' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic07_proration_linked_scenarios', command='cargo test --locked --test occupancy_proration_tests' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic07_accrual_corrections_linked_scenarios', command='cargo test --locked --test accrual_corrections_tests' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic07_flutter_linked_scenarios', command='flutter test test/dues_management_view_test.dart' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic11_rust_linked_scenarios', command='cargo test --locked --test payments_phase3_tests' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic11_flutter_linked_scenarios', command='flutter test test/payments_phase3_test.dart' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic11_api_linked_scenarios', command='<python> scripts/api_system_check.py --json' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic08_rust_linked_scenarios', command='cargo test --locked --test occupancy_state_machine_tests' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic08_flutter_linked_scenarios', command='flutter test test/unit_workspace_test.dart' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic09_rust_linked_scenarios', command='cargo test --locked --test payment_ledger_hardening_tests' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic09_flutter_linked_scenarios', command='flutter test test/payment_tracking_and_aging_test.dart' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic13_designated_payment_linked_scenario', command='cargo test --locked --test payment_compliance_tests when_payer_designates_a_period_then_that_due_is_settled_before_older_dues' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic13_closed_period_linked_scenarios', command='cargo test --locked --test billing_period_lifecycle_tests' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic13_due_day_month_end_linked_scenario', command='cargo test --locked --test accrual_schedule_tests when_the_due_day_is_beyond_the_month_end_then_it_falls_on_the_last_day' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic13_sale_departure_joint_payment_linked_scenario', command='cargo test --locked --test accrual_corrections_tests when_a_paid_month_is_split' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic13_capital_project_sale_override_linked_scenario', command='cargo test --locked --test sale_clearance_tests statement_itemizes_seller_debt' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic13_supplementary_charge_linked_scenario', command='cargo test --locked --test supplementary_charge_tests when_the_charge_is_created_late' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic13_catch_up_grace_reversal_linked_scenario', command='cargo test --locked --test payment_ledger_hardening_tests when_a_settled_payment_is_reversed' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic13_unmatched_multi_debtor_transfer_linked_scenario', command='cargo test --locked --test bank_multi_debtor_tests' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | — | passed | — | lint |
| unittest | harness-selftest | test_ci_mutation_report.CiMutationReportTest.test_aggregate_reports_combines_layers_and_scores | — | passed | — | lint |
| unittest | harness-selftest | test_ci_mutation_report.CiMutationReportTest.test_main_with_nested_artifact_directories_and_strict | — | passed | — | lint |
| unittest | harness-selftest | test_ci_suite_collection.SuiteCollectionTests.test_cancelled_not_run_and_missing_inputs_are_distinct | — | passed | — | lint |
| unittest | harness-selftest | test_ci_suite_collection.SuiteCollectionTests.test_duplicate_cases_are_preserved_as_attempts_but_not_unique_ids | — | passed | — | lint |
| unittest | harness-selftest | test_ci_suite_collection.SuiteCollectionTests.test_explicit_native_count_mismatch_marks_gate_and_suite_incomplete | — | passed | — | lint |
| unittest | harness-selftest | test_ci_suite_collection.SuiteCollectionTests.test_scenario_linking_does_not_fall_back_to_basename | — | passed | — | lint |
| unittest | harness-selftest | test_ci_suite_collection.SuiteCollectionTests.test_selects_latest_attempt_and_marks_unavailable_shards | — | passed | — | lint |
| unittest | harness-selftest | test_ci_test_report.CiTestReportTest.test_attempt_metadata_selects_latest_artifact_for_history_and_report | — | passed | — | lint |
| unittest | harness-selftest | test_ci_test_report.CiTestReportTest.test_incomplete_suite_count_includes_mixed_and_reused_evidence | — | passed | — | lint |
| unittest | harness-selftest | test_ci_test_report.CiTestReportTest.test_malformed_execution_records_keep_valid_evidence_and_mark_incomplete | — | passed | — | lint |
| unittest | harness-selftest | test_ci_test_report.CiTestReportTest.test_merges_shards_into_report_without_changing_history | — | passed | — | lint |
| unittest | harness-selftest | test_ci_test_report.CiTestReportTest.test_no_shard_results_still_writes_a_report | — | passed | — | lint |
| unittest | harness-selftest | test_ci_test_report.CiTestReportTest.test_workflow_upload_and_consume_the_producer_attempt_payload | — | passed | — | lint |
| unittest | harness-selftest | test_e2e_shard.AssignTests.test_balances_by_duration | — | passed | — | lint |
| unittest | harness-selftest | test_e2e_shard.AssignTests.test_deterministic_regardless_of_input_order | — | passed | — | lint |
| unittest | harness-selftest | test_e2e_shard.AssignTests.test_every_test_in_exactly_one_shard | — | passed | — | lint |
| unittest | harness-selftest | test_e2e_shard.AssignTests.test_more_shards_than_tests_leaves_empty_shards | — | passed | — | lint |
| unittest | harness-selftest | test_e2e_shard.AssignTests.test_unknown_tests_use_median | — | passed | — | lint |
| unittest | harness-selftest | test_e2e_shard.LoadDurationsTests.test_committed_history_is_readable | — | passed | — | lint |
| unittest | harness-selftest | test_e2e_shard.LoadDurationsTests.test_latest_duration_per_test_wins_and_skips_ignored | — | passed | — | lint |
| unittest | harness-selftest | test_e2e_shard.ParseShardTests.test_invalid | — | passed | — | lint |
| unittest | harness-selftest | test_e2e_shard.ParseShardTests.test_valid | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.CatalogueTests.test_closed_issue_lookup_is_best_effort | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.CatalogueTests.test_duplicate_foreign_and_untagged_scenarios_are_reported | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.CatalogueTests.test_linked_scenario_without_a_covering_test_is_reported | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.CatalogueTests.test_parses_tags_steps_and_modes | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.CatalogueTests.test_pending_note_citing_a_closed_issue_is_a_warning_not_a_failure | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.CatalogueTests.test_pending_note_joins_continuation_lines_and_ignores_other_comments | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.CatalogueTests.test_pending_scenario_without_a_reason_is_reported | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.CatalogueTests.test_repository_catalogue_is_consistent | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.CatalogueTests.test_story_without_scenario_is_reported | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.CatalogueTests.test_valid_workspace_has_no_problems | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.ReportTests.test_history_is_newest_first_per_scenario_and_aggregated_per_story | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.ReportTests.test_html_report_shows_scenarios_steps_and_escapes_text | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.ReportTests.test_latest_linked_record_supersedes_unlinked_gui_failure | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.ReportTests.test_latest_run_wins_and_story_takes_the_worst_status | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.ReportTests.test_run_inventory_deltas_and_dashboard_limit | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.ReportTests.test_run_markdown_lists_result_changes_and_gaps | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.ReportTests.test_runs_report_what_executed_and_what_changed | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.ReportTests.test_unexecuted_scenario_is_not_run | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.StoreTests.test_directory_store_round_trip | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.StoreTests.test_empty_run_is_not_recorded | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.StoreTests.test_git_store_appends_commits_without_touching_the_checkout | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.StoreTests.test_recorded_run_switch_reads_env_then_settings | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.StoreTests.test_require_run_applies_to_task_branches_that_change_behaviour | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.StoreTests.test_run_metadata_shape | — | passed | — | lint |
| unittest | harness-selftest | test_flutter_reuse_inventory.FlutterReuseInventoryTests.test_check_flag_sets_exit_code | — | passed | — | lint |
| unittest | harness-selftest | test_flutter_reuse_inventory.FlutterReuseInventoryTests.test_clipboard_outside_helper_is_reported | — | passed | — | lint |
| unittest | harness-selftest | test_flutter_reuse_inventory.FlutterReuseInventoryTests.test_comments_are_ignored | — | passed | — | lint |
| unittest | harness-selftest | test_flutter_reuse_inventory.FlutterReuseInventoryTests.test_counts_token_adoption_in_ui_only | — | passed | — | lint |
| unittest | harness-selftest | test_flutter_reuse_inventory.FlutterReuseInventoryTests.test_json_decimal_fallback_and_bank_amount_normalisation | — | passed | — | lint |
| unittest | harness-selftest | test_flutter_reuse_inventory.FlutterReuseInventoryTests.test_money_parse_in_ui_but_not_domain | — | passed | — | lint |
| unittest | harness-selftest | test_flutter_reuse_inventory.FlutterReuseInventoryTests.test_person_text_inputs_outside_the_shared_form_are_reported | — | passed | — | lint |
| unittest | harness-selftest | test_flutter_reuse_inventory.FlutterReuseInventoryTests.test_raw_chip_selection_page_and_snackbar_are_reported | — | passed | — | lint |
| unittest | harness-selftest | test_gate_cache.GateCacheTest.test_disabled_without_env | — | passed | — | lint |
| unittest | harness-selftest | test_gate_cache.GateCacheTest.test_pass_is_reused_and_failure_is_not | — | passed | — | lint |
| unittest | harness-selftest | test_gui_traceability.GuiTraceabilityTests.test_every_story_has_a_scenario_or_a_written_exclusion | — | passed | — | lint |
| unittest | harness-selftest | test_gui_traceability.GuiTraceabilityTests.test_markdown_section_is_delimited | — | passed | — | lint |
| unittest | harness-selftest | test_gui_traceability.GuiTraceabilityTests.test_outcomes_map_to_story_status | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestCli.test_failures_consume_the_budget_then_block | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestCli.test_record_is_reserved_for_ci | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestCli.test_record_refuses_incomplete_dependencies | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestCli.test_record_writes_evidence_and_status | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestCli.test_verify_is_read_only_by_default | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestDagValidation.test_cycles_and_duplicates_are_rejected | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestDagValidation.test_invalid_file_raises | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestDagValidation.test_runnable_requires_completed_dependencies | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestDagValidation.test_save_is_atomic_and_preserves_top_level_keys | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestDagValidation.test_task_without_any_check_is_rejected | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestDagValidation.test_unknown_dependency_is_rejected | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestDagValidation.test_unknown_gate_and_malformed_test_id_are_rejected | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestDagValidation.test_valid_dag_loads | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestGatesAndLoop.test_acceptance_id_format | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestGatesAndLoop.test_failing_command_reports_diagnostics | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestGatesAndLoop.test_missing_tool_fails_the_gate | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestGatesAndLoop.test_retry_budget | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestGatesAndLoop.test_rust_test_lines_are_parsed_per_test | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestGatesAndLoop.test_task_with_nothing_to_run_cannot_pass | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestGatesAndLoop.test_unknown_gate_fails | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestPersistenceLint.test_backend_passes_persistence_lint | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestPersistenceLint.test_service_repository_boundary_violation_caught | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestProjectData.test_project_dag_is_valid | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestProjectData.test_project_rtm_is_consistent | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestRtmValidator.test_named_test_must_have_passed | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestRtmValidator.test_unverified_requirements_need_no_evidence | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestRtmValidator.test_unverified_rtm_with_completed_task_fails_unless_recording | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestRtmValidator.test_verified_with_passing_evidence_passes_and_stale_commit_fails | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestRtmValidator.test_verified_without_evidence_fails | — | passed | — | lint |
| unittest | harness-selftest | test_journey_attempts.JourneyAttemptTests.test_active_manifest_is_not_reclaimed | — | passed | — | lint |
| unittest | harness-selftest | test_journey_attempts.JourneyAttemptTests.test_clock_client_rejects_unknown_and_incomplete_commands | — | passed | — | lint |
| unittest | harness-selftest | test_journey_attempts.JourneyAttemptTests.test_clock_client_uses_e2e_control_endpoint_and_enforces_monotonic_advance | — | passed | — | lint |
| unittest | harness-selftest | test_journey_attempts.JourneyAttemptTests.test_evidence_failure_does_not_skip_teardown_and_keeps_original_error | — | passed | — | lint |
| unittest | harness-selftest | test_journey_attempts.JourneyAttemptTests.test_make_viban_generates_valid_checksum | — | passed | — | lint |
| unittest | harness-selftest | test_journey_attempts.JourneyAttemptTests.test_make_viban_matches_reference_vector | — | passed | — | lint |
| unittest | harness-selftest | test_journey_attempts.JourneyAttemptTests.test_manifest_persists_each_created_resource_without_personal_data | — | passed | — | lint |
| unittest | harness-selftest | test_journey_attempts.JourneyAttemptTests.test_site_in_state_f3_creates_period_and_structure | — | passed | — | lint |
| unittest | harness-selftest | test_journey_attempts.JourneyAttemptTests.test_site_in_state_unknown_state_raises_value_error | — | passed | — | lint |
| unittest | harness-selftest | test_journey_attempts.JourneyAttemptTests.test_stale_manifest_for_another_database_is_not_reclaimed | — | passed | — | lint |
| unittest | harness-selftest | test_journey_attempts.JourneyAttemptTests.test_stale_manifest_is_reclaimed_only_for_its_database | — | passed | — | lint |
| unittest | harness-selftest | test_journey_attempts.JourneyAttemptTests.test_stale_recovery_skips_corrupt_manifests_and_continues | — | passed | — | lint |
| unittest | harness-selftest | test_journey_attempts.JourneyAttemptTests.test_successful_evidence_and_cleanup_reraise_original_journey_failure | — | passed | — | lint |
| unittest | harness-selftest | test_journey_attempts.JourneyAttemptTests.test_teardown_is_idempotent_and_scoped_to_manifest_site_ids | — | passed | — | lint |
| unittest | harness-selftest | test_journey_attempts.JourneyAttemptTests.test_teardown_rejects_untrusted_site_ids_before_running_sql | — | passed | — | lint |
| unittest | harness-selftest | test_journey_reconciliation.JourneyReconciliationTest.test_final_checkpoint | — | passed | — | lint |
| unittest | harness-selftest | test_logging_standards_lint.LoggingStandardsLintTests.test_debug_print_ratchet_tracks_counts | — | passed | — | lint |
| unittest | harness-selftest | test_logging_standards_lint.LoggingStandardsLintTests.test_println_and_dbg_are_reported_in_backend | — | passed | — | lint |
| unittest | harness-selftest | test_logging_standards_lint.LoggingStandardsLintTests.test_println_is_allowed_in_bin_and_cfg_test | — | passed | — | lint |
| unittest | harness-selftest | test_logging_standards_lint.LoggingStandardsLintTests.test_raw_print_is_reported_in_flutter | — | passed | — | lint |
| unittest | harness-selftest | test_logging_standards_lint.LoggingStandardsLintTests.test_real_workspace_passes | — | passed | — | lint |
| unittest | harness-selftest | test_logging_standards_lint.LoggingStandardsLintTests.test_sensitive_logging_is_reported | — | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_migrations_exist | — | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V12__financial_and_tenancy_remediation.sql', column='principal_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V12__financial_and_tenancy_remediation.sql', column='penalty_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V12__financial_and_tenancy_remediation.sql', column='amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V18__payments_phase2.sql', column='baseline_annual_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V18__payments_phase2.sql', column='total_annual_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V18__payments_phase2.sql', column='annual_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V18__payments_phase2.sql', column='annual_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V18__payments_phase2.sql', column='monthly_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V18__payments_phase2.sql', column='amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V18__payments_phase2.sql', column='fee_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V1__init_schema.sql', column='exit_balance' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V1__init_schema.sql', column='principal_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V1__init_schema.sql', column='delay_penalty' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V1__init_schema.sql', column='paid_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V1__init_schema.sql', column='dues_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='max_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='net_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='vat_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='total_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='opened_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='bank_closing_balance' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='total_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='principal_before' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='penalty_before' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='total_cost' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='fixed_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='consumption_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='total_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='monthly_fee' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='net_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='vat_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='total_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V38__accrual_corrections.sql', column='amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V38__accrual_corrections.sql', column='principal_before' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V38__accrual_corrections.sql', column='penalty_before' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V38__accrual_corrections.sql', column='penalty_reversed' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V39__advance_exit_settlements.sql', column='amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V39__advance_exit_settlements.sql', column='amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V40__late_fee_accruals.sql', column='outstanding_principal' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V40__late_fee_accruals.sql', column='cumulative_fee' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V40__late_fee_accruals.sql', column='daily_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V5__payment_tracking_and_receipts.sql', column='total_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V5__payment_tracking_and_receipts.sql', column='allocated_principal' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V5__payment_tracking_and_receipts.sql', column='allocated_penalty' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V5__payment_tracking_and_receipts.sql', column='amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V5__payment_tracking_and_receipts.sql', column='accrued_delay_penalty' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V5__payment_tracking_and_receipts.sql', column='total_outstanding' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V5__payment_tracking_and_receipts.sql', column='balance' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V5__payment_tracking_and_receipts.sql', column='amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V5__payment_tracking_and_receipts.sql', column='outstanding_balance' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V6__capital_expenditure_and_fixtures.sql', column='total_budget' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V6__capital_expenditure_and_fixtures.sql', column='contract_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V6__capital_expenditure_and_fixtures.sql', column='amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | — | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V10__ledger_and_referential_integrity.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V11__consolidate_household_members.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V12__financial_and_tenancy_remediation.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V13__security_hardening.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V14__referential_ledger_and_vocabulary_integrity.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V15__duplicated_facts_sync_and_pii.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V16__payment_ledger_integrity.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V17__payment_ledger_hardening.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V18__payments_phase2.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V19__authentication_authorization_audit.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V1__init_schema.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V20__payments_phase3.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V21__person_tenant_scope_and_account_activation.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V22__household_relationship_codes.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V23__derived_person_roles.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V24__person_contact_preferences.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V25__tenant_row_level_security.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V26__saas_site_onboarding_scope.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V27__seed_initial_owner_occupancies.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V28__site_announcements.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V29__allow_reuse_of_deleted_site_slugs.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V2__saas_multi_tenancy.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V30__release_identity_uniqueness_for_archived_records.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V31__unit_state_model.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V32__unit_responsible_contact.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V33__person_schema_foundations.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V34__person_merge_canonical.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V35__role_free_person_cards.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V36__revoke_migration_helpers_from_public.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V37__canonical_billing_period_and_accrual_runs.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V38__accrual_corrections.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V39__advance_exit_settlements.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V3__auth_and_permission_providers.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V40__late_fee_accruals.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V41__penalty_reevaluation_adjustments.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V42__accrual_schedule.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V43__billing_period_close_snapshots.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V44__occupancy_aware_dues_proration.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V45__effective_due_date.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V46__supplementary_charges.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V47__tenant_joint_liability_owners.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V48__seller_pays_overrides.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V49__reconciliation_match_assignments.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V4__site_bank_account.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V50__dues_liabilities_liable_person_unique_index.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V51__unit_monthly_tariff_override.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V5__payment_tracking_and_receipts.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V6__capital_expenditure_and_fixtures.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V7__viable_occupancy_ownership_and_identity.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V8__schema_integrity_fixes.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V9__referential_and_financial_integrity.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | — | passed | — | lint |
| unittest | harness-selftest | test_mutation_scenarios.CatalogueDriftTest.test_every_layer_and_risk_is_known | — | passed | — | lint |
| unittest | harness-selftest | test_mutation_scenarios.CatalogueDriftTest.test_every_scenario_applies_to_the_current_code | — | passed | — | lint |
| unittest | harness-selftest | test_mutation_scenarios.RunScenarioTest.test_compile_error_is_unviable_not_killed | — | passed | — | lint |
| unittest | harness-selftest | test_mutation_scenarios.RunScenarioTest.test_failing_suite_kills_and_file_is_restored | — | passed | — | lint |
| unittest | harness-selftest | test_mutation_scenarios.RunScenarioTest.test_file_is_restored_when_the_runner_raises | — | passed | — | lint |
| unittest | harness-selftest | test_mutation_scenarios.RunScenarioTest.test_journal_is_specific_to_this_checkout | — | passed | — | lint |
| unittest | harness-selftest | test_mutation_scenarios.RunScenarioTest.test_passing_suites_mean_survived | — | passed | — | lint |
| unittest | harness-selftest | test_mutation_scenarios.RunScenarioTest.test_restore_ignores_an_entry_from_another_checkout | — | passed | — | lint |
| unittest | harness-selftest | test_mutation_scenarios.RunScenarioTest.test_restore_uses_the_journal | — | passed | — | lint |
| unittest | harness-selftest | test_mutation_scenarios.RunScenarioTest.test_suite_needing_a_missing_capability_is_skipped | — | passed | — | lint |
| unittest | harness-selftest | test_mutation_scenarios.RunScenarioTest.test_timeout_stops_the_whole_process_group | — | passed | — | lint |
| unittest | harness-selftest | test_mutation_scenarios.SelectionAndStrictTest.test_detect_changed_files_invalid_base_raises | — | passed | — | lint |
| unittest | harness-selftest | test_mutation_scenarios.SelectionAndStrictTest.test_main_changed_with_invalid_base_returns_exit_code_2 | — | passed | — | lint |
| unittest | harness-selftest | test_mutation_scenarios.SelectionAndStrictTest.test_parse_git_output_paths_status_and_diff | — | passed | — | lint |
| unittest | harness-selftest | test_mutation_scenarios.SelectionAndStrictTest.test_select_filters_by_changed_files | — | passed | — | lint |
| unittest | harness-selftest | test_mutation_scenarios.SelectionAndStrictTest.test_strict_mode_exit_code | — | passed | — | lint |
| unittest | harness-selftest | test_mutation_scenarios.SummaryTest.test_score_ignores_unviable_timeout_and_skipped | — | passed | — | lint |
| unittest | harness-selftest | test_mutation_scenarios.ValidateTest.test_reports_missing_ambiguous_and_identical_snippets | — | passed | — | lint |
| unittest | harness-selftest | test_product_status.CatalogueHistoryTest.test_directory_outside_git_has_no_history | — | passed | — | lint |
| unittest | harness-selftest | test_product_status.CatalogueHistoryTest.test_history_has_one_point_per_day_and_lists_what_was_added | — | passed | — | lint |
| unittest | harness-selftest | test_product_status.DashboardTest.test_dashboard_needs_a_full_snapshot | — | passed | — | lint |
| unittest | harness-selftest | test_product_status.DashboardTest.test_dashboard_shows_epics_trends_and_escapes_text | — | passed | — | lint |
| unittest | harness-selftest | test_product_status.DashboardTest.test_site_snapshots_are_read_oldest_first_with_links | — | passed | — | lint |
| unittest | harness-selftest | test_product_status.SnapshotTest.test_epic_is_verified_only_when_every_scenario_passes | — | passed | — | lint |
| unittest | harness-selftest | test_product_status.SnapshotTest.test_scenario_state_uses_only_the_tests_that_ran | — | passed | — | lint |
| unittest | harness-selftest | test_product_status.SnapshotTest.test_snapshot_counts_states_per_epic | — | passed | — | lint |
| unittest | harness-selftest | test_product_status.SnapshotTest.test_summary_fallback_reads_the_time_from_the_run_id | — | passed | — | lint |
| unittest | harness-selftest | test_publish_test_report.PublishTestReportTests.test_root_is_the_product_status_dashboard_when_runs_carry_a_snapshot | — | passed | — | lint |
| unittest | harness-selftest | test_publish_test_report.PublishTestReportTests.test_root_opens_latest_dashboard_and_history_keeps_all_runs | — | passed | — | lint |
| unittest | harness-selftest | test_publish_test_report.PublishTestReportTests.test_workflow_copies_every_script_the_publisher_imports | — | passed | — | lint |
| unittest | harness-selftest | test_run_tests_groups.GateGroupTests.test_ci_runs_every_group | — | passed | — | lint |
| unittest | harness-selftest | test_run_tests_groups.GateGroupTests.test_every_gate_is_known | — | passed | — | lint |
| unittest | harness-selftest | test_run_tests_groups.GateGroupTests.test_groups_partition_order | — | passed | — | lint |
| unittest | harness-selftest | test_run_tests_groups.GateGroupTests.test_lint_gates_run_before_compiles | — | passed | — | lint |
| unittest | harness-selftest | test_run_tests_groups.GateGroupTests.test_report_gate_manifest_tracks_ci_group_partition | — | passed | — | lint |
| unittest | harness-selftest | test_run_tests_groups.GateGroupTests.test_unknown_group_is_rejected | — | passed | — | lint |
| unittest | harness-selftest | test_rust_standards_lint.RustStandardsLintTests.test_ad_hoc_hash_outside_fingerprint | — | passed | — | lint |
| unittest | harness-selftest | test_rust_standards_lint.RustStandardsLintTests.test_comments_strings_and_test_modules_are_ignored | — | passed | — | lint |
| unittest | harness-selftest | test_rust_standards_lint.RustStandardsLintTests.test_domain_must_not_depend_on_infrastructure | — | passed | — | lint |
| unittest | harness-selftest | test_rust_standards_lint.RustStandardsLintTests.test_flatten_in_query_extracted_struct_is_reported | — | passed | — | lint |
| unittest | harness-selftest | test_rust_standards_lint.RustStandardsLintTests.test_implicit_rounding_and_floats_are_reported | — | passed | — | lint |
| unittest | harness-selftest | test_rust_standards_lint.RustStandardsLintTests.test_inline_email_normalization_is_reported | — | passed | — | lint |
| unittest | harness-selftest | test_rust_standards_lint.RustStandardsLintTests.test_inline_iban_check_is_reported | — | passed | — | lint |
| unittest | harness-selftest | test_rust_standards_lint.RustStandardsLintTests.test_inline_turkish_folding_is_reported_outside_domain_text | — | passed | — | lint |
| unittest | harness-selftest | test_rust_standards_lint.RustStandardsLintTests.test_non_english_identifier_is_reported_but_turkish_text_is_not | — | passed | — | lint |
| unittest | harness-selftest | test_rust_standards_lint.RustStandardsLintTests.test_only_handlers_may_import_handlers | — | passed | — | lint |
| unittest | harness-selftest | test_rust_standards_lint.RustStandardsLintTests.test_person_inserts_are_confined_to_repository | — | passed | — | lint |
| unittest | harness-selftest | test_rust_standards_lint.RustStandardsLintTests.test_ratchet_fails_only_when_count_rises | — | passed | — | lint |
| unittest | harness-selftest | test_rust_standards_lint.RustStandardsLintTests.test_real_backend_passes | — | passed | — | lint |
| unittest | harness-selftest | test_rust_standards_lint.RustStandardsLintTests.test_regex_must_be_a_lazy_static | — | passed | — | lint |
| unittest | harness-selftest | test_rust_standards_lint.RustStandardsLintTests.test_string_error_counts_services_only | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.BackendRules.test_error_leak_ratchet | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.BackendRules.test_permissive_cors_and_weak_crypto | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.BackendRules.test_reviewed_public_route_passes_and_new_one_fails | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.BackendRules.test_system_route_must_be_development_and_guard_must_refuse_production | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.ClientAndToolingRules.test_accepted_finding_is_not_reported | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.ClientAndToolingRules.test_token_in_browser_storage | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.ClientAndToolingRules.test_unsafe_python | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.DependencyAudit.test_aliases_merge_and_allowlist_expiry | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.DependencyAudit.test_cargo_lock_keeps_registry_packages_only | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.DependencyAudit.test_pubspec_lock_keeps_hosted_packages_only | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.DependencyAudit.test_real_lock_files_parse | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.RepositoryState.test_repository_passes_with_committed_baseline | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.SecretRules.test_descriptive_ci_placeholder_is_not_a_secret | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.SecretRules.test_entropy_threshold_separates_secrets_from_repetitive_values | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.SecretRules.test_env_backup_is_a_tracked_secret_file | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.SecretRules.test_env_example_with_empty_values_passes | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.SecretRules.test_private_key_block_and_key_file | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.WorkflowAndImageRules.test_unpinned_images | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.WorkflowAndImageRules.test_untrusted_context_in_script_and_target_trigger | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.WorkflowAndImageRules.test_workflow_needs_permissions | — | passed | — | lint |
| unittest | harness-selftest | test_tenant_isolation_lint.LockScopeLintTests.test_allow_marker_opts_out | — | passed | — | lint |
| unittest | harness-selftest | test_tenant_isolation_lint.LockScopeLintTests.test_await_on_its_own_line_is_still_found | — | passed | — | lint |
| unittest | harness-selftest | test_tenant_isolation_lint.LockScopeLintTests.test_dropped_or_closed_guards_pass | — | passed | — | lint |
| unittest | harness-selftest | test_tenant_isolation_lint.LockScopeLintTests.test_write_guard_held_across_database_io | — | passed | — | lint |
| unittest | harness-selftest | test_tenant_isolation_lint.TenantIsolationLintTests.test_an_unparseable_router_fails_loudly | — | passed | — | lint |
| unittest | harness-selftest | test_tenant_isolation_lint.TenantIsolationLintTests.test_authz_context_handler_needs_a_site_check | — | passed | — | lint |
| unittest | harness-selftest | test_tenant_isolation_lint.TenantIsolationLintTests.test_authz_context_handler_that_checks_the_site_passes | — | passed | — | lint |
| unittest | harness-selftest | test_tenant_isolation_lint.TenantIsolationLintTests.test_guessed_tenant_fallbacks_are_flagged_outside_fixtures_and_tests | — | passed | — | lint |
| unittest | harness-selftest | test_tenant_isolation_lint.TenantIsolationLintTests.test_object_path_needs_a_scope_unless_the_middleware_owns_it | — | passed | — | lint |
| unittest | harness-selftest | test_tenant_isolation_lint.TenantIsolationLintTests.test_route_table_style_is_parsed | — | passed | — | lint |
| unittest | harness-selftest | test_tenant_isolation_lint.TenantIsolationLintTests.test_scoped_and_site_free_handlers_pass | — | passed | — | lint |
| unittest | harness-selftest | test_tenant_isolation_lint.TenantIsolationLintTests.test_service_transactions_must_bind_their_tenant | — | passed | — | lint |
| unittest | harness-selftest | test_tenant_isolation_lint.TenantIsolationLintTests.test_site_input_without_scope_is_flagged | — | passed | — | lint |
| unittest | harness-selftest | test_tenant_isolation_lint.TenantIsolationLintTests.test_tenant_keyed_tables_need_a_policy | — | passed | — | lint |
| unittest | harness-selftest | test_testid_lint.TestIdLintTests.test_ignore_pragma_exempts_state_keys | — | passed | — | lint |
| unittest | harness-selftest | test_testid_lint.TestIdLintTests.test_key_without_testid_is_reported | — | passed | — | lint |
| unittest | harness-selftest | test_testid_lint.TestIdLintTests.test_matching_testid_passes_including_interpolation | — | passed | — | lint |
| unittest | harness-selftest | test_testid_lint.TestIdLintTests.test_quote_style_does_not_matter | — | passed | — | lint |
| unittest | harness-selftest | test_testid_lint.TestIdLintTests.test_real_ui_has_no_missing_testids | — | passed | — | lint |
| unittest | harness-selftest | test_testid_lint.TestIdLintTests.test_unwrappable_constructor_is_skipped | — | passed | — | lint |
| unittest | harness-selftest | test_testid_lint.TestIdLintTests.test_variable_and_global_keys_are_not_ids | — | passed | — | lint |
| unittest | harness-selftest | test_ui_style_lint.UiStyleLintTests.test_deprecated_sheet_container_is_exempt_from_popup_rule | — | passed | — | lint |
| unittest | harness-selftest | test_ui_style_lint.UiStyleLintTests.test_emoji_in_string_is_reported_but_not_in_comments | — | passed | — | lint |
| unittest | harness-selftest | test_ui_style_lint.UiStyleLintTests.test_font_at_floor_passes | — | passed | — | lint |
| unittest | harness-selftest | test_ui_style_lint.UiStyleLintTests.test_font_below_floor_is_reported | — | passed | — | lint |
| unittest | harness-selftest | test_ui_style_lint.UiStyleLintTests.test_full_screen_pages_and_comments_pass | — | passed | — | lint |
| unittest | harness-selftest | test_ui_style_lint.UiStyleLintTests.test_hand_printed_money_is_reported | — | passed | — | lint |
| unittest | harness-selftest | test_ui_style_lint.UiStyleLintTests.test_money_formatter_passes | — | passed | — | lint |
| unittest | harness-selftest | test_ui_style_lint.UiStyleLintTests.test_popups_are_reported | — | passed | — | lint |
| unittest | harness-selftest | test_ui_style_lint.UiStyleLintTests.test_ratchet_blocks_new_literals_outside_theme | — | passed | — | lint |
| unittest | harness-selftest | test_ui_style_lint.UiStyleLintTests.test_real_ui_passes_with_committed_baseline | — | passed | — | lint |
| unittest | harness-selftest | test_ui_style_lint.UiStyleLintTests.test_stand_in_google_icon_is_reported | — | passed | — | lint |
| unittest | harness-selftest | test_ui_style_lint.UiStyleLintTests.test_without_baseline_counts_are_reported_only | — | passed | — | lint |
| unittest | harness-selftest | test_api_system_check.PublicRouteMirrorTests.test_drift_reports_both_directions | — | passed | — | lint |
| unittest | harness-selftest | test_api_system_check.PublicRouteMirrorTests.test_parser_reads_only_public_policy | — | passed | — | lint |
| unittest | harness-selftest | test_api_system_check.PublicRouteMirrorTests.test_public_routes_mirror_matches_app_rs | — | passed | — | lint |
| unittest | harness-selftest | test_ci_case_results.CaseAdapterTests.test_api_and_schema_json_rows_become_cases | — | passed | — | lint |
| unittest | harness-selftest | test_ci_case_results.CaseAdapterTests.test_cargo_parser_keeps_doctest_names_and_ignored_status | — | passed | — | lint |
| unittest | harness-selftest | test_ci_case_results.CaseAdapterTests.test_expected_manifest_includes_eight_shards_and_opt_in_database_cases | — | passed | — | lint |
| unittest | harness-selftest | test_ci_case_results.CaseAdapterTests.test_flutter_ids_include_file_path_and_malformed_json_is_ignored | — | passed | — | lint |
| unittest | harness-selftest | test_ci_case_results.CaseAdapterTests.test_flutter_parser_maps_results_and_runner_error | — | passed | — | lint |
| unittest | harness-selftest | test_ci_case_results.CaseAdapterTests.test_junit_failure_and_error_elements_are_handled_and_bad_times_are_null | — | passed | — | lint |
| unittest | harness-selftest | test_ci_case_results.CaseAdapterTests.test_junit_rows_include_parameterized_names_and_skips | — | passed | — | lint |
| unittest | harness-selftest | test_ci_case_results.CaseAdapterTests.test_unittest_parser_retains_fail_error_and_skip | — | passed | — | lint |
| unittest | harness-selftest | test_ci_case_results.GateCaptureTests.test_process_exit_code_is_preserved_in_gate_and_artifact | — | passed | — | lint |
| unittest | harness-selftest | test_ci_case_results.GateCaptureTests.test_sidecar_write_failure_does_not_change_native_gate_outcome | — | passed | — | lint |
| unittest | harness-selftest | test_ci_case_results.GateCaptureTests.test_unittest_sidecar_failure_keeps_success_exit_status | — | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_ci_ignores_only_the_linked_file | — | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_harness_linked_scenarios', command='<python> -m unittest discover -s harness/tests' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic07_rust_linked_scenarios', command='cargo test --locked --test integration_tests' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic07_billing_period_linked_scenarios', command='cargo test --locked --test billing_period_tests' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic07_proration_linked_scenarios', command='cargo test --locked --test occupancy_proration_tests' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic07_accrual_corrections_linked_scenarios', command='cargo test --locked --test accrual_corrections_tests' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic07_flutter_linked_scenarios', command='flutter test test/dues_management_view_test.dart' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic11_rust_linked_scenarios', command='cargo test --locked --test payments_phase3_tests' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic11_flutter_linked_scenarios', command='flutter test test/payments_phase3_test.dart' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic11_api_linked_scenarios', command='<python> scripts/api_system_check.py --json' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic08_rust_linked_scenarios', command='cargo test --locked --test occupancy_state_machine_tests' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic08_flutter_linked_scenarios', command='flutter test test/unit_workspace_test.dart' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic09_rust_linked_scenarios', command='cargo test --locked --test payment_ledger_hardening_tests' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic09_flutter_linked_scenarios', command='flutter test test/payment_tracking_and_aging_test.dart' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic13_designated_payment_linked_scenario', command='cargo test --locked --test payment_compliance_tests when_payer_designates_a_period_then_that_due_is_settled_before_older_dues' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic13_closed_period_linked_scenarios', command='cargo test --locked --test billing_period_lifecycle_tests' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic13_due_day_month_end_linked_scenario', command='cargo test --locked --test accrual_schedule_tests when_the_due_day_is_beyond_the_month_end_then_it_falls_on_the_last_day' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic13_sale_departure_joint_payment_linked_scenario', command='cargo test --locked --test accrual_corrections_tests when_a_paid_month_is_split' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic13_capital_project_sale_override_linked_scenario', command='cargo test --locked --test sale_clearance_tests statement_itemizes_seller_debt' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic13_supplementary_charge_linked_scenario', command='cargo test --locked --test supplementary_charge_tests when_the_charge_is_created_late' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic13_catch_up_grace_reversal_linked_scenario', command='cargo test --locked --test payment_ledger_hardening_tests when_a_settled_payment_is_reversed' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | test='test_epic13_unmatched_multi_debtor_transfer_linked_scenario', command='cargo test --locked --test bank_multi_debtor_tests' | passed | — | lint |
| unittest | harness-selftest | test_ci_linked_suites.LinkedSuitesCoveredInCi.test_every_linked_suite_also_runs_in_a_ci_gate | — | passed | — | lint |
| unittest | harness-selftest | test_ci_mutation_report.CiMutationReportTest.test_aggregate_reports_combines_layers_and_scores | — | passed | — | lint |
| unittest | harness-selftest | test_ci_mutation_report.CiMutationReportTest.test_main_with_nested_artifact_directories_and_strict | — | passed | — | lint |
| unittest | harness-selftest | test_ci_suite_collection.SuiteCollectionTests.test_cancelled_not_run_and_missing_inputs_are_distinct | — | passed | — | lint |
| unittest | harness-selftest | test_ci_suite_collection.SuiteCollectionTests.test_duplicate_cases_are_preserved_as_attempts_but_not_unique_ids | — | passed | — | lint |
| unittest | harness-selftest | test_ci_suite_collection.SuiteCollectionTests.test_explicit_native_count_mismatch_marks_gate_and_suite_incomplete | — | passed | — | lint |
| unittest | harness-selftest | test_ci_suite_collection.SuiteCollectionTests.test_scenario_linking_does_not_fall_back_to_basename | — | passed | — | lint |
| unittest | harness-selftest | test_ci_suite_collection.SuiteCollectionTests.test_selects_latest_attempt_and_marks_unavailable_shards | — | passed | — | lint |
| unittest | harness-selftest | test_ci_test_report.CiTestReportTest.test_attempt_metadata_selects_latest_artifact_for_history_and_report | — | passed | — | lint |
| unittest | harness-selftest | test_ci_test_report.CiTestReportTest.test_incomplete_suite_count_includes_mixed_and_reused_evidence | — | passed | — | lint |
| unittest | harness-selftest | test_ci_test_report.CiTestReportTest.test_malformed_execution_records_keep_valid_evidence_and_mark_incomplete | — | passed | — | lint |
| unittest | harness-selftest | test_ci_test_report.CiTestReportTest.test_merges_shards_into_report_without_changing_history | — | passed | — | lint |
| unittest | harness-selftest | test_ci_test_report.CiTestReportTest.test_no_shard_results_still_writes_a_report | — | passed | — | lint |
| unittest | harness-selftest | test_ci_test_report.CiTestReportTest.test_workflow_upload_and_consume_the_producer_attempt_payload | — | passed | — | lint |
| unittest | harness-selftest | test_e2e_shard.AssignTests.test_balances_by_duration | — | passed | — | lint |
| unittest | harness-selftest | test_e2e_shard.AssignTests.test_deterministic_regardless_of_input_order | — | passed | — | lint |
| unittest | harness-selftest | test_e2e_shard.AssignTests.test_every_test_in_exactly_one_shard | — | passed | — | lint |
| unittest | harness-selftest | test_e2e_shard.AssignTests.test_more_shards_than_tests_leaves_empty_shards | — | passed | — | lint |
| unittest | harness-selftest | test_e2e_shard.AssignTests.test_unknown_tests_use_median | — | passed | — | lint |
| unittest | harness-selftest | test_e2e_shard.LoadDurationsTests.test_committed_history_is_readable | — | passed | — | lint |
| unittest | harness-selftest | test_e2e_shard.LoadDurationsTests.test_latest_duration_per_test_wins_and_skips_ignored | — | passed | — | lint |
| unittest | harness-selftest | test_e2e_shard.ParseShardTests.test_invalid | — | passed | — | lint |
| unittest | harness-selftest | test_e2e_shard.ParseShardTests.test_valid | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.CatalogueTests.test_closed_issue_lookup_is_best_effort | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.CatalogueTests.test_duplicate_foreign_and_untagged_scenarios_are_reported | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.CatalogueTests.test_linked_scenario_without_a_covering_test_is_reported | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.CatalogueTests.test_parses_tags_steps_and_modes | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.CatalogueTests.test_pending_note_citing_a_closed_issue_is_a_warning_not_a_failure | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.CatalogueTests.test_pending_note_joins_continuation_lines_and_ignores_other_comments | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.CatalogueTests.test_pending_scenario_without_a_reason_is_reported | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.CatalogueTests.test_repository_catalogue_is_consistent | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.CatalogueTests.test_story_without_scenario_is_reported | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.CatalogueTests.test_valid_workspace_has_no_problems | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.ReportTests.test_history_is_newest_first_per_scenario_and_aggregated_per_story | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.ReportTests.test_html_report_shows_scenarios_steps_and_escapes_text | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.ReportTests.test_latest_linked_record_supersedes_unlinked_gui_failure | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.ReportTests.test_latest_run_wins_and_story_takes_the_worst_status | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.ReportTests.test_run_inventory_deltas_and_dashboard_limit | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.ReportTests.test_run_markdown_lists_result_changes_and_gaps | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.ReportTests.test_runs_report_what_executed_and_what_changed | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.ReportTests.test_unexecuted_scenario_is_not_run | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.StoreTests.test_directory_store_round_trip | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.StoreTests.test_empty_run_is_not_recorded | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.StoreTests.test_git_store_appends_commits_without_touching_the_checkout | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.StoreTests.test_recorded_run_switch_reads_env_then_settings | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.StoreTests.test_require_run_applies_to_task_branches_that_change_behaviour | — | passed | — | lint |
| unittest | harness-selftest | test_feature_traceability.StoreTests.test_run_metadata_shape | — | passed | — | lint |
| unittest | harness-selftest | test_flutter_reuse_inventory.FlutterReuseInventoryTests.test_check_flag_sets_exit_code | — | passed | — | lint |
| unittest | harness-selftest | test_flutter_reuse_inventory.FlutterReuseInventoryTests.test_clipboard_outside_helper_is_reported | — | passed | — | lint |
| unittest | harness-selftest | test_flutter_reuse_inventory.FlutterReuseInventoryTests.test_comments_are_ignored | — | passed | — | lint |
| unittest | harness-selftest | test_flutter_reuse_inventory.FlutterReuseInventoryTests.test_counts_token_adoption_in_ui_only | — | passed | — | lint |
| unittest | harness-selftest | test_flutter_reuse_inventory.FlutterReuseInventoryTests.test_json_decimal_fallback_and_bank_amount_normalisation | — | passed | — | lint |
| unittest | harness-selftest | test_flutter_reuse_inventory.FlutterReuseInventoryTests.test_money_parse_in_ui_but_not_domain | — | passed | — | lint |
| unittest | harness-selftest | test_flutter_reuse_inventory.FlutterReuseInventoryTests.test_person_text_inputs_outside_the_shared_form_are_reported | — | passed | — | lint |
| unittest | harness-selftest | test_flutter_reuse_inventory.FlutterReuseInventoryTests.test_raw_chip_selection_page_and_snackbar_are_reported | — | passed | — | lint |
| unittest | harness-selftest | test_gate_cache.GateCacheTest.test_disabled_without_env | — | passed | — | lint |
| unittest | harness-selftest | test_gate_cache.GateCacheTest.test_pass_is_reused_and_failure_is_not | — | passed | — | lint |
| unittest | harness-selftest | test_gui_traceability.GuiTraceabilityTests.test_every_story_has_a_scenario_or_a_written_exclusion | — | passed | — | lint |
| unittest | harness-selftest | test_gui_traceability.GuiTraceabilityTests.test_markdown_section_is_delimited | — | passed | — | lint |
| unittest | harness-selftest | test_gui_traceability.GuiTraceabilityTests.test_outcomes_map_to_story_status | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestCli.test_failures_consume_the_budget_then_block | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestCli.test_record_is_reserved_for_ci | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestCli.test_record_refuses_incomplete_dependencies | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestCli.test_record_writes_evidence_and_status | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestCli.test_verify_is_read_only_by_default | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestDagValidation.test_cycles_and_duplicates_are_rejected | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestDagValidation.test_invalid_file_raises | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestDagValidation.test_runnable_requires_completed_dependencies | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestDagValidation.test_save_is_atomic_and_preserves_top_level_keys | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestDagValidation.test_task_without_any_check_is_rejected | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestDagValidation.test_unknown_dependency_is_rejected | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestDagValidation.test_unknown_gate_and_malformed_test_id_are_rejected | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestDagValidation.test_valid_dag_loads | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestGatesAndLoop.test_acceptance_id_format | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestGatesAndLoop.test_failing_command_reports_diagnostics | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestGatesAndLoop.test_missing_tool_fails_the_gate | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestGatesAndLoop.test_retry_budget | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestGatesAndLoop.test_rust_test_lines_are_parsed_per_test | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestGatesAndLoop.test_task_with_nothing_to_run_cannot_pass | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestGatesAndLoop.test_unknown_gate_fails | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestPersistenceLint.test_backend_passes_persistence_lint | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestPersistenceLint.test_service_repository_boundary_violation_caught | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestProjectData.test_project_dag_is_valid | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestProjectData.test_project_rtm_is_consistent | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestRtmValidator.test_named_test_must_have_passed | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestRtmValidator.test_unverified_requirements_need_no_evidence | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestRtmValidator.test_unverified_rtm_with_completed_task_fails_unless_recording | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestRtmValidator.test_verified_with_passing_evidence_passes_and_stale_commit_fails | — | passed | — | lint |
| unittest | harness-selftest | test_harness.TestRtmValidator.test_verified_without_evidence_fails | — | passed | — | lint |
| unittest | harness-selftest | test_journey_attempts.JourneyAttemptTests.test_active_manifest_is_not_reclaimed | — | passed | — | lint |
| unittest | harness-selftest | test_journey_attempts.JourneyAttemptTests.test_clock_client_rejects_unknown_and_incomplete_commands | — | passed | — | lint |
| unittest | harness-selftest | test_journey_attempts.JourneyAttemptTests.test_clock_client_uses_e2e_control_endpoint_and_enforces_monotonic_advance | — | passed | — | lint |
| unittest | harness-selftest | test_journey_attempts.JourneyAttemptTests.test_evidence_failure_does_not_skip_teardown_and_keeps_original_error | — | passed | — | lint |
| unittest | harness-selftest | test_journey_attempts.JourneyAttemptTests.test_make_viban_generates_valid_checksum | — | passed | — | lint |
| unittest | harness-selftest | test_journey_attempts.JourneyAttemptTests.test_make_viban_matches_reference_vector | — | passed | — | lint |
| unittest | harness-selftest | test_journey_attempts.JourneyAttemptTests.test_manifest_persists_each_created_resource_without_personal_data | — | passed | — | lint |
| unittest | harness-selftest | test_journey_attempts.JourneyAttemptTests.test_site_in_state_f3_creates_period_and_structure | — | passed | — | lint |
| unittest | harness-selftest | test_journey_attempts.JourneyAttemptTests.test_site_in_state_unknown_state_raises_value_error | — | passed | — | lint |
| unittest | harness-selftest | test_journey_attempts.JourneyAttemptTests.test_stale_manifest_for_another_database_is_not_reclaimed | — | passed | — | lint |
| unittest | harness-selftest | test_journey_attempts.JourneyAttemptTests.test_stale_manifest_is_reclaimed_only_for_its_database | — | passed | — | lint |
| unittest | harness-selftest | test_journey_attempts.JourneyAttemptTests.test_stale_recovery_skips_corrupt_manifests_and_continues | — | passed | — | lint |
| unittest | harness-selftest | test_journey_attempts.JourneyAttemptTests.test_successful_evidence_and_cleanup_reraise_original_journey_failure | — | passed | — | lint |
| unittest | harness-selftest | test_journey_attempts.JourneyAttemptTests.test_teardown_is_idempotent_and_scoped_to_manifest_site_ids | — | passed | — | lint |
| unittest | harness-selftest | test_journey_attempts.JourneyAttemptTests.test_teardown_rejects_untrusted_site_ids_before_running_sql | — | passed | — | lint |
| unittest | harness-selftest | test_journey_reconciliation.JourneyReconciliationTest.test_final_checkpoint | — | passed | — | lint |
| unittest | harness-selftest | test_logging_standards_lint.LoggingStandardsLintTests.test_debug_print_ratchet_tracks_counts | — | passed | — | lint |
| unittest | harness-selftest | test_logging_standards_lint.LoggingStandardsLintTests.test_println_and_dbg_are_reported_in_backend | — | passed | — | lint |
| unittest | harness-selftest | test_logging_standards_lint.LoggingStandardsLintTests.test_println_is_allowed_in_bin_and_cfg_test | — | passed | — | lint |
| unittest | harness-selftest | test_logging_standards_lint.LoggingStandardsLintTests.test_raw_print_is_reported_in_flutter | — | passed | — | lint |
| unittest | harness-selftest | test_logging_standards_lint.LoggingStandardsLintTests.test_real_workspace_passes | — | passed | — | lint |
| unittest | harness-selftest | test_logging_standards_lint.LoggingStandardsLintTests.test_sensitive_logging_is_reported | — | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_migrations_exist | — | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V12__financial_and_tenancy_remediation.sql', column='principal_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V12__financial_and_tenancy_remediation.sql', column='penalty_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V12__financial_and_tenancy_remediation.sql', column='amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V18__payments_phase2.sql', column='baseline_annual_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V18__payments_phase2.sql', column='total_annual_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V18__payments_phase2.sql', column='annual_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V18__payments_phase2.sql', column='annual_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V18__payments_phase2.sql', column='monthly_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V18__payments_phase2.sql', column='amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V18__payments_phase2.sql', column='fee_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V1__init_schema.sql', column='exit_balance' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V1__init_schema.sql', column='principal_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V1__init_schema.sql', column='delay_penalty' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V1__init_schema.sql', column='paid_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V1__init_schema.sql', column='dues_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='max_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='net_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='vat_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='total_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='opened_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='bank_closing_balance' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='total_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='principal_before' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='penalty_before' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='total_cost' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='fixed_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='consumption_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='total_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='monthly_fee' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='net_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='vat_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V20__payments_phase3.sql', column='total_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V38__accrual_corrections.sql', column='amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V38__accrual_corrections.sql', column='principal_before' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V38__accrual_corrections.sql', column='penalty_before' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V38__accrual_corrections.sql', column='penalty_reversed' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V39__advance_exit_settlements.sql', column='amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V39__advance_exit_settlements.sql', column='amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V40__late_fee_accruals.sql', column='outstanding_principal' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V40__late_fee_accruals.sql', column='cumulative_fee' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V40__late_fee_accruals.sql', column='daily_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V5__payment_tracking_and_receipts.sql', column='total_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V5__payment_tracking_and_receipts.sql', column='allocated_principal' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V5__payment_tracking_and_receipts.sql', column='allocated_penalty' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V5__payment_tracking_and_receipts.sql', column='amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V5__payment_tracking_and_receipts.sql', column='accrued_delay_penalty' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V5__payment_tracking_and_receipts.sql', column='total_outstanding' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V5__payment_tracking_and_receipts.sql', column='balance' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V5__payment_tracking_and_receipts.sql', column='amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V5__payment_tracking_and_receipts.sql', column='outstanding_balance' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V6__capital_expenditure_and_fixtures.sql', column='total_budget' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V6__capital_expenditure_and_fixtures.sql', column='contract_amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | migration='V6__capital_expenditure_and_fixtures.sql', column='amount' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_money_columns_are_numeric_15_2 | — | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V10__ledger_and_referential_integrity.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V11__consolidate_household_members.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V12__financial_and_tenancy_remediation.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V13__security_hardening.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V14__referential_ledger_and_vocabulary_integrity.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V15__duplicated_facts_sync_and_pii.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V16__payment_ledger_integrity.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V17__payment_ledger_hardening.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V18__payments_phase2.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V19__authentication_authorization_audit.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V1__init_schema.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V20__payments_phase3.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V21__person_tenant_scope_and_account_activation.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V22__household_relationship_codes.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V23__derived_person_roles.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V24__person_contact_preferences.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V25__tenant_row_level_security.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V26__saas_site_onboarding_scope.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V27__seed_initial_owner_occupancies.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V28__site_announcements.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V29__allow_reuse_of_deleted_site_slugs.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V2__saas_multi_tenancy.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V30__release_identity_uniqueness_for_archived_records.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V31__unit_state_model.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V32__unit_responsible_contact.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V33__person_schema_foundations.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V34__person_merge_canonical.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V35__role_free_person_cards.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V36__revoke_migration_helpers_from_public.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V37__canonical_billing_period_and_accrual_runs.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V38__accrual_corrections.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V39__advance_exit_settlements.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V3__auth_and_permission_providers.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V40__late_fee_accruals.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V41__penalty_reevaluation_adjustments.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V42__accrual_schedule.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V43__billing_period_close_snapshots.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V44__occupancy_aware_dues_proration.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V45__effective_due_date.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V46__supplementary_charges.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V47__tenant_joint_liability_owners.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V48__seller_pays_overrides.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V49__reconciliation_match_assignments.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V4__site_bank_account.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V50__dues_liabilities_liable_person_unique_index.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V51__unit_monthly_tariff_override.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V5__payment_tracking_and_receipts.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V6__capital_expenditure_and_fixtures.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V7__viable_occupancy_ownership_and_identity.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V8__schema_integrity_fixes.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | migration='V9__referential_and_financial_integrity.sql' | passed | — | lint |
| unittest | harness-selftest | test_migration_numeric_policy.MigrationNumericPolicy.test_no_float_or_double_precision_column_in_any_migration | — | passed | — | lint |
| unittest | harness-selftest | test_mutation_scenarios.CatalogueDriftTest.test_every_layer_and_risk_is_known | — | passed | — | lint |
| unittest | harness-selftest | test_mutation_scenarios.CatalogueDriftTest.test_every_scenario_applies_to_the_current_code | — | passed | — | lint |
| unittest | harness-selftest | test_mutation_scenarios.RunScenarioTest.test_compile_error_is_unviable_not_killed | — | passed | — | lint |
| unittest | harness-selftest | test_mutation_scenarios.RunScenarioTest.test_failing_suite_kills_and_file_is_restored | — | passed | — | lint |
| unittest | harness-selftest | test_mutation_scenarios.RunScenarioTest.test_file_is_restored_when_the_runner_raises | — | passed | — | lint |
| unittest | harness-selftest | test_mutation_scenarios.RunScenarioTest.test_journal_is_specific_to_this_checkout | — | passed | — | lint |
| unittest | harness-selftest | test_mutation_scenarios.RunScenarioTest.test_passing_suites_mean_survived | — | passed | — | lint |
| unittest | harness-selftest | test_mutation_scenarios.RunScenarioTest.test_restore_ignores_an_entry_from_another_checkout | — | passed | — | lint |
| unittest | harness-selftest | test_mutation_scenarios.RunScenarioTest.test_restore_uses_the_journal | — | passed | — | lint |
| unittest | harness-selftest | test_mutation_scenarios.RunScenarioTest.test_suite_needing_a_missing_capability_is_skipped | — | passed | — | lint |
| unittest | harness-selftest | test_mutation_scenarios.RunScenarioTest.test_timeout_stops_the_whole_process_group | — | passed | — | lint |
| unittest | harness-selftest | test_mutation_scenarios.SelectionAndStrictTest.test_detect_changed_files_invalid_base_raises | — | passed | — | lint |
| unittest | harness-selftest | test_mutation_scenarios.SelectionAndStrictTest.test_main_changed_with_invalid_base_returns_exit_code_2 | — | passed | — | lint |
| unittest | harness-selftest | test_mutation_scenarios.SelectionAndStrictTest.test_parse_git_output_paths_status_and_diff | — | passed | — | lint |
| unittest | harness-selftest | test_mutation_scenarios.SelectionAndStrictTest.test_select_filters_by_changed_files | — | passed | — | lint |
| unittest | harness-selftest | test_mutation_scenarios.SelectionAndStrictTest.test_strict_mode_exit_code | — | passed | — | lint |
| unittest | harness-selftest | test_mutation_scenarios.SummaryTest.test_score_ignores_unviable_timeout_and_skipped | — | passed | — | lint |
| unittest | harness-selftest | test_mutation_scenarios.ValidateTest.test_reports_missing_ambiguous_and_identical_snippets | — | passed | — | lint |
| unittest | harness-selftest | test_product_status.CatalogueHistoryTest.test_directory_outside_git_has_no_history | — | passed | — | lint |
| unittest | harness-selftest | test_product_status.CatalogueHistoryTest.test_history_has_one_point_per_day_and_lists_what_was_added | — | passed | — | lint |
| unittest | harness-selftest | test_product_status.DashboardTest.test_dashboard_needs_a_full_snapshot | — | passed | — | lint |
| unittest | harness-selftest | test_product_status.DashboardTest.test_dashboard_shows_epics_trends_and_escapes_text | — | passed | — | lint |
| unittest | harness-selftest | test_product_status.DashboardTest.test_site_snapshots_are_read_oldest_first_with_links | — | passed | — | lint |
| unittest | harness-selftest | test_product_status.SnapshotTest.test_epic_is_verified_only_when_every_scenario_passes | — | passed | — | lint |
| unittest | harness-selftest | test_product_status.SnapshotTest.test_scenario_state_uses_only_the_tests_that_ran | — | passed | — | lint |
| unittest | harness-selftest | test_product_status.SnapshotTest.test_snapshot_counts_states_per_epic | — | passed | — | lint |
| unittest | harness-selftest | test_product_status.SnapshotTest.test_summary_fallback_reads_the_time_from_the_run_id | — | passed | — | lint |
| unittest | harness-selftest | test_publish_test_report.PublishTestReportTests.test_root_is_the_product_status_dashboard_when_runs_carry_a_snapshot | — | passed | — | lint |
| unittest | harness-selftest | test_publish_test_report.PublishTestReportTests.test_root_opens_latest_dashboard_and_history_keeps_all_runs | — | passed | — | lint |
| unittest | harness-selftest | test_publish_test_report.PublishTestReportTests.test_workflow_copies_every_script_the_publisher_imports | — | passed | — | lint |
| unittest | harness-selftest | test_run_tests_groups.GateGroupTests.test_ci_runs_every_group | — | passed | — | lint |
| unittest | harness-selftest | test_run_tests_groups.GateGroupTests.test_every_gate_is_known | — | passed | — | lint |
| unittest | harness-selftest | test_run_tests_groups.GateGroupTests.test_groups_partition_order | — | passed | — | lint |
| unittest | harness-selftest | test_run_tests_groups.GateGroupTests.test_lint_gates_run_before_compiles | — | passed | — | lint |
| unittest | harness-selftest | test_run_tests_groups.GateGroupTests.test_report_gate_manifest_tracks_ci_group_partition | — | passed | — | lint |
| unittest | harness-selftest | test_run_tests_groups.GateGroupTests.test_unknown_group_is_rejected | — | passed | — | lint |
| unittest | harness-selftest | test_rust_standards_lint.RustStandardsLintTests.test_ad_hoc_hash_outside_fingerprint | — | passed | — | lint |
| unittest | harness-selftest | test_rust_standards_lint.RustStandardsLintTests.test_comments_strings_and_test_modules_are_ignored | — | passed | — | lint |
| unittest | harness-selftest | test_rust_standards_lint.RustStandardsLintTests.test_domain_must_not_depend_on_infrastructure | — | passed | — | lint |
| unittest | harness-selftest | test_rust_standards_lint.RustStandardsLintTests.test_flatten_in_query_extracted_struct_is_reported | — | passed | — | lint |
| unittest | harness-selftest | test_rust_standards_lint.RustStandardsLintTests.test_implicit_rounding_and_floats_are_reported | — | passed | — | lint |
| unittest | harness-selftest | test_rust_standards_lint.RustStandardsLintTests.test_inline_email_normalization_is_reported | — | passed | — | lint |
| unittest | harness-selftest | test_rust_standards_lint.RustStandardsLintTests.test_inline_iban_check_is_reported | — | passed | — | lint |
| unittest | harness-selftest | test_rust_standards_lint.RustStandardsLintTests.test_inline_turkish_folding_is_reported_outside_domain_text | — | passed | — | lint |
| unittest | harness-selftest | test_rust_standards_lint.RustStandardsLintTests.test_non_english_identifier_is_reported_but_turkish_text_is_not | — | passed | — | lint |
| unittest | harness-selftest | test_rust_standards_lint.RustStandardsLintTests.test_only_handlers_may_import_handlers | — | passed | — | lint |
| unittest | harness-selftest | test_rust_standards_lint.RustStandardsLintTests.test_person_inserts_are_confined_to_repository | — | passed | — | lint |
| unittest | harness-selftest | test_rust_standards_lint.RustStandardsLintTests.test_ratchet_fails_only_when_count_rises | — | passed | — | lint |
| unittest | harness-selftest | test_rust_standards_lint.RustStandardsLintTests.test_real_backend_passes | — | passed | — | lint |
| unittest | harness-selftest | test_rust_standards_lint.RustStandardsLintTests.test_regex_must_be_a_lazy_static | — | passed | — | lint |
| unittest | harness-selftest | test_rust_standards_lint.RustStandardsLintTests.test_string_error_counts_services_only | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.BackendRules.test_error_leak_ratchet | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.BackendRules.test_permissive_cors_and_weak_crypto | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.BackendRules.test_reviewed_public_route_passes_and_new_one_fails | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.BackendRules.test_system_route_must_be_development_and_guard_must_refuse_production | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.ClientAndToolingRules.test_accepted_finding_is_not_reported | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.ClientAndToolingRules.test_token_in_browser_storage | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.ClientAndToolingRules.test_unsafe_python | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.DependencyAudit.test_aliases_merge_and_allowlist_expiry | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.DependencyAudit.test_cargo_lock_keeps_registry_packages_only | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.DependencyAudit.test_pubspec_lock_keeps_hosted_packages_only | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.DependencyAudit.test_real_lock_files_parse | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.RepositoryState.test_repository_passes_with_committed_baseline | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.SecretRules.test_descriptive_ci_placeholder_is_not_a_secret | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.SecretRules.test_entropy_threshold_separates_secrets_from_repetitive_values | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.SecretRules.test_env_backup_is_a_tracked_secret_file | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.SecretRules.test_env_example_with_empty_values_passes | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.SecretRules.test_private_key_block_and_key_file | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.WorkflowAndImageRules.test_unpinned_images | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.WorkflowAndImageRules.test_untrusted_context_in_script_and_target_trigger | — | passed | — | lint |
| unittest | harness-selftest | test_security_lint.WorkflowAndImageRules.test_workflow_needs_permissions | — | passed | — | lint |
| unittest | harness-selftest | test_tenant_isolation_lint.LockScopeLintTests.test_allow_marker_opts_out | — | passed | — | lint |
| unittest | harness-selftest | test_tenant_isolation_lint.LockScopeLintTests.test_await_on_its_own_line_is_still_found | — | passed | — | lint |
| unittest | harness-selftest | test_tenant_isolation_lint.LockScopeLintTests.test_dropped_or_closed_guards_pass | — | passed | — | lint |
| unittest | harness-selftest | test_tenant_isolation_lint.LockScopeLintTests.test_write_guard_held_across_database_io | — | passed | — | lint |
| unittest | harness-selftest | test_tenant_isolation_lint.TenantIsolationLintTests.test_an_unparseable_router_fails_loudly | — | passed | — | lint |
| unittest | harness-selftest | test_tenant_isolation_lint.TenantIsolationLintTests.test_authz_context_handler_needs_a_site_check | — | passed | — | lint |
| unittest | harness-selftest | test_tenant_isolation_lint.TenantIsolationLintTests.test_authz_context_handler_that_checks_the_site_passes | — | passed | — | lint |
| unittest | harness-selftest | test_tenant_isolation_lint.TenantIsolationLintTests.test_guessed_tenant_fallbacks_are_flagged_outside_fixtures_and_tests | — | passed | — | lint |
| unittest | harness-selftest | test_tenant_isolation_lint.TenantIsolationLintTests.test_object_path_needs_a_scope_unless_the_middleware_owns_it | — | passed | — | lint |
| unittest | harness-selftest | test_tenant_isolation_lint.TenantIsolationLintTests.test_route_table_style_is_parsed | — | passed | — | lint |
| unittest | harness-selftest | test_tenant_isolation_lint.TenantIsolationLintTests.test_scoped_and_site_free_handlers_pass | — | passed | — | lint |
| unittest | harness-selftest | test_tenant_isolation_lint.TenantIsolationLintTests.test_service_transactions_must_bind_their_tenant | — | passed | — | lint |
| unittest | harness-selftest | test_tenant_isolation_lint.TenantIsolationLintTests.test_site_input_without_scope_is_flagged | — | passed | — | lint |
| unittest | harness-selftest | test_tenant_isolation_lint.TenantIsolationLintTests.test_tenant_keyed_tables_need_a_policy | — | passed | — | lint |
| unittest | harness-selftest | test_testid_lint.TestIdLintTests.test_ignore_pragma_exempts_state_keys | — | passed | — | lint |
| unittest | harness-selftest | test_testid_lint.TestIdLintTests.test_key_without_testid_is_reported | — | passed | — | lint |
| unittest | harness-selftest | test_testid_lint.TestIdLintTests.test_matching_testid_passes_including_interpolation | — | passed | — | lint |
| unittest | harness-selftest | test_testid_lint.TestIdLintTests.test_quote_style_does_not_matter | — | passed | — | lint |
| unittest | harness-selftest | test_testid_lint.TestIdLintTests.test_real_ui_has_no_missing_testids | — | passed | — | lint |
| unittest | harness-selftest | test_testid_lint.TestIdLintTests.test_unwrappable_constructor_is_skipped | — | passed | — | lint |
| unittest | harness-selftest | test_testid_lint.TestIdLintTests.test_variable_and_global_keys_are_not_ids | — | passed | — | lint |
| unittest | harness-selftest | test_ui_style_lint.UiStyleLintTests.test_deprecated_sheet_container_is_exempt_from_popup_rule | — | passed | — | lint |
| unittest | harness-selftest | test_ui_style_lint.UiStyleLintTests.test_emoji_in_string_is_reported_but_not_in_comments | — | passed | — | lint |
| unittest | harness-selftest | test_ui_style_lint.UiStyleLintTests.test_font_at_floor_passes | — | passed | — | lint |
| unittest | harness-selftest | test_ui_style_lint.UiStyleLintTests.test_font_below_floor_is_reported | — | passed | — | lint |
| unittest | harness-selftest | test_ui_style_lint.UiStyleLintTests.test_full_screen_pages_and_comments_pass | — | passed | — | lint |
| unittest | harness-selftest | test_ui_style_lint.UiStyleLintTests.test_hand_printed_money_is_reported | — | passed | — | lint |
| unittest | harness-selftest | test_ui_style_lint.UiStyleLintTests.test_money_formatter_passes | — | passed | — | lint |
| unittest | harness-selftest | test_ui_style_lint.UiStyleLintTests.test_popups_are_reported | — | passed | — | lint |
| unittest | harness-selftest | test_ui_style_lint.UiStyleLintTests.test_ratchet_blocks_new_literals_outside_theme | — | passed | — | lint |
| unittest | harness-selftest | test_ui_style_lint.UiStyleLintTests.test_real_ui_passes_with_committed_baseline | — | passed | — | lint |
| unittest | harness-selftest | test_ui_style_lint.UiStyleLintTests.test_stand_in_google_icon_is_reported | — | passed | — | lint |
| unittest | harness-selftest | test_ui_style_lint.UiStyleLintTests.test_without_baseline_counts_are_reported_only | — | passed | — | lint |
| pytest-playwright | e2e | tests.test_epic02_manager::test_capital_segment_offers_project_creation | chromium | passed | 117.827 | 6/8 |
| pytest-playwright | e2e | tests.test_epic03_saas::test_reset_admin_password_non_existent_site_fails | chromium | passed | 1.166 | 6/8 |
| pytest-playwright | e2e | tests.test_epic04_invitations::test_pending_registrations_are_listed_for_the_manager | chromium | passed | 7.965 | 6/8 |
| pytest-playwright | e2e | tests.test_epic06_auth::test_manager_login_reaches_cockpit | chromium | passed | 5.358 | 6/8 |
| pytest-playwright | e2e | tests.test_epic06_auth::test_clear_login_cache_empties_the_fields | chromium-homeowner-homeOwner | passed | 3.194 | 6/8 |
| pytest-playwright | e2e | tests.test_epic06_auth::test_homeowner_changes_password_from_profile_and_logs_in_again | chromium | passed | 14.342 | 6/8 |
| pytest-playwright | e2e | tests.test_epic07_bank::test_confirming_matched_rows_records_the_payment | chromium | passed | 9.444 | 6/8 |
| pytest-playwright | e2e | tests.test_epic07_bank::test_period_accrual_charges_every_unit_once | chromium | passed | 19.067 | 6/8 |
| pytest-playwright | e2e | tests.test_epic07_bank::test_checkout_offers_fast_to_the_virtual_iban | chromium | passed | 6.229 | 6/8 |
| pytest-playwright | e2e | tests.test_epic08_occupancy::test_move_out_payout_waits_for_second_approver | chromium | passed | 10.668 | 6/8 |
| pytest-playwright | e2e | tests.test_epic08_occupancy::test_household_members_are_added | chromium | passed | 19.514 | 6/8 |
| pytest-playwright | e2e | tests.test_epic09_receipts::test_receipt_shows_number_and_penalty_principal_advance_split | chromium | passed | 7.563 | 6/8 |
| pytest-playwright | e2e | tests.test_epic12_unit_directory::test_residents_module_search_by_name_and_unit | chromium | passed | 9.082 | 6/8 |
| pytest-playwright | e2e | tests.test_features::test_accruing_an_installment_charges_owners_only | chromium | passed | 11.818 | 6/8 |
| pytest-playwright | e2e | tests.test_journey_accrual_corner_cases::test_resident_cannot_call_manager_actions | chromium | passed | 2.782 | 6/8 |
| pytest-playwright | e2e | tests.test_journey_accruals_payments::test_fourth_accrual_idempotent | chromium | passed | 2.764 | 6/8 |
| pytest-playwright | e2e | tests.test_journey_accruals_payments::test_overpayment_becomes_advance_offsetting_next_accrual | chromium | passed | 2.751 | 6/8 |
| pytest-playwright | e2e | tests.test_journey_clock_dates::test_liability_moves_through_pending_overdue_paid_and_cancelled | chromium-0-read:2026-11-09-PENDING-1500.00 | passed | 2.664 | 6/8 |
| pytest-playwright | e2e | tests.test_journey_clock_dates::test_resplit_share_keeps_an_effective_due_date_and_a_late_fee_that_follow_its_creation | chromium | passed | 3.768 | 6/8 |
| pytest-playwright | e2e | tests.test_journey_financial_transitions::test_partial_payment_reduces_the_principal_used_for_later_fees | chromium | passed | 2.748 | 6/8 |
| pytest-playwright | e2e | tests.test_journey_fixtures::test_site_admin_historical_reference_fixtures | chromium-F6 | passed | 6.58 | 6/8 |
| pytest-playwright | e2e | tests.test_journey_fixtures::test_stale_attempt_recovery_preserves_live_attempt | chromium | passed | 3.667 | 6/8 |
| pytest-playwright | e2e | tests.test_journey_liability_changes::test_final_open_debt_stays_with_each_former_and_current_debtor | chromium | passed | 5.982 | 6/8 |
| pytest-playwright | e2e | tests.test_journey_occupancy_changes::test_resident_added_after_accruals_is_charged_from_start_date | chromium | passed | 3.849 | 6/8 |
| pytest-playwright | e2e | tests.test_journey_occupancy_changes::test_duplicate_national_id_returns_match_without_second_person | chromium | passed | 3.633 | 6/8 |
| pytest-playwright | e2e | tests.test_journey_payment_corner_cases::test_two_parallel_transfers_for_one_unit_are_both_applied | chromium | passed | 2.748 | 6/8 |
| pytest-playwright | e2e | tests.test_journey_payment_corner_cases::test_approved_held_transfer_settles_only_the_assigned_person | chromium | passed | 3.782 | 6/8 |
| pytest-playwright | e2e | tests.test_journey_period_status_matrix::test_settled_or_cancelled_liability_cannot_be_paid_or_corrected | chromium-A-1-Eyl\xfcl 2026-PAID-records a 100.00 payment designating | passed | 2.983 | 6/8 |
| pytest-playwright | e2e | tests.test_journey_starting_states_gui::test_f3_accruing_the_same_period_again_is_blocked | chromium | passed | 15.829 | 6/8 |
| pytest-playwright | e2e | tests.test_journey_tenant_isolation::test_replacing_tenant_keeps_history_and_receipts_private | chromium | passed | 3.451 | 6/8 |
| pytest-playwright | e2e | tests.test_p2_edge::test_every_amount_uses_the_turkish_format | chromium | passed | 6.609 | 6/8 |
| pytest-playwright | e2e | tests.test_spec007_payments_phase2::test_resident_statement_ages_overdue_dues_with_the_penalty | chromium | passed | 5.699 | 6/8 |
| pytest-playwright | e2e | tests.test_journey_clock_dates::test_grace_boundary_decides_whether_a_late_fee_is_charged | chromium-5-2026-11-10-0.00-0.00 | passed | 2.704 | 6/8 |
| pytest-playwright | e2e | tests.test_journey_financial_transitions::test_aging_bucket_changes_at_each_day_boundary | chromium-30-overdue_1_30_days-overdue_1_30_days-75.00 | passed | 2.566 | 6/8 |
| pytest-playwright | e2e | tests.test_journey_starting_states::test_starting_states_survive_backend_restart | chromium-F2 | passed | 2.999 | 6/8 |
| pytest-playwright | e2e | tests.test_journey_accrual_corner_cases::test_invalid_accrual_input_is_rejected_and_creates_nothing | chromium-date-outside-period | passed | 2.636 | 6/8 |
| pytest-playwright | e2e | tests.test_journey_period_status_matrix::test_each_period_status_allows_only_its_own_commands | chromium-CLOSED-close | passed | 2.797 | 6/8 |
| pytest-playwright | e2e | tests.test_journey_reconciliation::test_cash_equals_cumulative_receipts | day0 | passed | 0.027 | 6/8 |
| pytest-playwright | e2e | tests.test_journey_reconciliation::test_site_totals_count_joint_receivable_once | — | passed | 0.368 | 6/8 |
| pytest-playwright | e2e | tests.test_epic01_resident_dues::test_site_announcement_reaches_the_resident | chromium | passed | 121.278 | 8/8 |
| pytest-playwright | e2e | tests.test_epic02_manager::test_resident_without_history_can_be_deleted | chromium | passed | 36.227 | 8/8 |
| pytest-playwright | e2e | tests.test_epic02_manager::test_refused_delete_keeps_the_resident_card | chromium | passed | 11.176 | 8/8 |
| pytest-playwright | e2e | tests.test_epic04_invitations::test_approving_a_registration_creates_an_active_account | chromium | passed | 7.748 | 8/8 |
| pytest-playwright | e2e | tests.test_epic04_invitations::test_home_owner_submits_online_registration | chromium | passed | 1.39 | 8/8 |
| pytest-playwright | e2e | tests.test_epic07_bank::test_statement_upload_matches_known_sender_and_flags_unknown | chromium | passed | 7.768 | 8/8 |
| pytest-playwright | e2e | tests.test_epic08_occupancy::test_tenant_move_in | chromium | passed | 14.224 | 8/8 |
| pytest-playwright | e2e | tests.test_epic08_occupancy::test_move_out_transfer_waits_for_second_approver | chromium | passed | 11.314 | 8/8 |
| pytest-playwright | e2e | tests.test_epic08_occupancy::test_operational_dues_go_to_the_tenant_and_capital_dues_to_the_owner | chromium | passed | 19.601 | 8/8 |
| pytest-playwright | e2e | tests.test_epic08_occupancy::test_household_members_survive_a_backend_restart | chromium | passed | 21.534 | 8/8 |
| pytest-playwright | e2e | tests.test_features::test_budget_is_split_by_land_share_without_rounding_drift | chromium | passed | 12.403 | 8/8 |
| pytest-playwright | e2e | tests.test_journey_accrual_corner_cases::test_scheduler_catches_up_missed_months | chromium | passed | 4.589 | 8/8 |
| pytest-playwright | e2e | tests.test_journey_accruals_payments::test_payment_clears_oldest_period_first | chromium | passed | 3.283 | 8/8 |
| pytest-playwright | e2e | tests.test_journey_accruals_payments::test_invalid_payment_amounts_rejected | chromium | passed | 3.366 | 8/8 |
| pytest-playwright | e2e | tests.test_journey_clock_dates::test_share_starting_after_the_period_due_date_is_not_late_before_it_existed | chromium-2026-11-05-2026-11-05-1300.00-2026-11-10-19.50 | passed | 4.214 | 8/8 |
| pytest-playwright | e2e | tests.test_journey_financial_transitions::test_unmatched_statement_item_is_queued_and_changes_no_balance | chromium | passed | 3.449 | 8/8 |
| pytest-playwright | e2e | tests.test_journey_fixtures::test_teardown_works_after_half_built_state | chromium | passed | 6.798 | 8/8 |
| pytest-playwright | e2e | tests.test_journey_liability_changes::test_former_owners_and_tenants_remain_collectible_after_the_changes | chromium | passed | 5.798 | 8/8 |
| pytest-playwright | e2e | tests.test_journey_occupancy_changes::test_mid_month_move_in_splits_the_period | chromium | passed | 4.468 | 8/8 |
| pytest-playwright | e2e | tests.test_journey_occupancy_changes::test_sale_of_a_tenant_occupied_unit_with_the_same_tenant_is_not_split | chromium | passed | 3.632 | 8/8 |
| pytest-playwright | e2e | tests.test_journey_payment_corner_cases::test_correction_after_partial_payment_moves_paid_amount_to_advance | chromium | passed | 4.014 | 8/8 |
| pytest-playwright | e2e | tests.test_journey_payment_corner_cases::test_unmatched_statement_item_is_assigned_and_approved_exactly_once | chromium | passed | 4.532 | 8/8 |
| pytest-playwright | e2e | tests.test_journey_starting_states::test_f0_accrue_period_refused_no_units | chromium | passed | 2.816 | 8/8 |
| pytest-playwright | e2e | tests.test_journey_starting_states_gui::test_f4_resident_sees_what_the_admin_sees | chromium | passed | 16.18 | 8/8 |
| pytest-playwright | e2e | tests.test_journey_tenant_isolation::test_resident_cannot_read_another_unit_financial_records | chromium | passed | 4.553 | 8/8 |
| pytest-playwright | e2e | tests.test_p2_edge::test_offline_state_shows_a_banner_and_keeps_the_balance | chromium | passed | 8.255 | 8/8 |
| pytest-playwright | e2e | tests.test_p2_edge::test_co_resident_joins_through_a_unit_invite | chromium | passed | 6.043 | 8/8 |
| pytest-playwright | e2e | tests.test_p2_edge::test_payer_name_alias_auto_matches_the_transfer | chromium | passed | 7.954 | 8/8 |
| pytest-playwright | e2e | tests.test_p2_edge::test_reload_never_leaves_a_broken_screen | chromium | passed | 6.754 | 8/8 |
| pytest-playwright | e2e | tests.test_epic06_auth::test_clear_login_cache_empties_the_fields | chromium-manager-siteManager | passed | 3.912 | 8/8 |
| pytest-playwright | e2e | tests.test_journey_clock_dates::test_liability_moves_through_pending_overdue_paid_and_cancelled | chromium-0-read:2026-11-10-PENDING-1500.00 | passed | 3.303 | 8/8 |
| pytest-playwright | e2e | tests.test_journey_fixtures::test_site_admin_historical_reference_fixtures | chromium-F7 | passed | 6.618 | 8/8 |
| pytest-playwright | e2e | tests.test_journey_period_status_matrix::test_settled_or_cancelled_liability_cannot_be_paid_or_corrected | chromium-A-1-Eyl\xfcl 2026-PAID-requests a 100.00 credit note on | passed | 3.679 | 8/8 |
| pytest-playwright | e2e | tests.test_journey_accrual_corner_cases::test_invalid_accrual_input_is_rejected_and_creates_nothing | chromium-invalid-date | passed | 3.418 | 8/8 |
| pytest-playwright | e2e | tests.test_journey_clock_dates::test_grace_boundary_decides_whether_a_late_fee_is_charged | chromium-5-2026-11-15-0.00-0.00 | passed | 3.38 | 8/8 |
| pytest-playwright | e2e | tests.test_journey_financial_transitions::test_aging_bucket_changes_at_each_day_boundary | chromium-31-overdue_31_60_days-overdue_31_60_days-77.50 | passed | 3.232 | 8/8 |
| pytest-playwright | e2e | tests.test_journey_starting_states::test_starting_states_survive_backend_restart | chromium-F3 | passed | 3.432 | 8/8 |
| pytest-playwright | e2e | tests.test_journey_period_status_matrix::test_each_period_status_allows_only_its_own_commands | chromium-CLOSED-reopen | passed | 4.101 | 8/8 |
| pytest-playwright | e2e | tests.test_journey_reconciliation::test_cash_equals_cumulative_receipts | day1 | passed | 1.111 | 8/8 |
| pytest-playwright | e2e | tests.journeys.test_journey_home_owner::test_home_owner_journey | chromium | passed | 144.772 | 4/8 |
| pytest-playwright | e2e | tests.test_cross_cutting::test_theme_choice_on_login_screen_holds_after_login | chromium | passed | 6.221 | 4/8 |
| pytest-playwright | e2e | tests.test_epic01_resident_dues::test_virtual_iban_shown_and_copied | chromium | passed | 5.075 | 4/8 |
| pytest-playwright | e2e | tests.test_epic01_resident_dues::test_account_movements_itemise_principal_and_penalty | chromium | passed | 5.198 | 4/8 |
| pytest-playwright | e2e | tests.test_epic03_saas::test_onboarding_a_site_issues_working_manager_credentials | chromium | passed | 8.945 | 4/8 |
| pytest-playwright | e2e | tests.test_epic03_saas::test_site_with_units_cannot_be_deleted | chromium | passed | 4.494 | 4/8 |
| pytest-playwright | e2e | tests.test_epic06_auth::test_wrong_password_shows_error_and_stays_on_login | chromium | passed | 4.402 | 4/8 |
| pytest-playwright | e2e | tests.test_epic07_bank::test_non_excel_banks_have_no_excel_sample_download | chromium | passed | 6.066 | 4/8 |
| pytest-playwright | e2e | tests.test_epic08_occupancy::test_owner_occupied_unit_operational_dues_go_to_the_owner | chromium | passed | 13.963 | 4/8 |
| pytest-playwright | e2e | tests.test_epic08_occupancy::test_ownership_transfer_keeps_the_previous_owner_in_history | chromium | passed | 14.113 | 4/8 |
| pytest-playwright | e2e | tests.test_epic09_payments::test_debt_aging_buckets_total_the_overdue_sum | chromium | passed | 6.287 | 4/8 |
| pytest-playwright | e2e | tests.test_features::test_virman_dialog_offers_the_real_advance_balance_of_the_unit | chromium | passed | 6.876 | 4/8 |
| pytest-playwright | e2e | tests.test_journey_accrual_corner_cases::test_invalid_accrual_input_is_rejected_and_creates_nothing | chromium-zero-amount | passed | 2.608 | 4/8 |
| pytest-playwright | e2e | tests.test_journey_accrual_corner_cases::test_two_managers_accruing_at_once_create_one_set_of_liabilities | chromium | passed | 3.114 | 4/8 |
| pytest-playwright | e2e | tests.test_journey_accruals_payments::test_single_debt_in_current_month_in_youngest_bucket | chromium | passed | 2.599 | 4/8 |
| pytest-playwright | e2e | tests.test_journey_accruals_payments::test_multi_site_journey_accruals_and_designated_payments | chromium | passed | 9.015 | 4/8 |
| pytest-playwright | e2e | tests.test_journey_clock_dates::test_late_fee_never_reopens_a_settled_liability | chromium | passed | 2.682 | 4/8 |
| pytest-playwright | e2e | tests.test_journey_liability_changes::test_ownership_and_occupancy_changes_do_not_move_money | chromium | passed | 5.851 | 4/8 |
| pytest-playwright | e2e | tests.test_journey_occupancy_changes::test_proration_respects_month_length_and_edge_days | chromium-Ekim 2026-2026-10-10-2026-10-01-0.00-1500.00 | passed | 2.612 | 4/8 |
| pytest-playwright | e2e | tests.test_journey_occupancy_changes::test_switching_proration_changes_responsibility | chromium-enabled | passed | 2.168 | 4/8 |
| pytest-playwright | e2e | tests.test_journey_payment_corner_cases::test_payment_reversal_restores_the_debt_and_the_fee | chromium | passed | 2.915 | 4/8 |
| pytest-playwright | e2e | tests.test_journey_starting_states::test_f2_first_accrual_charges_units_tariffs_and_debtors | chromium | passed | 2.564 | 4/8 |
| pytest-playwright | e2e | tests.test_journey_starting_states_gui::test_f0_site_grows_to_f2_through_the_screens | chromium | passed | 122.207 | 4/8 |
| pytest-playwright | e2e | tests.test_journey_starting_states_gui::test_f5_multiple_periods_add_up_per_unit_and_per_site | chromium | passed | 12.864 | 4/8 |
| pytest-playwright | e2e | tests.test_journey_tenant_isolation::test_tenant_statement_excludes_owner_private_transactions | chromium | passed | 3.201 | 4/8 |
| pytest-playwright | e2e | tests.test_p2_edge::test_remove_tenant_only_keeps_the_owner | chromium | passed | 8.431 | 4/8 |
| pytest-playwright | e2e | tests.test_spec007_payments_phase2::test_card_payment_on_the_provider_page_issues_a_receipt | chromium | passed | 8.01 | 4/8 |
| pytest-playwright | e2e | tests.test_spec007_payments_phase2::test_manager_downloads_the_receipt_pdf_and_reverses_the_receipt | chromium | passed | 10.487 | 4/8 |
| pytest-playwright | e2e | tests.test_journey_clock_dates::test_share_starting_after_the_period_due_date_is_not_late_before_it_existed | chromium-2026-11-15-2026-11-15-800.00-2026-11-15-5.33 | passed | 3.303 | 4/8 |
| pytest-playwright | e2e | tests.test_journey_fixtures::test_site_admin_reference_fixtures | chromium-F1 | passed | 4.629 | 4/8 |
| pytest-playwright | e2e | tests.test_journey_fixtures::test_balances_identical_after_backend_restart | chromium-F5 | passed | 3.351 | 4/8 |
| pytest-playwright | e2e | tests.test_journey_liability_changes::test_a_successors_receipt_settles_only_the_successors_charges | chromium-A-01-Ben-Nisan 2027 | passed | 5.747 | 4/8 |
| pytest-playwright | e2e | tests.test_journey_period_status_matrix::test_each_period_status_allows_only_its_own_commands | chromium-DRAFT-close | passed | 2.733 | 4/8 |
| pytest-playwright | e2e | tests.test_journey_period_status_matrix::test_bank_statement_item_reconciliation_statuses | chromium-approved-APPROVED-1 | passed | 2.665 | 4/8 |
| pytest-playwright | e2e | tests.test_journey_clock_dates::test_liability_moves_through_pending_overdue_paid_and_cancelled | chromium-5-read:2026-11-15-PENDING-1500.00 | passed | 2.599 | 4/8 |
| pytest-playwright | e2e | tests.test_journey_period_status_matrix::test_settled_or_cancelled_liability_cannot_be_paid_or_corrected | chromium-A-5-Eyl\xfcl 2026-CANCELLED-requests cancellation of | passed | 3.516 | 4/8 |
| pytest-playwright | e2e | tests.test_journey_financial_transitions::test_aging_bucket_changes_at_each_day_boundary | chromium-61-overdue_60_plus_days-overdue_61_90_days-152.50 | passed | 2.551 | 4/8 |
| pytest-playwright | e2e | tests.test_journey_reconciliation::test_cash_equals_cumulative_receipts | day3 | passed | 0.688 | 4/8 |
| pytest-playwright | e2e | tests.journeys.test_journey_home_resident::test_home_resident_journey | chromium | passed | 148.732 | 7/8 |
| pytest-playwright | e2e | tests.test_epic02_manager::test_overdue_filter_lists_every_overdue_flat | chromium | passed | 7.94 | 7/8 |
| pytest-playwright | e2e | tests.test_epic03_saas::test_portfolio_lists_every_site | chromium | passed | 4.465 | 7/8 |
| pytest-playwright | e2e | tests.test_epic03_saas::test_portfolio_stats_agree_with_site_list | chromium | passed | 1.123 | 7/8 |
| pytest-playwright | e2e | tests.test_epic03_saas::test_edit_site_updates_the_card | chromium | passed | 6.875 | 7/8 |
| pytest-playwright | e2e | tests.test_epic06_auth::test_logout_returns_to_login_screen | chromium | passed | 9.681 | 7/8 |
| pytest-playwright | e2e | tests.test_epic06_auth::test_saas_admin_must_change_bootstrap_password | chromium | passed | 6.338 | 7/8 |
| pytest-playwright | e2e | tests.test_epic07_bank::test_wrong_statement_format_is_rejected_and_excel_accepted | chromium | passed | 16.024 | 7/8 |
| pytest-playwright | e2e | tests.test_epic07_bank::test_fast_webhook_pays_the_balance_once | chromium | passed | 5.459 | 7/8 |
| pytest-playwright | e2e | tests.test_epic07_bank::test_unmatched_row_is_assigned_to_a_unit_by_hand | chromium | passed | 9.075 | 7/8 |
| pytest-playwright | e2e | tests.test_epic08_occupancy::test_tenant_move_out_keeps_history_and_debt | chromium | passed | 9.033 | 7/8 |
| pytest-playwright | e2e | tests.test_epic08_occupancy::test_move_out_keeps_tenant_advance_when_selected | chromium | passed | 9.064 | 7/8 |
| pytest-playwright | e2e | tests.test_epic12_person_picker::test_picker_chooses_an_existing_person_through_the_live_search_api | chromium | passed | 12.31 | 7/8 |
| pytest-playwright | e2e | tests.test_features::test_disbursement_within_collected_cash_updates_the_reserve | chromium | passed | 9.638 | 7/8 |
| pytest-playwright | e2e | tests.test_journey_accrual_corner_cases::test_duplicate_accrual_with_a_different_amount_changes_nothing | chromium | passed | 2.833 | 7/8 |
| pytest-playwright | e2e | tests.test_journey_accruals_payments::test_exact_payment_settles_debt_leaving_zero | chromium | passed | 2.666 | 7/8 |
| pytest-playwright | e2e | tests.test_journey_accruals_payments::test_one_kurus_short_leaves_one_kurus_open | chromium | passed | 2.648 | 7/8 |
| pytest-playwright | e2e | tests.test_journey_clock_dates::test_owner_moves_in_after_the_tenant_leaves_and_takes_the_dues_back | chromium | passed | 3.582 | 7/8 |
| pytest-playwright | e2e | tests.test_journey_financial_transitions::test_operational_and_capital_balances_separate_for_tenant | chromium | passed | 2.616 | 7/8 |
| pytest-playwright | e2e | tests.test_journey_fixtures::test_parallel_journey_managers_only_see_their_site_data | chromium | passed | 3.682 | 7/8 |
| pytest-playwright | e2e | tests.test_journey_liability_changes::test_designated_april_receipts_leave_february_and_march_unpaid | chromium | passed | 5.884 | 7/8 |
| pytest-playwright | e2e | tests.test_journey_multisite_setup::test_onboarding_attempt_starts_with_an_empty_site_list | chromium | passed | 1.93 | 7/8 |
| pytest-playwright | e2e | tests.test_journey_onboarding_88_units::test_onboard_two_sites_and_create_88_units_from_zero | chromium | passed | 4.299 | 7/8 |
| pytest-playwright | e2e | tests.test_journey_payment_corner_cases::test_transfer_on_unit_with_several_debtors_is_held_for_the_manager | chromium | passed | 3.599 | 7/8 |
| pytest-playwright | e2e | tests.test_journey_period_status_matrix::test_reversal_moves_paid_liability_back_to_overdue | chromium | passed | 2.849 | 7/8 |
| pytest-playwright | e2e | tests.test_journey_period_status_matrix::test_unit_occupancy_allowed_commands | chromium-A-7-no owner-move in tenant-TENANT_MOVE_IN | passed | 2.881 | 7/8 |
| pytest-playwright | e2e | tests.test_journey_starting_states_gui::test_f2_people_without_a_period_have_no_debt | chromium | passed | 16.803 | 7/8 |
| pytest-playwright | e2e | tests.test_journey_tenant_isolation::test_manager_lists_and_searches_are_site_scoped | chromium | passed | 3.576 | 7/8 |
| pytest-playwright | e2e | tests.test_p2_edge::test_virman_moves_advance_to_the_capital_due | chromium | passed | 6.806 | 7/8 |
| pytest-playwright | e2e | tests.test_cross_cutting::test_mobile_viewport_login_and_dashboard | chromium-manager-ManagerCockpit | passed | 4.639 | 7/8 |
| pytest-playwright | e2e | tests.test_journey_accrual_corner_cases::test_move_out_with_an_advance_needs_a_second_approver | chromium-TRANSFER | passed | 3.518 | 7/8 |
| pytest-playwright | e2e | tests.test_journey_clock_dates::test_grace_boundary_decides_whether_a_late_fee_is_charged | chromium-0-2026-11-11-2.50-2.50 | passed | 2.683 | 7/8 |
| pytest-playwright | e2e | tests.test_journey_financial_transitions::test_aging_bucket_changes_at_each_day_boundary | chromium-1-overdue_1_30_days-overdue_1_30_days-2.50 | passed | 2.534 | 7/8 |
| pytest-playwright | e2e | tests.test_journey_starting_states::test_starting_states_survive_backend_restart | chromium-F1 | passed | 2.781 | 7/8 |
| pytest-playwright | e2e | tests.test_journey_occupancy_changes::test_proration_respects_month_length_and_edge_days | chromium-\u015eubat 2028-2028-02-10-2028-02-15-724.14-775.86 | passed | 2.682 | 7/8 |
| pytest-playwright | e2e | tests.test_journey_period_status_matrix::test_each_period_status_allows_only_its_own_commands | chromium-CLOSED-accrue | passed | 2.798 | 7/8 |
| pytest-playwright | e2e | tests.test_journey_clock_dates::test_liability_moves_through_pending_overdue_paid_and_cancelled | chromium-0-pay:500.00:2026-11-10-PENDING-1000.00 | passed | 2.651 | 7/8 |
| pytest-playwright | e2e | tests.test_journey_fixtures::test_site_admin_reference_fixtures | chromium-F5 | passed | 5.096 | 7/8 |
| pytest-playwright | e2e | tests.test_journey_reconciliation::test_homeowner_totals_and_joint_exposure | — | passed | 0.432 | 7/8 |
| pytest-playwright | e2e | tests.journeys.test_journey_saas_admin::test_saas_admin_journey | chromium | passed | 188.266 | 2/8 |
| pytest-playwright | e2e | tests.test_epic01_resident_dues::test_no_dues_shows_zero_balance_without_overdue_badge | chromium | passed | 6.518 | 2/8 |
| pytest-playwright | e2e | tests.test_epic01_resident_dues::test_resident_actions_meet_touch_target_and_hide_unapproved_features | chromium | passed | 6.861 | 2/8 |
| pytest-playwright | e2e | tests.test_epic02_manager::test_manager_adds_owner_resident | chromium | passed | 21.682 | 2/8 |
| pytest-playwright | e2e | tests.test_epic02_manager::test_house_type_tariff_is_saved_and_negative_amount_rejected | chromium | passed | 11.952 | 2/8 |
| pytest-playwright | e2e | tests.test_epic03_saas::test_manager_never_sees_another_sites_units | chromium | passed | 8.44 | 2/8 |
| pytest-playwright | e2e | tests.test_epic03_saas::test_empty_site_can_be_deleted | chromium | passed | 12.431 | 2/8 |
| pytest-playwright | e2e | tests.test_epic04_invitations_core::test_unit_invite_link_is_shown_and_copied | chromium | passed | 7.752 | 2/8 |
| pytest-playwright | e2e | tests.test_epic04_invitations_core::test_unit_invite_link_targets_the_right_site_and_unit | chromium | passed | 7.366 | 2/8 |
| pytest-playwright | e2e | tests.test_epic04_invitations_core::test_rejected_registration_leaves_the_queue | chromium | passed | 8.344 | 2/8 |
| pytest-playwright | e2e | tests.test_epic06_auth::test_profile_logout_and_browser_back_stay_logged_out | chromium | passed | 14.157 | 2/8 |
| pytest-playwright | e2e | tests.test_epic07_bank::test_confirming_matched_rows_keeps_the_unmatched_ones | chromium | passed | 11.576 | 2/8 |
| pytest-playwright | e2e | tests.test_epic08_occupancy::test_capital_dues_after_transfer_billed_to_new_owner | chromium | passed | 2.057 | 2/8 |
| pytest-playwright | e2e | tests.test_epic09_payments::test_payment_stream_role_filter_shows_only_tenant_payments | chromium | passed | 9.664 | 2/8 |
| pytest-playwright | e2e | tests.test_journey_accrual_corner_cases::test_merging_duplicate_people_preserves_liabilities_and_payments | chromium | passed | 4.281 | 2/8 |
| pytest-playwright | e2e | tests.test_journey_accruals_payments::test_bank_webhook_matches_transfer_and_allocates | chromium | passed | 4.248 | 2/8 |
| pytest-playwright | e2e | tests.test_journey_accruals_payments::test_multi_site_journey_accruals_through_march_first | chromium | passed | 12.849 | 2/8 |
| pytest-playwright | e2e | tests.test_journey_clock_dates::test_backdated_payment_recalculates_fees_using_its_value_date | chromium | passed | 4.382 | 2/8 |
| pytest-playwright | e2e | tests.test_journey_clock_dates::test_month_boundary_uses_istanbul_time_not_utc | chromium | passed | 4.897 | 2/8 |
| pytest-playwright | e2e | tests.test_journey_corner_cases::test_moving_out_with_debt_keeps_the_debt_and_the_history | chromium | passed | 4.482 | 2/8 |
| pytest-playwright | e2e | tests.test_journey_liability_changes::test_titles_and_occupancies_change_on_their_effective_dates | chromium | passed | 7.561 | 2/8 |
| pytest-playwright | e2e | tests.test_journey_occupancy_changes::test_tenant_left_without_notice_is_moved_out_at_the_real_date | chromium | passed | 5.999 | 2/8 |
| pytest-playwright | e2e | tests.test_journey_payment_corner_cases::test_same_bank_transaction_sent_twice_is_applied_once | chromium | passed | 4.267 | 2/8 |
| pytest-playwright | e2e | tests.test_journey_starting_states::test_f3_period_exists_open_zero_liabilities | chromium | passed | 3.698 | 2/8 |
| pytest-playwright | e2e | tests.test_journey_starting_states_gui::test_f1_units_without_people_show_as_unassigned | chromium | passed | 15.26 | 2/8 |
| pytest-playwright | e2e | tests.test_journey_tenant_isolation::test_direct_reads_and_downloads_require_site_access | chromium | passed | 5.586 | 2/8 |
| pytest-playwright | e2e | tests.test_p2_edge::test_empty_credentials_are_rejected_without_a_request | chromium | passed | 5.59 | 2/8 |
| pytest-playwright | e2e | tests.test_features::test_excel_upload_offers_a_sample_for_each_catalogued_excel_bank | chromium-YAPI_KREDI-Yap\u0131 Kredi Bankas\u0131 | passed | 9.995 | 2/8 |
| pytest-playwright | e2e | tests.test_journey_occupancy_changes::test_proration_respects_month_length_and_edge_days | chromium-Kas\u0131m 2026-2026-11-10-2026-11-16-750.00-750.00 | passed | 4.207 | 2/8 |
| pytest-playwright | e2e | tests.test_journey_period_status_matrix::test_bank_statement_item_reconciliation_statuses | chromium-rejected-REJECTED-0 | passed | 4.232 | 2/8 |
| pytest-playwright | e2e | tests.test_journey_fixtures::test_site_admin_reference_fixtures | chromium-F3 | passed | 7.867 | 2/8 |
| pytest-playwright | e2e | tests.test_journey_fixtures::test_balances_identical_after_backend_restart | chromium-F7 | passed | 5.213 | 2/8 |
| pytest-playwright | e2e | tests.test_journey_liability_changes::test_a_successors_receipt_settles_only_the_successors_charges | chromium-B1-01-Hana-Nisan 2027 | passed | 9.382 | 2/8 |
| pytest-playwright | e2e | tests.test_journey_period_status_matrix::test_each_period_status_allows_only_its_own_commands | chromium-OPEN-close | passed | 4.432 | 2/8 |
| pytest-playwright | e2e | tests.test_journey_period_status_matrix::test_unit_occupancy_allowed_commands | chromium-A-2-tenant-occupied-move in owner-OWNER_MOVE_IN | passed | 4.564 | 2/8 |
| pytest-playwright | e2e | tests.test_journey_clock_dates::test_liability_moves_through_pending_overdue_paid_and_cancelled | chromium-0-pay:1500.00:2026-11-10-PAID-0.00 | passed | 4.183 | 2/8 |
| pytest-playwright | e2e | tests.test_journey_financial_transitions::test_aging_bucket_changes_at_each_day_boundary | chromium-91-overdue_60_plus_days-overdue_90_plus_days-227.50 | passed | 3.984 | 2/8 |
| pytest-playwright | e2e | tests.test_journey_reconciliation::test_final_period_statuses | — | passed | 0.766 | 2/8 |
| pytest-playwright | e2e | tests.journeys.test_journey_auditor::test_auditor_journey | chromium | passed | 164.705 | 5/8 |
| pytest-playwright | e2e | tests.test_epic02_manager::test_manager_can_create_an_announcement | chromium | passed | 7.653 | 5/8 |
| pytest-playwright | e2e | tests.test_epic02_manager::test_cockpit_shows_the_accrued_total_before_any_payment | chromium | passed | 5.435 | 5/8 |
| pytest-playwright | e2e | tests.test_epic03_saas::test_admin_password_reset_issues_a_new_password_and_retires_the_old | chromium | passed | 8.119 | 5/8 |
| pytest-playwright | e2e | tests.test_epic06_auth::test_each_tab_has_a_url_and_browser_back_returns_to_it | chromium | passed | 6.358 | 5/8 |
| pytest-playwright | e2e | tests.test_epic07_bank::test_excel_bank_samples_download_as_parser_compatible_workbooks | chromium | passed | 7.292 | 5/8 |
| pytest-playwright | e2e | tests.test_epic07_bank::test_overpayment_becomes_an_advance | chromium | passed | 5.293 | 5/8 |
| pytest-playwright | e2e | tests.test_epic07_bank::test_manual_assignment_records_the_payment | chromium | passed | 12.663 | 5/8 |
| pytest-playwright | e2e | tests.test_epic08_occupancy::test_ownership_transfer_records_the_previous_owners_period | chromium | passed | 14.218 | 5/8 |
| pytest-playwright | e2e | tests.test_epic08_occupancy::test_previous_owner_advance_transfer_waits_for_second_approver | chromium | passed | 17.371 | 5/8 |
| pytest-playwright | e2e | tests.test_features::test_disbursement_larger_than_collected_cash_is_refused | chromium | passed | 14.698 | 5/8 |
| pytest-playwright | e2e | tests.test_features::test_capital_project_is_marked_as_the_responsibility_of_the_owner | chromium | passed | 5.954 | 5/8 |
| pytest-playwright | e2e | tests.test_journey_accrual_corner_cases::test_second_move_out_and_move_in_on_an_occupied_unit_are_refused | chromium | passed | 3.067 | 5/8 |
| pytest-playwright | e2e | tests.test_journey_accruals_payments::test_late_fee_follows_clock_day_by_day | chromium | passed | 2.949 | 5/8 |
| pytest-playwright | e2e | tests.test_journey_accruals_payments::test_payment_toward_closed_period_allocated_to_oldest_debt | chromium | passed | 3.049 | 5/8 |
| pytest-playwright | e2e | tests.test_journey_fixtures::test_site_admin_reference_fixtures | chromium-F0 | passed | 5.105 | 5/8 |
| pytest-playwright | e2e | tests.test_journey_fixtures::test_balances_identical_after_backend_restart | chromium-F4 | passed | 3.693 | 5/8 |
| pytest-playwright | e2e | tests.test_journey_liability_changes::test_march_charges_follow_the_new_owners_and_the_vacancies | chromium | passed | 5.499 | 5/8 |
| pytest-playwright | e2e | tests.test_journey_liability_changes::test_a_successors_receipt_settles_only_the_successors_charges | chromium-A-01-Ben-Mart 2027 | passed | 6.464 | 5/8 |
| pytest-playwright | e2e | tests.test_journey_occupancy_changes::test_move_out_after_accrual_resplits_open_liability | chromium | passed | 4.117 | 5/8 |
| pytest-playwright | e2e | tests.test_journey_payment_corner_cases::test_payment_for_unit_without_debt_becomes_the_payers_advance | chromium | passed | 3.196 | 5/8 |
| pytest-playwright | e2e | tests.test_journey_period_status_matrix::test_each_period_status_allows_only_its_own_commands | chromium-DRAFT-accrue | passed | 3.1 | 5/8 |
| pytest-playwright | e2e | tests.test_journey_starting_states::test_f0_unknown_virtual_iban_payment_stored_unmatched | chromium | passed | 2.584 | 5/8 |
| pytest-playwright | e2e | tests.test_journey_starting_states_gui::test_f0_every_page_shows_an_empty_state | chromium | passed | 19.424 | 5/8 |
| pytest-playwright | e2e | tests.test_journey_starting_states_gui::test_f4_single_period_shows_one_debt_each | chromium | passed | 10.318 | 5/8 |
| pytest-playwright | e2e | tests.test_journey_tenant_isolation::test_site_parameter_cannot_widen_manager_permissions | chromium | passed | 3.917 | 5/8 |
| pytest-playwright | e2e | tests.test_p2_edge::test_penalty_detail_shows_days_and_the_penalty_amount | chromium | passed | 5.984 | 5/8 |
| pytest-playwright | e2e | tests.test_p2_edge::test_tenant_capital_payment_receipt_names_the_owner_and_rent_offset | chromium | passed | 7.242 | 5/8 |
| pytest-playwright | e2e | tests.test_p2_edge::test_debt_aging_buckets_add_up_to_the_grand_total | chromium | passed | 6.798 | 5/8 |
| pytest-playwright | e2e | tests.test_journey_accrual_corner_cases::test_invalid_accrual_input_is_rejected_and_creates_nothing | chromium-negative-amount | passed | 3.055 | 5/8 |
| pytest-playwright | e2e | tests.test_journey_occupancy_changes::test_switching_proration_changes_responsibility | chromium-disabled | passed | 2.549 | 5/8 |
| pytest-playwright | e2e | tests.test_journey_clock_dates::test_liability_moves_through_pending_overdue_paid_and_cancelled | chromium-0-read:2026-11-11-OVERDUE-1502.50 | passed | 2.965 | 5/8 |
| pytest-playwright | e2e | tests.test_journey_period_status_matrix::test_settled_or_cancelled_liability_cannot_be_paid_or_corrected | chromium-A-5-Eyl\xfcl 2026-CANCELLED-records a 100.00 payment designating | passed | 3.931 | 5/8 |
| pytest-playwright | e2e | tests.test_journey_clock_dates::test_share_starting_after_the_period_due_date_is_not_late_before_it_existed | chromium-2026-11-05-2026-11-18-1300.00-2026-11-18-2.17 | passed | 3.849 | 5/8 |
| pytest-playwright | e2e | tests.test_journey_clock_dates::test_grace_boundary_decides_whether_a_late_fee_is_charged | chromium-5-2026-11-16-15.00-15.00 | passed | 3.015 | 5/8 |
| pytest-playwright | e2e | tests.test_journey_financial_transitions::test_aging_bucket_changes_at_each_day_boundary | chromium-60-overdue_31_60_days-overdue_31_60_days-150.00 | passed | 2.883 | 5/8 |
| pytest-playwright | e2e | tests.test_journey_period_status_matrix::test_bank_statement_item_reconciliation_statuses | chromium-already_processed-ALREADY_PROCESSED-1 | passed | 2.999 | 5/8 |
| pytest-playwright | e2e | tests.test_journey_reconciliation::test_cash_equals_cumulative_receipts | day2 | passed | 1.336 | 5/8 |
| pytest-playwright | e2e | tests.journeys.test_journey_site_manager::test_site_manager_journey | chromium | passed | 197.752 | 3/8 |
| pytest-playwright | e2e | tests.test_cross_cutting::test_mobile_viewport_login_and_dashboard | chromium-homeowner-ResidentHome | passed | 6.553 | 3/8 |
| pytest-playwright | e2e | tests.test_epic01_resident_dues::test_overdue_balance_matches_backend_total | chromium | passed | 7.744 | 3/8 |
| pytest-playwright | e2e | tests.test_epic02_manager::test_house_type_tariff_rejects_more_than_two_decimals | chromium | passed | 10.732 | 3/8 |
| pytest-playwright | e2e | tests.test_epic02_manager::test_cockpit_counts_a_payment_as_collected | chromium | passed | 8.023 | 3/8 |
| pytest-playwright | e2e | tests.test_epic02_manager::test_cockpit_shows_collection_progress_and_unit_breakdown | chromium | passed | 8.349 | 3/8 |
| pytest-playwright | e2e | tests.test_epic04_invitations_core::test_manager_shares_a_site_invite_link | chromium | passed | 9.69 | 3/8 |
| pytest-playwright | e2e | tests.test_epic06_auth::test_homeowner_login_reaches_dashboard | chromium | passed | 6.909 | 3/8 |
| pytest-playwright | e2e | tests.test_epic06_auth::test_manager_switches_between_cockpit_and_own_flat | chromium | passed | 8.376 | 3/8 |
| pytest-playwright | e2e | tests.test_epic06_auth::test_logout_asks_for_confirmation_and_cancel_keeps_the_session | chromium | passed | 12.146 | 3/8 |
| pytest-playwright | e2e | tests.test_epic07_bank::test_approved_statement_match_clears_the_homeowners_balance | chromium | passed | 11.702 | 3/8 |
| pytest-playwright | e2e | tests.test_epic08_occupancy::test_household_members_are_archived_on_move_out | chromium | passed | 22.249 | 3/8 |
| pytest-playwright | e2e | tests.test_features::test_virman_transfer_clears_a_capital_due_from_the_advance_balance | chromium | passed | 12.611 | 3/8 |
| pytest-playwright | e2e | tests.test_features::test_owner_dashboard_shows_capital_dues_separately | chromium | passed | 6.921 | 3/8 |
| pytest-playwright | e2e | tests.test_journey_accrual_corner_cases::test_move_out_with_an_advance_needs_a_second_approver | chromium-PAYOUT | passed | 5.491 | 3/8 |
| pytest-playwright | e2e | tests.test_journey_accruals_payments::test_multiple_debts_across_periods_listed_oldest_first | chromium | passed | 4.182 | 3/8 |
| pytest-playwright | e2e | tests.test_journey_accruals_payments::test_closed_period_accepts_no_new_accrual_keeps_debts | chromium | passed | 4.433 | 3/8 |
| pytest-playwright | e2e | tests.test_journey_clock_dates::test_grace_boundary_decides_whether_a_late_fee_is_charged | chromium-0-2026-11-10-0.00-0.00 | passed | 4.299 | 3/8 |
| pytest-playwright | e2e | tests.test_journey_clock_dates::test_one_person_who_owns_one_unit_and_rents_another_is_billed_in_each_role | chromium | passed | 5.997 | 3/8 |
| pytest-playwright | e2e | tests.test_journey_financial_transitions::test_concurrent_deliveries_of_one_bank_event_are_credited_once | chromium | passed | 4.365 | 3/8 |
| pytest-playwright | e2e | tests.test_journey_financial_transitions::test_aging_bucket_changes_at_each_day_boundary | chromium-0-current-current-0.00 | passed | 4.032 | 3/8 |
| pytest-playwright | e2e | tests.test_journey_fixtures::test_failed_attempt_evidence_and_retry_cleanup_are_isolated | chromium | passed | 21.366 | 3/8 |
| pytest-playwright | e2e | tests.test_journey_liability_changes::test_april_move_ins_redirect_new_charges_and_rosters | chromium | passed | 8.73 | 3/8 |
| pytest-playwright | e2e | tests.test_journey_liability_changes::test_unit_statement_attributes_open_items_to_former_debtors | chromium | skipped | 9.703 | 3/8 |
| pytest-playwright | e2e | tests.test_journey_occupancy_changes::test_unit_created_mid_month_is_billed_for_chargeable_days | chromium | passed | 3.849 | 3/8 |
| pytest-playwright | e2e | tests.test_journey_payment_corner_cases::test_transfer_for_another_site_is_applied_only_there | chromium | passed | 6.249 | 3/8 |
| pytest-playwright | e2e | tests.test_journey_period_status_matrix::test_rejected_or_approved_statement_item_cannot_change_status_again | chromium | passed | 4.251 | 3/8 |
| pytest-playwright | e2e | tests.test_journey_starting_states::test_starting_states_survive_backend_restart | chromium-F0 | passed | 3.663 | 3/8 |
| pytest-playwright | e2e | tests.test_journey_starting_states_gui::test_f2_cancelling_accrual_confirmation_makes_no_financial_change | chromium | passed | 18.583 | 3/8 |
| pytest-playwright | e2e | tests.test_journey_tenant_isolation::test_manager_cannot_mutate_another_site_records | chromium | passed | 5.847 | 3/8 |
| pytest-playwright | e2e | tests.test_p2_edge::test_adding_a_resident_to_an_occupied_unit_warns_and_saves_nothing | chromium | passed | 15.317 | 3/8 |
| pytest-playwright | e2e | tests.test_p2_edge::test_debt_aging_total_matches_the_open_ledger | chromium | passed | 8.743 | 3/8 |
| pytest-playwright | e2e | tests.test_journey_period_status_matrix::test_unit_occupancy_allowed_commands | chromium-A-3-owned, vacant-move out tenant-MOVE_OUT | passed | 4.301 | 3/8 |
| pytest-playwright | e2e | tests.test_journey_period_status_matrix::test_bank_statement_item_reconciliation_statuses | chromium-unmatched-UNMATCHED-0 | passed | 4.23 | 3/8 |
| pytest-playwright | e2e | tests.test_journey_fixtures::test_site_admin_reference_fixtures | chromium-F4 | passed | 8.266 | 3/8 |
| pytest-playwright | e2e | tests.test_journey_occupancy_changes::test_proration_respects_month_length_and_edge_days | chromium-\u015eubat 2027-2027-02-10-2027-02-15-750.00-750.00 | passed | 4.2 | 3/8 |
| pytest-playwright | e2e | tests.test_journey_clock_dates::test_liability_moves_through_pending_overdue_paid_and_cancelled | chromium-0-pay:1502.50:2026-11-11-PAID-0.00 | passed | 4.329 | 3/8 |
| pytest-playwright | e2e | tests.test_journey_reconciliation::test_fixture_shape | — | passed | 1.108 | 3/8 |
| pytest-playwright | e2e | tests.test_epic02_manager::test_manager_can_send_a_payment_reminder | chromium | passed | 139.226 | 1/8 |
| pytest-playwright | e2e | tests.test_epic02_manager::test_cockpit_amounts_keep_kurus | chromium | passed | 5.528 | 1/8 |
| pytest-playwright | e2e | tests.test_epic03_saas::test_new_manager_must_change_password_and_lands_on_an_empty_site | chromium | passed | 7.781 | 1/8 |
| pytest-playwright | e2e | tests.test_epic04_invitations_core::test_approved_resident_first_login | chromium | passed | 6.662 | 1/8 |
| pytest-playwright | e2e | tests.test_epic06_auth::test_homeowner_sees_no_manager_actions_and_api_refuses_them | chromium | passed | 4.71 | 1/8 |
| pytest-playwright | e2e | tests.test_epic07_bank::test_period_accrual_charges_each_unit_its_house_type_tariff | chromium | passed | 14.745 | 1/8 |
| pytest-playwright | e2e | tests.test_epic08_occupancy::test_history_lists_previous_tenant_with_exit_balance_and_the_new_one | chromium | passed | 7.485 | 1/8 |
| pytest-playwright | e2e | tests.test_epic09_receipts::test_homeowner_receipt_shows_the_issued_receipt_number | chromium | passed | 5.201 | 1/8 |
| pytest-playwright | e2e | tests.test_epic09_receipts::test_tenant_statement_lists_operational_items_only | chromium | passed | 8.134 | 1/8 |
| pytest-playwright | e2e | tests.test_epic12_people_directory::test_people_directory_pages_and_filters_server_results | chromium | passed | 10.28 | 1/8 |
| pytest-playwright | e2e | tests.test_features::test_owner_fast_payment_raises_the_collected_amount_of_the_project | chromium | passed | 6.521 | 1/8 |
| pytest-playwright | e2e | tests.test_features::test_equal_allocation_gives_every_unit_the_same_share | chromium | passed | 10.934 | 1/8 |
| pytest-playwright | e2e | tests.test_features::test_excel_upload_offers_a_sample_for_each_catalogued_excel_bank | chromium-KUVEYT_TURK-Kuveyt T\xfcrk Kat\u0131l\u0131m Bankas\u0131 | passed | 7.434 | 1/8 |
| pytest-playwright | e2e | tests.test_journey_accrual_corner_cases::test_manager_of_another_site_sees_nothing_of_this_site | chromium | passed | 4.38 | 1/8 |
| pytest-playwright | e2e | tests.test_journey_accruals_payments::test_single_debt_in_previous_month_stays_attached | chromium | passed | 2.647 | 1/8 |
| pytest-playwright | e2e | tests.test_journey_accruals_payments::test_advance_balance_offsets_next_accrual | chromium | passed | 2.717 | 1/8 |
| pytest-playwright | e2e | tests.test_journey_accruals_payments::test_multi_site_journey_accruals_and_mixed_payments | chromium | passed | 29.411 | 1/8 |
| pytest-playwright | e2e | tests.test_journey_liability_changes::test_receipts_before_the_changes_allocate_to_the_paying_debtor | chromium | passed | 4.417 | 1/8 |
| pytest-playwright | e2e | tests.test_journey_occupancy_changes::test_tenant_left_without_notice_delayed_approval_sets_due_date_to_approval_date | chromium | passed | 3.748 | 1/8 |
| pytest-playwright | e2e | tests.test_journey_payment_corner_cases::test_requester_of_a_correction_cannot_approve_it | chromium | passed | 2.783 | 1/8 |
| pytest-playwright | e2e | tests.test_journey_period_status_matrix::test_bank_statement_item_reconciliation_statuses | chromium-pending-PENDING_APPROVAL-0 | passed | 2.682 | 1/8 |
| pytest-playwright | e2e | tests.test_journey_starting_states::test_f2_units_without_owner_reported_separately | chromium | passed | 2.632 | 1/8 |
| pytest-playwright | e2e | tests.test_journey_starting_states_gui::test_f1_manager_adds_first_owners_and_tenant | chromium | passed | 43.242 | 1/8 |
| pytest-playwright | e2e | tests.test_journey_starting_states_gui::test_f5_unit_search_zero_matches_is_recoverable | chromium | passed | 9.883 | 1/8 |
| pytest-playwright | e2e | tests.test_p2_edge::test_google_sign_in_redirects_to_the_provider | chromium | skipped | 2.332 | 1/8 |
| pytest-playwright | e2e | tests.test_p2_edge::test_empty_approval_queue_shows_zero | chromium | passed | 5.501 | 1/8 |
| pytest-playwright | e2e | tests.test_spec007_payments_phase2::test_interim_operating_budget_becomes_the_legal_basis_of_accrued_dues | chromium | passed | 7.393 | 1/8 |
| pytest-playwright | e2e | tests.test_journey_occupancy_changes::test_proration_respects_month_length_and_edge_days | chromium-Ekim 2026-2026-10-10-2026-10-31-1451.61-48.39 | passed | 2.655 | 1/8 |
| pytest-playwright | e2e | tests.test_journey_clock_dates::test_share_starting_after_the_period_due_date_is_not_late_before_it_existed | chromium-2026-11-18-2026-11-18-650.00-2026-11-18-1.08 | passed | 3.334 | 1/8 |
| pytest-playwright | e2e | tests.test_journey_fixtures::test_site_admin_reference_fixtures | chromium-F2 | passed | 4.982 | 1/8 |
| pytest-playwright | e2e | tests.test_journey_fixtures::test_balances_identical_after_backend_restart | chromium-F6 | passed | 4.697 | 1/8 |
| pytest-playwright | e2e | tests.test_journey_liability_changes::test_a_successors_receipt_settles_only_the_successors_charges | chromium-A-02-Eli-Nisan 2027 | passed | 5.849 | 1/8 |
| pytest-playwright | e2e | tests.test_journey_period_status_matrix::test_each_period_status_allows_only_its_own_commands | chromium-OPEN-accrue again | passed | 2.765 | 1/8 |
| pytest-playwright | e2e | tests.test_journey_period_status_matrix::test_unit_occupancy_allowed_commands | chromium-A-1-owner-occupied-move in tenant-TENANT_MOVE_IN | passed | 2.848 | 1/8 |
| pytest-playwright | e2e | tests.test_journey_clock_dates::test_liability_moves_through_pending_overdue_paid_and_cancelled | chromium-5-read:2026-11-16-OVERDUE-1515.00 | passed | 2.649 | 1/8 |
| pytest-playwright | e2e | tests.test_journey_financial_transitions::test_aging_bucket_changes_at_each_day_boundary | chromium-90-overdue_60_plus_days-overdue_61_90_days-225.00 | passed | 2.516 | 1/8 |
| pytest-playwright | e2e | tests.test_journey_clock_dates::test_liability_moves_through_pending_overdue_paid_and_cancelled | chromium-0-cancel:2026-11-12-CANCELLED-0.00 | passed | 3.25 | 1/8 |
| pytest-playwright | e2e | tests.test_journey_reconciliation::test_eleven_open_rows | — | passed | 0.345 | 1/8 |
