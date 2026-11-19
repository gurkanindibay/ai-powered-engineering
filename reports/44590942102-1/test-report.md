# Test run 20261119T185819Z-d3804f6

- **Task:** master
- **Result:** PASS (2 SKIPPED, 137 PASS)
- **Executed:** 139 tests in 2168s, covering 116 of 293 automated scenarios
- **Commit:** `d3804f6904` on `master`
- **Started:** 2026-11-19T18:58:19Z (ci)

## Executed tests

| Scenario / GUI id | Status | Change | Time | Name |
|---|---|---|---|---|
| `SC-01-01-01` | PASS | new | 5.6s | Preserve kurus-level precision in dues calculation |
| `SC-01-02-01` | PASS |  | 5.6s | Calculate 10-day overdue statutory delay penalty |
| `SC-01-03-01` | PASS |  | 5.6s | Emit reactive state on dashboard launch |
| `SC-01-03-02` | PASS |  | 7.1s | Site announcement reaches the resident |
| `SC-01-04-01` | PASS |  | 5.6s | Render resident hero balance with overdue amount |
| `SC-01-04-02` | PASS |  | 131.2s | Render zero balance without overdue badge |
| `SC-01-04-03` | PASS | new | 4.6s | Action buttons meet touch target size and unapproved features are hidden |
| `SC-01-05-01` | PASS |  | 5.1s | View recent financial movements |
| `SC-01-06-01` | PASS |  | 7.4s | Display cached dues when network is offline |
| `SC-02-01-01` | PASS |  | 5.2s | Cockpit shows the accrued total before any payment |
| `SC-02-01-02` | PASS |  | 7.1s | Cockpit counts a payment as collected |
| `SC-02-01-03` | PASS |  | 5.6s | Cockpit amounts keep kurus |
| `SC-02-01-04` | PASS |  | 8.3s | House type tariff is saved and a negative amount is rejected |
| `SC-02-01-05` | PASS |  | 10.0s | House type tariff rejects more than two decimals |
| `SC-02-01-06` | PASS | new | 7.8s | Display complex collection progress with the unit status breakdown |
| `SC-02-02-01` | PASS |  | 7.4s | Overdue filter lists every overdue flat |
| `SC-02-03-01` | PASS |  | 12.4s | Manager adds a new home owner manually |
| `SC-02-03-02` | PASS |  | 14.7s | Adding a resident to an occupied unit warns and saves nothing |
| `SC-02-03-03` | PASS |  | 24.9s | A resident without ledger history can be deleted |
| `SC-02-03-04` | PASS |  | 10.2s | A refused delete keeps the resident card |
| `SC-02-04-01` | PASS |  | 8.1s | Reminder action is offered for overdue flats |
| `SC-02-05-01` | PASS |  | 9.2s | Manager creates an announcement |
| `SC-03-01-01` | PASS |  | 6.2s | Query operations strictly scoped by tenant |
| `SC-03-02-01` | PASS |  | 4.4s | SaaS Admin views portfolio overview |
| `SC-03-02-02` | PASS |  | 1.1s | Portfolio statistics agree with the site list |
| `SC-03-03-01` | PASS |  | 8.7s | SaaS Admin creates new site and provisions first Site Admin |
| `SC-03-04-01` | PASS |  | 8.7s | Generate temporary password for newly registered Site Admin |
| `SC-03-04-02` | PASS |  | 7.4s | New manager is forced to change the temporary password |
| `SC-03-06-01` | PASS |  | 9.0s | Delete site without any related actions |
| `SC-03-06-02` | PASS |  | 6.0s | Invariant prevents deletion of active site with transactions |
| `SC-03-07-01` | PASS |  | 9.1s | SaaS Admin renews temporary password for a site manager |
| `SC-03-07-02` | PASS | new | 1.2s | Password renewal fails for non-existent site |
| `SC-04-01-01` | PASS |  | 7.5s | Generate 7-day secure invite link |
| `SC-04-02-01` | PASS |  | 7.5s | Site Admin copies or shares invite link |
| `SC-04-02-02` | PASS | new | 5.5s | Empty approval queue shows an empty state |
| `SC-04-03-01` | PASS | new | 1.1s | Home owner submits online registration |
| `SC-04-04-01` | PASS |  | 7.5s | Site manager views pending applications |
| `SC-04-05-01` | PASS |  | 7.0s | Approve applicant and provision account |
| `SC-04-05-02` | PASS |  | 6.4s | Approved resident signs in with the issued password |
| `SC-04-06-01` | PASS |  | 6.6s | Reject unverified registration |
| `SC-04-07-01` | PASS |  | 5.6s | Home owner generates unit-scoped invitation link |
| `SC-04-07-01` | PASS |  | 5.4s | Home owner generates unit-scoped invitation link |
| `SC-04-07-02` | PASS | new | 6.4s | Co-resident registers with unit-scoped permissions |
| `SC-06-01-01` | PASS |  | 4.4s | Home resident is restricted from site-wide management |
| `SC-06-02-02` | PASS |  | 6.5s | Site manager signs in and reaches the cockpit |
| `SC-06-02-03` | PASS |  | 4.7s | Home owner signs in and reaches the resident dashboard |
| `SC-06-02-04` | PASS |  | 4.5s | Wrong password shows an error and stays on the login screen |
| `SC-06-02-05` | PASS |  | 3.1s | Clearing the login cache empties the credential fields |
| `SC-06-02-05` | PASS |  | 4.7s | Clearing the login cache empties the credential fields |
| `SC-06-02-06` | PASS |  | 4.7s | Empty password is rejected without a request |
| `SC-06-03-02` | SKIPPED |  | 2.2s | Google sign-in button starts the provider flow |
| `SC-06-04-02` | PASS |  | 14.3s | Home owner changes the password from the profile and signs in again |
| `SC-06-04-03` | PASS |  | 9.3s | Logout returns to the login screen |
| `SC-06-04-04` | PASS |  | 11.6s | Browser back after logout does not re-enter the session |
| `SC-06-04-05` | PASS |  | 6.1s | Manager switches between the cockpit and the own flat |
| `SC-06-04-06` | PASS |  | 11.4s | Cancelling the logout confirmation keeps the session |
| `SC-06-05-01` | SKIPPED |  | 2.2s | Google sign-in option is offered on the login screen |
| `SC-06-05-03` | PASS |  | 6.5s | Email and password sign-in opens the role dashboard |
| `SC-06-06-01` | PASS |  | 6.0s | SaaS admin with a temporary password is held at the password change screen |
| `SC-06-06-02` | PASS |  | 172.4s | Site manager with a temporary password is held at the password change screen |
| `SC-06-06-03` | PASS |  | 133.1s | Home owner with a temporary password is held at the password change screen |
| `SC-06-06-04` | PASS |  | 95.1s | Home resident with a temporary password is held at the password change screen |
| `SC-06-06-05` | PASS |  | 152.8s | Auditor with a temporary password is held at the password change screen |
| `SC-07-02-01` | PASS |  | 7.3s | Site manager uploads a bank statement Excel file |
| `SC-07-02-02` | PASS |  | 11.0s | Approving a matched row clears the resident's balance |
| `SC-07-02-04` | PASS |  | 8.3s | An unmatched row is assigned to a unit by hand |
| `SC-07-02-05` | PASS | new | 7.1s | A stored payer-name alias auto-matches a re-uploaded row |
| `SC-07-03-01` | PASS |  | 7.0s | Real-time incoming transfer clears dues once |
| `SC-07-04-01` | PASS |  | 7.2s | Resident chooses the FAST transfer payment method |
| `SC-07-04-02` | PASS |  | 127.5s | Copy button puts the unspaced IBAN on the clipboard |
| `SC-07-05-01` | PASS |  | 5.0s | Surplus transfer is allocated to the resident advance balance |
| `SC-07-06-02` | PASS |  | 15.6s | Wrong statement format is rejected and the matching format is accepted |
| `SC-07-06-03` | PASS | new | 8.8s | Excel upload offers a sample for each catalogued Excel bank |
| `SC-07-06-04` | PASS | new | 5.9s | Excel sample options exclude banks without an Excel format |
| `SC-07-07-01` | PASS |  | 19.0s | Manager accrues a period once and the duplicate is blocked |
| `SC-07-07-04` | PASS | new | 14.7s | Manual accrual charges each unit its tariff, not a fixed amount |
| `SC-08-01-01` | PASS |  | 18.5s | Accrue monthly operational dues to tenant and capital project to owner |
| `SC-08-02-01` | PASS |  | 19.2s | Household members are bound to the active resident session |
| `SC-08-02-02` | PASS | new | 22.0s | Household members are archived when the resident moves out |
| `SC-08-03-01` | PASS |  | 8.6s | Move-out preserves historical payment receipts and unsettled debt |
| `SC-08-03-02` | PASS | new | 8.7s | Move-out can keep the advance without changing the balance |
| `SC-08-03-03` | PASS | new | 10.6s | Move-out payout is debited only after four-eyes approval |
| `SC-08-03-04` | PASS | new | 10.6s | Move-out transfer changes debtor only after four-eyes approval |
| `SC-08-04-01` | PASS |  | 7.0s | New tenant moves in and past occupancy history is retrievable |
| `SC-08-04-02` | PASS | new | 13.1s | Tenant move-in opens an active tenant session |
| `SC-08-05-01` | PASS |  | 13.3s | Change property owner upon title deed sale without affecting tenant |
| `SC-08-05-02` | PASS | new | 1.2s | Capital dues after the transfer are billed to the new owner |
| `SC-08-05-03` | PASS | new | 17.9s | Previous owner's advance is paid out or transferred only with a second approver |
| `SC-09-01-01` | PASS |  | 7.4s | Filter payment stream by tenant payments for current month |
| `SC-09-01-02` | PASS | new | 6.0s | Debt aging buckets total the overdue sum |
| `SC-09-02-01` | PASS |  | 8.9s | Settle delay penalty first, then oldest dues, then credit surplus as advance |
| `SC-09-03-01` | PASS |  | 8.0s | Generate itemized sub-ledger statement for a tenant |
| `SC-09-03-02` | PASS |  | 5.4s | Resident statement ages an overdue due with its penalty |
| `SC-09-04-01` | PASS |  | 4.8s | Issue sequential payment receipt upon settlement |
| `SC-09-04-02` | PASS |  | 10.2s | Manager downloads the receipt PDF and reverses the receipt |
| `SC-09-04-03` | PASS |  | 8.9s | Receipt shows the penalty, principal and advance split |
| `SC-09-04-04` | PASS |  | 7.8s | Card payment on the provider page issues a receipt |
| `SC-10-01-01` | PASS |  | 11.7s | Budget is split by land share without rounding drift |
| `SC-10-01-02` | PASS |  | 11.4s | Equal allocation gives every unit the same share |
| `SC-10-02-01` | PASS |  | 11.8s | Accruing an installment charges owners only |
| `SC-10-03-01` | PASS |  | 6.0s | Owner FAST payment raises the collected amount of the project |
| `SC-10-03-02` | PASS |  | 8.9s | Tenant payment produces a TBK 314 rent-offset receipt |
| `SC-10-04-01` | PASS |  | 8.7s | Virman dialog offers the real advance balance of the unit |
| `SC-10-04-02` | PASS | new | 6.5s | Virman transfer clears a capital due from the advance balance |
| `SC-10-05-01` | PASS |  | 9.0s | Disbursement within collected cash updates the reserve |
| `SC-10-05-02` | PASS |  | 16.4s | Disbursement larger than collected cash is refused |
| `SC-10-06-01` | PASS |  | 4.9s | Owner dashboard shows capital dues separately |
| `SC-10-06-02` | PASS |  | 5.8s | Capital project is marked as the responsibility of the owner |
| `SC-10-07-01` | PASS |  | 6.4s | Capital segment offers project creation |
| `SC-12-02-03` | PASS | new | 9.3s | The directory pager adapts to a narrow viewport |
| `SC-12-02-05` | PASS |  | 9.3s | Unit search folds Turkish names and phone digits |
| `SC-12-02-06` | PASS |  | 9.3s | Unit rows expose distinct actions and details targets |
| `SC-12-02-07` | PASS |  | 9.3s | Compact unit rows adapt from phone to desktop widths |
| `SC-12-03-04` | PASS |  | 11.5s | Choose an existing person through the live search API |
| `SC-12-04-01` | PASS |  | 10.2s | People paging and activation filters use the server query |
| `SC-12-04-02` | PASS | new | 10.2s | People search and directory position survive restoration |
| `SC-12-06-04` | PASS | new | 13.3s | Unit actions started from the residents tab choose people through the person picker |
| `SC-13-07-01` | PASS | new | 2.4s | Every starting state can be built using the documented fixture path |
| `SC-13-07-01` | PASS | new | 2.9s | Every starting state can be built using the documented fixture path |
| `SC-13-07-01` | PASS | new | 5.1s | Every starting state can be built using the documented fixture path |
| `GUI-J-01` | PASS |  | 125.1s | test_saas_admin_journey[chromium] |
| `GUI-X-04` | PASS |  | 132.5s | test_mobile_viewport_login_and_dashboard[chromium-homeowner-ResidentHome] |
| `GUI-X-04` | PASS |  | 5.1s | test_mobile_viewport_login_and_dashboard[chromium-manager-ManagerCockpit] |
| `GUI-X-02` | PASS |  | 8.3s | test_theme_choice_on_login_screen_holds_after_login[chromium] |
| `GUI-03-05` | PASS |  | 8.3s | test_edit_site_updates_the_card[chromium] |
| `GUI-X-07` | PASS |  | 6.0s | test_each_tab_has_a_url_and_browser_back_returns_to_it[chromium] |
| `GUI-07-05` | PASS |  | 8.4s | test_confirming_matched_rows_keeps_the_unmatched_ones[chromium] |
| `GUI-07-03` | PASS |  | 9.4s | test_confirming_matched_rows_records_the_payment[chromium] |
| `GUI-07-05` | PASS |  | 12.4s | test_manual_assignment_records_the_payment[chromium] |
| `GUI-08-03` | PASS |  | 19.7s | test_household_members_survive_a_backend_restart[chromium] |
| `GUI-08-02` | PASS |  | 13.8s | test_owner_occupied_unit_operational_dues_go_to_the_owner[chromium] |
| `GUI-08-06` | PASS |  | 14.8s | test_ownership_transfer_records_the_previous_owners_period[chromium] |
| `GUI-09-06` | PASS |  | 6.2s | test_debt_aging_buckets_add_up_to_the_grand_total[chromium] |
| `GUI-09-06` | PASS |  | 6.6s | test_debt_aging_total_matches_the_open_ledger[chromium] |
| `GUI-X-06` | PASS |  | 6.1s | test_every_amount_uses_the_turkish_format[chromium] |
| `GUI-01-06` | PASS |  | 6.8s | test_penalty_detail_shows_days_and_the_penalty_amount[chromium] |
| `GUI-X-05` | PASS |  | 7.3s | test_reload_never_leaves_a_broken_screen[chromium] |
| `GUI-08-08` | PASS |  | 8.1s | test_remove_tenant_only_keeps_the_owner[chromium] |
| `GUI-02-06` | PASS |  | 8.2s | test_interim_operating_budget_becomes_the_legal_basis_of_accrued_dues[chromium] |

