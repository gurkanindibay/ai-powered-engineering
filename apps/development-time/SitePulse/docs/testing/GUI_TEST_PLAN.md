# SitePulse GUI Test Plan (Scenario Catalogue)

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
  - ❌ not found. Phase 1 confirms it; if it's really missing, it's a product gap. The test is written and marked `xfail(reason="UI gap")`, never skipped silently.
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
| GUI-02-04 | 02-03 | Manager | P2 | seed | Add a resident to an already occupied unit → duplicate warning ("halihazırda kayıtlı sakin") and nothing is saved | as above | ✅ |
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
| GUI-08-07 | 08-02 | Manager | P2 | seed | Search the residents module by name and unit | `module_search_input` | ✅ |
| GUI-08-08 | 08-03 | Manager | P2 | ui:GUI-08-01 | Remove the tenant only (owner kept) | `remove_tenant_only_button` | ✅ |
| GUI-08-09 | 08-06 | Manager | P0 | ui:GUI-08-04 (tenant moved out, unit vacant) | Vacant unit → owner move-in → the confirmation names the owner on record and has no person fields → confirm → unit owner-occupied, owner unchanged. DB check: active `OWNER` occupancy for the owner, no change in `unit_ownerships` | to be defined with the UI | ❌ not built (story pending) |
| GUI-08-10 | 08-06 | Manager | P1 | seed (vacant unit) | Vacant unit shows two separate actions, tenant move-in (person form) and owner move-in (confirmation). The tenant form has no role switch | to be defined with the UI | ❌ not built (story pending) |
| GUI-08-11 | 08-07 | Manager | P0 | seed | Each unit card shows only the actions legal for its state: no move-out on a vacant unit, no plain move-in on an occupied unit. API check: the illegal command is rejected and nothing changes | to be defined with the UI | ❌ not built (story pending) |
| GUI-08-12 | 08-08 | Manager | P1 | ui:GUI-08-01 + `overdue_dues(tenant, 1500.00)` | Replace the tenant → the previous tenant's history entry shows "Left with ₺1.500,00", the new tenant is active. Then "owner takes the unit back" → unit owner-occupied, owner unchanged | to be defined with the UI | ❌ not built (story pending) |
| GUI-08-13 | 08-09 | Manager | P1 | seed (owner-occupied unit) | Transfer ownership of an owner-occupied unit → unit vacant with the new owner. Repeat with "new owner moves in" → owner-occupied by the new owner | to be defined with the UI | ❌ not built (story pending) |
| GUI-08-14 | 08-10 | Manager | P1 | seed + vacant-period owner dues + tenant dues | Move-out → the exit balance in history equals the tenant's own unpaid dues, not the unit total. A move-out date before the session start is rejected with a message | to be defined with the UI | ❌ not built (story pending) |

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

## 5. Coverage summary
| Epic | Stories | Covered by GUI | …of which partial | Excluded |
|---|---|---|---|---|
| EPIC-01 | 6 | 4 (01-03, 01-04, 01-05, 01-06) | — | 2 (01-01, 01-02 domain) |
| EPIC-02 | 5 | 5 | 02-04 (message), 02-05 (UI not found) | — |
| EPIC-03 | 7 | 6 | — | 1 (03-05 API) |
| EPIC-04 | 7 | 7 | 04-03 (API arrange) | — |
| EPIC-05 | 6 | — | — | 6 |
| EPIC-06 | 5 | 5 | 06-03 (button only) | — |
| EPIC-07 | 7 | 7 | — | — |
| EPIC-08 | 10 | 10 | 08-06 to 08-10 (planned, UI not built) | — |
| EPIC-09 | 7 | 7 | 09-03 (wording) | — |
| EPIC-10 | 7 | 7 | 10-06 tenant (UI not found) | — |
| **Total** | **67** | **58** | **11** | **9** |

