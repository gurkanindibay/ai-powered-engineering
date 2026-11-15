# Test run 20261115T190712Z-7d1dd84

- **Task:** master
- **Result:** PASS (2 SKIPPED, 117 PASS)
- **Executed:** 119 tests in 3138s, covering 93 of 149 automated scenarios
- **Commit:** `7d1dd840a9` on `master`
- **Started:** 2026-11-15T19:07:12Z (ci)

## Executed tests

| Scenario / GUI id | Status | Change | Time | Name |
|---|---|---|---|---|
| `SC-01-02-01` | PASS |  | 6.9s | Calculate 10-day overdue statutory delay penalty |
| `SC-01-03-01` | PASS |  | 6.9s | Emit reactive state on dashboard launch |
| `SC-01-03-02` | PASS |  | 5.5s | Site announcement reaches the resident |
| `SC-01-04-01` | PASS |  | 6.9s | Render resident hero balance with overdue amount |
| `SC-01-04-02` | PASS |  | 306.7s | Render zero balance without overdue badge |
| `SC-01-05-01` | PASS |  | 5.6s | View recent financial movements |
| `SC-01-06-01` | PASS |  | 7.1s | Display cached dues when network is offline |
| `SC-02-01-01` | PASS |  | 7.1s | Cockpit shows the accrued total before any payment |
| `SC-02-01-02` | PASS |  | 7.0s | Cockpit counts a payment as collected |
| `SC-02-01-03` | PASS |  | 5.1s | Cockpit amounts keep kurus |
| `SC-02-01-04` | PASS |  | 9.2s | House type tariff is saved and a negative amount is rejected |
| `SC-02-01-05` | PASS |  | 9.7s | House type tariff rejects more than two decimals |
| `SC-02-02-01` | PASS |  | 7.3s | Overdue filter lists every overdue flat |
| `SC-02-03-01` | PASS |  | 13.5s | Manager adds a new home owner manually |
| `SC-02-03-02` | PASS |  | 14.4s | Adding a resident to an occupied unit warns and saves nothing |
| `SC-02-03-03` | PASS |  | 233.9s | A resident without ledger history can be deleted |
| `SC-02-03-04` | PASS |  | 9.4s | A refused delete keeps the resident card |
| `SC-02-04-01` | PASS |  | 8.1s | Reminder action is offered for overdue flats |
| `SC-02-05-01` | PASS |  | 8.7s | Manager creates an announcement |
| `SC-03-01-01` | PASS |  | 6.1s | Query operations strictly scoped by tenant |
| `SC-03-02-01` | PASS |  | 5.7s | SaaS Admin views portfolio overview |
| `SC-03-02-02` | PASS |  | 1.3s | Portfolio statistics agree with the site list |
| `SC-03-03-01` | PASS |  | 8.9s | SaaS Admin creates new site and provisions first Site Admin |
| `SC-03-04-01` | PASS |  | 8.9s | Generate temporary password for newly registered Site Admin |
| `SC-03-04-02` | PASS |  | 7.0s | New manager is forced to change the temporary password |
| `SC-03-06-01` | PASS |  | 10.0s | Delete site without any related actions |
| `SC-03-06-02` | PASS |  | 4.9s | Invariant prevents deletion of active site with transactions |
| `SC-03-07-01` | PASS |  | 9.3s | SaaS Admin renews temporary password for a site manager |
| `SC-04-01-01` | PASS |  | 8.8s | Generate 7-day secure invite link |
| `SC-04-02-01` | PASS |  | 8.8s | Site Admin copies or shares invite link |
| `SC-04-04-01` | PASS |  | 8.9s | Site manager views pending applications |
| `SC-04-05-01` | PASS |  | 6.8s | Approve applicant and provision account |
| `SC-04-05-02` | PASS |  | 7.1s | Approved resident signs in with the issued password |
| `SC-04-06-01` | PASS |  | 6.5s | Reject unverified registration |
| `SC-04-07-01` | PASS |  | 7.1s | Home owner generates unit-scoped invitation link |
| `SC-04-07-01` | PASS |  | 5.1s | Home owner generates unit-scoped invitation link |
| `SC-06-01-01` | PASS |  | 6.2s | Home resident is restricted from site-wide management |
| `SC-06-02-02` | PASS |  | 6.7s | Site manager signs in and reaches the cockpit |
| `SC-06-02-03` | PASS |  | 4.4s | Home owner signs in and reaches the resident dashboard |
| `SC-06-02-04` | PASS |  | 5.7s | Wrong password shows an error and stays on the login screen |
| `SC-06-02-05` | PASS |  | 4.1s | Clearing the login cache empties the credential fields |
| `SC-06-02-05` | PASS |  | 3.6s | Clearing the login cache empties the credential fields |
| `SC-06-02-06` | PASS |  | 4.2s | Empty password is rejected without a request |
| `SC-06-03-02` | SKIPPED |  | 2.2s | Google sign-in button starts the provider flow |
| `SC-06-04-02` | PASS |  | 16.4s | Home owner changes the password from the profile and signs in again |
| `SC-06-04-03` | PASS |  | 9.6s | Logout returns to the login screen |
| `SC-06-04-04` | PASS |  | 12.3s | Browser back after logout does not re-enter the session |
| `SC-06-04-05` | PASS |  | 7.6s | Manager switches between the cockpit and the own flat |
| `SC-06-04-06` | PASS |  | 11.1s | Cancelling the logout confirmation keeps the session |
| `SC-06-05-01` | SKIPPED |  | 2.2s | Google sign-in option is offered on the login screen |
| `SC-06-05-03` | PASS |  | 6.7s | Email and password sign-in opens the role dashboard |
| `SC-06-06-01` | PASS |  | 7.5s | SaaS admin with a temporary password is held at the password change screen |
| `SC-06-06-02` | PASS |  | 344.7s | Site manager with a temporary password is held at the password change screen |
| `SC-06-06-03` | PASS |  | 240.1s | Home owner with a temporary password is held at the password change screen |
| `SC-06-06-04` | PASS |  | 247.9s | Home resident with a temporary password is held at the password change screen |
| `SC-06-06-05` | PASS |  | 307.7s | Auditor with a temporary password is held at the password change screen |
| `SC-07-02-01` | PASS |  | 6.5s | Site manager uploads a bank statement Excel file |
| `SC-07-02-02` | PASS |  | 10.9s | Approving a matched row clears the resident's balance |
| `SC-07-02-04` | PASS |  | 8.9s | An unmatched row is assigned to a unit by hand |
| `SC-07-03-01` | PASS |  | 5.4s | Real-time incoming transfer clears dues once |
| `SC-07-04-01` | PASS |  | 6.0s | Resident chooses the FAST transfer payment method |
| `SC-07-04-02` | PASS |  | 5.7s | Copy button puts the unspaced IBAN on the clipboard |
| `SC-07-05-01` | PASS |  | 5.8s | Surplus transfer is allocated to the resident advance balance |
| `SC-07-06-02` | PASS |  | 15.8s | Wrong statement format is rejected and the matching format is accepted |
| `SC-07-07-01` | PASS |  | 21.3s | Manager accrues a period once and the duplicate is blocked |
| `SC-08-01-01` | PASS |  | 18.1s | Accrue monthly operational dues to tenant and capital project to owner |
| `SC-08-02-01` | PASS |  | 21.4s | Household members are bound to the active resident session |
| `SC-08-03-01` | PASS |  | 8.8s | Move-out preserves historical payment receipts and unsettled debt |
| `SC-08-04-01` | PASS |  | 9.4s | New tenant moves in and past occupancy history is retrievable |
| `SC-08-05-01` | PASS |  | 14.3s | Change property owner upon title deed sale without affecting tenant |
| `SC-09-01-01` | PASS |  | 7.2s | Filter payment stream by tenant payments for current month |
| `SC-09-02-01` | PASS |  | 6.7s | Settle delay penalty first, then oldest dues, then credit surplus as advance |
| `SC-09-03-01` | PASS |  | 7.5s | Generate itemized sub-ledger statement for a tenant |
| `SC-09-03-02` | PASS |  | 7.0s | Resident statement ages an overdue due with its penalty |
| `SC-09-04-01` | PASS |  | 4.9s | Issue sequential payment receipt upon settlement |
| `SC-09-04-02` | PASS |  | 10.9s | Manager downloads the receipt PDF and reverses the receipt |
| `SC-09-04-03` | PASS |  | 6.7s | Receipt shows the penalty, principal and advance split |
| `SC-09-04-04` | PASS |  | 7.8s | Card payment on the provider page issues a receipt |
| `SC-10-01-01` | PASS |  | 12.1s | Budget is split by land share without rounding drift |
| `SC-10-01-02` | PASS |  | 11.1s | Equal allocation gives every unit the same share |
| `SC-10-02-01` | PASS |  | 13.7s | Accruing an installment charges owners only |
| `SC-10-03-01` | PASS |  | 6.4s | Owner FAST payment raises the collected amount of the project |
| `SC-10-03-02` | PASS |  | 8.7s | Tenant payment produces a TBK 314 rent-offset receipt |
| `SC-10-04-01` | PASS |  | 6.5s | Virman dialog offers the real advance balance of the unit |
| `SC-10-05-01` | PASS |  | 9.4s | Disbursement within collected cash updates the reserve |
| `SC-10-05-02` | PASS |  | 16.8s | Disbursement larger than collected cash is refused |
| `SC-10-06-01` | PASS |  | 7.0s | Owner dashboard shows capital dues separately |
| `SC-10-06-02` | PASS |  | 5.6s | Capital project is marked as the responsibility of the owner |
| `SC-10-07-01` | PASS |  | 7.7s | Capital segment offers project creation |
| `SC-12-02-05` | PASS |  | 11.0s | Unit search folds Turkish names and phone digits |
| `SC-12-02-06` | PASS |  | 11.0s | Unit rows expose distinct actions and details targets |
| `SC-12-02-07` | PASS |  | 11.0s | Compact unit rows adapt from phone to desktop widths |
| `SC-12-03-04` | PASS |  | 12.1s | Choose an existing person through the live search API |
| `SC-12-04-01` | PASS |  | 9.6s | People paging and activation filters use the server query |
| `SC-12-06-04` | PASS | new | 14.3s | Unit actions started from the residents tab choose people through the person picker |
| `GUI-J-01` | PASS |  | 266.2s | test_saas_admin_journey[chromium] |
| `GUI-X-04` | PASS |  | 4.7s | test_mobile_viewport_login_and_dashboard[chromium-homeowner-ResidentHome] |
| `GUI-X-04` | PASS |  | 6.8s | test_mobile_viewport_login_and_dashboard[chromium-manager-ManagerCockpit] |
| `GUI-X-02` | PASS |  | 231.5s | test_theme_choice_on_login_screen_holds_after_login[chromium] |
| `GUI-03-05` | PASS |  | 6.7s | test_edit_site_updates_the_card[chromium] |
| `GUI-X-07` | PASS |  | 7.9s | test_each_tab_has_a_url_and_browser_back_returns_to_it[chromium] |
| `GUI-07-05` | PASS |  | 9.3s | test_confirming_matched_rows_keeps_the_unmatched_ones[chromium] |
| `GUI-07-03` | PASS |  | 10.9s | test_confirming_matched_rows_records_the_payment[chromium] |
| `GUI-07-05` | PASS |  | 12.6s | test_manual_assignment_records_the_payment[chromium] |
| `GUI-08-03` | PASS |  | 19.9s | test_household_members_survive_a_backend_restart[chromium] |
| `GUI-08-02` | PASS |  | 13.9s | test_owner_occupied_unit_operational_dues_go_to_the_owner[chromium] |
| `GUI-08-06` | PASS |  | 15.3s | test_ownership_transfer_records_the_previous_owners_period[chromium] |
| `GUI-08-01` | PASS |  | 12.5s | test_tenant_move_in[chromium] |
| `GUI-04-07` | PASS |  | 4.8s | test_co_resident_joins_through_a_unit_invite[chromium] |
| `GUI-09-06` | PASS |  | 8.9s | test_debt_aging_buckets_add_up_to_the_grand_total[chromium] |
| `GUI-09-06` | PASS |  | 6.5s | test_debt_aging_total_matches_the_open_ledger[chromium] |
| `GUI-04-08` | PASS |  | 5.3s | test_empty_approval_queue_shows_zero[chromium] |
| `GUI-X-06` | PASS |  | 6.3s | test_every_amount_uses_the_turkish_format[chromium] |
| `GUI-07-06` | PASS |  | 6.9s | test_payer_name_alias_auto_matches_the_transfer[chromium] |
| `GUI-01-06` | PASS |  | 7.0s | test_penalty_detail_shows_days_and_the_penalty_amount[chromium] |
| `GUI-X-05` | PASS |  | 6.9s | test_reload_never_leaves_a_broken_screen[chromium] |
| `GUI-08-08` | PASS |  | 8.2s | test_remove_tenant_only_keeps_the_owner[chromium] |
| `GUI-09-07` | PASS |  | 8.3s | test_virman_moves_advance_to_the_capital_due[chromium] |
| `GUI-02-06` | PASS |  | 8.6s | test_interim_operating_budget_becomes_the_legal_basis_of_accrued_dues[chromium] |

