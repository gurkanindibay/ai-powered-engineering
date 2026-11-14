# SitePulse UX & UI Evaluation

Nov 7, 2026 · Gürkan İndibay

## Executive summary

SitePulse's Flutter UI has a strong visual direction and rich feature coverage, but it is not yet production-grade: accessibility, consistency and maintainability gaps will surface quickly with real residents.

The five priorities, in order:

1. **Accessibility** — no `Semantics` widgets anywhere, status colors that fail WCAG contrast (white on green 2.5:1, on amber 2.2:1), and 191 text styles below 12 px.
2. **Design system enforcement** — the theme defines colors only; 903 hard-coded `fontSize` values and 2,483 direct `Colors.*` references bypass it.
3. **Money display consistency** — the same amount renders as `₺1.423,33` in one place and `₺1423.33` in another; the hero card converts to `double` for formatting.
4. **Navigation model** — no routes or deep links on a web target; a "Profile" tab that opens a sheet; two parallel manager paths behind a segmented switch.
5. **Production hygiene** — the "simulate offline" toggle and one-tap logout sit in the main app bar; there is no localization layer for the hard-coded Turkish strings.

## Re-evaluation after remediation (Nov 7, 2026)

Every finding below was re-checked against `master` (after the GUI test suite merge) and then worked on. **8 of 16 are fixed and 8 are partly fixed.** The partial ones are listed with what is left.

| # | Finding | Status | What changed | Left to do |
| --- | --- | --- | --- | --- |
| 1 | Screen-reader support | Partly fixed | `Semantics` on custom toggles, tabs, segments, filter chips, action tiles and hero buttons (`selected`, `button`, labels); toasts and the offline banner are live regions; decorative icons excluded. Widget tests check `textContrastGuideline` and `labeledTapTargetGuideline` on the resident home and login | `androidTapTargetGuideline` still fails on dense 32 dp buttons; no TalkBack/VoiceOver pass yet |
| 2 | Status colour contrast | Fixed | Two tiers of tokens: bright `accent*` for icons and fills, `*Fill` for white text (green `#047857`, amber `#B45309`, red `#B91C1C`, primary `#0369A1`) and theme-aware `*Text(context)`. Secondary text darkened. Every pair is tested at ≥ 4.5:1 in both themes | Colours passed through variables (`statusColor`) are converted only where a test found them |
| 3 | Money display | Fixed | One `MoneyFormatter` (`Decimal` only, `₺1.423,33`), used by all screens, ledger rows and `Money`. The hero card no longer uses `double`. `ui_style_lint` fails on any hand-formatted amount | — |
| 4 | Typography | Fixed | `TextTheme` with the type scale; no text below 12 px (156 raised, lint-enforced) | Nav labels use the 12 px Label token, not the 14 px the quick-win list suggested |
| 5 | Navigation | Fixed | `MaterialApp.router` with a URL per role and tab (`/resident/home`, `/manager/dues`, `/manager/my-flat/home`, `/admin/sites`). Back, bookmarks and deep links work; a deep link opened while signed out is applied after login | The session is still not persisted, so reload goes to login first (then back to the tab) |
| 6 | Design system bypassed | Partly fixed | `ColorScheme` with `on*` and `surfaceContainer`, a `StatusColors` `ThemeExtension`, spacing, radius and breakpoint tokens, button and input themes. Raw `Color(0x…)` outside the theme went from 105 to 26. The new `ui_style_lint` ratchet blocks new literals | About 900 literal `fontSize`s still need moving to `TextTheme` (the ratchet only stops growth) |
| 7 | Profile tab, tab reset | Fixed | Profile opens from the avatar only. Changing the manager path goes to Home explicitly | — |
| 8 | One-tap logout | Fixed | Logout lives in the profile sheet and asks first ("Çıkış yapılsın mı?") | — |
| 9 | Offline toggle, forced dark mode | Fixed | The offline simulator sits under "Geliştirici araçları" in debug and E2E builds only. Real browser offline events show the banner. The theme follows the system until chosen, and the choice is saved | On mobile and desktop the theme choice is saved only for the session (web uses `localStorage`) |
| 10 | Forms | Partly fixed | Login fields have `autofillHints`, the right keyboard, `textInputAction` and Enter-to-submit inside an `AutofillGroup` | `TextFormField` validators for IBAN, amount and phone across the other forms |
| 11 | Responsive | Fixed | `NavigationRail` from 840 dp, content capped at 1,200 dp, and a two-column resident home. Overflows at 375 dp were fixed and are tested for all three roles | — |
| 12 | Feedback | Partly fixed | Success, info, warning and error toasts each have their own icon and fill and are announced by kind. Errors stay until dismissed. Skeleton lists replace list spinners; offline is an inline banner | Dialogs still open from the controller listener |
| 13 | Manager switch | Partly fixed | Labels ellipsize with the full name in a tooltip; the switch has 48 dp targets and selected-state semantics | Replacing the segmented switch with an account switcher is a product decision |
| 14 | Localization, emoji | Partly fixed | `flutter_localizations` with `tr_TR`, and shared words in `AppStrings` (`Vazgeç` appeared 35 times). No emoji are left in UI strings (lint-enforced) | Moving screen copy to ARB waits on the open locale question |
| 15 | Login | Partly fixed | The quick-login tab shows in dev and test builds only; demo personas were already test-only; a vector Google "G" replaces `Icons.g_mobiledata` | One form with role detection (needs a backend change); swap in the official Google asset when `flutter_svg` is added |
| 16 | Maintainability | Partly fixed | Turkish identifiers and the whole Turkish alias layer (`AidatBorcu`, `siteAdi`, `daireNo`, …) are gone; the resident home is one shared builder | `dashboard_screen.dart` is still ~8,500 lines |

