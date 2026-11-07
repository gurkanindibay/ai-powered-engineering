# SitePulse GUI Test Coverage: What Is Not Covered

Date: 2026-11-07. Scope: the browser suite in `e2e/` (Playwright, real backend and database) against the scenario catalogue in [GUI_TEST_PLAN.md](GUI_TEST_PLAN.md) and the Flutter UI in `flutter/lib/ui`.

**Bottom line.** All 83 catalogued scenarios now have at least one browser test. But the behaviour of 28 of them is never confirmed as working: those tests exist only as strict xfails that pin a known defect or a missing feature. In addition, about 20 UI features have no scenario at all, and the suite runs only in Chrome on a desktop viewport.

## 1. Numbers

| Measure | Value |
|---|---|
| Catalogued scenarios | 83 (P0 21, P1 46, P2 16) |
| Scenarios with at least one test | 83 (GUI-X-01 is enforced by the conftest page guard on every test; GUI-X-03 is tagged on GUI-03-03's test) |
| Tests | 96 runs from 94 test functions (two are parameterised per role) |
| Expected to pass / strict xfail | 54 / 42 |
| Scenarios verified only by xfail (behaviour not confirmed) | 28 |
| Scenarios with both a passing test and a pinned defect | 11 |
| User stories | 62: see the generated "GUI end-to-end coverage" section in `COMPLETION_STATUS.md` |

Latest full run: see §8.

## 2. Gap found while writing this report: GUI-02-01 had no test

GUI-02-01 (P0, STORY-02-01: cockpit collected amount and "%NN Tahsil Edildi" equal to the ledger) was listed as automated in the Phase 2/3 summaries but had no test. Writing it uncovered two more defects. It now has three tests:
- `test_epic02_manager.py::test_cockpit_shows_the_accrued_total_before_any_payment` (smoke, passes): with nothing paid, the cockpit shows the accrued total and %0.
- `…::test_cockpit_counts_a_payment_as_collected` (strict xfail): the cockpit drops paid flats from its totals. With 2 × ₺1.400,00 accrued and B Blok D:3 paid, it shows "₺0 / ₺1400" and "%0" instead of ₺1.400 / ₺2.800 and %50.
- `…::test_cockpit_amounts_keep_kurus` (strict xfail): amounts are printed with `toStringAsFixed(0)`, so 2 × ₺1.400,55 shows as "₺2801".

## 3. Scenarios whose intended behaviour is not verified (only strict xfails)

These tests pass only by failing. The behaviour the story asks for is untested until the defect is fixed and the `xfail` marker is removed (the strict marker turns the fix into a failure, so it cannot be missed).

| Area | Scenarios | Why |
|---|---|---|
| Approval workflow | GUI-04-02, 04-03, 04-04, 04-05 | The client never loads `/registration/pending`; reject is client-only |
| Bank reconciliation | GUI-07-04, 07-07, 07-08, 07-09 | Statement confirmation not persisted; bank account never loaded (format guard off); FAST webhook skips the KMK penalty |
| Matching | GUI-07-06 | Payer-name aliases are stored but ignored |
| Occupancy / ledger | GUI-08-02 | Liability id sequence left behind by period accrual; operational dues charged to TENANT on owner-occupied units |
| Dues filters and detail | GUI-02-02, GUI-01-06 | Overdue filter drops flats; penalty detail shows 0 days |
| Resident dashboard | GUI-01-03, 01-05 | Account movements lump principal and penalty; no offline banner |
| SaaS | GUI-03-05 | Site edit answers 400 but the UI shows success |
| Capital | GUI-10-06, 10-09, 10-10, 10-11, GUI-09-07 | No overdraw guard; virman units hard-coded; no owner capital line; no tenant badge |
| Payments | GUI-09-03 | No tenant statement (UI or API) |
| Invitations | GUI-04-01, 04-07 | No manager site invite link; owner-occupied units cannot take co-residents |
| Not implemented | GUI-01-04, 02-06, 02-07, GUI-06-11 | Announcements cannot be created; no reminders; Google sign-in is simulated |
| Formatting | GUI-X-06 | Several views print `₺1400.00` / `₺42000` instead of `₺1.400,00` |

The eleven scenarios that have both a passing test and a pinned defect (the passing part is verified): GUI-02-01, GUI-02-05, 02-08, 03-01, 04-06, 07-03, 07-05, 08-03, 08-06, 09-04, 09-06.

## 4. Scenario steps that were dropped (no UI for them)

| Scenario | Dropped step | Reason |
|---|---|---|
| GUI-09-01 | Period filter; totals, collection rate and channel split | The payment stream has role, channel and status filters only, and no totals in the embedded view |
| GUI-03-02 | Unit count and plan in the onboarding form | The form has no such fields (plan defaults to STANDARD) |
| GUI-04-01 | WhatsApp share | No share button; the manager has no invite at all |
| GUI-09-04 | Receipt download | "Paylaş / PDF" shows a toast; no file is produced |
| GUI-01-01, 07-08, 09-02 | The stories' exact amounts (e.g. ₺23,33 after 10 days) | The backend has no clock control; tests compare against the API's computed values instead |

## 5. UI features with no scenario

These screens and actions exist in the app but no catalogued scenario or test exercises them.

| Feature | Where | Role |
|---|---|---|
| Card payment (3D Secure path) in checkout | `components/payment_checkout_dialog.dart:559` `_buildCardPaymentView` | Homeowner |
| Manual cash payment dialog ("Nakit / Manuel Tahsilat") | `components/payment_tracking_page.dart:111` `openRecordManualPayment` | Manager |
| House type create and delete | `components/house_types_modal.dart:29`, `:145` | Manager |
| Capital project wizard validation (empty title, invalid budget) and contractor fields | `components/capital_projects_view.dart:1247` | Manager |
| Edit and delete household members | `dashboard/dashboard_screen.dart:1701`, `:1710` (`edit_member_*`, `delete_member_*`) | Manager |
| Responsible person, occupancy status, owner/residents tabs in the module | `residents/owners_residents_module_page.dart:589`, `:691`, `:1734` | Manager |
| Owner move-out (`move_out_ho_*`) | `dashboard/dashboard_screen.dart:1281` | Manager |
| SaaS site status and plan change in the edit form | `dashboard/dashboard_screen.dart:7931` | SaaS admin |
| "Site Değiştir" (multi-site manager) | `components/manager_cockpit_view.dart:112` | Manager |
| "Talep / Arıza" issue report | `dashboard/dashboard_screen.dart:5619` | Homeowner |
| Announcements view ("Duyurular", hard-coded "3 Yeni" badge) | `dashboard/dashboard_screen.dart:5740` | Homeowner |
| Receipts list ("Dekontlar") | `dashboard/dashboard_screen.dart:5329` | Homeowner |
| Payment stream channel and settlement filters, search | `components/payment_tracking_page.dart:1316` | Manager |
| Debt aging bracket cards (per flat) | `components/payment_tracking_page.dart:1529` | Manager |
| Full-screen bank reconciliation page | `components/bank_statement_reconciliation_page.dart` (`action_open_bank_reconciliation`) | Manager |
| Sender IBAN add/delete in the matching card | `components/unit_matching_criteria_card.dart:26` | Homeowner |
| "Çevrimdışı Simüle Et" toggle | `dashboard/dashboard_screen.dart:200` | Any |

## 6. Kinds of testing not covered

| Kind | Status |
|---|---|
| Other browsers | Only Chrome has been run. `scripts/gui_e2e.py --browser firefox|webkit` exists but was never exercised; clipboard checks degrade to toast-only there. |
| Mobile | Only a 375 px smoke test (login and dashboard, GUI-X-04), not the full scenarios. |
| Concurrency in the browser | No test has two users acting at once (e.g. manager approves while the resident logs in). The API system check covers concurrent payments at HTTP level only. |
| Input hardening | No XSS, injection or very long input tests through the UI. |
| Accessibility | No screen-reader, contrast or focus-order checks. The E2E build turns semantics on, but nothing asserts labels. |
| Visual / theme | Theme persistence is checked through a test-only label; nothing checks rendering. |
| Performance | No load-time or large-dataset (hundreds of units) checks. |
| Session persistence | Reload returns to the login screen; the test accepts it as current behaviour because the stories do not specify it. |

## 7. Process gaps

- **CI:** the `gui-e2e` gate runs locally through `scripts/run_tests.py`; it is not in GitHub Actions (needs PostgreSQL, Rust, Flutter and Chrome on the runner). Without it, a regression is only caught when someone runs the suite.
- **Flakiness:** the 12-minute full run exposed three timing-sensitive steps (login tab, residents search, tenant removal) that passed when run alone. They now retry or poll for the end state; a repeated full run is the check (§8).
- **EPIC-05** is outside the GUI suite by design (backend gates).

## 8. Latest full run

`python3 scripts/run_tests.py --only testid-lint,harness-selftest,gui-e2e` (2026-11-07): testid-lint and harness-selftest PASSED. gui-e2e FAILED: 96 tests, **52 passed, 42 strict xfail, 2 failed** in 12 minutes.

**Open issue:** GUI-08-07 (residents search) and GUI-08-08 (remove the tenant only) fail in every full-suite run but pass on their own, with the P2 file alone, and with the EPIC-09, EPIC-10 and P2 files together. Their screenshots show the search returning the right single card and the tenant-removal dialog closing without effect. The per-test reset truncates every table and restarts the backend, and the theme toggle is not persisted, so the leak is not yet found. Both tests now report the ids on screen and the database rows when they fail, so the next full run will show what differs.

## 9. Recommended next steps (in order)

1. Fix the defects behind the 28 xfail-only scenarios, starting with data integrity: the liability id sequence, the webhook penalty allocation, statement confirmation and manual assignment persistence, household member persistence.
2. Add scenarios for §5, starting with money paths: card checkout, manual cash, house type create/delete, wizard validation.
3. Run the suite in CI (nightly is enough given its length), at least for `-m smoke`.
4. Run Firefox and WebKit once and record differences; then decide which browsers to keep.
5. Extend the mobile run from smoke to the P0 set.