**Scenarios:** 89 (P0: 23, P1: 50, P2: 16) including cross-cutting. Story traceability was checked by script: all 67 `STORY-*` ids in `.specify/requirements` map to a scenario or a written exclusion.

**Product gaps confirmed in Phase 1** (code and API checked; tests are written as `xfail(reason="UI gap")`):
- GUI-02-06: payment reminder / direct message (STORY-02-04)
- GUI-02-07: announcement creation, which has no API either (STORY-02-05)
- GUI-10-11: tenant capital badge and banner (STORY-10-06, tenant half)
- STORY-04-03: public self-registration form (API only)

GUI-01-03 (account movements) was a false alarm: the section exists.

## 6. Phase 1 results (2026-11-07)
1. ✅ `testId()` helper (`lib/testing/test_id.dart`) and E2E semantics bootstrap in `main.dart`, active only with `--dart-define=E2E=true`.
2. ✅ All 161 existing `Key`s mirrored as `testId`s, plus 17 new ids: login tabs, email, password and submit for all three roles; Google button; theme toggle; hero label, amount, overdue badge and pay button; logout. The remaining `NEW:` ids are added screen by screen as each scenario is implemented.
3. ✅ Probe (`e2e/probe_semantics.py`) in real Chrome: ids are rendered as `flt-semantics-identifier`, and UI login as manager and homeowner reaches the dashboards with no page errors.
4. ✅ Builder endpoints confirmed (Section 4). Still open: seed passwords for `mehmet.oz@begonya.com` and the SaaS bootstrap password; the probe uses only the manager and homeowner.
5. Clipboard scenarios (GUI-03-02, 04-01, 07-01) need the Playwright `clipboard-read` permission in Chromium. On Firefox and WebKit they fall back to checking the toast only.

## 7. Implemented tests (Phase 2, 2026-11-07)
Run with `scripts/gui_e2e.py run -m smoke`. Each test carries `@pytest.mark.gui_id("<id>")`.

| Scenario | Test | Result |
|---|---|---|
| GUI-06-01 | `test_epic06_auth.py::test_manager_login_reaches_cockpit` | pass |
| GUI-06-02 | `test_epic06_auth.py::test_homeowner_login_reaches_dashboard` | pass |
| GUI-06-03 | `test_epic06_auth.py::test_wrong_password_shows_error_and_stays_on_login` | pass |
| GUI-06-06 | `test_epic06_auth.py::test_saas_admin_must_change_bootstrap_password` | pass |
| GUI-06-08 | `test_epic06_auth.py::test_logout_returns_to_login_screen` | pass (header logout button) |
| GUI-01-01 | `test_epic01_resident_dues.py::test_overdue_balance_matches_backend_total` | pass |
| GUI-01-02 | `test_epic01_resident_dues.py::test_no_dues_shows_zero_balance_without_overdue_badge` | pass |
| GUI-07-01 | `test_epic01_resident_dues.py::test_virtual_iban_shown_and_copied` | pass (clipboard checked in Chromium) |
| GUI-02-03 | `test_epic02_manager.py::test_manager_adds_owner_resident` | pass (DB check on persons + units) |
| GUI-10-01 | `test_epic02_manager.py::test_capital_segment_offers_project_creation` | pass |
| GUI-03-01 | `test_epic03_saas.py::test_portfolio_lists_every_site` | pass |
| GUI-03-01 | `test_epic03_saas.py::test_portfolio_stats_agree_with_site_list` | **xfail: backend bug** (placeholder stats) |

Ids added in Phase 2: `btn_header_logout`, `virtual_iban_text`, `btn_copy_iban`, `btn_cockpit_house_types`, `btn_cockpit_add_resident`, `add_resident_{unit,name,email,phone}_field`, `btn_save_new_resident`, `change_password_{current,new,confirm}`, `btn_submit_change_password`.