**Tests.** Flutter tests went from 144 to 181, and all pass. New tests are `design_system_test.dart` (formatter, contrast, type scale, toasts) and `ux_shell_and_navigation_test.dart` (routes, router, app bar, logout confirmation, offline banner, rail, 375 dp layouts, semantics, autofill, contrast guidelines). Existing tests were updated for the new behaviour. Where content grew past the 800×600 test viewport, taps now scroll into view first. The Playwright suite's page objects, tab counts and money parsers were updated, and the strict xfails these fixes resolve were removed (GUI-01-05, GUI-X-06, GUI-02-01 kuruş). A new GUI-X-07 test covers URLs and back. See `GUI_TEST_PLAN.md` §11. `ui_style_lint.py` runs as gate `ui-style-lint`.

## Scope and method

The review covers the SitePulse Flutter client (`apps/development-time/SitePulse/flutter/lib/ui`, about 33,400 lines across 21 files), the only end-user UI in the workspace. AuditGuard, TaskPilot and DevFactory have no UI.

It is a static code review against the project's own specs (`ui-ux-spec.md`, `PAPARA_DESIGN_GUIDELINES.md`), WCAG 2.1 AA and Material 3 guidance. Contrast ratios were computed from the theme tokens in `app_theme.dart`. The app was not run: Playwright is not installed locally, so layout and interaction findings come from code and should be confirmed on a device.

## Strengths

The product thinking is ahead of the implementation polish; these are worth keeping.

- **Clear visual direction.** A documented fintech-style language (calm palette, 20 px card radius, flat borders) with both light and dark themes on Material 3.
- **Role-aware home screens.** Resident, site manager and SaaS admin each get a tailored tab set; a manager can switch to their own flat.
- **Resident hero card.** Balance, debt, advance payment and virtual IBAN with copy-to-clipboard are front and centre, which matches the primary job ("what do I owe, how do I pay").
- **Empty-state guidance.** Users without a unit see a guidance card instead of a blank page (`_buildNoHomeownerGuidanceCard`), with tests in `zero_data_guidance_test.dart`.
- **Useful feedback signals.** Unmatched bank transactions show as a badge on the Dues tab; pull-to-refresh is wired up; icon buttons carry tooltips (39 in total).
- **Shared containers.** `AppModalSheet` and `AppFullscreenPage` cap content width (480–640 px), a good base for consistent dialogs.
- **Decimal-safe amount entry** in `payment_checkout_dialog.dart`, which uses `Decimal` for the entered amount.

## Findings

Sixteen issues, five rated High; paths are relative to `SitePulse/flutter/lib/`. Counts come from searching the `ui/` tree.

