# Test run 20261115T215144Z-761e392

- **Task:** master
- **Result:** PASS (2 SKIPPED, 119 PASS)
- **Executed:** 121 tests in 1974s, covering 95 of 153 automated scenarios
- **Commit:** `761e3928c6` on `master`
- **Started:** 2026-11-15T21:51:44Z (ci)

## Executed tests

| Scenario / GUI id | Status | Change | Time | Name |
|---|---|---|---|---|
| `SC-01-02-01` | PASS |  | 5.0s | Calculate 10-day overdue statutory delay penalty |
| `SC-01-03-01` | PASS |  | 5.0s | Emit reactive state on dashboard launch |
| `SC-01-03-02` | PASS |  | 5.3s | Site announcement reaches the resident |
| `SC-01-04-01` | PASS |  | 5.0s | Render resident hero balance with overdue amount |
| `SC-01-04-02` | PASS |  | 4.7s | Render zero balance without overdue badge |
| `SC-01-05-01` | PASS |  | 143.8s | View recent financial movements |
| `SC-01-06-01` | PASS |  | 8.7s | Display cached dues when network is offline |
| `SC-02-01-01` | PASS |  | 6.7s | Cockpit shows the accrued total before any payment |
| `SC-02-01-02` | PASS |  | 7.2s | Cockpit counts a payment as collected |
| `SC-02-01-03` | PASS |  | 5.7s | Cockpit amounts keep kurus |
| `SC-02-01-04` | PASS |  | 10.6s | House type tariff is saved and a negative amount is rejected |
| `SC-02-01-05` | PASS |  | 9.8s | House type tariff rejects more than two decimals |
| `SC-02-02-01` | PASS |  | 8.5s | Overdue filter lists every overdue flat |
| `SC-02-03-01` | PASS |  | 14.7s | Manager adds a new home owner manually |
| `SC-02-03-02` | PASS |  | 15.0s | Adding a resident to an occupied unit warns and saves nothing |
| `SC-02-03-03` | PASS |  | 28.9s | A resident without ledger history can be deleted |
| `SC-02-03-04` | PASS |  | 11.8s | A refused delete keeps the resident card |
| `SC-02-04-01` | PASS |  | 9.0s | Reminder action is offered for overdue flats |
| `SC-02-05-01` | PASS |  | 7.0s | Manager creates an announcement |
| `SC-03-01-01` | PASS |  | 6.2s | Query operations strictly scoped by tenant |
| `SC-03-02-01` | PASS |  | 4.7s | SaaS Admin views portfolio overview |
| `SC-03-02-02` | PASS |  | 1.1s | Portfolio statistics agree with the site list |
| `SC-03-03-01` | PASS |  | 9.0s | SaaS Admin creates new site and provisions first Site Admin |
| `SC-03-04-01` | PASS |  | 9.0s | Generate temporary password for newly registered Site Admin |
| `SC-03-04-02` | PASS |  | 7.5s | New manager is forced to change the temporary password |
| `SC-03-06-01` | PASS |  | 11.1s | Delete site without any related actions |
| `SC-03-06-02` | PASS |  | 6.3s | Invariant prevents deletion of active site with transactions |
| `SC-03-07-01` | PASS |  | 7.6s | SaaS Admin renews temporary password for a site manager |
| `SC-04-01-01` | PASS |  | 6.9s | Generate 7-day secure invite link |
| `SC-04-02-01` | PASS |  | 6.9s | Site Admin copies or shares invite link |
| `SC-04-04-01` | PASS |  | 7.1s | Site manager views pending applications |
| `SC-04-05-01` | PASS |  | 8.5s | Approve applicant and provision account |
| `SC-04-05-02` | PASS |  | 9.0s | Approved resident signs in with the issued password |
| `SC-04-06-01` | PASS |  | 6.3s | Reject unverified registration |
| `SC-04-07-01` | PASS |  | 5.3s | Home owner generates unit-scoped invitation link |
| `SC-04-07-01` | PASS |  | 7.0s | Home owner generates unit-scoped invitation link |
| `SC-06-01-01` | PASS |  | 4.6s | Home resident is restricted from site-wide management |
| `SC-06-02-02` | PASS |  | 5.1s | Site manager signs in and reaches the cockpit |
| `SC-06-02-03` | PASS |  | 4.5s | Home owner signs in and reaches the resident dashboard |
| `SC-06-02-04` | PASS |  | 4.8s | Wrong password shows an error and stays on the login screen |
| `SC-06-02-05` | PASS |  | 4.2s | Clearing the login cache empties the credential fields |
| `SC-06-02-05` | PASS |  | 3.6s | Clearing the login cache empties the credential fields |
| `SC-06-02-06` | PASS |  | 4.0s | Empty password is rejected without a request |
| `SC-06-03-02` | SKIPPED |  | 2.3s | Google sign-in button starts the provider flow |
| `SC-06-04-02` | PASS |  | 14.6s | Home owner changes the password from the profile and signs in again |
| `SC-06-04-03` | PASS |  | 9.5s | Logout returns to the login screen |
| `SC-06-04-04` | PASS |  | 13.5s | Browser back after logout does not re-enter the session |
| `SC-06-04-05` | PASS |  | 6.0s | Manager switches between the cockpit and the own flat |
| `SC-06-04-06` | PASS |  | 11.6s | Cancelling the logout confirmation keeps the session |
| `SC-06-05-01` | SKIPPED |  | 2.3s | Google sign-in option is offered on the login screen |
| `SC-06-05-03` | PASS |  | 5.1s | Email and password sign-in opens the role dashboard |
| `SC-06-06-01` | PASS |  | 6.5s | SaaS admin with a temporary password is held at the password change screen |
| `SC-06-06-02` | PASS |  | 158.5s | Site manager with a temporary password is held at the password change screen |
| `SC-06-06-03` | PASS |  | 118.3s | Home owner with a temporary password is held at the password change screen |
| `SC-06-06-04` | PASS |  | 106.3s | Home resident with a temporary password is held at the password change screen |
| `SC-06-06-05` | PASS |  | 111.4s | Auditor with a temporary password is held at the password change screen |
| `SC-07-02-01` | PASS |  | 9.1s | Site manager uploads a bank statement Excel file |
| `SC-07-02-02` | PASS |  | 11.1s | Approving a matched row clears the resident's balance |
| `SC-07-02-04` | PASS |  | 8.6s | An unmatched row is assigned to a unit by hand |
| `SC-07-03-01` | PASS |  | 5.7s | Real-time incoming transfer clears dues once |
| `SC-07-04-01` | PASS |  | 5.8s | Resident chooses the FAST transfer payment method |
| `SC-07-04-02` | PASS |  | 5.0s | Copy button puts the unspaced IBAN on the clipboard |
| `SC-07-05-01` | PASS |  | 6.9s | Surplus transfer is allocated to the resident advance balance |
| `SC-07-06-02` | PASS |  | 15.8s | Wrong statement format is rejected and the matching format is accepted |
| `SC-07-06-03` | PASS | new | 9.6s | Excel upload offers a sample for each catalogued Excel bank |
| `SC-07-06-04` | PASS | new | 6.0s | Excel sample options exclude banks without an Excel format |
| `SC-07-07-01` | PASS |  | 19.5s | Manager accrues a period once and the duplicate is blocked |
| `SC-08-01-01` | PASS |  | 21.5s | Accrue monthly operational dues to tenant and capital project to owner |
| `SC-08-02-01` | PASS |  | 18.1s | Household members are bound to the active resident session |
| `SC-08-03-01` | PASS |  | 8.6s | Move-out preserves historical payment receipts and unsettled debt |
| `SC-08-04-01` | PASS |  | 7.3s | New tenant moves in and past occupancy history is retrievable |
| `SC-08-05-01` | PASS |  | 14.0s | Change property owner upon title deed sale without affecting tenant |
| `SC-09-01-01` | PASS |  | 9.4s | Filter payment stream by tenant payments for current month |
| `SC-09-02-01` | PASS |  | 6.8s | Settle delay penalty first, then oldest dues, then credit surplus as advance |
| `SC-09-03-01` | PASS |  | 8.3s | Generate itemized sub-ledger statement for a tenant |
| `SC-09-03-02` | PASS |  | 8.0s | Resident statement ages an overdue due with its penalty |
| `SC-09-04-01` | PASS |  | 4.9s | Issue sequential payment receipt upon settlement |
| `SC-09-04-02` | PASS |  | 10.3s | Manager downloads the receipt PDF and reverses the receipt |
| `SC-09-04-03` | PASS |  | 6.8s | Receipt shows the penalty, principal and advance split |
| `SC-09-04-04` | PASS |  | 7.8s | Card payment on the provider page issues a receipt |
| `SC-10-01-01` | PASS |  | 13.9s | Budget is split by land share without rounding drift |
| `SC-10-01-02` | PASS |  | 11.2s | Equal allocation gives every unit the same share |
| `SC-10-02-01` | PASS |  | 11.7s | Accruing an installment charges owners only |
| `SC-10-03-01` | PASS |  | 6.2s | Owner FAST payment raises the collected amount of the project |
| `SC-10-03-02` | PASS |  | 8.5s | Tenant payment produces a TBK 314 rent-offset receipt |
| `SC-10-04-01` | PASS |  | 6.5s | Virman dialog offers the real advance balance of the unit |
| `SC-10-05-01` | PASS |  | 9.6s | Disbursement within collected cash updates the reserve |
| `SC-10-05-02` | PASS |  | 14.3s | Disbursement larger than collected cash is refused |
| `SC-10-06-01` | PASS |  | 6.2s | Owner dashboard shows capital dues separately |
| `SC-10-06-02` | PASS |  | 7.1s | Capital project is marked as the responsibility of the owner |
| `SC-10-07-01` | PASS |  | 108.9s | Capital segment offers project creation |
| `SC-12-02-05` | PASS |  | 8.8s | Unit search folds Turkish names and phone digits |
| `SC-12-02-06` | PASS |  | 8.8s | Unit rows expose distinct actions and details targets |
| `SC-12-02-07` | PASS |  | 8.8s | Compact unit rows adapt from phone to desktop widths |
| `SC-12-03-04` | PASS |  | 11.9s | Choose an existing person through the live search API |
| `SC-12-04-01` | PASS |  | 10.6s | People paging and activation filters use the server query |
| `SC-12-06-04` | PASS | new | 14.0s | Unit actions started from the residents tab choose people through the person picker |
| `GUI-J-01` | PASS |  | 141.7s | test_saas_admin_journey[chromium] |
| `GUI-X-04` | PASS |  | 4.5s | test_mobile_viewport_login_and_dashboard[chromium-homeowner-ResidentHome] |
| `GUI-X-04` | PASS |  | 6.9s | test_mobile_viewport_login_and_dashboard[chromium-manager-ManagerCockpit] |
| `GUI-X-02` | PASS |  | 104.1s | test_theme_choice_on_login_screen_holds_after_login[chromium] |
| `GUI-03-05` | PASS |  | 6.8s | test_edit_site_updates_the_card[chromium] |
| `GUI-X-07` | PASS |  | 7.8s | test_each_tab_has_a_url_and_browser_back_returns_to_it[chromium] |
| `GUI-07-05` | PASS |  | 10.7s | test_confirming_matched_rows_keeps_the_unmatched_ones[chromium] |
| `GUI-07-03` | PASS |  | 9.1s | test_confirming_matched_rows_records_the_payment[chromium] |
| `GUI-07-05` | PASS |  | 10.4s | test_manual_assignment_records_the_payment[chromium] |
| `GUI-08-03` | PASS |  | 22.4s | test_household_members_survive_a_backend_restart[chromium] |
| `GUI-08-02` | PASS |  | 14.0s | test_owner_occupied_unit_operational_dues_go_to_the_owner[chromium] |
| `GUI-08-06` | PASS |  | 12.7s | test_ownership_transfer_records_the_previous_owners_period[chromium] |
| `GUI-08-01` | PASS |  | 14.8s | test_tenant_move_in[chromium] |
| `GUI-04-07` | PASS |  | 4.9s | test_co_resident_joins_through_a_unit_invite[chromium] |
| `GUI-09-06` | PASS |  | 8.3s | test_debt_aging_buckets_add_up_to_the_grand_total[chromium] |
| `GUI-09-06` | PASS |  | 6.5s | test_debt_aging_total_matches_the_open_ledger[chromium] |
| `GUI-04-08` | PASS |  | 5.5s | test_empty_approval_queue_shows_zero[chromium] |
| `GUI-X-06` | PASS |  | 7.1s | test_every_amount_uses_the_turkish_format[chromium] |
| `GUI-07-06` | PASS |  | 8.8s | test_payer_name_alias_auto_matches_the_transfer[chromium] |
| `GUI-01-06` | PASS |  | 5.5s | test_penalty_detail_shows_days_and_the_penalty_amount[chromium] |
| `GUI-X-05` | PASS |  | 5.7s | test_reload_never_leaves_a_broken_screen[chromium] |
| `GUI-08-08` | PASS |  | 8.2s | test_remove_tenant_only_keeps_the_owner[chromium] |
| `GUI-09-07` | PASS |  | 8.3s | test_virman_moves_advance_to_the_capital_due[chromium] |
| `GUI-02-06` | PASS |  | 9.9s | test_interim_operating_budget_becomes_the_legal_basis_of_accrued_dues[chromium] |

