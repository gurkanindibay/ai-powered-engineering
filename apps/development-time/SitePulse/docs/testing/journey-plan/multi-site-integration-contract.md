# Multi-site financial journey integration contract

This contract describes the final integration boundary for [issue #246](https://github.com/gurkanindibay/ai-powered-engineering/issues/246). The component issues were delivered independently so their fixtures could be reviewed in isolation. The parent journey is complete only when the components run in one E2E attempt from an empty site list and the combined checkpoints below pass in CI.

The accepted data, dates, amounts, and invariants remain defined by [the approved journey analysis](zero-to-multi-site-financial-journey.md). This page records how its active implementation pieces compose; it does not replace their acceptance scenarios or mark any in-progress issue complete.

## Component composition

| Issue | Responsibility in the integrated attempt | Required hand-off |
|---|---|---|
| [#251](https://github.com/gurkanindibay/ai-powered-engineering/issues/251) | Establish a genuinely empty E2E database/site list and check manager-facing evidence surfaces. | Reset only the disposable E2E database before the attempt; capture unit workspace statements and **Dues Management → Tahsilat & Kasa Takibi** evidence. |
| [#247](https://github.com/gurkanindibay/ai-powered-engineering/issues/247) | Onboard Site A and Site B, create three blocks and all 88 units through product flows, then register people. | Return both site IDs and a verified unit inventory to the same attempt; do not seed a prebuilt site or create residents before the 88 units. |
| [#248](https://github.com/gurkanindibay/ai-powered-engineering/issues/248) | Accrue January–April 2027 and post the approved full, partial, missed, and designated payments. | Use the shared attempt's sites and controlled Europe/Istanbul clock; retain payment history and balances between checkpoints. |
| [#249](https://github.com/gurkanindibay/ai-powered-engineering/issues/249) | Exercise ownership and occupancy changes, historical debt, and household/title transitions. | Apply first-of-month changes to the same units before accrual; keep former debtors visible in final statements. |
| [#250](https://github.com/gurkanindibay/ai-powered-engineering/issues/250) | Supply independent Decimal expectations for cash, open debt, allocations, and period status. | Compare the live ledger and manager views against fixture-derived values, not values read from the product response under test. |

## Integrated attempt contract

1. Start one attempt with an empty site list using the disposable E2E database setup. No global production reset endpoint or SQL-created journey entities are allowed.
2. Keep both sites, all identities, the clock, and the attempt evidence alive through onboarding, four billing periods, transitions, and final reconciliation. Do not reset between component stages.
3. Create and verify 24 units in Site A and 64 in Site B before registering residents. Record the site IDs and exact block/unit inventory in attempt evidence.
4. Run each monthly checkpoint at the approved controlled date. After each payment stage, assert site-scoped posted cash and payment allocations; after April 10, assert period statuses, debtor-level open rows, fees, joint exposure, and site totals.
5. Use manager-facing checks for onboarding and inventory, one household or title transition, unit statements, and site cash/receipt evidence. Compare the cash view with posted receipts and check Site B before and after a Site A payment.
6. Make failures identify the site, period, unit, debtor, and expected/actual amount. Preserve the attempt trace and browser evidence in the existing CI artifacts.

The April 10 expected posted cash is TRY 90,658.50 for Site A and TRY 189,538.75 for Site B. Expected open primary debt including fees is TRY 5,804.09 and TRY 2,661.67 respectively. Count an owner's joint exposure separately in owner reporting and once only in site debt totals.

## Completion gate and current dependencies

Issue #246 is ready to close when all linked component issues are complete, the integrated attempt above runs from a clean isolated setup in CI, and the cash/debt/manager-view assertions pass together. Passing component model tests or separately passing journey slices does not satisfy this gate.

The component slices are delivered by these PRs:

| Issue | Delivered by |
|---|---|
| [#247](https://github.com/gurkanindibay/ai-powered-engineering/issues/247) | [PR #262](https://github.com/gurkanindibay/ai-powered-engineering/pull/262) (merged) |
| [#248](https://github.com/gurkanindibay/ai-powered-engineering/issues/248) | [PR #259](https://github.com/gurkanindibay/ai-powered-engineering/pull/259) (merged) |
| [#249](https://github.com/gurkanindibay/ai-powered-engineering/issues/249) | [PR #256](https://github.com/gurkanindibay/ai-powered-engineering/pull/256) (merged) |
| [#250](https://github.com/gurkanindibay/ai-powered-engineering/issues/250) | [PR #254](https://github.com/gurkanindibay/ai-powered-engineering/pull/254) (merged) |
| [#251](https://github.com/gurkanindibay/ai-powered-engineering/issues/251) | [PR #257](https://github.com/gurkanindibay/ai-powered-engineering/pull/257): the one-attempt composition and manager-browser assertions |

This table records where each slice lives, not its live status; review, CI and merge state are tracked on those PRs and on [issue #246](https://github.com/gurkanindibay/ai-powered-engineering/issues/246). Issue #246 stays open until #251 is merged and the integrated attempt passes on `master`; do not report it complete while an issue, check, or review remains unresolved.