| # | Area | Finding | Evidence | Severity |
| --- | --- | --- | --- | --- |
| 1 | Accessibility | No screen-reader support: 0 `Semantics` widgets, 0 `semanticLabel`s. Custom `InkWell` toggles never announce their selected state. | `ui/dashboard/dashboard_screen.dart:337` | High |
| 2 | Accessibility | Status colors fail WCAG AA: white on green 2.5:1, on amber 2.2:1, on red 3.8:1; white on primary is 4.1:1, short of 4.5:1 for body text. | `ui/theme/app_theme.dart:5` | High |
| 3 | Money display | Two formats for one amount: a hand-rolled `₺1.423,33` formatter that goes through `double`, and 66 `toStringAsFixed` calls giving `₺1423.33`. | `ui/components/hero_balance_card.dart:378`, `payment_checkout_dialog.dart:800` | High |
| 4 | Typography | No type scale: the theme has no `TextTheme`; 191 styles are 9–11 px, including nav labels (11 px) and the role badge (10 px). | `ui/dashboard/dashboard_screen.dart:158`, `:293` | High |
| 5 | Navigation | No routes or URLs on a web target. Browser back leaves the app; reload drops the current tab; nothing can be deep-linked or bookmarked. | `main.dart:29` | High |
| 6 | Design system | Theme is bypassed: 903 literal `fontSize`s, 105 raw `Color(0x…)`, 146 `Colors.white/black`; `Theme.of` used once. Scaffold color is set by hand from the controller. | `ui/dashboard/dashboard_screen.dart:126` | Medium |
| 7 | Navigation | The "Profil & Yetki" tab opens a sheet instead of a tab, duplicating the avatar. Tab index is silently reset when the manager path changes. | `ui/dashboard/dashboard_screen.dart:276–287` | Medium |
| 8 | Safety | Logout is one tap, red, beside the theme toggle, with no confirmation; its tooltip mixes "log out" and "switch role". | `ui/dashboard/dashboard_screen.dart:213` | Medium |
| 9 | Production hygiene | "Simulate offline" toggle sits in every user's app bar. Dark mode is forced on by default, ignores the system setting and is not saved. | `dashboard_screen.dart:192`, `dashboard_controller.dart:40` | Medium |
| 10 | Forms | 127 bare `TextField`s vs 6 validators; 0 `autofillHints`, 0 `textInputAction`. Password managers can't fill login, Enter doesn't submit, errors show late. | `ui/auth/login_screen.dart:610` | Medium |
| 11 | Responsive | Dashboard is one phone column stretched across desktop web: no max width, only 2 `LayoutBuilder` breakpoints in the app. | `ui/dashboard/dashboard_screen.dart:252` | Medium |
| 12 | Feedback | 159 SnackBars carry most feedback, all in the same cyan, so errors look like success. 0 skeleton loaders; dialogs pop from a controller listener. | `ui/dashboard/dashboard_screen.dart:73` | Medium |
| 13 | Information architecture | Manager mode is a 50/50 segmented switch; the `{site} Yönetimi` label at 12 px has no ellipsis and will overflow with long site names. | `ui/dashboard/dashboard_screen.dart:376` | Low |
| 14 | Localization | All UI strings are hard-coded Turkish with no ARB/`intl` layer ("Vazgeç" appears 24 times). Emoji (🇹🇷, 💡) used as icons render differently per platform. | `ui/components/hero_balance_card.dart:98` | Low |
| 15 | Login | Four login paths (role tabs, quick-all, demo personas, Google) on one 1,962-line screen; the Google button uses `Icons.g_mobiledata`, not the brand mark. | `ui/auth/login_screen.dart:689` | Low |
| 16 | Maintainability | `dashboard_screen.dart` is 8,485 lines; the resident layout is copy-pasted twice; Turkish identifiers (`siteAdi`, `daireNo`, `_buildHesapHareketleriSection`) break the English-only rule. | `ui/dashboard/dashboard_screen.dart:470`, `:517` | Low |

## Recommendations

Work in three phases: fix what blocks real users first, then make the design system the only way to style UI, then restructure. Numbers in brackets point to findings.

### Phase 1 — Quick wins (about 1 sprint)