## 8. Phase 3: P0 complete (2026-11-07)
All 21 P0 scenarios are automated: `scripts/gui_e2e.py run -m smoke` gives **19 passed, 4 strict xfail** (about 3 minutes including stack start). Stable on the last two consecutive runs (an earlier run exposed a race in `fill()` on prefilled fields; it now verifies the field value and retries). Every xfail names a confirmed product defect; it turns into a failure (XPASS) as soon as the defect is fixed, so the marker must then be removed.

| Scenario | Test | Result |
|---|---|---|
| GUI-03-02 | `test_epic03_saas.py::test_onboarding_a_site_issues_working_manager_credentials` | pass (DB: slug, SITE_MANAGER with `must_change_password`, blocks; the shown password logs in) |
| GUI-04-02 | `test_epic04_invitations.py::test_pending_registrations_are_listed_for_the_manager` | **xfail: gap**, the client never loads `/registration/pending` |
| GUI-04-03 | `test_epic04_invitations.py::test_approving_a_registration_creates_an_active_account` | **xfail: gap**, same cause |
| GUI-07-03 | `test_epic07_bank.py::test_statement_upload_matches_known_sender_and_flags_unknown` | pass (generated Kuveyt Türk .xlsx: 1 matched ₺1400.00, 1 unmatched ₺250.00) |
| GUI-07-03 | `test_epic07_bank.py::test_confirming_matched_rows_records_the_payment` | **xfail: bug**, confirmation is client-only |
| GUI-07-10 | `test_epic07_bank.py::test_period_accrual_charges_every_unit_once` | pass (N liabilities, duplicate blocked, count unchanged) |
| GUI-08-01 | `test_epic08_occupancy.py::test_tenant_move_in` | pass (active TENANT occupancy, `units.tenant_person_id`) |
| GUI-08-04 | `test_epic08_occupancy.py::test_tenant_move_out_keeps_history_and_debt` | pass (occupancy closed, `exit_balance` 1500.00, liability and person kept) |
| GUI-09-01 | `test_epic09_payments.py::test_payment_stream_role_filter_shows_only_tenant_payments` | pass (role filter; ids equal the API's TENANT entries). The UI has no period filter, so that part of the scenario is not testable |
| GUI-10-02 | `SC-10-01-01` in `.specify/features/EPIC-10/STORY-10-01-capital-project-creation.feature` | pass (unit shares sum exactly to ₺500.000,00; unit 14's share is exact) |
| GUI-10-04 | `SC-10-02-01` in `.specify/features/EPIC-10/STORY-10-02-installment-scheduling.feature` | pass (OWNER / CAPITAL_DUES rows only, installment marked accrued) |
| GUI-X-01 | conftest `page_guard` | applies to every test |

New builders: `Api.change_password`, `submit_registration`, `move_in`, `create_period`, `accrue_period`, `record_manual_payment`, `payment_stream`; `Builders.tenant_debt` (SQL arrange). `support/bank_files.py` generates statement files in code, so there are no binary fixtures in git.

New ids: `btn_open_add_site`, `add_site_{name,city,address,admin_name,admin_email,admin_phone}_field`, `site_credentials_password`, `btn_close_site_credentials`, `approval_credentials_password`, `btn_close_approval_dialog`, `pending_count_badge`, `pending_card_<id>`, `btn_approve_<id>`, `btn_reject_<id>`, `btn_open_accrual_dialog`, `accrual_dialog_period`, `btn_confirm_period_accrual`, `snackbar_accrual_result`, `btn_open_bank_import`, `btn_import_pick_file`, `import_summary_{matched,unmatched}`, `btn_confirm_matched_import`, `filter_{role,channel}_chip`, `filter_{role,channel}_option_<v>`, `payment_entry_<id>_<role>`, `radio_allocation_{by_land_share,equal}`, `chip_installments_<n>`, `installment_accrued_<n>`, `unit_share_<block>_<unit>`, `move_in_{name,email,phone}_field`, `btn_confirm_move_in`, `btn_confirm_move_out`. `testId()` gained an optional `label` for widgets that keep their text out of the semantics tree (`SelectableText`).

**Findings from Phase 3** (in addition to the four in GUI_AUTOMATION_PLAN.md):
5. **Approval queue never loads (gap, STORY-04-04/05).** No client code calls `GET /api/v1/registration/pending`. The badge stays at 0 whatever is submitted.
6. **Statement confirmation is not persisted (bug, STORY-07-02).** "Eşleşenleri Onayla & Kaydet" changes only in-memory client state. After a reload the payment is gone, and no `payment_entries` or `paid_amount` change is written.
7. **Operational dues are charged to TENANT on owner-occupied units.** `accrue-period` writes `debtor_type = TENANT` for units with no tenant. It also stores today's date as `due_date` instead of the period's (2026-10-15), while the dialog shows a hard-coded "₺1.400,00" and "15.10.2026".
8. **Accrual dialog with no period.** When the site has no dues period, "Toplu Aidat Tahakkuku" still opens, shows an empty period and offers to accrue.
9. **Unit-share API placeholders.** `GET /capital-projects/:id/unit-shares` returns the block id as `block` ("1") and placeholder owners (`person-2`, the same phone for every unit). The project's "Kat Malikleri" tab shows them. This is the same block-id issue as finding 2.
10. **Inconsistent money formatting (GUI-X-06).** The import summary and the capital views print `₺1400.00` / `₺285714.29` (`toStringAsFixed` or `toString`), not the Turkish `₺1.400,00` used elsewhere.
11. **Unreproduced:** once, on a long-lived exploration stack, the first `accrue-installment` call returned 400 "db error" (nothing was logged) and an identical retry succeeded. It has not happened on a clean stack. The service also reads every site's units (`inner.units`, no site filter) and inserts the per-unit rows without a transaction, so a mid-way failure would leave a partial accrual.

## 9. Phase 3: P1 complete (2026-11-07, after merging master `a10646a`)
All 46 P1 scenarios are automated. `scripts/gui_e2e.py run -m core` gives **26 passed, 28 strict xfail** (about 7½ minutes); the P0 smoke suite is unchanged at 19 passed, 4 strict xfail. Each new xfail was re-run with `--runxfail` to confirm it fails on the assertion its reason names, not on a test error. Shared xfail reasons live in `e2e/support/known_issues.py`.

| Epic | Scenarios automated | Passing | Strict xfail (defect or gap) |
|---|---|---|---|
| EPIC-06 | 06-05 (×2 roles), 06-07, 06-08, 06-09, 06-10 | all | — |
| EPIC-03 | 03-03, 03-04, 03-05, 03-06, 03-07, 03-08 | 03-03, 03-04, 03-06, 03-07, 03-08 | 03-05 |
| EPIC-02 | 02-02, 02-05, 02-06, 02-07, 02-08 | 02-05 (no history), 02-08 (save, negative amount) | 02-02, 02-05 (refused delete), 02-06, 02-07, 02-08 (>2 decimals) |
| EPIC-01 | 01-03, 01-04 | — | 01-03, 01-04 |
| EPIC-04 | 04-01, 04-04, 04-05, 04-06 | 04-06 (link shown and copied) | 04-01, 04-04, 04-05, 04-06 (site/unit/token) |
| EPIC-07 | 07-02, 07-04, 07-07, 07-08, 07-09 | 07-02 | 07-04, 07-07, 07-08, 07-09 |
| EPIC-08 | 08-02, 08-05, 08-06 | 08-05, 08-06 (new owner) | 08-02 (×2), 08-06 (previous owner's period) |
| EPIC-10 | 10-03, 10-06, 10-11 | 10-03 | 10-06, 10-11 |
| Cross-cutting | X-04 (×2 roles) | all | — |

Second pass (the remaining ten):

| Scenario | Test | Result |
|---|---|---|
| GUI-07-05 | `test_epic07_bank.py::test_unmatched_row_is_assigned_to_a_unit_by_hand` | pass (UI flow) |
| GUI-07-05 | `…::test_manual_assignment_records_the_payment` | **xfail: bug**, assignment is client-only |
| GUI-07-05 | `…::test_confirming_matched_rows_keeps_the_unmatched_ones` | **xfail: bug**, unmatched rows dropped |
| GUI-08-03 | `test_epic08_occupancy.py::test_household_members_are_added` | pass (API lists both members) |
| GUI-08-03 | `…::test_household_members_survive_a_backend_restart` | **xfail: bug**, memory only |
| GUI-09-02 / 09-04 | `test_epic09_receipts.py::test_receipt_shows_number_and_penalty_principal_advance_split` | pass (TAH number, penalty → principal → advance equals the API, sums to the total) |
| GUI-09-04 | `…::test_homeowner_receipt_shows_the_issued_receipt_number` | **xfail: bug** |
| GUI-09-03 | `…::test_tenant_statement_lists_operational_items_only` | **xfail: gap** |
| GUI-10-05 | `SC-10-05-01` in `.specify/features/EPIC-10/STORY-10-05-contractor-disbursements.feature` | pass (disbursed 1000, reserve 3000, DB row) |
| GUI-10-07 | `…::test_owner_fast_payment_raises_the_projects_collected_amount` | pass (collected 4000, DB paid 4000) |
| GUI-10-09 | `…::test_virman_dialog_offers_real_units_and_advances` | **xfail: bug**, hard-coded units |
| GUI-10-10 | `…::test_owner_dashboard_shows_capital_dues_separately` | **xfail: gap** |
| GUI-X-02 | `test_cross_cutting.py::test_theme_choice_on_login_screen_holds_after_login` | pass |

New builders: `Api.create_site`, `webhook_transfer` (signed with the E2E webhook secret), `move_out`; `Builders.foreign_site_unit` (SQL arrange). New page objects: `ProfileSheet`, SaaS card actions (edit, delete, reset password). `AddResidentForm.save()` now dismisses the "Sakin Kaydedildi!" confirmation.

New ids: `btn_open_profile`, `role_path_{manager_cockpit,my_flat}`, `profile_change_password_{current,new,confirm}`, `btn_submit_profile_change_password`, `btn_reset_admin_password_<id>`, `btn_delete_site_<id>`, `site_delete_locked_<id>`, `site_card_name_<id>`, `btn_ack_delete_blocked`, `btn_confirmation_{confirm,cancel}` (shared confirmation page and sheet), `btn_edit_house_type_<type>`, `house_type_{name,amount}_field`, `btn_save_house_type`, `house_type_error`, `dues_filter_<ALL|PAID|OVERDUE>`, `ledger_row_<n>`, `resident_action_<receipts|invite|requests|announcements>`, `invite_link_text`, `invite_security_notice`, `btn_copy_invite_link`, `btn_close_resident_provisioned`, `checkout_option_{card,virtual_iban}`, `checkout_fast_note`, `hero_advance_pill`, `snackbar_import_error`, `history_item_<id>`.

**Findings from the P1 pass** (continuing the numbering of §8):
12. **Period accrual breaks the next ledger insert.** `accrue-period` writes `dues_liabilities` rows with explicit ids and leaves the identity sequence behind (ids 1 and 2 exist, next sequence value 1). The next identity insert, such as `accrue-installment`, fails with 400 "db error" until the sequence passes the existing ids. This explains finding 11, which is now reproduced.
13. **FAST webhook ignores the KMK penalty.** Paying the full total (₺1.423,33) leaves ₺23,33 open. Overpaying ₺2.860,67 shows an advance of ₺1.460,67, which is the payment minus the principal only. This contradicts the penalty → principal → advance order (STORY-09-02).
14. **Bank account never loaded, so the format guard is off.** The client only posts the bank account; it never reads it. An MT940 `.sta` is accepted for the Kuveyt Türk EXCEL account.
15. **Site edit not saved, but shown as saved.** `PUT /saas/sites/1` answers 400, `updateSite` returns true anyway, and the card shows the new name. Nothing is stored.
16. **Refused delete still removes the card.** Deleting a unit with ledger history gets a 400 from the backend, but the card disappears.
17. **Overdue filter loses flats.** With both units overdue the badge says "Geciken (2)" but one card is listed, "Tümü" shows 1 of 2, the total is wrong, and the days-overdue figure disagrees with the due date.
18. **Client-only flows:** `rejectRegistration` makes no API call, and the unit invite link is built in the client (slug `sitemiz`, unit id instead of number "A Blok Blok D:2", a token the backend never issued).
19. **No overdraw guard on disbursements.** A ₺120.000,00 contractor disbursement is recorded with ₺0 collected.
20. **Ownership history incomplete.** A transfer writes a `unit_ownerships` row for the new owner only; the previous owner's period is not recorded, and the seed creates no initial ownership rows.
21. **Validation gaps:** house type amounts with more than two decimals are accepted; account movements lump principal and penalty into one row without a thousands separator.
22. **`must_change_password` not enforced server-side.** The SaaS admin could create a site through the API while still on the bootstrap password.
23. **UI gaps:** managers have no site invite link (only home users have "Davet Linki"), and the "Duyurular" tile shows a hard-coded "3 Yeni" badge.

24. **Manual unit assignment not persisted.** Assigning an unmatched statement row to a unit clears it on screen but writes no payment. Confirming the matched rows of an import also silently drops its unmatched rows from "🏦 Eşleşmeyenler".
25. **Household members are memory-only.** They are kept in backend memory (no `occupancy_members` or `persons` row, `resident_id` "0", a placeholder e-mail when none is given) and are lost on restart.
26. **Homeowner receipt number is wrong.** It shows the bank transaction id instead of the issued receipt number (`DKN-…`/`TAH-…`). Receipt amounts are printed unformatted (`₺2000`, `₺53.67`). "Paylaş / PDF" only shows a toast; no file is produced.
27. **Virman dialog is hard-coded.** It offers units `d-14` "Mevcut Avans: ₺3.000,00" and `d-1` regardless of the site's units and balances.
28. **No tenant statement (ekstre)** in the UI or the API.
29. **No owner capital breakdown.** The owner's dashboard folds capital dues into one balance, with no capital line or project detail.

E2E-only test hooks added: the theme toggles carry `theme:dark` / `theme:light` labels, since the page is canvas-rendered. `fill()` now focuses the field before looking for its `<input>`, because Flutter creates the input only on focus.

## 10. Phase 3: P2 complete (2026-11-07)
All 16 P2 scenarios are automated in `e2e/tests/test_p2_edge.py` (marker `edge`): **8 passed, 8 strict xfail**. Every xfail was run with `--runxfail` and fails on the assertion its reason names.

| Scenario | Result |
|---|---|
| GUI-06-04 empty password → error banner, no `/auth/login` request | pass |
| GUI-06-11 Google sign-in reaches the provider | **xfail: gap**, simulated login, no OAuth redirect |
| GUI-01-05 offline banner, balance kept | **xfail: gap**, no offline banner; `isOffline` is unused |
| GUI-01-06 penalty detail (days, amount) | **xfail: bug**, detail says "0 Gün Gecikme" for a 10-day-old debt |
| GUI-02-04 resident added to an occupied unit → warning, cancel saves nothing | pass |
| GUI-04-07 co-resident joins via a unit invite | **xfail: bug**, "unit 2 has no active occupancy session" |
| GUI-04-08 empty approval queue | pass (trivially, given finding 5) |
| GUI-07-06 payer-name alias auto-matches | **xfail: bug**, the stored alias is ignored by matching |
| GUI-08-07 residents module search by name and unit | pass |
| GUI-08-08 remove the tenant only | pass (owner kept, occupancy closed) |
| GUI-09-05 / GUI-10-08 tenant pays capital: on-behalf owner + TBK 314 note | pass |
| GUI-09-06 aging buckets + penalty = grand total | pass |
| GUI-09-06 aging total = open ledger | **xfail: bug**, partial payments ignored (₺42.000 shown, ₺41.000 open) |
| GUI-09-07 virman from a real unit's advance | **xfail: bug**, hard-coded units (finding 27) |
| GUI-X-05 reload never leaves a broken screen | pass (the session is not persisted: reload returns to login) |
| GUI-X-06 Turkish money format everywhere | **xfail: bug** (finding 10) |

New ids: `hero_detail_button`, `penalty_days`, `penalty_formula`, `aging_bucket_{current,1_30,31_60,60_plus}`, `aging_total_penalty`, `aging_grand_total`, `receipt_on_behalf`, `receipt_rent_offset_note`, `btn_edit_payer_names`, `payer_name_input`, `btn_add_payer_name`, `btn_save_payer_names`, `btn_dues_more_actions`, `menu_item_virman`.

**Findings from P2:**
30. **Penalty detail shows 0 days.** The detail dialog says "0 Gün Gecikme" for a debt that is 10 days overdue.
31. **Debt aging ignores partial payments.**
32. **Payer-name aliases are ignored.** They are saved (`unit_payer_names`) but never used when a statement is matched.
33. **Owner-occupied units can't take co-residents.** They have no `unit_occupancies` row, so unit-invite registration fails ("no active occupancy session").
34. **Google sign-in is simulated, and there's no offline banner.**
35. **The session is not persisted.** A browser reload always returns to the login screen. The test accepts this as the current design; the stories do not say otherwise.

**Correction (found by the coverage gap report, `GUI_COVERAGE_GAPS.md`):** GUI-02-01 had no test although §8 counted all P0 as automated. It now has three tests in `test_epic02_manager.py`: one passing smoke test, plus strict xfails for finding 36.
36. **Cockpit totals are wrong after a payment, and kuruş are lost.** The cockpit drops paid flats from its totals ("₺0 / ₺1400", "%0" instead of ₺1.400 / ₺2.800, %50) and rounds amounts to whole lira (`toStringAsFixed(0)`).

37. **Remove-tenant lookup mixes unit and person ids.** `update_home_owner` looks the unit up with `id = $1 OR owner_person_id = $1 OR tenant_person_id = $1`, mixing unit and person ids, and silently falls back to in-memory state when the lookup fails. The response is 200 with a unit id that differs from the database, and the tenant is not removed. It is intermittent (seen only in full-suite runs); GUI-08-08 is a non-strict xfail.

Phase 4 (gate, lint, traceability) is done; see GUI_AUTOMATION_PLAN.md. Per-story GUI status: `COMPLETION_STATUS.md`, section "GUI end-to-end coverage".

## 11. UX/UI remediation (2026-11-07, `docs/ux/UX_UI_EVALUATION_REPORT.md`)

The UI changes from the UX report changed what some tests look for. The suite was updated with them:

| Change in the app | Test change |
|---|---|
| Logout moved from the app bar into the profile sheet and now asks for confirmation (`btn_logout` → `btn_confirm_logout` / `btn_confirm_cancel`); `btn_header_logout` is gone | `Shell.logout()` goes avatar → profile → confirm. New: `test_logout_asks_for_confirmation_and_cancel_keeps_the_session` (GUI-06-08) |
| "Profil & Yetki" is no longer a navigation tab; destinations carry `nav_<home\|dues\|residents\|my_flat\|sites>` ids and render as a rail from 840 dp | `Shell.nav()` clicks `nav_<key>`; `nav_tab_count()` counts `nav_*`. GUI-06-10 expects 3 tabs (cockpit) and 2 (own flat) |
| Theme toggle moved from the app bar to the profile sheet (`btn_profile_toggle_theme`, still labelled `theme:dark`/`theme:light`); the theme follows the system until chosen and the choice is saved | GUI-X-02 reads the label from the profile sheet |
| URL per role and tab (`Router`, hash URLs): `/resident/home`, `/manager/dues`, `/manager/my-flat/home`, `/admin/sites` | New GUI-X-07 `test_each_tab_has_a_url_and_browser_back_returns_to_it` |
| Real browser offline/online events drive an inline `offline_banner` | GUI-01-05 strict xfail removed (finding 34, offline part, fixed) |
| One `MoneyFormatter` (`Decimal`, `₺1.423,33`) for every amount, including the import summary, capital views, cockpit and receipts | GUI-X-06 and GUI-02-01 "keeps kuruş" strict xfails removed (findings 10 and the rounding half of 36 fixed). The parsers in `pages/manager.py`, `test_epic02/07/09/10` and `test_p2_edge.py` now read the Turkish format through `support.money.last_amount` |
| Login tab labels lost their emoji prefixes | none (tests use ids) |

Still open from §8–§10: the cockpit's paid-flat totals (36, first half), the lump ledger row (GUI-01-03), and every other strict xfail. Their reasons are unchanged.

## 12. Per-role user journeys (2026-11-11)

**Why the suite missed the forced password change bug.** A user with a temporary password reached a dashboard where every call was refused, so "the admin can enter but sees nothing". The suite still passed, for four reasons:
1. **The tests checked a widget, not an outcome.** GUI-06-06 waited for `banner_must_change_password`, changed the password, and waited for the banner to go. It never checked that the admin's sites appeared, before or after. GUI-03-03 used an empty new site, where "no unit cards" looks the same as "nothing loaded".
2. **Refused calls passed silently.** `page_guard` failed only on 5xx and recorded 4xx. A dashboard full of 403 `PASSWORD_CHANGE_REQUIRED` answers passed.
3. **No real first sign-in.** `E2EStack.reset()` sets `must_change_password=false` for every seeded user, including the bootstrap admin. Only GUI-06-06 set it back, and GUI-03-03 used a freshly created empty site.
4. **The suite was organised by epic, not by user.** There were actors and tests for the manager, the owner and the SaaS admin only. **The home resident and the auditor had no GUI test at all.**

**Changes.**
- `e2e/tests/journeys/`: one journey per role (GUI-J-01 … J-05), built on `support/journey.py` (`Journey.step`, `NetworkLog`) and `pages/onboarding.py` (`ForcePasswordChange`).
- `page_guard` (GUI-X-01) now fails any test that gets a 403 `PASSWORD_CHANGE_REQUIRED`.
- `pages/login.py` knows `resident` and `auditor`; they use the home-user form, and the server decides the role.
- `gui_traceability.py` accepts `GUI-J-nn` ids.

**Verified:** all five journeys pass on the fixed client. Run against the pre-fix client (`e217514`), **all five fail at step 1**, and the guard reports the refused calls (`/saas/sites`, `/site-admin/home-owners`, `/accounting/expenses`).

**Client defects the journeys found (fixed).** Each had been there on every normal sign-in and was hidden by reason 2:

| Defect | Fix |
|---|---|
| `DashboardScreen` asked for the site manager's directory (`GET /site-admin/home-owners`) for owners, residents and auditors: 403 | `fetchHomeOwners` returns early unless `canReadSiteDirectory` (site manager) |
| Residents asked for the owner's household list (`GET /home-residents/members/:unit`): 403 | `fetchResidentDashboard` loads members only when `canManageHousehold` (owner, manager) |
| The auditor's desk asked for `GET /site-admin/overview` (SITE_MANAGE): 403 | `fetchSiteManagerOverview` is for the site manager only |
| Residents were offered "Sakin Davet", which the server refuses (STORY-04-07: only the owner invites) | The invite action is shown to owners only |
| The role checks during sign-in read the previous session's role | `_loadRoleData` sets the session role first |

Flutter unit tests: `test/role_scoped_fetch_test.dart`.