## Automated scenarios not executed in this run

`SC-05-06-01`, `SC-07-01-01`, `SC-07-01-02`, `SC-07-02-03`, `SC-07-03-02`, `SC-07-05-02`, `SC-07-06-01`, `SC-07-07-02`, `SC-07-07-03`, `SC-11-01-01`, `SC-11-01-02`, `SC-11-02-01`, `SC-11-02-02`, `SC-11-02-03`, `SC-11-02-04`, `SC-11-03-01`, `SC-11-03-02`, `SC-11-04-01`, `SC-11-04-02`, `SC-11-04-03`, `SC-11-05-01`, `SC-11-05-02`, `SC-11-05-03`, `SC-11-05-04`, `SC-11-06-01`, `SC-11-06-02`, `SC-11-07-01`, `SC-11-07-02`, `SC-11-07-03`, `SC-11-08-01`, `SC-11-08-02`, `SC-11-09-01`, `SC-11-09-02`, `SC-11-10-01`, `SC-11-10-02`, `SC-11-11-01`, `SC-11-12-01`, `SC-11-13-01`, `SC-11-14-01`, `SC-12-03-01`, `SC-12-03-02`, `SC-12-03-03`, `SC-12-05-01`, `SC-12-05-02`, `SC-12-05-03`, `SC-12-05-04`, `SC-12-05-05`, `SC-12-05-06`, `SC-12-06-01`, `SC-12-06-02`, `SC-12-06-03`, `SC-12-07-01`, `SC-12-07-02`, `SC-12-07-03`, `SC-12-08-01`, `SC-12-08-02`
