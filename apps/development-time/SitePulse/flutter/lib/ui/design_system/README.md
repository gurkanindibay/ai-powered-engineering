# SitePulse design system

Shared, controller-free Flutter building blocks. **Use these before writing a local widget.**

The full catalogue, usage contracts, the rules for promoting a widget to a shared component, and the
review checklist live in the agent skill
[`.agents/skills/flutter-reusable-components/SKILL.md`](../../../../../../../.agents/skills/flutter-reusable-components/SKILL.md).
That skill is mandatory for SitePulse Flutter work through
[`.agents/rules/flutter-components.md`](../../../../../../../.agents/rules/flutter-components.md).

| File | Use it for |
| --- | --- |
| `sp_tone.dart` | `SpTone` colour roles (text-safe in both themes, via `StatusColors`) |
| `sp_metric.dart` | `SpMetricValue`, `SpIconMetric`: label/value figures |
| `sp_guidance_card.dart` | `SpGuidanceCard`: empty states and first-run guidance |
| `sp_status_badge.dart` | `SpStatusBadge`: status and bucket pills |
| `sp_filter_chip.dart` | `SpFilterChip`: directory filter chips |
| `sp_money_field.dart` | `SpMoneyFormField`, `MoneyInput`, `validateMoneyInput`: typed amounts (Decimal only) |
| `sp_clipboard.dart` | `spCopyToClipboard`, `spCopyIban`, `SpIbanCopyRow`: copying |
| `sp_feedback.dart` | `SpToast`, `spSnackBar(kind:)`, `showSpConfirmDialog` |
| `sp_skeleton.dart`, `sp_semantics.dart` | Loading placeholders, selected-state semantics |
| `money_formatter.dart` | Re-export of `MoneyFormatter` / `formatTry` |

Related shared code outside this folder:
- `ui/components/sp_dialog_pages.dart`: `showSpSelection<T>`.
- `ui/components/app_fullscreen_page.dart`: `pushConfirmation`.
- `ui/residents/resident_directory.dart`: resident directory pieces.
- `domain/formatting/json_decimal.dart`: `readDecimal`.
- `domain/services/bank_file_parser.dart`: bank statement parsing.

Guard: `python3 scripts/flutter_reuse_inventory.py --check` (gate `flutter-reuse` in `run_tests.py`).
Add new components to the skill's catalogue and give them a test in `test/reusable_components_test.dart`.
