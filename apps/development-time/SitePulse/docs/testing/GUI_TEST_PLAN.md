# SitePulse GUI Test Plan (Scenario Catalogue)

> **Catalogue only.** The scenario IDs, steps and selector names below are retained for traceability. Historical execution notes have been removed. Current test status is reported by CI and the [SitePulse Test Strategy](TEST_STRATEGY.md). The current browser suite has no xfail markers.

Status: Phase 0 output of [GUI_AUTOMATION_PLAN.md](GUI_AUTOMATION_PLAN.md). Built from `.specify/requirements/EPIC-01..10` at master `8d0d1d3`.
Scope: the Flutter web client driven in a real browser (Playwright), against the real Rust backend and PostgreSQL.

## 1. How to read this catalogue

- **ID** `GUI-<epic>-<nn>`. **Story** is the requirement id it traces to.
- **Pri**: P0 = smoke (every run), P1 = core (each merge), P2 = edge (nightly).
- **Arrange** is how the test sets up its data before it touches the UI:
  - `seed` means the base seed (`backend/db/seed/02-test-seed.sql` + `POST /api/v1/system/seed-test-fixtures`) is enough.
  - `api:<builder>` means a data builder in `e2e/support/api.py` (Section 4) creates the extra data through the REST API.
  - `ui:<GUI-id>` means the data comes from running another scenario's UI flow first.
- **Selectors** are existing `Key` ids, which Phase 1 mirrors as `flt-semantics-identifier`. `NEW:` marks an id that Phase 1 must add.
- **UI** is the result of a label/key search of `flutter/lib` on 2026-11-07, **not yet confirmed in a running app**:
  - ✅ the id or label exists
  - ◐ something close exists but the wording or flow differs from the story
  - This item was a historical product gap; check current feature scenarios and CI results for its status.
- **DB check** means after the UI asserts, the test also reads the value back with `scripts/db_verify.py query-json` or the API and compares it as an exact `Decimal`.

## 2. Test data and actors

| Actor | Login | Source |
|---|---|---|
| Site Manager (Begonya Sitesi) | `mehmet.demir@begonya.com` / test password from `backend/src/state.rs` seed | seed |
| Home Owner, A Blok D:14 | `ahmet.yilmaz@begonya.com` / seed test password | seed |
| Home Owner, B Blok D:3 | `mehmet.oz@begonya.com` / password in a fixture config (hash only in SQL) | seed |
| SaaS Admin | `admin@sitepulse.io` / `bootstrap_admin_password()` read from backend env; `must_change_password = true` | seed |
| Home resident (household member of A Blok D:14) | created per journey through the owner's unit invite; temporary password from the registration | api builders |
| Auditor (denetçi), Begonya Sitesi | created per journey with SQL (no API issues auditor accounts) | SQL arrange |
| Tenants, co-residents, new owners (Selin Demir, Canan Kaya, Zeynep Kaya, Selim Evsahibi, Burak Demir, Kerem Yılmaz …) | created per test | api builders |

Passwords are never written into test files. `e2e/fixtures/actors.example.json` holds the dev-only seed passwords, and the real file is gitignored.

**Base seed today:** sites Begonya Sitesi + Kardelen Rezidans; units A Blok D:14 (owner Ahmet, land share 24) and B Blok D:3 (owner Mehmet Öz); a Kuveyt Türk bank account; house types. **There are no dues periods, tenants, capital projects or registrations**, so most scenarios rely on api builders.

## 3. Scenario catalogue

