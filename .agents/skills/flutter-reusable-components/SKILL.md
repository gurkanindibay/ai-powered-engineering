---
name: flutter-reusable-components
description: >
  Catalogue and usage rules for SitePulse's shared Flutter components (design-system widgets,
  money input, clipboard, selection pages, resident directory, Decimal JSON reading). Use it
  before writing or reviewing any widget, form field, amount parsing, copy action, filter,
  empty state, status pill, confirmation page or API model under
  apps/development-time/SitePulse/flutter, and when deciding whether new UI should become a
  shared component.
license: MIT
metadata:
  author: Antigravity
  version: "1.0.0"
---

# SitePulse Flutter Reusable Components

SitePulse has one shared implementation for each recurring UI and money pattern. This skill tells
you which one to use, how to use it, and when to add a new one. The history and evidence are in
[docs/flutter-reusability-report.md](file:///docs/flutter-reusability-report.md).

**The rule:** before writing a private `_buildX` helper, a `Container` styled as a card or pill, a
`TextField` for an amount, a `Clipboard` call, a `Decimal.tryParse`, a filter chip or a selection
page, look the need up in the catalogue below. Use the shared component when it fits. When it
almost fits, extend it, following §4. Write a local version only when §3 says the need is genuinely
local.

Paths below are relative to `apps/development-time/SitePulse/flutter/lib/`.

---

## 1. Component catalogue

### Colour roles: `SpTone` (`ui/design_system/sp_tone.dart`)
`neutral`, `info`, `success`, `warning`, `danger`, `accent`. Shared widgets take a tone, never a raw
`Color`. `tone.foreground(context)` is text-safe in both themes (it resolves through the
`StatusColors` theme extension), `tone.accent(context)` is for icons and borders, and
`tone.tint(context)` is for pill and icon-well backgrounds.

| Old code | Use |
| --- | --- |
| `AppColors.accentGreen` / `Colors.green` as a status | `SpTone.success` |
| `AppColors.accentOrange` / `Colors.amber`, `Colors.orange` | `SpTone.warning` |
| `AppColors.accentRed` / `Colors.red` | `SpTone.danger` |
| `AppColors.accentCyan` / `Colors.blue` | `SpTone.info` |
| `AppColors.accentPurple` / `Colors.indigo` | `SpTone.accent` |

### Module headers: `SpPageHeader` (`ui/design_system/sp_page_header.dart`)
`SpPageHeader(title:, icon:, subtitle:, actions:)` is the full-width bordered module identity
card. Titles wrap; actions wrap beneath the title. Place it after any context switcher and before
section navigation, summaries and filters. The page layout contract and screen audit are in
[docs/page-layout-standard.md](../../../docs/page-layout-standard.md). Dedicated full-screen flows
use `AppFullscreenPage` with its AppBar title, top-aligned body and sticky bottom actions.

### Metrics: `SpMetricValue`, `SpIconMetric` (`ui/design_system/sp_metric.dart`)
- `SpMetricValue(label:, value:, tone:)`: a label above a bold value (summary rows).
- `SpIconMetric(label:, value:, icon:, tone:, dense:)`: an icon, a value and a centred label.
- `value` is pre-formatted text. Money **must** come from `formatTry` / `MoneyFormatter`, never a
  string literal such as `'₺240.000'`.

### Empty states and guidance: `SpGuidanceCard` (`ui/design_system/sp_guidance_card.dart`)
`SpGuidanceCard(icon:, title:, message:, tone:, prominent:, tonedBorder:, action:, tip:)`.
`prominent` is the first-run variant with the icon in a tinted circle; `tip` is the bordered
lightbulb strip. The caller decides *which* state applies (no site, no period, no rows, filtered
out). While data is loading, show `SpSkeletonList` (`ui/design_system/sp_skeleton.dart`), never
guidance.

### Status pills: `SpStatusBadge` (`ui/design_system/sp_status_badge.dart`)
`SpStatusBadge(label:, tone:, icon:)`. Map the domain status to a label and tone in the feature
code; the badge never infers a state from its wording. When two states share a tone, add an
`icon` so status is not conveyed by colour alone.

### Filter chips: `SpFilterChip` (`ui/design_system/sp_filter_chip.dart`)
`SpFilterChip(label:, selected:, onSelected:, tone:, id:)`. `id` is both the `Key` and the
automation `testId`. Filter state stays in the caller. A raw `FilterChip(` fails the
`filter-chip` rule.

### Choosing from a list: `showSpSelection<T>` (`ui/components/sp_dialog_pages.dart`)
```dart
final choice = await showSpSelection<String>(
  context: context,
  title: 'Ödeyen Rolü Filtresi',
  options: const ['ALL', 'TENANT', 'OWNER'],
  labelOf: PaymentTrackingPage.roleLabel,
  selected: _selectedRole,
  idOf: (v) => 'filter_role_option_$v',
);
if (choice == null || choice == _selectedRole || !mounted) return; // back = no change
```
This builds a full-screen page, as the constitution requires. Building `SpSelectionPage(` by hand
fails the `selection-page` rule.

### Money input: `SpMoneyFormField`, `MoneyInput`, `validateMoneyInput` (`ui/design_system/sp_money_field.dart`)
- **One parsing rule:** `MoneyFormatter.tryParse` accepts `1.423,33`, `1423,33`, `1423.33` and
  `₺1.423`. Without a comma, a dot counts as thousands grouping only when exactly three digits
  follow it (`1.423` is 1423; `1.42` is 1.42).
- **In a `Form`:**
  `SpMoneyFormField(controller:, decoration:, requiredMessage:, invalidMessage:, positive:, extraValidator:, onAmountChanged:, restrictInput:, autovalidateMode:)`.
- **Outside a form:** call `MoneyInput.parse(text).amount`, which is `null` for empty or invalid
  text. Call `validateMoneyInput(text)` to get the error message.
- **Never** fall back to `Decimal.zero` for invalid input that will be *submitted*. Never convert
  money to `double`. Business limits (maximum payable, allocation rules) go in `extraValidator` or
  the caller.
- `Decimal.tryParse(` anywhere in `lib/ui` fails the `money-parse` rule.

### Copying: `spCopyToClipboard`, `spCopyIban`, `SpIbanCopyRow` (`ui/design_system/sp_clipboard.dart`)
- `spCopyToClipboard(context, text, successMessage:)` copies **exactly** what it is given, awaits
  the platform call, and shows a success or error toast.
- `spCopyIban(context, iban)` removes the grouping spaces (`normalizeIban`); use it for IBANs only.
- `SpIbanCopyRow(iban:, onCopied:, compact:, copyButtonId:)` is the bordered IBAN row with a
  "Kopyala" pill. It shows an empty label when the IBAN is empty.
- A raw `Clipboard.setData(` fails the `clipboard` rule.

### Feedback: `SpToast`, `spSnackBar(kind:)` (`ui/design_system/sp_feedback.dart`)
New code calls `SpToast.success/info/warning/error(context, message)` or `spSnackBar(kind: ...)`.
`appSnackBar` (which infers the kind from colour or wording) exists only for legacy call sites. Do
not add new calls to it, and convert nearby ones when you touch a file. Constructing `SnackBar(`
directly fails the `raw-snackbar` rule.

### Confirmations: `AppFullscreenPage.pushConfirmation` (`ui/components/app_fullscreen_page.dart`)
This is the single confirmation implementation. `showSpConfirmDialog` (sp_feedback.dart) is an
adapter for `destructive:` / `confirmKey:` callers. Pass `cancelId` / `confirmId` to keep stable
automation ids. Never use `AlertDialog`, `showDialog` or bottom sheets (the `no-popup` rule in
`ui_style_lint.py`).

### Password change: `ChangePasswordForm` (`ui/components/change_password_form.dart`)
Current / new / confirm fields, client validation (match, `kMinPasswordLength`, differs from current)
and submit through `DashboardController.changePassword`. Used by the forced
`ForcePasswordChangeScreen` (temporary password, every role) and the profile sheet. Pass `idPrefix` /
`submitId` to keep automation ids. Do not build another password form.

### Resident directory (`ui/residents/resident_directory.dart`)
These are feature widgets, shared by the dashboard directory and `OwnersResidentsModulePage`:
- `ResidentOccupancyStats.from(units)`: counts, plus `occupancyRate` computed with integer
  arithmetic.
- `ResidentSummary(stats:, dense:)`: the "Sakin & Mülkiyet Durum Özeti" card.
- `matchesResidentFilters(ho, blockFilter:, occupancyFilter:, query:)` with `OccupancyFilter.*`
  and `allBlocksFilter`.
- `normalizeBlockCode`, `distinctBlocks`.

Any new resident list, count or filter goes through these instead of re-implementing the
`.where(...)` logic.

### Decimal from JSON: `readDecimal`, `readDecimalOrNull` (`domain/formatting/json_decimal.dart`)
`readDecimal(json, 'total_amount')` (optionally with `fallback:`) and
`readDecimalOrNull(json, 'contract_amount')`. Malformed values are reported through
`onMalformedDecimal`. The `Decimal.tryParse(json['k']?.toString() ?? '0') ?? Decimal.zero`
pattern fails the `json-decimal` rule.

### Bank statements: `BankFileParser` (`domain/services/bank_file_parser.dart`)
- `parseText` and `parseBytes` handle MT940, CSV/TSV and free-form text.
- `parseMt940` returns every transaction.
- `parseAmount` normalises statement amounts with the `MoneyFormatter` rule.

Controllers call the parser; they never parse statements themselves (the `bank-amount` rule).

### Existing foundations (unchanged)
`AppSpacing`, `AppRadius`, `AppBreakpoints`, `StatusColors`, `AppTheme.textTheme`
(`ui/theme/app_theme.dart`); `AppFullscreenPage`, `showSpPage` with `SpAlertPage` /
`SpDialogPage` (`ui/components/`); `SpSkeletonList`, `selectableSemantics`; `AppStrings`
(`l10n/app_strings.dart`); `testId` (`testing/test_id.dart`); `MoneyFormatter` / `formatTry`.

---

## 2. Writing UI with the catalogue

1. **Look it up.** Find the need in §1. Search for an existing call site
   (`grep -rn "SpGuidanceCard(" lib/ui`) and copy its shape.
2. **Pass data, not controllers.** Shared widgets take values, a tone and callbacks.
   `DashboardController` stays in the feature container.
3. **Use tokens inside new code:** `AppSpacing.*` for padding and gaps, `AppRadius.*` for corners,
   `Theme.of(context).textTheme.*` for text, and `SpTone` for colour. A literal is acceptable only
   where no token exists. The `ui-style-lint` ratchet must not go up.
4. **Strings:** labels used by more than one screen live in `AppStrings` (for example
   `AppStrings.totalUnits` and `AppStrings.remainingDebt`). Shared widgets receive strings from
   the caller.
5. **Automation:** every interactive shared component takes an `id` / `copyButtonId` / `idOf`.
   Keep existing ids when migrating; `testid_lint.py` must stay green.

---

## 3. When a local widget is fine

A private builder is acceptable when **all** of these are true:
- only one screen needs it, and no catalogue entry covers it;
- it renders domain-specific layout, not a generic card, pill, row or field;
- it does not parse money, copy to the clipboard, show feedback, or open a page.

If a second screen needs the same thing, promote it (§4) instead of copying it.

---

## 4. Adding or extending a shared component

Promote a pattern when **two or more real callers** need the same behaviour, semantics or visual
contract.

1. **Placement.**
   - Generic, controller-free presentation goes in `ui/design_system/sp_<name>.dart`.
   - Page hosts go in `ui/components/`.
   - Feature-specific shared pieces go next to the feature (for example `ui/residents/`).
   - Pure parsing or formatting goes in `domain/formatting/`.
2. **Contract.** Use a named constructor with values, `SpTone`, callbacks and an optional
   automation id. Add a few named variants (`dense`, `prominent`, `compact`), not a constructor
   with many flags. Keep business rules, controller access and data fetching out.
3. **Implementation.** Use tokens (§2.3). Use `withValues(alpha:)`, not the deprecated
   `withOpacity`. Use `ExcludeSemantics` on decorative icons, and add `Semantics` or
   `selectableSemantics` for state.
4. **Migration.** Move every existing duplicate, then delete the private helpers. Keep keys and
   `testId`s. List any behaviour difference you unify in the PR description.
5. **Tests.** Add cases to `flutter/test/reusable_components_test.dart`, built without
   `DashboardController`: content, the callback or return value, light and dark themes, and 2x
   text scaling. For parsing helpers, cover empty, invalid, zero, sub-kuruş and large values.
6. **Guard.** If the old pattern can be detected lexically, add a rule to `RULES` in
   `apps/development-time/SitePulse/scripts/flutter_reuse_inventory.py` (with a scope and an
   exemption for the shared file). Add a self-test in
   `harness/tests/test_flutter_reuse_inventory.py`, and an inventory counter if useful.
7. **Register.** Add the component to §1 of this skill and to the `flutter_reuse_inventory.py`
   entry in [skills.md](file:///skills.md).

---

## 5. Review checklist (Maker and Checker)

- [ ] No new private `_buildMetric*`, `_buildEmptyState`, `_build*Pill`, `_build*FilterChip` or
      `_copy*` helpers duplicate a catalogue entry.
- [ ] Amounts: parsed through `MoneyInput` / `SpMoneyFormField` / `MoneyFormatter.tryParse`,
      shown through `formatTry`, never `double`, and invalid input never submitted as zero.
- [ ] API money is read through `readDecimal` / `readDecimalOrNull`.
- [ ] Copying goes through `sp_clipboard.dart`, and only IBANs are normalised.
- [ ] Colours are expressed as `SpTone` / `StatusColors` / `AppColors` helpers, never raw
      `Colors.*` or `Color(0x…)` in feature code.
- [ ] New feedback uses `SpToast` / `spSnackBar(kind:)`; no new `appSnackBar`.
- [ ] Interactions are full-screen (`AppFullscreenPage`, `showSpPage`, `showSpSelection`,
      `pushConfirmation`).
- [ ] Keys and `testId`s are preserved; shared widgets have isolated tests.

## 6. Enforcement

Run these before concluding a Flutter change. All of them are gates in `run_tests.py`:

```bash
./scripts/flutter_reuse_inventory.py --check   # gate flutter-reuse: clipboard, money-parse, json-decimal,
                                               # bank-amount, filter-chip, selection-page, raw-snackbar
./scripts/ui_style_lint.py                     # gate ui-style-lint: font floor, MoneyFormatter, no-popup, ratchet
./scripts/testid_lint.py                       # gate testid-lint
(cd apps/development-time/SitePulse/flutter && flutter analyze && flutter test)
```

Use the inventory table (`./scripts/flutter_reuse_inventory.py`, without `--check`) to track
adoption: `AppSpacing.` should rise relative to `EdgeInsets.`, `SpTone.` should rise relative to
raw colours, and `spSnackBar(` / `SpToast.` should rise relative to `appSnackBar(`.
