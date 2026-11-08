---
description: Mandatory reuse of SitePulse's shared Flutter components (design system, money input, clipboard, selection, resident directory, Decimal JSON).
globs: apps/development-time/SitePulse/flutter/**, **/*.dart
---

# Flutter Shared-Component Directives

When creating, modifying or reviewing Dart code under `apps/development-time/SitePulse/flutter/`:

## 1. Authoritative Reference
- The component catalogue, usage contracts, promotion procedure and review checklist are in
  [flutter-reusable-components](file:///.agents/skills/flutter-reusable-components/SKILL.md). Read it
  before writing a widget helper, form field, copy action, filter, empty state, status pill,
  confirmation or API model.
- The background and evidence are in
  [docs/flutter-reusability-report.md](file:///docs/flutter-reusability-report.md).

## 2. Obligations

### For UI/UX and Architect Agents
1. Specify screens in terms of catalogue components (`SpMetricValue`, `SpGuidanceCard`,
   `SpStatusBadge`, `SpFilterChip`, `SpMoneyFormField`, `SpIbanCopyRow`, `showSpSelection`,
   `ResidentSummary`) and `SpTone` colour roles, not raw colours or bespoke containers.
2. When a design needs something the catalogue lacks, state whether it is local (one screen) or a
   new shared component (two or more screens), following §3 and §4 of the skill.

### For Developer Agent (The Maker)
1. **Reuse first:** use the catalogue component when it fits; extend it when it almost fits. Never
   copy a private `_buildX` helper into a second screen; promote it instead.
2. **Money:** parse typed amounts with `MoneyInput` / `SpMoneyFormField` (`MoneyFormatter.tryParse`),
   read API money with `readDecimal`, parse statements with `BankFileParser`, and display with
   `formatTry`. No `double`, and invalid input is never submitted as `Decimal.zero`.
3. **Platform effects:** clipboard through `sp_clipboard.dart`, feedback through `SpToast` /
   `spSnackBar(kind:)`, and interactions through full-screen pages (`AppFullscreenPage`,
   `showSpPage`, `showSpSelection`, `pushConfirmation`).
4. **Tokens:** use `AppSpacing`, `AppRadius`, theme text styles and `SpTone` in new code. Do not
   raise the `ui-style-lint` ratchet.
5. **Keep automation ids:** pass the existing keys and `testId`s through shared components.

### For Tester Agent (The Checker)
1. Reject changes that duplicate a catalogue entry or bypass the money, clipboard or feedback
   helpers (checklist §5 of the skill).
2. Every new or extended shared component gets controller-free tests in
   `flutter/test/reusable_components_test.dart` (content, callbacks, both themes, 2x text scale).

## 3. Automated Verification
Run `python3 scripts/flutter_reuse_inventory.py --check` (gate `flutter-reuse`), together with
`ui_style_lint.py`, `testid_lint.py`, `flutter analyze` and `flutter test`, before submitting any
Flutter change.
