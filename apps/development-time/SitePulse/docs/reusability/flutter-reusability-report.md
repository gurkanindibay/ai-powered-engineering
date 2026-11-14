# SitePulse Flutter Reusability Assessment

Date: 8 November 2026  
Scope: `apps/development-time/SitePulse/flutter`  
Method: static repository review; no application code changed.  
Revision: 3 (recommendations implemented; see [Implementation status](#implementation-status) and [Revision notes](#revision-notes)).

## Implementation status

Revision 3 implements the recommendations below. All 207 Flutter tests pass (181 existing + 26 new), `flutter analyze` reports no new warnings, and the `ui-style-lint` ratchet dropped from 903 to 857 literal font sizes.

| Recommendation | Status | Where |
| --- | --- | --- |
| 1. Metric widgets | Done: manager, SaaS and dues summaries use `SpMetricValue`; resident summaries use `SpIconMetric` | [sp_metric.dart](../../flutter/lib/ui/design_system/sp_metric.dart) |
| 2. Resident content | Partly done: the summary card, occupancy stats, block/occupancy/search filtering and filter chips are shared by the dashboard and the module (module search now also matches e-mail, as the dashboard did). Unit cards, household forms and workflows are **not** merged yet; they still need a behaviour inventory | [resident_directory.dart](../../flutter/lib/ui/residents/resident_directory.dart) |
| 3. Money input | Done: `MoneyInput`, `validateMoneyInput`, `SpMoneyFormField`; checkout, manual payment, transfer, capital budget/disbursement and house types parse with `MoneyFormatter.tryParse`. The transfer form now reports an invalid amount instead of ignoring it. The parser rule (a dot without a comma is grouping only before exactly three digits) is documented and tested | [sp_money_field.dart](../../flutter/lib/ui/design_system/sp_money_field.dart) |
| 4. IBAN copy | Done: `spCopyToClipboard` awaits the write and reports failure; `spCopyIban` normalises only IBANs; `SpIbanCopyRow` replaces the checkout and virtual-IBAN rows. The matching card's description is now copied with its spaces | [sp_clipboard.dart](../../flutter/lib/ui/design_system/sp_clipboard.dart) |
| 5. Filters and selection pages | Done for chips and payment filters: `SpFilterChip`; `showSpSelection<T>` replaces the three payment filter pages (back = no change; the settlement options gained ids) | [sp_filter_chip.dart](../../flutter/lib/ui/design_system/sp_filter_chip.dart), [sp_dialog_pages.dart](../../flutter/lib/ui/components/sp_dialog_pages.dart) |
| 6. Guidance cards | Done: manager, dues and dashboard guidance use `SpGuidanceCard`. The unboxed payment-tracking empty state is unchanged | [sp_guidance_card.dart](../../flutter/lib/ui/design_system/sp_guidance_card.dart) |
| 7. Page hosts | Partly done: `AppFullscreenPage.pushConfirmation` is the one confirmation implementation and `showSpConfirmDialog` is an adapter (automation ids kept). The unused, deprecated `AppModalSheet` was deleted. Scaffold internals are not merged | [app_fullscreen_page.dart](../../flutter/lib/ui/components/app_fullscreen_page.dart) |
| 8. Status badges | Done: aging pills, payer-role and reconciliation status use `SpStatusBadge` with `SpTone`; the 31-60 and 60+ buckets also carry icons | [sp_status_badge.dart](../../flutter/lib/ui/design_system/sp_status_badge.dart) |
| 9. Tokens | Done inside every new component (`SpTone` resolves through `StatusColors`) | [sp_tone.dart](../../flutter/lib/ui/design_system/sp_tone.dart) |
| 10. Non-widget reuse | Done: 57 JSON fallbacks use `readDecimal`/`readDecimalOrNull`, which report malformed values. `BankFileParser.parseMt940` parses every `:61:`/`:86:` pair with its own date, direction and reference, and the controller's duplicate MT940 and free-form paths were removed. XLSX numeric cells (`1423.33`) are no longer read as 142333 | [json_decimal.dart](../../flutter/lib/domain/formatting/json_decimal.dart), [bank_file_parser.dart](../../flutter/lib/domain/services/bank_file_parser.dart) |
| Tooling | Done: `flutter_reuse_inventory.py` (`--help`, `--json`, `--check`), gate `flutter-reuse`, registered in `skills.md` | [flutter_reuse_inventory.py](../../scripts/flutter_reuse_inventory.py) |

**Keeping it reused:** the catalogue and promotion rules are in the [flutter-reusable-components skill](../../../../../.agents/skills/flutter-reusable-components/SKILL.md). It is bound to all SitePulse Flutter work by [.agents/rules/flutter-components.md](../../../../../.agents/rules/flutter-components.md), `AGENTS.md`, and the Developer, Tester and UI/UX agent specs, and enforced by the `flutter-reuse` gate.

New tests: [reusable_components_test.dart](../../flutter/test/reusable_components_test.dart) and [test_flutter_reuse_inventory.py](../../harness/tests/test_flutter_reuse_inventory.py).

**Still open:** merging the resident unit cards, household forms and move-in/out/transfer workflows; shared scaffold internals for the page hosts; migrating the remaining 70 `appSnackBar` calls to explicit kinds; and the custom dues/capital segment tabs. **Found during implementation, not changed:** `HeroBalanceCard` and `UnitMatchingCriteriaCard` fall back to a hard-coded demo IBAN when none is allocated, so a resident could see a payment IBAN that is not theirs. This needs a product decision.

## Executive assessment

**Yes—several reusable components can be created.** SitePulse already has useful foundations, but substantial feature UI remains implemented as private widget-building methods inside large screens. The best next step is to consolidate repeated behavior within this application, starting with metrics and resident management. Publishing a separate component package would be premature.

The highest-value candidates are:

1. **Metric presentation:** extract shared label/value and icon/value/label widgets from repeated helpers.
2. **Resident-management content and forms:** share the UI currently implemented in both the dashboard and standalone residents module.
3. **Money input:** reuse the existing decimal-safe parser through a consistent field component.
4. **IBAN copying:** share copy behavior and accessible presentation, with explicit normalization rules.
5. **Filter selection and guidance states:** standardize repeated controls and empty-state layouts.

Two cross-cutting findings matter as much as any single widget:

- **Design tokens exist but are barely adopted.** `AppSpacing`, `AppRadius`, `StatusColors`, and the theme's text styles are bypassed by hundreds of inline literals. New shared widgets will only deliver consistency if they consume these tokens.
- **Money parsing is not reused in the domain layer either.** The same JSON-to-`Decimal` fallback appears 54 times, and the controller has bank-statement amount parsing outside `BankFileParser`. These are reuse opportunities for helpers, not widgets, but they carry financial risk.

This assessment identifies candidates and migration boundaries; it does not claim measured performance improvements, exact duplicate-code percentages, or implementation effort in days.

## Scope and evidence quality

The Flutter package contains 45 Dart files under `lib/`, totaling 35,636 lines, and 18 `*_test.dart` files directly under `test/`. The `lib/ui/` subtree contains 29 files and 32,497 lines, including `DashboardController`.

Concentration is significant: `dashboard_screen.dart` has 8,567 lines, `dashboard_controller.dart` has 5,174, and `owners_residents_module_page.dart` has 3,059. File size is a maintainability signal, not proof of duplication by itself. Recommendations below are grounded in inspected implementations and call sites.

Lexical inventory of `lib/ui/` (occurrences / files):

| Pattern | Count | Interpretation |
| --- | --- | --- |
| `InputDecoration(` | 154 / 12 | Input styling is largely per call site; the theme's input decoration is not relied on. |
| `Clipboard.setData(` | 5 / 5 | None awaited; four strip all spaces from the payload. |
| `TextStyle(` / `fontSize:` | 1,026 / 21 and 921 / 21 | Versus 3 `textTheme.` references: the type scale is mostly bypassed. |
| `EdgeInsets.` / `AppSpacing.` | 741 / 21 and 28 / 4 | Spacing tokens are rarely used. |
| `BorderRadius.circular(` / `AppRadius.` | 673 / 21 and 10 / 4 | Radius tokens are rarely used. |
| Raw `Colors.blue/red/green/orange/amber/grey/purple/teal` | 94 / 11 | None in `app_theme.dart`; these bypass `AppColors` and `StatusColors`. |
| `Color(0x` | 72 / 10 | 38 are theme definitions; 34 are inline in 9 feature files. |
| `StatusColors` | 15 / 1 | The theme extension is defined but not consumed outside `app_theme.dart`. |
| `appSnackBar(` / `spSnackBar(` | 75 / 12 and 3 / 1 | The legacy, wording-inferred feedback API dominates. |
| `AppStrings.` | 86 / 18 | Localization exists, but labels such as `'Toplam Daire'` are still repeated as literals in 4 files. |
| `testId(` | 304 / 19 | Extractions must carry identifiers through as parameters. |

These are lexical counts, not extraction opportunities or identical implementations. Counts include declarations where applicable and describe this checkout only.

Graphify was attempted first, but this checkout has no `graphify-out/` directory, so no graph was available to query. Findings therefore use direct source inspection. No browser review, runtime profiling, automated clone analysis, or test execution was performed. Existing test coverage was inspected, but passing status was not established.

All source links below are relative to this report; named symbols identify the relevant implementation.

## Existing reusable assets to preserve

| Asset | Evidence | Recommendation |
| --- | --- | --- |
| Theme, typography, spacing, radii, breakpoints, status colors | [app_theme.dart](../../flutter/lib/ui/theme/app_theme.dart): `AppTheme`, `AppColors`, `AppSpacing`, `AppRadius`, `AppBreakpoints`, `StatusColors` (a `ThemeExtension`) | Extend and adopt these foundations rather than introducing a second token system. Adoption is currently low (see inventory), so every extracted component should use tokens internally. Prefer existing Material themes for ordinary buttons and inputs. |
| Full-screen interaction host | [app_fullscreen_page.dart](../../flutter/lib/ui/components/app_fullscreen_page.dart): `AppFullscreenPage`, `push`, `buildBottomBar` | Reuse for forms and interactions; preserve the workspace requirement for full-screen flows. |
| Full-screen confirmation and selection hosts | [sp_dialog_pages.dart](../../flutter/lib/ui/components/sp_dialog_pages.dart): `SpAlertPage`, `SpDialogPage`, `SpSelectionPage`, `showSpPage` | Keep the public adapters during migration; consolidate common scaffold internals only after documenting their layout differences. |
| Feedback | [sp_feedback.dart](../../flutter/lib/ui/design_system/sp_feedback.dart): `SpToast`, `spSnackBar(kind:)`, compatibility `appSnackBar`, `showSpConfirmDialog` | `appSnackBar` (75 calls) infers the kind from background colour or message wording; `spSnackBar` (3 calls) takes an explicit `ToastKind`. New shared components should emit explicit kinds; migrate legacy callers opportunistically. |
| Loading and selection semantics | [sp_skeleton.dart](../../flutter/lib/ui/design_system/sp_skeleton.dart), [sp_semantics.dart](../../flutter/lib/ui/design_system/sp_semantics.dart) | Compose existing helpers into new widgets; do not create another skeleton or selected-state semantics system. |
| Money formatting and parsing | [domain formatter](../../flutter/lib/domain/formatting/money_formatter.dart): `MoneyFormatter`; [UI entry point](../../flutter/lib/ui/design_system/money_formatter.dart) | The UI file re-exports the domain implementation; this is intentional reuse, not duplicate formatting logic. |
| Localization | [app_strings.dart](../../flutter/lib/l10n/app_strings.dart): `AppStrings` | Shared widgets take display strings from callers; repeated feature labels move into `AppStrings` as they are migrated. |
| Domain-specific UI | [HeroBalanceCard](../../flutter/lib/ui/components/hero_balance_card.dart), [VirtualIbanCard](../../flutter/lib/ui/components/virtual_iban_card.dart), [ResidentActionsRow](../../flutter/lib/ui/components/resident_actions_row.dart) | Preserve recognizable feature components while extracting smaller shared pieces where repetition is demonstrated. |
| Automation identifiers | [test_id.dart](../../flutter/lib/testing/test_id.dart): `testId` | Preserve existing keys and semantic identifiers through extractions. |

## Recommended component candidates

Priority indicates recommended sequence and value; effort is relative implementation and migration complexity, not a time estimate.

| Candidate | Priority | Relative effort | Reuse scope | Main benefit |
| --- | --- | --- | --- | --- |
| `SpMetricValue` / `SpMetricTile` | P1 | Small | Multiple features | Remove closely matching presentation helpers. |
| `OwnersResidentsContent`, resident cards and forms | P1 | Large | Dashboard and standalone module | Prevent two implementations of the same workflows from drifting. |
| `SpMoneyFormField` | P1 | Medium | Checkout, payments, capital projects, house types, household edit | Consistent parsing and invalid-input behavior. |
| `SpIbanCopyRow` plus copy helper | P1 | Small–medium | Balance, IBAN, checkout, matching | Consistent empty states, clipboard handling, and feedback. |
| Decimal field-reading helper | P1 | Small | `dues_models.dart`, `DashboardController` | One audited place for API money decoding; no silent zero. |
| `SpFilterChip` and typed selection helper | P2 | Medium | Directories, payments, dues | Shared selection semantics and appearance. |
| `SpGuidanceCard` | P2 | Small | Dashboard, manager, dues, payments | Consistent empty-state layout without sharing business decisions. |
| Shared full-screen scaffold internals | P2 | Medium | Existing page hosts | Reduce parallel app-bar/body implementations. |
| `SpStatusBadge` | P3 | Small–medium | Payment and aging views initially | Centralize status presentation and accessible color roles. |

### 1. Metric widgets: the best first extraction

**Evidence:** `ManagerCockpitView._buildMetricTile` in [manager_cockpit_view.dart](../../flutter/lib/ui/components/manager_cockpit_view.dart), `SaasAdminView._buildMetric` in [saas_admin_view.dart](../../flutter/lib/ui/components/saas_admin_view.dart), and `_buildStatTile` in [dues_management_view.dart](../../flutter/lib/ui/components/dues_management_view.dart) each render a label above a bold value. The manager and SaaS implementations are identical apart from the value font size (14 vs 13).

Icon-based metrics recur in `_buildMetricItem` in both [dashboard_screen.dart](../../flutter/lib/ui/dashboard/dashboard_screen.dart) and [owners_residents_module_page.dart](../../flutter/lib/ui/residents/owners_residents_module_page.dart). Capital projects adds a decorated card in `_buildMetricTile` in [capital_projects_view.dart](../../flutter/lib/ui/components/capital_projects_view.dart).

**Proposed boundary:** begin with `SpMetricValue(label, value, tone)` for the closely matching label/value case. Add a separate icon metric or a small, named layout variant only when migrating the resident summaries. A decorated `SpMetricTile` can compose the value widget. Avoid one constructor with many flags for every existing layout.

**Keep outside:** financial calculations, counts, formatting choices, data fetching, and controller access. The basic widget can receive formatted text; monetary formatting remains the caller's responsibility through `MoneyFormatter`. Note that `SaasAdminView` currently passes hand-written strings such as `'₺240.000 /ay'`; when migrating, produce such values through `formatTry` rather than literals.

**Verification:** migrate manager and SaaS first, preserving appearance; check long labels, large values, light/dark themes, and text scaling. Then migrate dues and resident metrics where the contract fits.

### 2. Resident content and forms: highest structural value

**Evidence:** the dashboard contains `_buildHomeOwnersManagementView`, `_buildKpiMetrics`, `_buildMetricItem`, occupancy/block filters, `_buildHomeOwnerCard`, household editing, move-in/out, ownership transfer, and add-resident flows. The standalone residents module implements corresponding directory, summary, filter, card, and form behavior.

Both paths are reachable: the dashboard returns `_buildHomeOwnersManagementView` from its manager secondary tab and also opens `OwnersResidentsModulePage`; [dues_management_view.dart](../../flutter/lib/ui/components/dues_management_view.dart) opens the module as well. This is active duplication, rather than merely unused historical code.

**Proposed boundary:** extract feature-owned `OwnersResidentsContent` with reusable `UnitResidentCard`, `ResidentSummary`, and `ResidentFilters`. The dashboard embeds the content; the standalone page wraps it in `AppFullscreenPage`. Extract shared contact/household fields before attempting to unify entire add/edit workflows.

**Contract:** pass displayed data, current filters, selected card tabs, and typed callbacks. Keep shell-specific navigation, loading orchestration, controller subscriptions, and persistence outside low-level cards. Keep filter state local to each host unless synchronized state is explicitly required.

**Migration caution:** the module has `initialUnitId`, `initialBlockFilter`, and `initialOccupancyFilter`; preserve and test these behaviors. The two implementations have styling and workflow differences, so do not replace one wholesale without a behavior inventory. Preserve distinctions among owners, tenants, co-residents, active responsibility, and ledger roles.

**Verification:** exercise both entry points for owner-occupied, tenant-occupied, and vacant units; search/filter; add/edit/remove household members; move-in/out; transfer; cancellation; and return to the calling screen.

### 3. Money input: share parsing as well as appearance

**Evidence:** amount fields use at least four parsing strategies:

| Call site | Strategy | Invalid input result |
| --- | --- | --- |
| Checkout `_onAmountChanged` in [payment_checkout_dialog.dart](../../flutter/lib/ui/components/payment_checkout_dialog.dart) | Replace `,` with `.`, strip `₺`, `Decimal.tryParse` | `Decimal.zero` |
| Manual payment and transfer forms in [payment_tracking_page.dart](../../flutter/lib/ui/components/payment_tracking_page.dart) | Replace `,` with `.`, `Decimal.tryParse` | `Decimal.zero` |
| Household edit in `dashboard_screen.dart` | Replace `,` with `.`, `Decimal.tryParse` | Falls back to the existing `monthlyDues`; the text is only ever set from a `Decimal` (display-only, never user-typed), so the fallback is unreachable in practice |
| Capital budget/disbursement in [capital_projects_view.dart](../../flutter/lib/ui/components/capital_projects_view.dart), house types in [house_types_modal.dart](../../flutter/lib/ui/components/house_types_modal.dart) | Raw `Decimal.tryParse` | Validation error (comma decimals rejected) |
| Dues preview in `dashboard_screen.dart` | `MoneyFormatter.tryParse` | `null` (the only UI caller of the shared parser) |

`MoneyFormatter.tryParse` accepts grouped Turkish amounts and currency symbols.

For example, the shared parser accepts `1.423,33`, while checkout's replacement yields `1.423.33`, which fails decimal parsing and falls back to zero. Capital and house-type forms reject `1400,50`. Revision 2 called the household edit the riskiest case, but its dues text is set only from tariff `Decimal` values and is never bound to an editable field, so the fallback cannot be reached; it now uses `MoneyFormatter.tryParse` for consistency. These are source-level inconsistencies; live user impact was not reproduced.

The shared parser also has an ambiguity to settle before it becomes the single entry point: with no comma, `1.423` is read as 1423 (thousands grouping), but `1.42` is read as 1.42. Document this rule and test it, or require a comma for decimals.

**Proposed boundary:** `SpMoneyFormField` composes `TextFormField`, uses `MoneyFormatter.tryParse`, and exposes `Decimal?` with an explicit validation result. Preserve partial text while the user types; format on an agreed boundary such as focus loss rather than replacing input on every keystroke.

**Keep outside:** positivity rules, maximum payable amount, advance allocation, installment calculations, submission, and ledger effects. Invalid text must remain distinguishable from a valid zero. Never convert money to `double` or `num` for shared-field convenience.

**Verification:** grouped/un-grouped amounts, comma and dot inputs supported by the existing parser, currency symbols, empty/partial/invalid text, negative values under caller policy, and large Decimal amounts. Changing parsing is behavioral work and needs tests, even if introduced alongside a widget extraction.

### 4. IBAN copy row and copy behavior

**Evidence:** clipboard actions exist in [virtual_iban_card.dart](../../flutter/lib/ui/components/virtual_iban_card.dart), `HeroBalanceCard`'s private `_IbanRow`, [payment_checkout_dialog.dart](../../flutter/lib/ui/components/payment_checkout_dialog.dart), [unit_matching_criteria_card.dart](../../flutter/lib/ui/components/unit_matching_criteria_card.dart), and the dashboard invitation flow.

**Proposed boundary:** a compact `SpIbanCopyRow(iban, label, onCopied)` handles selectable display, empty state, accessible action, and feedback. A small clipboard helper accepts an exact payload; IBAN normalization belongs in the IBAN-specific adapter. Await copying before reporting success and handle failure through the existing feedback system.

Today none of the five calls awaits `Clipboard.setData`; feedback varies from an `appSnackBar` with wording-inferred kind (matching card) to none at all, and the invitation copy is the only call that preserves the exact text.

**Important distinction:** `_copyToClipboard` in the matching card strips spaces for every input, including `criteria.recommendedDescription`. Reusing that normalization for descriptions or invitation URLs could change content. Preserve exact text by default; remove grouping spaces only for an IBAN copy action.

`VirtualIbanCard` can retain its richer layout and compose the row. Do not force the balance hero, checkout, and all clipboard actions into a single full card.

**Verification:** exact clipboard payload, grouped IBAN normalization, empty IBAN, spaced description preservation, clipboard failure, and existing automation identifiers.

### 5. Filter controls and selection pages

**Evidence:** occupancy/block chips repeat between the dashboard and resident module. Custom selected segments also exist in dues (`_buildSegmentTab`) and capital projects (`_buildSubTabButton`). Payment tracking repeats three full-screen option-list methods: `_showChannelFilterDialog`, `_showRoleFilterDialog`, and `_showSettlementFilterDialog`.

**Proposed boundary:** use a themed Material chip where it meets the need. Extract `SpFilterChip` only for the recurring application-specific contract. Add a typed full-screen selection helper returning `T?`, implemented on the existing `SpSelectionPage`, with supplied options, labels, selected value, and stable identifiers.

**Keep outside:** fetching on selection, role rules, query construction, and current filter state. Distinguish a chip that applies a selection from a button that opens a selection page. Keep tab/segment navigation separate unless its semantics and interaction genuinely match.

**Verification:** selected-state semantics, keyboard focus, cancellation without mutation, identifier preservation, and refresh after a committed selection.

### 6. Guidance and empty states

**Evidence:** manager `_buildNoSiteGuidance` and `_buildNoPeriodGuidance` share icon/title/body card layouts. Dues has `_buildZeroDataGuidanceCard`, dashboard has `_buildNoHomeownerGuidanceCard`, and payment tracking has `_buildEmptyState`.

**Proposed boundary:** `SpGuidanceCard(icon, title, message, action, tone)` standardizes spacing, wrapping, and optional action placement. Use a simple composable body for unboxed states rather than adding many appearance flags.

**Keep outside:** deciding whether there is no site, no assigned unit, no dues period, no matching data, or a loading/error condition. These states have different meaning and actions. Continue using `SpSkeletonList` for loading; do not display an empty state while data is pending.

**Verification:** long localized copy, optional action, small widths, text scaling, and existing zero-data guidance expectations.

### 7. Consolidate existing page hosts incrementally

**Evidence:** `AppFullscreenPage` builds its own app bar, width constraint, and safe-area layout. `SpDialogPage`, `SpAlertPage`, and `SpSelectionPage` share `_spAppBar` but implement separate scaffolds and body arrangements. Two full-screen confirmation entry points exist: `AppFullscreenPage.pushConfirmation` (9 callers, in the dashboard and residents module) and `showSpConfirmDialog` (1 caller, `profile_role_sheet.dart`). A third, `AppModalSheet.showConfirmation`, is a bottom-sheet variant on a deprecated class and has no callers. Converge on one confirmation API and keep the other as a thin adapter.

**Recommendation:** share internal app-bar and frame primitives, or extend an existing host after documenting required capabilities. Retain the current public APIs as adapters until callers migrate. Preserve scroll ownership: forms, free-form content, and selection lists cannot all be blindly wrapped in another scroll view. Also preserve return values, back/cancel behavior, sticky actions, keyboard insets, and stable back-button identifiers.

`AppModalSheet` (`ui/components/app_modal_sheet.dart`) was marked `@Deprecated`, called the prohibited `showModalBottomSheet`, and had no callers in Flutter `lib/`, `test/` or the `e2e/` suite. It was deleted in revision 3. The exemption for it in `ui_style_lint.py` is now inert.

### 8. Status badges: useful after the first migrations

**Evidence:** payment entry cards and `DebtAgingWidget._buildBracketPill` in payment tracking, plus status labels inside reconciliation `_buildQueueItemCard`, each build status presentation locally. The aging pills use raw Material colours (`Colors.blue`, `Colors.amber.shade700`, `Colors.orange.shade800`, `Colors.red.shade700`) instead of `StatusColors`, so their contrast does not follow the theme.

**Proposed boundary:** `SpStatusBadge(label, tone, icon)` owns padding, readable theme colors, and optional icon semantics. Features map domain statuses to labels and tones. A badge must not infer a settlement or occupancy state from display wording.

**Verification:** contrast in both themes, text wrapping, and meaningful text/icon cues independent of color. The token tests establish useful foundations, but they do not prove accessibility for every badge composition.

### 9. Token adoption inside shared components (cross-cutting)

**Evidence:** see the inventory table. `AppSpacing`, `AppRadius`, and `StatusColors` are defined but rarely or never used. Inline `TextStyle(fontSize: ...)` replaces the theme's type scale throughout feature code.

**Recommendation:** do not run a mass find-and-replace. Each extracted component should use `AppSpacing`, `AppRadius`, theme text styles, and `StatusColors` internally, so adoption grows as callers migrate. Where a literal has no matching token (for example `fontSize: 13`), decide whether to snap it to the scale or add a token. Record that decision instead of preserving it silently. Test appearance in both themes before and after.

### 10. Non-widget reuse: money decoding and bank-statement parsing

**Evidence:** the pattern `Decimal.tryParse(json[key]?.toString() ?? '0') ?? Decimal.zero` appears 54 times across [dues_models.dart](../../flutter/lib/domain/models/dues_models.dart) and [dashboard_controller.dart](../../flutter/lib/ui/dashboard/dashboard_controller.dart). A missing field and a malformed amount both become a valid zero, and nothing is reported. Separately, the controller's pasted-statement path contains its own MT940 `:61:` regex and line-amount normalization alongside calls to `BankFileParser.parseText` in [bank_file_parser.dart](../../flutter/lib/domain/services/bank_file_parser.dart).

**Proposed boundary:** a small domain helper such as `readDecimal(json, key, {Decimal? fallback})` in `lib/domain/`. It should state whether absence is allowed and surface malformed values (log or throw in debug) instead of coercing them. Move all statement amount parsing into `BankFileParser` so one tested parser covers files and pasted text.

**Keep outside:** ledger semantics such as whether a missing balance may be treated as zero; callers choose that explicitly.

**Verification:** existing [financial_fixture_test.dart](../../flutter/test/financial_fixture_test.dart) and [bank_file_parser_test.dart](../../flutter/test/bank_file_parser_test.dart), plus new cases for missing keys, malformed strings, numeric JSON values, and pasted MT940 text producing the same rows as the file path.

## Architectural limits on reuse

Application-internal reuse is more immediately valuable than reuse across products. Many feature widgets accept the broad `DashboardController`, and labels, currency conventions, and business workflows are SitePulse-specific. For example, `UnitMatchingCriteriaCard` takes the controller directly, whereas `VirtualIbanCard` already accepts simple values and a callback.

Use two boundaries:

- **Design-system widgets:** theme-driven visual controls receiving values and callbacks, with no `DashboardController`, API calls, or money calculations.
- **Feature widgets:** resident directories, household forms, ledger summaries, and reconciliation presentation that intentionally understand SitePulse models. Feature containers adapt controllers to smaller presentation contracts.

Do not split `DashboardController` merely to support the first metric extraction. Later, feature-specific state/controllers can reduce coupling where repeated workflows need it. Likewise, do not create a generic CRUD form engine, a universal transaction card, or wrappers around every `Container` and `TextField`. A wrapper should own repeated behavior, semantics, or a stable visual contract that the existing theme cannot already provide.

## Suggested implementation sequence

1. **Small proof:** extract the matching manager/SaaS metric widget using design tokens, migrate both callers, and verify it independently of `DashboardController`.
2. **Behavioral consistency:** settle the `MoneyFormatter.tryParse` ambiguity rule, then add money-input and IBAN-copy primitives with explicit parsing and normalization tests. Migrate one flow at a time.
3. **Domain helpers (can run in parallel with step 2):** introduce the Decimal field reader and move pasted-statement parsing into `BankFileParser`.
4. **Resident consolidation:** inventory differences between dashboard and standalone module; share summary/filter presentation, then cards and contact fields, then workflows where contracts match.
5. **Broader adoption:** migrate guidance cards, typed selections, and badges. Consolidate page-host internals after scroll/navigation contracts are clear.

Suggested placement: general presentation primitives under the existing `lib/ui/design_system/`; full-screen hosts remain under `lib/ui/components/`; resident-specific pieces stay under `lib/ui/residents/`. Keep the current directory structure until extraction demonstrates a need for a wider reorganization.

## Verification and acceptance criteria for future implementation

Existing regression assets include [design_system_test.dart](../../flutter/test/design_system_test.dart), [ux_shell_and_navigation_test.dart](../../flutter/test/ux_shell_and_navigation_test.dart), [zero_data_guidance_test.dart](../../flutter/test/zero_data_guidance_test.dart), [owners_residents_module_test.dart](../../flutter/test/owners_residents_module_test.dart), [home_owner_directory_and_edit_test.dart](../../flutter/test/home_owner_directory_and_edit_test.dart), [payment_tracking_and_aging_test.dart](../../flutter/test/payment_tracking_and_aging_test.dart), and [financial_fixture_test.dart](../../flutter/test/financial_fixture_test.dart).

Gaps in the current test assets: there are no golden tests, and [ui_test_helpers.dart](../../flutter/test/ui_test_helpers.dart) contains only a logout helper. For each new shared component, add a focused widget test (built without `DashboardController`) covering light/dark themes, text scaling, and `testId` propagation. Golden tests are optional and should be introduced only if the team accepts maintaining them.

An extraction is ready when at least two real callers use its shared contract, the migrated private implementations are removed, presentation widgets can be tested without constructing the dashboard controller, and feature-specific rules remain in their owning layer. Preserve keys, E2E semantic identifiers, full-screen navigation, caller state on return, and Decimal precision.

Run focused widget/domain regressions and the Flutter suite for implementation changes, then the required SitePulse gate runner: `python3 apps/development-time/SitePulse/scripts/run_tests.py` with the required database environment, or `--skip-db` when PostgreSQL is unavailable. Report skipped gates explicitly. After actual code changes, follow the workspace rules: run `graphify update .` and restart the stack with `apps/development-time/SitePulse/scripts/restart-all.sh`.

The inventory above was produced by ad-hoc commands. Under the workspace tool-crystallization rule, if it is re-run to track migration progress, turn it into a `scripts/` Python tool with `--help` and `--json`, and register it in `skills.md`.

This report is documentation only: no components were implemented, no runtime behavior changed, and no tests or verification gates are represented as passed.

## Revision notes

Revision 3 implemented the report (see [Implementation status](#implementation-status)) and corrected one revision 2 claim: the household-edit dues fallback is unreachable, because that text is never user-editable.


Revision 2 corrected and extended revision 1:

- **Corrected:** the confirmation API on `AppFullscreenPage` is `pushConfirmation`. `showConfirmation` belongs to the deprecated bottom-sheet `AppModalSheet` and has no callers.
- **Corrected:** Graphify was unavailable because no `graphify-out/` directory exists, not only `graph.json`.
- **Corrected:** the manager/SaaS metric helpers are identical except font size, not just similar.
- **Added:** a lexical inventory showing design-token, typography, colour, feedback, and localization adoption gaps.
- **Added:** money-input call sites missed in revision 1 (`house_types_modal.dart`, household edit with silent fallback), the shared parser's dot-ambiguity, and the fact that `MoneyFormatter.tryParse` has only one UI caller.
- **Added:** non-widget reuse (54 repeated JSON Decimal fallbacks; bank-statement parsing outside `BankFileParser`).
- **Added:** raw colours in aging pills, unawaited clipboard calls, `appSnackBar`/`spSnackBar` usage split, test-asset gaps, and the exact stack-restart script.