## Automated scenarios not executed in this run

`SC-05-06-01`, `SC-07-01-01`, `SC-07-01-02`, `SC-07-02-03`, `SC-07-03-02`, `SC-07-05-02`, `SC-07-06-01`, `SC-07-07-02`, `SC-07-07-03`, `SC-08-07-09`, `SC-08-07-10`, `SC-11-01-01`, `SC-11-01-02`, `SC-11-02-01`, `SC-11-02-02`, `SC-11-02-03`, `SC-11-02-04`, `SC-11-03-01`, `SC-11-03-02`, `SC-11-04-01`, `SC-11-04-02`, `SC-11-04-03`, `SC-11-05-01`, `SC-11-05-02`, `SC-11-05-03`, `SC-11-05-04`, `SC-11-06-01`, `SC-11-06-02`, `SC-11-07-01`, `SC-11-07-02`, `SC-11-07-03`, `SC-11-08-01`, `SC-11-08-02`, `SC-11-09-01`, `SC-11-09-02`, `SC-11-10-01`, `SC-11-10-02`, `SC-11-11-01`, `SC-11-12-01`, `SC-11-13-01`, `SC-11-14-01`, `SC-12-03-01`, `SC-12-03-02`, `SC-12-03-03`, `SC-12-05-01`, `SC-12-05-02`, `SC-12-05-03`, `SC-12-05-04`, `SC-12-05-05`, `SC-12-05-06`, `SC-12-06-01`, `SC-12-06-02`, `SC-12-06-03`, `SC-12-07-01`, `SC-12-07-02`, `SC-12-07-03`, `SC-12-08-01`, `SC-12-08-02`
