# SitePulse uncovered-scenario assessment

**25 November 2026 · master `535284c` · 19 proposed issues for 30 unautomated scenarios.** Five issues may require product changes and 14 cover tests, fixtures or scenario updates. Add **one separate CI reporting issue** if the goal also includes reconciling all 213 entries marked “Automated, no CI result.” That brings the initial backlog to **20 issues**. The estimate groups scenarios that share a workflow or blocker. [Product-status dashboard](https://gurkanindibay.github.io/ai-powered-engineering/) · [Matching master CI run](https://github.com/gurkanindibay/ai-powered-engineering/actions/runs/45568761048)

## What the dashboard shows

| State | Scenarios | Backlog implication |
| --- | ---: | --- |
| Passing | 227 | Passing scenario evidence in the published snapshot |
| Failing | 0 | No observed failing scenario in the snapshot |
| Automated, no CI result | 213 | Reconcile scenario links with CI case results and check which lane ran |
| Planned | 30 | Implement or recover automation, including product work where the scenario still fails |
| **Total** | **470** | **440 automated (93.6%)** |

The planned scenarios are concentrated in **EPIC-13 (21)**. EPIC-02 and EPIC-06 have three each, EPIC-10 has two, and EPIC-03 has one. The two pending smoke scenarios are the site lifecycle and first manager sign-in. [Product-status dashboard](https://gurkanindibay.github.io/ai-powered-engineering/) · [Scenario catalogue](../../.specify/features/README.md)

## Proposed issue backlog

**Start with issues 1–2 for smoke coverage and issue 3 for the shared dependency on person-level accrual.** The scope column marks items that may require changes to product behavior. Several pending notes predate implementation work. Reproduce those scenarios against current master and confine any fix to the behavior that is still missing.

| # | Proposed issue | Scenario IDs | Scope and acceptance outcome |
| ---: | --- | --- | --- |
| 1 | Automate the manager site lifecycle | `SC-13-06-01` | **Smoke.** Run all eight checkpoints against one isolated site, from setup through dues collection and period closure. |
| 2 | Automate first manager sign-in | `SC-13-08-01` | **Smoke.** Sign in with provisioned credentials, change the password, and verify the populated site becomes accessible. |
| 3 | Verify per-person occupancy accrual and correction | `SC-13-03-02`, `SC-13-03-03`, `SC-13-03-07`, `SC-13-03-09`, `SC-13-03-21` | **Product and tests.** Verify separate debts for successive occupants, the effective date, same-day handover, exact decimal totals, debtor IDs on original and corrected rows, and each resident's view. Recheck against the person-scoping work in [#255](https://github.com/gurkanindibay/ai-powered-engineering/issues/255) and the site-clock fixes. |
| 4 | Verify joint-owner exposure in the multi-site journey | `SC-13-14-10` | **Potential product change and tests.** Confirm the journey's accrued rows carry joint-owner exposure and count the debt once. Reuse the existing joint-liability assertions and check whether the journey fixture or accrual path still needs a fix. [#207](https://github.com/gurkanindibay/ai-powered-engineering/issues/207) · [#304](https://github.com/gurkanindibay/ai-powered-engineering/pull/304) |
| 5 | Preserve the seller's advance on title transfer | `SC-13-03-06` | **Product and tests.** Verify the seller retains the advance until payout or approved transfer and the buyer starts with a zero advance. |
| 6 | Verify overdue-day badge text | `SC-02-02-02` | Add a stable semantics target and assert the exact day count and overdue badge in the dues ledger. |
| 7 | Update and automate owner registration | `SC-02-03-05` | Update the stale temporary-credential scenario to reflect the activation link and automate the current flow. |
| 8 | Verify the resident announcement feed | `SC-02-05-02` | Publish as a manager and verify the intended resident sees the announcement. |
| 9 | Deliver and verify manager credential SMS | `SC-03-04-03` | **Potential product change and tests.** Verify the onboarding flow is wired to credential delivery and use a fake gateway in CI to assert the dispatch. |
| 10 | Automate Google sign-in with a CI identity-provider fake | `SC-06-03-02`, `SC-06-05-01`, `SC-06-05-02` | Verify the login option, provider redirect and profile after callback with the shared fake. |
| 11 | Complete and automate the resident capital-dues view | `SC-10-06-03`, `SC-10-06-04` | **Product and tests.** Verify owner project details and deliver and test the tenant guidance banner. |
| 12 | Extend F3 coverage for start-residing dates | `SC-13-01-10`, `SC-13-01-15` | Pin the accrual schedule and house-type tariff. Verify ordinary and backdated occupancy against expected charges. |
| 13 | Automate recovery from transient failures and stale actions | `SC-13-08-02`, `SC-13-08-06`, `SC-13-08-07` | Reuse browser response interception to distinguish loading, failure and empty states, recover a committed payment after a lost response, and refresh stale occupancy state. |
| 14 | Automate browser session isolation | `SC-13-08-04`, `SC-13-10-08` | Verify the browser clears prior data after manager-session expiry and discards a late response after switching tenants. |
| 15 | Verify resident payment confirmation across views | `SC-13-04-13` | Confirm the same payment is visible in the resident statement and manager view. |
| 16 | Verify tenant checkout and owner collection in the browser | `SC-13-05-17` | Assert the checkout debt breakdown and continued ability to collect from the owner using the existing backend flow. |
| 17 | Verify period statuses and enabled actions | `SC-13-11-05` | Assert the supported action matrix across period states. |
| 18 | Automate partial Excel import | `SC-13-05-10` | Run the mixed-validity file in the journey fixture and assert accepted records and visible row errors. Reuse companion file work where applicable. [#418](https://github.com/gurkanindibay/ai-powered-engineering/issues/418) |
| 19 | Verify manager statements in the four-period multi-site journey | `SC-13-13-05` | Check the browser entry points and assert period history, payer identity, site scoping and cash totals against ledger expectations. Reconcile the pending tag with the work delivered under [#251](https://github.com/gurkanindibay/ai-powered-engineering/issues/251). |

All 30 pending IDs appear once. The five potential product issues cover 10 scenarios. The remaining 14 issues cover 20 scenarios. Close each issue when its scenario assertions run and pass in the appropriate CI lane and the `@pending` tags are removed. For issue 4, sequence it after issue 3 if the same accrual path blocks both.

## Existing work and CI evidence

- **Open work can be reused.** The open issue list had six entries at assessment time. [#418](https://github.com/gurkanindibay/ai-powered-engineering/issues/418) supplies companion files for manual testing. [#383](https://github.com/gurkanindibay/ai-powered-engineering/issues/383) covers nightly browser and API checks. [#437](https://github.com/gurkanindibay/ai-powered-engineering/issues/437) addresses remaining site-local date conversions. Their published scopes leave the corresponding scenario assertions in this backlog. [Open issues](https://github.com/gurkanindibay/ai-powered-engineering/issues)
- **Replace stale blocker references as each scenario is resolved.** The traceability check flagged eight pending scenarios that still refer to closed issues. [#207](https://github.com/gurkanindibay/ai-powered-engineering/issues/207), [#251](https://github.com/gurkanindibay/ai-powered-engineering/issues/251), [#271](https://github.com/gurkanindibay/ai-powered-engineering/issues/271), and [#273](https://github.com/gurkanindibay/ai-powered-engineering/issues/273) provide implementation history for those entries.
- **Optional issue 20: publish scenario results across CI lanes.** Join named Rust, Flutter, API, harness and browser case results with the scenario catalogue. Distinguish passing, failed, skipped and scheduled evidence and surface links that cannot be matched. A one-off name and module/file comparison found **194 of the 213** dashboard entries had at least one linked passing case in the same CI artifact. That match provides a triage lead. Verify assertion quality and investigate the remaining **19**, including tests in other lanes and unmapped links, before estimating additional gap-specific tickets. [Master CI run and `e2e-test-report` artifact](https://github.com/gurkanindibay/ai-powered-engineering/actions/runs/45568761048)

The count applies to the existing acceptance catalogue at this revision. A wider requirements audit or newly specified behavior would need its own estimate.