### EPIC-13 Site Admin journeys (backend and GUI scenarios are tracked in `.specify/features/EPIC-13`)
| ID | Story | Role | Pri | Arrange | Steps → Expected | Selectors | UI |
|---|---|---|---|---|---|---|---|
| GUI-13-01 | 13-05 | Manager | P1 | F1 | Import a workbook with valid people and one invalid national id → good rows are reported and the invalid row is rejected (`SC-13-05-10`, pending) | Journey GUI flow not implemented | ⏳ |
| GUI-13-02 | 13-05 | Manager | P1 | F5 | Check out a tenant with debt → debt split and owner collection details are visible (`SC-13-05-17`, blocked by #207) | Journey GUI flow not implemented | ⏳ |
| GUI-13-03 | 13-11 | Manager | P1 | F2 | Period rows show their statuses and only their allowed actions (`SC-13-11-05`, pending) | Journey GUI flow not implemented | ⏳ |
| — | 13-09 | — | — | — | **Excluded:** financial transitions in this story are specified at the backend layer; no GUI scenario is in scope. | | |

### EPIC-06 Identity, Authentication & Permissions (run first; every other test depends on login)
| ID | Story | Role | Pri | Arrange | Steps → Expected | Selectors | UI |
|---|---|---|---|---|---|---|---|
| GUI-06-01 | 06-02 | Manager | P0 | seed | Clear the prefilled fields, enter valid manager credentials, submit → Manager cockpit loads ("Site Yönetim Paneli") | NEW:`login_manager_email`, `login_manager_password`, `login_manager_submit`; `btn_open_unified_dues_center` | ◐ fields have no ids |
| GUI-06-02 | 06-02 | Homeowner | P0 | seed | Same, in the homeowner panel → resident dashboard with hero balance card | NEW:`login_homeowner_*`; NEW:`hero_balance_card` | ◐ |
| GUI-06-03 | 06-02 | Any | P0 | seed | Wrong password → `login_error_banner` shown, still on the login screen | `login_error_banner` | ✅ |
| GUI-06-04 | 06-02 | Any | P2 | seed | Empty email or password → validation message, no request sent (check the network log) | NEW:login ids | ◐ |
| GUI-06-05 | 06-02 | Any | P1 | seed | Clear login cache (homeowner and manager) → fields empty | `btn_clear_login_cache_homeowner`, `btn_clear_login_cache_manager` | ✅ |
| GUI-06-06 | 03-04/06-04/06-06 | SaaS | P0 | seed | Log in with the bootstrap password → forced `screen_force_password_change` (no dashboard) → change password → log out → log in with the new password succeeds and the old one fails | `screen_force_password_change`, `change_password_{current,new,confirm}`, `btn_submit_change_password` | ✅ |
| GUI-06-07 | 06-04 | Homeowner | P1 | seed | Profile sheet → change password → re-login works | `btn_change_password_sheet` | ✅ |
| GUI-06-08 | 06-04 | Any role | P1 | seed | Profile sheet → logout → back on the login screen; browser back does not re-enter the dashboard | NEW:`btn_logout` ("Çıkış") | ◐ |
| GUI-06-09 | 06-01 | Homeowner | P1 | seed | Homeowner session shows no manager actions (no cockpit, no unified dues center, no SaaS); a direct manager API call made with the page token returns 403 | absence of `btn_open_unified_dues_center` | ✅ |
| GUI-06-10 | 06-04 | Manager | P1 | seed | Switch the active path to "Kendi Dairem (Kat Maliki)" → the manager's own flat dashboard opens; switch back → cockpit | NEW:`role_path_manager_cockpit`, `role_path_my_flat` | ◐ |
| GUI-06-11 | 06-05/06-03 | Any | P2 | seed | "Google ile Giriş Yap" button is visible and starts the flow (stop at the redirect; assert the target host only) | NEW:`btn_google_sign_in` | ✅ |
| — | 06-03 | — | — | — | **Excluded:** the full Google sign-in can't run against Google's real sign-in page in automation. Covered by backend `when_valid_google_id_token_*` tests. | | |

### EPIC-01 Resident Dues & Financial Transparency
| ID | Story | Role | Pri | Arrange | Steps → Expected | Selectors | UI |
|---|---|---|---|---|---|---|---|
| GUI-01-01 | 01-03/01-04 | Homeowner | P0 | api:`overdue_dues(unit=A14, amount=1400.00, days=10)` | Log in → hero card shows **₺1.423,33** and "10 Gün Gecikme (%5 KMK)". DB check: total equals the API `totalDue` | NEW:`hero_balance_amount`, `hero_overdue_badge` | ✅ |
| GUI-01-02 | 01-04 | Homeowner | P1 | api:`no_dues(A14)` | Log in → "no outstanding dues" state, no overdue badge | NEW:`hero_balance_amount` | ✅ |
| GUI-01-03 | 01-05 | Homeowner | P1 | as GUI-01-01 | Open account movements → rows "Eylül 2026 Aidatı ₺1.400,00" and "KMK Gecikme Tazminatı +₺<penalty>" | NEW:`ledger_row_*` | ✅ section "HESAP HAREKETLERİ →" (`_buildHesapHareketleriSection`) |
| GUI-01-04 | 01-03 | Homeowner | P1 | api:`announcement(site-1)` | Dashboard shows the site announcement in "Site Duyuruları" | NEW:`announcement_list` | ✅ |
| GUI-01-05 | 01-06 | Homeowner | P2 | as GUI-01-01 | Load the dashboard, set the browser context offline, reload state → "Çevrimdışı" banner, last balance still shown | NEW:`offline_banner` | ✅ |
| GUI-01-06 | 01-04 | Homeowner | P2 | as GUI-01-01 | Detail of the delay penalty ("KMK Madde 20 Yasal Gecikme Cetveli") lists days and penalty ₺23,33 | NEW:`penalty_detail` | ✅ |
| — | 01-01, 01-02 | — | — | — | **Excluded:** pure domain math, covered by `calculate_dues_usecase_test.dart` and Rust unit tests. Their visible result is asserted in GUI-01-01. | | |

### EPIC-02 Site Manager Operations
| ID | Story | Role | Pri | Arrange | Steps → Expected | Selectors | UI |
|---|---|---|---|---|---|---|---|
| GUI-02-01 | 02-01 | Manager | P0 | api:`dues_period(site-1, paid_ratio=...)` | Cockpit shows collected amount and "%NN Tahsilat" badge equal to API totals (exact Decimal) | NEW:`cockpit_collected_amount`, `cockpit_collection_rate` | ✅ |
| GUI-02-02 | 02-02 | Manager | P1 | api:`overdue_dues(A14)` + `paid_dues(B3)` | Unified dues center → "🔴 Geciken (n)" filter → only overdue flats listed (A Blok D:14), count equals n | `btn_open_unified_dues_center`, `segment_tab_*`, `subtab_button_*` | ◐ label is "Geciken", not "Gecikmede" |
| GUI-02-03 | 02-03 | Manager | P0 | seed | Residents module → add new resident (block B, unit 25, "Fatma Şahin", fatma@gmail.com) → save → unit appears in the list and the unit count goes up by 1. DB check: unit exists | `btn_cockpit_manage_residents`, `module_add_new_resident_btn`, `module_new_resident_*`, `module_save_new_resident_btn` | ✅ |
| GUI-02-04 | 02-03 | Manager | P2 | seed | Add a resident to an already occupied unit → duplicate warning ("halihazırda kayıtlı sakin") and the unit is unchanged (the person card chosen in the picker stays without a role) | as above, `sp_person_create`, `person_form_*` | ✅ |
| GUI-02-05 | 02-03 | Manager | P1 | ui:GUI-02-03 | Delete that resident → confirm dialog → removed. DB check: soft-delete/archive follows the zero-data-loss rule | `btn_delete_resident_*`, `btn_confirm_delete_resident` | ✅ |
| GUI-02-06 | 02-04 | Manager | P1 | api:`overdue_dues(A14)` | Payment tracking → "Hatırlat" on A Blok D:14 → confirmation toast | NEW:`btn_remind_*` | ❌ **confirmed gap**: "Hatırlatma SMS" is only a caption on the aging tile; no reminder or message action exists |
| GUI-02-07 | 02-05 | Manager → Homeowner | P1 | seed | Manager creates announcement "Planlı Su Kesintisi" → visible in the manager feed → log in as homeowner → visible there | NEW:`btn_create_announcement` | ❌ **confirmed gap**: announcements are display-only; no create UI and no backend route |
| GUI-02-08 | 02-01 | Manager | P1 | seed | House types modal: edit the 2+1 tariff → saved; invalid amount (negative, or more than 2 decimals) → validation error | NEW:`house_type_*` | ✅ |

### EPIC-03 SaaS Multi-Tenancy & Onboarding
| ID | Story | Role | Pri | Arrange | Steps → Expected | Selectors | UI |
|---|---|---|---|---|---|---|---|
| GUI-03-01 | 03-02 | SaaS | P0 | seed (password already changed via api) | SaaS dashboard shows Begonya Sitesi and Kardelen Rezidans cards plus totals (sites, units, monthly dues) equal to the API | NEW:`saas_site_card_*`, `saas_total_*` | ✅ |
| GUI-03-02 | 03-03/03-04 | SaaS | P0 | seed | "Yeni Site" → fill "Palmiye Evleri Sitesi", Kadıköy/İstanbul, 40 units, plan, admin Murat Yıldırım → save → credentials dialog with `SP-XXXX-YYYY` password and copy button → new card in the portfolio. DB check: slug `palmiye-evleri-sitesi`, SITE_MANAGER user | `add_site_blocks_field`, `btn_save_new_site`, NEW:`credentials_dialog_password`, `btn_copy_credentials` | ✅ |
| GUI-03-03 | 03-04/06-06 | New manager | P1 | ui:GUI-03-02 | Log in with the issued temporary password → forced password change screen (cockpit not reachable) → cockpit of the new, empty site (zero-data guidance) | `screen_force_password_change` | ✅ |
| GUI-03-04 | 03-01 | Manager | P1 | api:`unit(kardelen-rezidans)` | Begonya manager never sees Kardelen units or totals anywhere in the cockpit or residents module | residents list | ✅ |
| GUI-03-05 | 03-02 | SaaS | P1 | seed | Edit site → change name/address/admin phone → save → card updated | `btn_edit_site_*`, `edit_site_*_field`, `btn_save_site_edit` | ✅ |
| GUI-03-06 | 03-06 | SaaS | P1 | ui:GUI-03-02 (empty site) | Delete the empty site → confirm → removed from the portfolio | NEW:`btn_delete_site_*` | ✅ "Sil" |
| GUI-03-07 | 03-06 | SaaS | P1 | seed | Try to delete Begonya (has units) → blocked with the invariant message ("aktif daireler … bulunmaktadır") and the card stays | NEW:`btn_delete_site_*` | ✅ |
| GUI-03-08 | 03-07 | SaaS | P1 | seed | "Şifre Yenile" on a site → new `SP-XXXX-PASS` password dialog; the old manager password stops working | NEW:`btn_reset_admin_password_*` | ✅ |
| — | 03-05 | — | — | — | **Excluded:** REST contract, covered by `scripts/api_system_check.py`. | | |
| — | 11-01, 11-02, 11-03, 11-04, 11-05, 11-06, 11-07, 11-08, 11-09, 11-10, 11-11, 11-12, 11-13, 11-14 | — | — | — | **Excluded:** payments phase 3 has no GUI scenarios yet; covered by `backend/tests/payments_phase3_tests.rs`, `flutter/test/payments_phase3_test.dart` and `scripts/api_system_check.py`. | | |
| — | 12-01 | — | — | — | **Excluded:** backend schema foundation; GUI coverage belongs to the API and client stories that follow. | | |
| — | 12-03 | — | — | — | **Partial (confirmed gap):** shared person picker and form components are tested as Flutter widgets but are not wired into a manager screen yet; browser coverage follows when action flows integrate them in issue #99. | | |
| — | 12-05 | — | — | — | **Excluded:** REST and persistence contract with no GUI surface yet; covered by `backend/tests/db_person_api_tests.rs` and `scripts/api_system_check.py`. | | |
| — | 08-12, 12-10 | — | — | — | **Excluded:** repeated unit and person actions are checked against the API and the database; covered by `backend/tests/db_unit_person_action_cycles_tests.rs`. | | |
| — | 07-08, 07-09, 07-10, 07-11, 07-12, 07-13 | — | — | — | **Partial (confirmed gap):** accrual integrity stories (canonical period, atomic batch, proration, catch-up and grace, corrections, period close, late-fee consistency) are specified with `@pending` scenarios and not implemented yet; browser coverage follows with each implementation. | | |
| — | 12-06 | — | — | — | **Partial (confirmed gap):** unit action pages choose people through the shared person field; covered by Flutter widget tests (`owners_residents_module_test.dart`, `responsible_contact_selection_test.dart`, `unit_registration_person_refs_test.dart`); browser coverage follows with the picker flow. | | |

### EPIC-04 Invitation & Approval Workflow
| ID | Story | Role | Pri | Arrange | Steps → Expected | Selectors | UI |
|---|---|---|---|---|---|---|---|
| GUI-04-01 | 04-01/04-02 | Manager | P1 | seed | "Davet Linki" → modal shows a `.../join/begonya-sitesi?token=...` URL, a WhatsApp share button and "Linki Kopyala" → clipboard holds the URL and a toast "Davet linki kopyalandı!" appears | `btn_invite_resident_link`, NEW:`invite_link_text`, `btn_copy_invite_link`, `btn_share_whatsapp` | ✅ |
| GUI-04-02 | 04-04 | Manager | P0 | api:`registration_request(Kerem Yılmaz, B Blok D:18)` ×2 | Cockpit shows "Onay Bekleyen Başvurular" with badge "2 Bekliyor"; each card shows block, unit, contact and age | NEW:`pending_badge`, `pending_card_*` | ✅ |
| GUI-04-03 | 04-05 | Manager | P0 | as GUI-04-02 | "Onayla & Şifre Üret" on Kerem → credentials dialog (`SP-SAKIN-…`) → badge 2→1 → Kerem appears in the dues ledger. DB check: user active | NEW:`btn_approve_*`, `credentials_dialog_password` | ✅ |
| GUI-04-04 | 04-06 | Manager | P1 | as GUI-04-02 | "Reddet" → card leaves the queue. DB check: status REJECTED | NEW:`btn_reject_*` | ✅ |
| GUI-04-05 | 04-05 | Approved resident | P1 | ui:GUI-04-03 | Log in as Kerem with the issued password → forced change → dashboard for B Blok D:18 only | login ids | ✅ |
| GUI-04-06 | 04-07 | Homeowner | P1 | seed | Household → generate unit invite link → URL contains `/units/<id>` and the warning "Bu link sadece A Blok D:14 yetkisi tanımlar…" is shown | NEW:`btn_unit_invite_link` | ◐ |
| GUI-04-07 | 04-07 | Co-resident | P2 | api:`unit_invite_registration(Zeynep, SPOUSE, A14)` | Zeynep logs in → sees A Blok D:14 dues only and appears in the household member list. The API for another unit returns 403 | household list | ◐ |
| GUI-04-08 | 04-02 | Manager | P2 | seed | Empty queue → "Onay Bekleyen Başvuru Bulunmuyor" | — | ✅ |
| — | 04-03 | — | — | — | **Partial (confirmed gap):** there's no public self-registration form in the Flutter app; it only generates the `/join/...` invite URL. Registrations are created through `POST /api/v1/registration/submit/:slug` in Arrange. | | |

### EPIC-07 Bank Integration & Reconciliation
| ID | Story | Role | Pri | Arrange | Steps → Expected | Selectors | UI |
|---|---|---|---|---|---|---|---|
| GUI-07-01 | 07-01/07-04 | Homeowner | P0 | seed | Virtual IBAN card shows the 26-character TR IBAN, spaced; "IBAN Kopyala" → clipboard holds the unspaced IBAN, toast "IBAN kopyalandı". DB check: equals `units.virtual_iban` | NEW:`virtual_iban_text`, `btn_copy_iban` | ✅ |
| GUI-07-02 | 07-04 | Homeowner | P1 | api:`overdue_dues(A14)` | "Hemen Öde" → checkout dialog → FAST/virtual IBAN option shows the IBAN and the "no description needed" explanation | NEW:`btn_pay_now`, `checkout_option_fast` | ◐ exact story text differs |
| GUI-07-03 | 07-02 | Manager | P0 | api:`overdue_dues(A14, 1423.33)` | Bank reconciliation → upload `fixtures/bank/kuveyt_excel_a14.xlsx` → the row matches A Blok D:14 at 100% for ₺1.423,33 and shows status pending approval | `action_open_bank_reconciliation`, `btn_stream_upload_bank_statement` | ✅ |
| GUI-07-04 | 07-02 | Manager | P1 | ui:GUI-07-03 | Approve the match → dues status paid; hero card for Ahmet shows ₺0. DB check: collection transaction | NEW:`btn_approve_match_*` | ✅ |
| GUI-07-05 | 07-02 | Manager | P1 | upload a row with no unit hint | Unmatched banner "… Eşleşmeyen Banka Hareketi Var" → resolve → manual unit assignment to A Blok D:14 → banner count goes down | `banner_unmatched_bank_transactions`, `dashboard_unmatched_bank_alert`, `btn_resolve_unmatched_bank` | ✅ |
| GUI-07-06 | 07-02 | Manager | P2 | as GUI-07-05 | Unit matching criteria card: add a payer-name alias → re-upload → auto-matched | NEW:`matching_criteria_*` | ✅ |
| GUI-07-07 | 07-06 | Manager | P1 | seed (bank format EXCEL) | Upload an MT940 file → format-mismatch error and nothing is queued; upload Excel → succeeds | upload button | ✅ |
| GUI-07-08 | 07-03 | Homeowner | P1 | api:`webhook_transfer(A14 IBAN, 1460.67)` then the same again | After the first webhook, the dashboard shows paid and a receipt; after the duplicate the balance hasn't changed | hero ids | ✅ |
| GUI-07-09 | 07-05 | Homeowner | P1 | api:`overdue_dues(1400.00)` + `webhook_transfer(2860.67)` | Hero card shows "+₺1.460,67" in the advance style, a pill saying an advance is available, and a "FAST ile Avans Yükleme" movement | `hero_balance_amount`, NEW:`hero_advance_pill` | ✅ "Avans" |
| GUI-07-10 | 07-07 | Manager | P0 | seed | Dues management → accrue the "Ekim 2026" period → confirm → N liabilities created; accrue the same period again → duplicate-blocked message and the count is unchanged. DB check | NEW:`btn_accrue_period`, `btn_confirm_accrual_dialog` | ✅ |

### EPIC-08 Occupancy Lifecycle & Dual Ledger
| ID | Story | Role | Pri | Arrange | Steps → Expected | Selectors | UI |
|---|---|---|---|---|---|---|---|
| GUI-08-01 | 08-04 | Manager | P0 | seed (B3 vacant of tenant) | Residents module → move-in tenant "Selin Demir" to B Blok D:3 → status tenant-occupied, tenant shown | `module_move_in_*`, `module_move_in_role_selector`, `module_new_tenant_*`, `module_confirm_move_in_btn` | ✅ |
| GUI-08-02 | 08-01 | Manager / Tenant | P1 | ui:GUI-08-01 + capital project api | Accrue operational dues → charged to the tenant; capital installment → charged to the owner. Each balance is shown on the correct person. DB check: `debtor_type` | dues ledger | ◐ |
| GUI-08-03 | 08-02 | Manager | P1 | ui:GUI-08-01 | Add household members "Ali Kaya (Son)" and "Can Kaya" → list shows primary contact plus 2 members | `module_edit_dialog_add_household_member`, `module_member_*_input`, `module_save_household_btn` | ✅ |
| GUI-08-04 | 08-03/09-05 | Manager | P0 | ui:GUI-08-01 + `overdue_dues(tenant, 1500.00)` | Move-out → confirm (message: history kept, unit becomes empty) → unit vacant, household cleared. History still shows the tenant left owing ₺1.500,00. DB check: nothing deleted, `exit_balance` = 1500.00 | `module_move_out_*`, `module_confirm_move_out_btn` | ✅ |
| GUI-08-05 | 08-04 | Manager | P1 | ui:GUI-08-04 | Move in a new tenant → history timeline lists the previous tenant ("Left with ₺1.500,00") and the new one ("Active") | `module_history_ho_*` | ✅ |
| GUI-08-06 | 08-05/09-07 | Manager | P1 | seed (+ optional tenant) | Transfer ownership of A Blok D:14 to "Selim Evsahibi" → new owner shown, tenant unchanged, the old owner's history kept with closing balance | `module_transfer_ownership_*`, `module_transfer_new_owner_*_input`, `module_confirm_transfer_ownership_btn` | ✅ |
| GUI-08-07 | 08-02, 12-02 | Manager | P2 | seed | Search the residents module by name and unit | `module_search_input` | ✅ |
| GUI-08-08 | 08-03 | Manager | P2 | ui:GUI-08-01 | Remove the tenant only (owner kept): the unit workspace's move-out | `workspace_action_move_out_*`, `module_confirm_move_out_btn` | ✅ |
| GUI-08-09 | 08-06 | Manager | P0 | ui:GUI-08-04 (tenant moved out, unit vacant) | Vacant unit → owner move-in → the confirmation names the owner on record and has no person fields → confirm → unit owner-occupied, owner unchanged. DB check: active `OWNER` occupancy for the owner, no change in `unit_ownerships` | to be defined with the UI | ❌ not built (story pending) |
| GUI-08-10 | 08-06 | Manager | P1 | seed (vacant unit) | Vacant unit shows two separate actions, tenant move-in (person form) and owner move-in (confirmation). The tenant form has no role switch | to be defined with the UI | ❌ not built (story pending) |
| GUI-08-11 | 08-07 | Manager | P0 | seed | Each unit card shows only the actions legal for its state: no move-out on a vacant unit, no plain move-in on an occupied unit. API check: the illegal command is rejected and nothing changes | to be defined with the UI | ❌ not built (story pending) |
| GUI-08-12 | 08-08 | Manager | P1 | ui:GUI-08-01 + `overdue_dues(tenant, 1500.00)` | Replace the tenant → the previous tenant's history entry shows "Left with ₺1.500,00", the new tenant is active. Then "owner takes the unit back" → unit owner-occupied, owner unchanged | to be defined with the UI | ❌ not built (story pending) |
| GUI-08-13 | 08-09 | Manager | P1 | seed (owner-occupied unit) | Transfer ownership of an owner-occupied unit → unit vacant with the new owner. Repeat with "new owner moves in" → owner-occupied by the new owner | to be defined with the UI | ❌ not built (story pending) |
| GUI-08-14 | 08-10 | Manager | P1 | seed + vacant-period owner dues + tenant dues | Move-out → the exit balance in history equals the tenant's own unpaid dues, not the unit total. A move-out date before the session start is rejected with a message | to be defined with the UI | ❌ not built (story pending) |
| GUI-08-15 | 08-11 | Manager | P1 | seed | Directory row → open workspace → actions and information tabs switch modes; allowed actions match unit status | unit_workspace_*, workspace_actions, workspace_information | ✅ |

### EPIC-09 Payment Tracking & Treasury
| ID | Story | Role | Pri | Arrange | Steps → Expected | Selectors | UI |
|---|---|---|---|---|---|---|---|
| GUI-09-01 | 09-01 | Manager | P0 | api:`payments(mixed channels, tenant+owner, Ekim 2026)` | "Ödeme Takibi" → filter period Ekim 2026 + debtor TENANT → only tenant payments; totals, collection rate and channel split equal the API | `action_payment_tracking`, NEW:`filter_period`, `filter_debtor_type`, `payment_total` | ✅ |
| GUI-09-02 | 09-01/09-02 | Manager | P1 | api:`overdue_dues(1400.00, penalty 23.33)` + `webhook_transfer(2000.00)` | Open the payment → allocation dialog shows 23,33 penalty → 1.400,00 principal → 576,67 advance (exact) | NEW:`payment_row_*`, `allocation_line_*` | ✅ "Detay" |
| GUI-09-03 | 09-03 | Manager | P1 | api:tenant + owner capital dues on one unit | Tenant statement (ekstre) shows operational dues, tenant payments and interest only, with no capital dues | NEW:`btn_statement_*` | ◐ "Cari Hesap" ❌, "Ekstre" ✅ |
| GUI-09-04 | 09-04 | Homeowner | P1 | ui:GUI-07-04 | Open the receipt → fullscreen receipt with a `TAH-2026-…` number, site tax id and itemized breakdown; download works | NEW:`receipt_*`, `btn_download_receipt` | ✅ "Makbuz" |
| GUI-09-05 | 09-06 | Manager | P2 | api:tenant pays capital with "Asansör Demirbaş" | Receipt says the tenant paid on behalf of the owner; the tenant's operational balance is unchanged | receipt ids | ◐ |
| GUI-09-06 | 09-01 | Manager | P2 | api:payments | Debt aging buckets total the overdue sum | NEW:`aging_bucket_*` | ◐ |
| GUI-09-07 | 09-01 | Manager | P2 | api:advance balance | Virman (advance → capital) action available and works from payment tracking | NEW:`btn_virman_*` | ✅ |

### EPIC-10 Capital Expenditure & Fixture Dues
| ID | Story | Role | Pri | Arrange | Steps → Expected | Selectors | UI |
|---|---|---|---|---|---|---|---|
| GUI-10-01 | 10-07 | Manager | P0 | seed | Aidat Yönetimi → "Demirbaş & Yatırım" segment → summary plus the "Yeni Demirbaş Projesi", "Hakediş" and "Taksit Tahakkuk" actions are visible (empty state uses `btn_open_first_capital_project`) | `segment_tab_*`, `btn_open_capital_project_wizard`, `btn_open_first_capital_project` | ✅ |
| GUI-10-02 | 10-01 | Manager | P0 | api:`units(n, land_shares)` | Wizard: title, category, budget ₺500.000,00, land-share allocation → submit → project ACTIVE; unit-by-unit table sums **exactly** to the budget and Unit 14's share is correct. DB check (exact Decimal) | `input_capital_project_title`, `dropdown_capital_project_category`, `input_capital_project_budget`, `btn_submit_capital_project`, `project_tab_*` | ✅ |
| GUI-10-03 | 10-01 | Manager | P1 | api:`units(12)` | Equal allocation ₺60.000,00 → every unit ₺5.000,00 | as above | ✅ |
| GUI-10-04 | 10-02 | Manager | P0 | ui:GUI-10-02 with 3 installments | Accrue installment 1 → confirm → installment marked accrued; liabilities are owner-only. DB check: `CAPITAL_DUES`/`OWNER`, no tenant rows | `btn_accrue_installment_*`, `btn_confirm_accrual_dialog` | ✅ |
| GUI-10-05 | 10-05 | Manager | P1 | api:project collected 220.000,00, disbursed 50.000,00 | Record disbursement 120.000,00 "2. Hakediş" to a contractor with invoice → disbursed 170.000,00, cash 50.000,00 | `btn_record_disbursement`, `input_disbursement_*`, `btn_submit_disbursement` | ✅ |
| GUI-10-06 | 10-05 | Manager | P1 | as GUI-10-05 | A disbursement larger than collected cash → overdrawn warning and nothing is recorded | as above, `btn_close_disbursement_modal` | ✅ |
| GUI-10-07 | 10-03 | Owner | P1 | ui:GUI-10-04 + `webhook_transfer(owner, 4000.00, "Demirbaş 1. Taksit")` | Owner dashboard shows the capital due paid and the project collected amount up by 4.000,00 | project ids | ✅ |
| GUI-10-08 | 10-03 | Tenant | P2 | tenant on unit 14 + capital due + tenant payment | Receipt contains the legal rent-offset clause (TBK 314) | receipt ids | ◐ |
| GUI-10-09 | 10-04 | Manager | P1 | api:advance 3.500,00 + capital due 2.500,00 | Virman 2.500,00 → advance 1.000,00, capital due paid. DB check: audit row | NEW:`btn_virman_*` | ✅ |
| GUI-10-10 | 10-06 | Owner | P1 | ui:GUI-10-04 | Owner balance card shows the operational and capital lines separately; "Detay" opens the project breakdown, contractor and installment schedule | `hero_*`, "Detay" | ✅ |
| GUI-10-11 | 10-06 | Tenant | P1 | tenant on a unit with an active project | The tenant sees the project with the "Kat Maliki Sorumluluğunda" badge and the owner-responsibility banner, and no capital debt on their own balance | NEW:`capital_owner_badge` | ❌ **confirmed gap**: neither the badge nor the banner text exists in `lib/ui` |

### User journeys: one per role (`e2e/tests/journeys`, marker `journey`)
Each journey is one test that follows a single user from the first sign-in with a temporary password to signing in again, through every case that role covers. Steps are named, so a failure names the step (`[auditor journey] step 4 '…' failed`). Every journey starts with the same STORY-06-06 gate: only `screen_force_password_change`, route `/change-password`, **zero business calls** (network log), held deep links, form validation, then the role home **with data that matches the API** and **no refused (4xx) calls**. Each journey ends by logging out, signing in again with the new password and checking that the temporary password is rejected.

| ID | Story | Role | Pri | Arrange | Steps → Expected | Selectors | UI |
|---|---|---|---|---|---|---|---|
| GUI-J-01 | 03-02/03-03/03-04/03-06/03-07/06-01/06-06 | SaaS | P0 | seed (bootstrap admin flagged as at first boot) | Gate → held `/admin/sites` link opens → portfolio = API site list → a site with units is locked → onboard a site (issued password works, server holds the new manager at the gate) → delete the empty site → step-up, then reset the Begonya manager's password → manager pages and API closed → sign in again | `screen_force_password_change`, `btn_edit_site_*`, `site_credentials_password`, `site_delete_locked_1` | ✅ |
| GUI-J-02 | 02-03/03-01/06-01/06-06/08-04/10-07 | Manager | P0 | SQL: seed manager flagged (state after a SaaS reset) | Gate → a SaaS link falls back to `/manager/home` → residents tab = every unit of site 1 → register an owner → move a tenant in → dues has 5 segments and the capital wizard → own flat and back (3/2 tabs) → SaaS pages and API closed → sign in again | `delete_ho_*`, `move_in_*`, `btn_open_capital_project_wizard`, `role_path_*` | ✅ |
| GUI-J-03 | 01-02/01-04/04-07/06-01/06-06/07-04 | Owner | P0 | SQL: overdue dues on A Blok D:14; owner flagged | Gate → balance = API total with penalty, overdue badge → virtual IBAN = API → unit invite link → manager pages and API closed → change the password from the profile → sign in again | `hero_balance_amount`, `virtual_iban_text`, `resident_action_invite`, `invite_link_text` | ✅ |
| GUI-J-04 | 04-07/06-01/06-06/08-02 | Resident | P0 | API: owner invite link → resident registration (issued temporary password) | Gate → the flat's balance = API → no invite action, invite API refused → manager pages and API closed → sign in again | `hero_balance_amount`, no `resident_action_invite` | ✅ |
| GUI-J-05 | 06-01/06-06 | Auditor | P0 | SQL: auditor account (no API issues one) | Gate → ledger rows = API trial balance → read-only (no requests tab, dunning or notice publishing) → manager/resident pages and API closed → sign in again | `finance_tab_*`, `trial_balance_*` | ✅ |

### EPIC-12 Unified People and Unit Directory
| ID | Story | Role | Pri | Arrange | Steps → Expected | Selectors | UI |
|---|---|---|---|---|---|---|---|
| GUI-12-01 | 12-04 | Manager | P1 | seed people directory | Search for a person, apply an activation filter, page through results, open a person profile and return → the query, filters and directory position remain available | `people_search_input`, `people_filter_pending`, `people_filter_no_login`, person rows, directory pager | ✅ |
| GUI-12-02 | 12-06, 12-07 | Manager | P1 | seed unit with owner person | Open a unit workspace, open the owner's person card, edit the name, open the unit from the card and return → list search and focus are kept and the new name shows on the unit | `workspace_person_owner_<id>`, `person_edit_btn`, `person_unit_<unit>`, `person_open_login_btn`, `person_role_tenant_btn` | ✅ |
| GUI-12-03 | 12-03 | Manager | P1 | seed unit A Blok D:14 and another unit's owner in the same site | Open the unit workspace, start a title transfer, search the person picker for the other owner and choose them → the live, paged search request succeeds and the chosen card becomes the owner with no new person created | `module_unit_actions_<id>`, `workspace_action_transfer_ownership_<id>`, `module_transfer_new_owner_name_input`, `sp_person_search`, `sp_person_result_<id>` | ✅ |
| — | 12-08 | — | — | — | **Partial:** the person card merge has no browser scenario yet; its step-up flow is covered by Flutter widget tests in `person_merge_test.dart` (SC-12-08-01, SC-12-08-02) and the server side by `backend/tests/db_person_merge_tests.rs`. | | |
| — | 12-09 | — | — | — | **Partial:** the person import from Excel has no browser scenario yet (the browser cannot pick a file); the template and the workbook reader are covered by Flutter unit tests in `person_import_xlsx_test.dart` (SC-12-09-01, SC-12-09-02) and the server rules by `backend/tests/person_records_tests.rs`. | | |

### Cross-cutting
| ID | Role | Pri | Steps → Expected | UI |
|---|---|---|---|---|
| GUI-X-01 | Any | P0 | Every test fails if there are uncaught browser console errors, failed (5xx) API calls, or any call refused with 403 `PASSWORD_CHANGE_REQUIRED` (the client called a business route with a temporary password; opt out with `allow_password_gate`) | — |
| GUI-X-02 | Any | P1 | Theme toggle on the login screen (`controller.toggleTheme`) switches dark/light, and the choice holds after login | ✅ |
| GUI-X-03 | Manager | P1 | Zero-data guidance on a fresh site (no units, no periods) shows the guidance cards, not errors | ✅ |
| GUI-X-04 | Homeowner, Manager | P1 | At 375×812 (mobile): login, dashboard, payment checkout and residents module work with no horizontal scroll | — |
| GUI-X-05 | Any | P2 | Browser reload on the dashboard keeps or restores the session as designed | — |
| GUI-X-06 | Any | P2 | Every amount shown uses the Turkish format `₺1.234,56` with 2 decimals | — |
| GUI-X-07 | Manager | P1 | Each tab has its own URL (`/manager/home`, `/manager/residents`, `/manager/dues`); browser back returns to the previous tab | ✅ |

### Excluded (no GUI surface)
EPIC-05 (05-01 … 05-06): schema, concurrency, REST, harness and RTM. Covered by `run_tests.py` gates, `schema_integrity_check.py`, `api_system_check.py` and `harness/tests`.
| — | 13-03 | — | — | — | **Excluded:** The automated scenarios of story 13-03 are backend journeys; its two GUI scenarios (SC-13-03-03, SC-13-03-19) stay `@pending` in the feature file until they are automated. | | |
| — | 13-01 | — | — | — | **Partial:** Starting state reference fixtures F0 to F3 are covered by journey tests and `run_tests.py` gates; their screens are GUI-13-05 … GUI-13-10. | | |
| — | 13-02, 13-04, 13-07 | — | — | — | **Excluded:** Backend-only journey contract for accruals, payments and teardown, covered by test_journey_accruals_payments.py and test_journey_fixtures.py. | | |
| — | 13-07 | — | — | — | **Excluded:** Backend-only journey fixture, invariant and teardown contract, covered by journey tests and `run_tests.py` gates. | | |
| — | 13-01, 13-12 | — | — | — | **Excluded:** Backend-only late-fee rule for supplementary charges, covered by `backend/tests/supplementary_charge_tests.rs`. | | |
| — | 13-14 | — | — | — | **Excluded:** Backend-only liability journey (title, vacancy and move-in changes), covered by `e2e/tests/test_journey_liability_changes.py`. | | |
| — | 13-25 | — | — | — | **Excluded:** Reconciliation of debt and cash by site is verified by the fixture-derived model in `e2e/tests/test_journey_reconciliation.py`; the GUI statement checks are pending (SC-13-25-06, SC-13-25-07). | | |
| — | 13-13 | — | — | — | **Excluded:** Multi-site journey onboarding is covered by `e2e/tests/test_journey_onboarding_88_units.py` (issue #247), four-period accruals/payments by `e2e/tests/test_journey_accruals_payments.py` (issue #248), and the manager statement, payer and cash views by GUI-13-04 (`SC-13-13-05`, issue #462). | | |
| — | 13-10 | — | — | — | **Partial:** Backend isolation automated; GUI isolation scenario (SC-13-10-08) is pending separate GUI issue. | | |
| — | 13-06, 13-08 | — | — | — | **Partial:** Lifecycle chain (13-06) and manager session states (13-08) specified in .specify/features/EPIC-13; GUI automation pending. | | |
| GUI-13-04 | 13-26 | Manager | P0 | zero-site to April final | Onboard two sites, create 88 units through manager commands, run four periods, then inspect both managers' unit statements, unit counts and site cash (`SC-13-26-02`, `SC-13-13-05`). | Site A and Site B journey builders; unit workspace, account statement and payment stream | ✅ |
| GUI-13-05 | 13-01 | Manager | P1 | F0 | Open dashboard, collection, cash, units and people pages of an empty site → zero dashboard, empty-state message on every page (`SC-13-01-01`) | `cockpit_*`, `segment_tab_*`, `people_search_input` | ✅ |
| GUI-13-06 | 13-01 | Manager | P1 | F1 | Open units and people pages of a site with units but no people → 7 unassigned units, no owners or residents (`SC-13-01-04`) | `add_resident_btn`, `people_search_input` | ✅ |
| GUI-13-07 | 13-01 | Manager | P1 | F1 | Register two owners and a tenant on empty units → units and directory show them, no liability exists (`SC-13-01-05`) | `module_new_resident_*`, `module_confirm_move_in_btn` | ✅ |
| GUI-13-08 | 13-01 | Manager, home owner | P1 | F2 | People without a period → collection page offers the first accrual, owner dashboard balance 0.00 (`SC-13-01-06`) | `btn_open_accrual_dialog`, `hero_balance_amount` | ✅ |
| GUI-13-09 | 13-01 | Manager | P1 | F3 | Accrue the same period again after residents exist → duplicate blocked, no liability (`SC-13-01-11`) | `btn_open_accrual_dialog`, `snackbar_accrual_result` | ✅ |
| GUI-13-10 | 13-01 | Manager | P1 | F0 | Grow the site from F0 to F2 through the screens: add "A Blok" with 7 units and its tariffs → F1 (7 vacant units, A-6 "Large flat", no people or liabilities), then the owners and tenants → F2 (units page, people directory and each workspace agree) (`SC-13-01-12`) | `btn_add_block`, `block_form_*`, `btn_save_block_units`, `add_resident_btn`, `module_*`, `workspace_identity` | ✅ |
| GUI-13-11 | 13-02 | Manager | P0 | F4 | Single accrual period → total 8800.00, five overdue debtors with their amounts (`SC-13-02-01`) | `cockpit_*`, `aging_*` | ✅ |
| GUI-13-12 | 13-02 | Resident | P1 | F4 | Tenant dashboard equals the admin unit statement (`SC-13-02-02`) | `hero_balance_amount`, `statement_total_tenant` | ✅ |
| GUI-13-13 | 13-02 | Manager | P0 | F5 | Multiple periods → per-unit balances and site total, advance of A-6 (`SC-13-02-04`) | `aging_*`, `workspace_action_statement_*` | ✅ |

## 4. API data builders (`e2e/support/api.py`), confirmed against `backend/src/app.rs`
Each builder calls real backend endpoints (no direct SQL writes), returns the ids it created, and runs after a reset.

| Builder | Endpoint(s) | Status |
|---|---|---|
| reset | `POST /api/v1/system/reset-to-initial-state`, `POST /api/v1/system/seed-test-fixtures` | ✅ (destructive, so only run against the E2E backend; see the plan's risks) |
| `overdue_dues` (canonical) | `POST /api/v1/system/accrue-test-due`: fixed A Blok D:14, Eylül 2026, ₺1.400,00, no parameters | ◐ no custom amount, unit or due date |
| `overdue_dues` / `paid_dues` / `dues_period` (general) | `POST /api/v1/dues/periods`, `POST /api/v1/dues/accrue-period` | ✅ |
| `unit` / `units(land_shares)` | `POST /api/v1/site-admin/home-owners`, `POST /api/v1/system/provision-site-units`, `POST /api/v1/site-admin/blocks` | ✅ |
| `tenant` (move-in / move-out) | `POST /api/v1/site-admin/units/:id/move-in`, `.../move-out` | ✅ |
| `registration_request` | `POST /api/v1/registration/submit/:slug` | ✅ |
| `unit_invite_registration` | `GET /api/v1/home-residents/invite-link/:unit_id`, `POST /api/v1/home-residents/register` | ✅ |
| `capital_project` (+ installment accrual, disbursement) | `POST /api/v1/capital-projects`, `.../:id/accrue-installment`, `.../:id/disbursements` | ✅ |
| `payments` | `POST /api/v1/payments/record-manual` | ✅ |
| `webhook_transfer` / `advance_balance` | `POST /api/v1/bank/webhook/incoming-transfer` (overpaying creates an advance) | ✅ |
| `announcement` | — | ❌ no backend route (matches the GUI-02-07 gap) |

**Dates and money.** The KMK delay penalty is computed from the real clock, and the backend has no way to fix the date. The story's "10 days → ₺23,33" therefore only holds on one day. Money assertions read the expected value from `GET /api/v1/residents/:unit_id/dashboard` (`totalDue`, `penalty`) and compare the screen to it as an exact `Decimal`. The fixed values (₺1.400,00 principal and the 5% monthly rate) are still asserted as constants. A date-control test hook in the backend would allow asserting the story's exact numbers; this is a suggested follow-up, not a blocker.

## Current status

This file is the GUI scenario and selector catalogue. Use `.specify/features/` and CI reports for current coverage and execution status.