## Automated scenarios not executed in this run

`SC-02-04-02`, `SC-03-04-04`, `SC-03-05-01`, `SC-05-03-01`, `SC-05-04-01`, `SC-05-06-01`, `SC-06-02-01`, `SC-06-03-01`, `SC-06-06-06`, `SC-07-01-01`, `SC-07-01-02`, `SC-07-02-03`, `SC-07-03-02`, `SC-07-03-03`, `SC-07-03-04`, `SC-07-05-02`, `SC-07-06-01`, `SC-07-07-02`, `SC-07-07-03`, `SC-07-08-01`, `SC-07-08-02`, `SC-07-08-03`, `SC-07-08-04`, `SC-07-09-01`, `SC-07-09-02`, `SC-07-09-03`, `SC-07-09-04`, `SC-07-09-05`, `SC-07-09-06`, `SC-07-10-01`, `SC-07-10-02`, `SC-07-10-03`, `SC-07-10-04`, `SC-07-10-05`, `SC-07-10-06`, `SC-07-10-07`, `SC-07-11-01`, `SC-07-11-02`, `SC-07-11-03`, `SC-07-11-04`, `SC-07-11-05`, `SC-07-12-01`, `SC-07-12-02`, `SC-07-12-03`, `SC-07-12-04`, `SC-07-12-05`, `SC-07-12-06`, `SC-07-12-07`, `SC-07-13-01`, `SC-07-13-02`, `SC-07-13-03`, `SC-07-13-04`, `SC-08-02-03`, `SC-08-06-01`, `SC-08-06-02`, `SC-08-06-03`, `SC-08-07-01`, `SC-08-07-02`, `SC-08-07-03`, `SC-08-07-04`, `SC-08-07-05`, `SC-08-07-06`, `SC-08-07-07`, `SC-08-07-08`, `SC-08-07-09`, `SC-08-07-10`, `SC-08-08-01`, `SC-08-08-02`, `SC-08-08-03`, `SC-08-09-01`, `SC-08-09-02`, `SC-08-09-03`, `SC-08-09-04`, `SC-08-10-01`, `SC-08-10-02`, `SC-08-10-03`, `SC-08-10-04`, `SC-08-10-05`, `SC-08-10-06`, `SC-08-11-01`, `SC-08-11-02`, `SC-08-11-03`, `SC-08-12-01`, `SC-08-12-02`, `SC-08-12-03`, `SC-08-12-04`, `SC-08-12-05`, `SC-08-12-06`, `SC-08-12-07`, `SC-08-12-08`, `SC-08-12-09`, `SC-08-12-10`, `SC-08-12-11`, `SC-08-12-12`, `SC-08-12-13`, `SC-09-02-02`, `SC-09-04-05`, `SC-09-04-06`, `SC-09-04-07`, `SC-09-05-01`, `SC-09-05-02`, `SC-09-05-03`, `SC-09-05-04`, `SC-09-05-05`, `SC-09-05-06`, `SC-09-06-01`, `SC-09-06-02`, `SC-09-06-03`, `SC-09-06-04`, `SC-09-07-01`, `SC-10-05-03`, `SC-11-01-01`, `SC-11-01-02`, `SC-11-02-01`, `SC-11-02-02`, `SC-11-02-03`, `SC-11-02-04`, `SC-11-03-01`, `SC-11-03-02`, `SC-11-04-01`, `SC-11-04-02`, `SC-11-04-03`, `SC-11-05-01`, `SC-11-05-02`, `SC-11-05-03`, `SC-11-05-04`, `SC-11-06-01`, `SC-11-06-02`, `SC-11-07-01`, `SC-11-07-02`, `SC-11-07-03`, `SC-11-08-01`, `SC-11-08-02`, `SC-11-09-01`, `SC-11-09-02`, `SC-11-10-01`, `SC-11-10-02`, `SC-11-11-01`, `SC-11-12-01`, `SC-11-13-01`, `SC-11-14-01`, `SC-12-01-01`, `SC-12-02-01`, `SC-12-02-02`, `SC-12-02-04`, `SC-12-02-08`, `SC-12-02-09`, `SC-12-03-01`, `SC-12-03-02`, `SC-12-03-03`, `SC-12-05-01`, `SC-12-05-02`, `SC-12-05-03`, `SC-12-05-04`, `SC-12-05-05`, `SC-12-05-06`, `SC-12-06-01`, `SC-12-06-02`, `SC-12-06-03`, `SC-12-07-01`, `SC-12-07-02`, `SC-12-07-03`, `SC-12-08-01`, `SC-12-08-02`, `SC-12-09-01`, `SC-12-09-02`, `SC-12-10-01`, `SC-12-10-02`, `SC-12-10-03`, `SC-12-10-04`, `SC-12-10-05`, `SC-12-10-06`, `SC-12-10-07`, `SC-12-10-08`, `SC-12-10-09`, `SC-12-10-10`, `SC-12-10-11`