- [x] Add a single `MoneyFormatter` built on `intl` `NumberFormat.currency(locale: 'tr_TR', symbol: '₺')` that takes `Decimal`, and replace all 66 `toStringAsFixed` calls and the `double` path in the hero card [3].
- [x] Darken status tokens for text and filled buttons (for example green `#047857`, amber `#B45309`, red `#B91C1C`, primary `#0369A1`) so every pair reaches 4.5:1; keep the bright tones for icons and fills only [2].
- [x] Raise the minimum font size to 12 px, with 14 px for body and nav labels [4].
- [x] Hide the offline simulator behind a debug or test-mode flag; follow the system theme by default and save the user's choice [9].
- [x] Move logout into the profile sheet with a confirm step; drop "Profil & Yetki" from the bottom bar [7, 8].
- [x] Add `autofillHints`, `textInputAction` and `onSubmitted` to the login fields so password managers work and Enter submits [10].
- [x] Give SnackBars success, warning and error variants with icon plus color [12].
- [x] Add `maxLines: 1` and ellipsis to the manager path switcher labels [13].

### Phase 2 — Design system and accessibility (2–3 sprints)

- [ ] Define a full `TextTheme` and `ColorScheme` (including `onPrimary`, `surfaceContainer` and status roles) plus spacing and radius tokens in a `ThemeExtension`; read them through `Theme.of(context)` [6].
- [x] Add a lint (custom rule or CI grep) that blocks new literal `fontSize` and `Color(0x…)` outside `ui/theme/` [6].
- [x] Wrap custom toggles, chips and cards in `Semantics` (label, `selected`, `button`); add labels to icon-only controls; replace emoji with `Icon`s [1, 14].
- [ ] Run Flutter's `meetsGuideline(textContrastGuideline)` and `androidTapTargetGuideline` in widget tests (text contrast and labelled tap targets now run; the Android tap-target check is still open) for the main screens [1, 2].
- [ ] Move to `TextFormField` with inline validators for IBAN, amount and phone, shown on blur [10].
- [x] Add skeleton placeholders for the dashboard and lists in place of spinners [12].

### Phase 3 — Structure and scale (2–4 sprints)

