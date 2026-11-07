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
| GUI-06-06 | 03-04/06-04 | SaaS | P0 | seed | Log in with the bootstrap password → `banner_must_change_password` → change password → log out → log in with the new password succeeds and the old one fails | `banner_must_change_password`, `btn_open_change_password` | ✅ |
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
| GUI-03-03 | 03-04 | New manager | P1 | ui:GUI-03-02 | Log in with the issued temporary password → forced password change → cockpit of the new, empty site (zero-data guidance) | `banner_must_change_password` | ✅ |
| GUI-03-04 | 03-01 | Manager | P1 | api:`unit(kardelen-rezidans)` | Begonya manager never sees Kardelen units or totals anywhere in the cockpit or residents module | residents list | ✅ |
| GUI-03-05 | 03-02 | SaaS | P1 | seed | Edit site → change name/address/admin phone → save → card updated | `btn_edit_site_*`, `edit_site_*_field`, `btn_save_site_edit` | ✅ |
| GUI-03-06 | 03-06 | SaaS | P1 | ui:GUI-03-02 (empty site) | Delete the empty site → confirm → removed from the portfolio | NEW:`btn_delete_site_*` | ✅ "Sil" |
| GUI-03-07 | 03-06 | SaaS | P1 | seed | Try to delete Begonya (has units) → blocked with the invariant message ("aktif daireler … bulunmaktadır") and the card stays | NEW:`btn_delete_site_*` | ✅ |
| GUI-03-08 | 03-07 | SaaS | P1 | seed | "Şifre Yenile" on a site → new `SP-XXXX-PASS` password dialog; the old manager password stops working | NEW:`btn_reset_admin_password_*` | ✅ |
| — | 03-05 | — | — | — | **Excluded:** REST contract, covered by `scripts/api_system_check.py`. | | |

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

### Cross-cutting
| ID | Role | Pri | Steps → Expected | UI |
|---|---|---|---|---|
| GUI-X-01 | Any | P0 | Every P0 test fails if there are uncaught browser console errors or failed (5xx) API calls | — |
| GUI-X-02 | Any | P1 | Theme toggle on the login screen (`controller.toggleTheme`) switches dark/light, and the choice holds after login | ✅ |
| GUI-X-03 | Manager | P1 | Zero-data guidance on a fresh site (no units, no periods) shows the guidance cards, not errors | ✅ |
| GUI-X-04 | Homeowner, Manager | P1 | At 375×812 (mobile): login, dashboard, payment checkout and residents module work with no horizontal scroll | — |
| GUI-X-05 | Any | P2 | Browser reload on the dashboard keeps or restores the session as designed | — |
| GUI-X-06 | Any | P2 | Every amount shown uses the Turkish format `₺1.234,56` with 2 decimals | — |

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
| EPIC-08 | 5 | 5 | — | — |
| EPIC-09 | 7 | 7 | 09-03 (wording) | — |
| EPIC-10 | 7 | 7 | 10-06 tenant (UI not found) | — |
| **Total** | **62** | **53** | **6** | **9** |

**Scenarios:** 83 (P0: 21, P1: 46, P2: 16) including cross-cutting. Story traceability was checked by script: all 62 `STORY-*` ids in `.specify/requirements` map to a scenario or a written exclusion.

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
| GUI-10-02 | `test_epic10_capital.py::test_project_budget_is_split_by_land_share_to_the_kurus` | pass (unit shares sum exactly to ₺500.000,00; unit 14's share is exact) |
| GUI-10-04 | `test_epic10_capital.py::test_installment_accrual_charges_owners_only` | pass (OWNER / CAPITAL_DUES rows only, installment marked accrued) |
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

Next: P1 scenarios, epic by epic (Phase 3 continues), then the Phase 4 wiring.