- [x] Adopt URL routing (done with Flutter's `Router` API, no new package) with URLs per role and tab (for example `/resident/home`, `/manager/dues`) so back, reload and deep links work on web [5, 7].
- [x] Add breakpoints: `NavigationRail` and a 2-column layout at 840 px and up, with content capped near 1,200 px [11].
- [ ] Replace the manager segmented switch with an account switcher in the profile menu, or a separate "My flat" tab [13].
- [ ] Move strings to ARB files with `flutter_localizations`, keeping Turkish as the default locale [14].
- [ ] Split `dashboard_screen.dart` into one widget per tab and role, extract the shared resident layout, and rename Turkish identifiers [16].
- [ ] Simplify login to one form with role detection; keep demo personas only in test mode; use the official Google sign-in button [15].

## GUI component standards

Ship these standards as a small `ui/design_system/` package: a set of tokens plus `Sp*` wrapper widgets. Screens then use the wrappers and never style Material widgets directly, which closes findings 4, 6, 10 and 12.

### Foundation tokens

| Token group | Values | Rule |
| --- | --- | --- |
| Spacing (dp) | 4 · 8 · 12 · 16 · 24 · 32 · 48 | Screen gutter 16; card padding 16–20; space between sections 24 |
| Radius (dp) | 8 chip · 12 button/input · 20 card · 28 sheet top | No other radius values |
| Type scale (size/weight) | Amount 32/700 · Title 20/600 · Subtitle 16/600 · Body 14/400 · Label 12/500 | 12 px is the floor; amounts use tabular figures |
| Color roles | primary, onPrimary, surface, surfaceContainer, outline, success, warning, danger, info (+ `on*` for each) | Text-bearing pairs ≥ 4.5:1; status shown by icon + text + color, never color alone |
| Elevation | 0, with a 1 px `outline` border | Shadows only on sheets and menus |
| Motion | 150 ms (micro), 250 ms (page/sheet), standard easing | Respect `MediaQuery.disableAnimations` |
| Touch target | ≥ 48 × 48 dp | Applies to icon buttons, chips and list rows |
| Breakpoints (dp) | < 600 compact · 600–839 medium · ≥ 840 expanded | Content capped at 1,200 |

### Element standards

| Element | Standard | Flutter implementation |
| --- | --- | --- |
| Buttons | One primary action per screen or card. Height 48. Verb labels ("Öde", "Kaydet"). The cancel button sits left of confirm. Loading swaps the label for a 20 px spinner and disables the button. | `SpButton.primary` = `FilledButton`; `.secondary` = `FilledButton.tonal`; `.tertiary` = `TextButton`; `.danger` = filled `danger` + confirm dialog |
| Text inputs | Visible label above or floating, helper text, error shown on blur, never placeholder-only. Correct keyboard, autofill hints and input action on every field. | `SpTextField` wraps `TextFormField` with `OutlineInputBorder` (radius 12) |
| Money input | ₺ prefix, right-aligned, `tr_TR` grouping as you type, decimal keyboard, parsed to `Decimal`. | `SpAmountField` + `MoneyFormatter` |
| IBAN input | `TR` prefix locked; digits grouped in 4s; checksum validated; paste-friendly. | `SpIbanField` with input formatter and mod-97 validator |
| Money display | Always `MoneyText(Decimal)`: tabular figures; debt in `danger` with the word "Borç", credit in `success` with "+". | `FontFeature.tabularFigures()` |
| Cards | `surface` fill, 1 px `outline`, radius 20, padding 16–20. One heading, at most one primary action. | `SpCard` (replaces ad-hoc `Container` + `BoxDecoration`) |
| Lists and feed | Row 56 dp (one line) or 72 dp (two lines). Leading 40 dp tinted icon tile; trailing amount right-aligned; date group headers 12 px/600, uppercase. | `SpListTile`, `SpSectionHeader` |
| Status chips | Fixed set: Paid (success), Overdue (danger), Pending (warning), Partial (info), Draft (neutral). Each has an icon + label. | `SpStatusChip(DuesStatus)` |
| Dialogs and sheets | Phones (< 600): modal bottom sheet for tasks. Larger screens: centred dialog, max width 560. `AlertDialog` only for confirmations, naming the object and the consequence. | `AppModalSheet` (existing) made adaptive; `SpConfirmDialog` |
| Navigation | 3–5 destinations, each a real page with a URL; no actions in the bar. `NavigationBar` when compact, `NavigationRail` when medium, extended rail when expanded. | `go_router` `StatefulShellRoute` + `SpAdaptiveScaffold` |
| App bar | Title + site context on the left; at most 2 actions on the right (notifications, avatar). Theme, logout and role switch live in the profile sheet. | `SpAppBar` |
| Feedback | Snackbars: success/info auto-close in 4 s; errors stay until dismissed and offer an action. Page-level states (offline, must change password) use an inline `MaterialBanner`. | `SpToast.success/error/info`, `SpBanner` |
| Loading | Skeleton screens for loads over 300 ms; spinners only inside buttons. | `SpSkeleton` (shimmer optional) |
| Empty states | 48 dp icon, title, one-line explanation, one call to action. | `SpEmptyState` (generalises `_buildNoHomeownerGuidanceCard`) |

A reference page that applies these standards (resident home, phone size, light and dark) lives at [ux-reference/resident_home_reference.html](ux-reference/resident_home_reference.html). Open it in a browser; it uses sample data.

Keep the catalogue in [Widgetbook](https://pub.dev/packages/widgetbook) and cover each `Sp*` widget with light, dark and 200 % text-scale golden tests, so design drift fails CI.

## Icon set

Adopt **Material Symbols Rounded** through the [`material_symbols_icons`](https://pub.dev/packages/material_symbols_icons) package, used only through one semantic `SpIcons` class. It fits the spec's 24 dp grid and 2 px rounded stroke, and it is native to Flutter. Its fill axis also gives outlined-inactive and filled-active states from one glyph.

The app today mixes three styles from 171 different Material icons: 424 uses of the default filled style, 136 outlined and 28 rounded. Icon sizes take 11 different values between 11 and 48 px. Several meanings also have two icons: `key` vs `vpn_key_outlined`, `person_add_alt` vs `person_add_alt_1`, `close` vs `clear`, `delete_outline` vs `delete_forever`. Lucide and Phosphor match the stroke style too, but they have fewer finance and building glyphs and would add a second dependency.

### Style rules

- **One family:** Rounded, weight 400, grade 0, fill 0 by default; fill 1 only for the selected nav destination, a selected toggle and status icons.
- **Three sizes:** 20 dp inline and dense rows, 24 dp default (buttons, app bar, nav), 48 dp empty states. Inside a 40 dp tinted tile the icon is 24 dp.
- **Color:** icons take the color of the text beside them. Semantic colors are used only for status icons and quick-action tiles, with the spec's 15 % tint behind them.
- **One meaning, one glyph:** the map below is the full list; add new entries to `SpIcons` before using them.
- **No emoji or stand-ins:** 🇹🇷 and 💡 become icons; the Google button and the SitePulse logo (currently `Icons.flash_on`) become SVG assets via `flutter_svg`.
- **Accessibility:** icon-only buttons need a `tooltip` (which also sets the semantic label); purely decorative icons go inside `ExcludeSemantics`.
- **Enforcement:** a lint or CI check rejects `Icons.` and `Symbols.` outside `ui/design_system/`.

### Semantic icon map

| Concept (UI label) | `SpIcons` name | Material Symbol | Color role |
| --- | --- | --- | --- |
| Home (Ana Sayfa) | `home` | `home` | neutral |
| My flat (Dairem) | `myUnit` | `door_front` | neutral |
| Residents & owners (Sakinler & Malikler) | `residents` | `group` | neutral |
| Sites (Siteler) | `sites` | `domain` | neutral |
| Profile & permissions | `profile` | `account_circle` | neutral |
| Dues management (Aidat Yönetimi) | `dues` | `payments` | primary |
| Pay dues (Aidat Öde) | `pay` | `credit_card` | primary |
| Virtual IBAN / bank transfer | `virtualIban` | `account_balance` | success |
| Receipts (Dekontlar) | `receipts` | `receipt_long` | info |
| Account activity (Hesap Hareketleri) | `transactions` | `swap_vert` | neutral |
| Bank statement upload | `uploadStatement` | `upload_file` | primary |
| Match payment to unit | `reconcile` | `link` | primary |
| Invite resident (Sakin Davet) | `invite` | `person_add` | warning |
| Household (Hane) | `household` | `family_restroom` | neutral |
| Ownership transfer (Mülk Devri) | `transferOwnership` | `real_estate_agent` | neutral |
| Move-out (Tahliye) | `moveOut` | `door_open` | danger |
| House types & tariffs | `houseTypes` | `home_work` | neutral |
| Capital projects | `capitalProjects` | `construction` | neutral |
| Announcements (Duyurular) | `announcements` | `campaign` | warning |
| Requests / faults (Talep / Arıza) | `requests` | `handyman` | neutral |
| Security & credentials | `security` | `verified_user` | success |
| Password / login key | `password` | `key` | neutral |
| Status: paid | `statusPaid` | `check_circle` (filled) | success |
| Status: overdue | `statusOverdue` | `error` (filled) | danger |
| Status: pending | `statusPending` | `schedule` (filled) | warning |
| Status: partial | `statusPartial` | `clock_loader_40` (filled) | info |
| Offline | `offline` | `cloud_off` | warning |
| Info / warning | `info` / `warning` | `info` / `warning` | info / warning |
| Add / edit / delete | `add` / `edit` / `delete` | `add` / `edit` / `delete` | neutral / neutral / danger |
| Close / search / filter / copy | `close` / `search` / `filter` / `copy` | `close` / `search` / `filter_list` / `content_copy` | neutral |

This map replaces section 1.2 of `ui-ux-spec.md` and adds the concepts that spec does not cover. Check the newer glyphs (`door_open`, `clock_loader_40`) against the installed package version before rollout.

## Next steps

Check these findings in the running app before Phase 1 begins. The proposed replacement colors were checked and all reach at least 5.0:1 on white.

- [ ] Run the web and mobile builds at 390 px and 1,440 px and screenshot each role's home screen to confirm findings 11 and 13.
- [ ] Do a 30-minute TalkBack or VoiceOver pass on login, the resident home screen and payment checkout to size finding 1.
- [ ] Usability-test 3–5 residents on "find what I owe and pay it" to confirm whether the current navigation causes real friction.
- [ ] Open question: is English or another locale planned? The answer sets the priority of finding 14.
