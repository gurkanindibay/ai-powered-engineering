# Linked-evidence audit: do linked tests prove the rule? (2026-11-26, issue #509)

The traceability gate proves that a scenario has a **named test that runs in CI**; it cannot
prove that the test's assertions cover the acceptance rule. This audit reads the tests behind
the highest-risk links and records, per scenario, what the test asserts and what is missing.

Scope, as issue #509 asks: financial calculations, tenant isolation, and tests linked to more
than one scenario.

## Method

Reproduce with the commands below; "link" always means an explicit `covers:` declaration
(`// covers:` or `@pytest.mark.covers`) inside `backend/tests`, `flutter/test` or `e2e/tests`.

```bash
python3 scripts/feature_traceability.py check          # evidence verdicts, link problems
python3 scripts/feature_traceability.py report         # scenario -> linked tests
```

The selection was computed from the catalogue (`feature_traceability.load_catalogue()`):

- every test that declared `covers:` for three or more scenarios at the time of the audit
  (eight tests, listed below; the EPIC-01 balance test falls below the cap once corrected);
- every scenario of `STORY-13-10` (tenant isolation, 8 scenarios);
- every financial scenario (EPIC-01/02/07/08/09/10/11/13) whose only links are such a
  multi-scenario test.

Each selected test was then read in full. Verdicts: **proves** (an assertion fails if the rule
breaks), **partly proves** (some of the claimed scenarios have no assertion of their own),
**weak** (the test cannot fail for that rule).

## State of the catalogue

- 472 scenarios: 461 `@linked`, 11 Gherkin-only. Evidence verdicts today: 461 `OK`, 11 `GHERKIN`.
- 601 links, **0 link problems**: no whole-suite wrapper, no script declaration, no
  unattached (file-level) declaration, and no link to a test that does not execute in CI.
  The wrapper file `e2e/tests/test_linked_backend_suites.py` no longer carries links.
- One divergence was found and fixed in #513: `load_links()` (used by the HTML report's
  `linked_tests` column) named 560 of the 601 links and left 41 blank, because it scans a
  five-line window; the evidence resolver (`test_strategy_scan.resolve_links`) resolves all
  601. The report now takes its names from that resolver (`Catalogue.resolved_links()`), so
  all 601 links show their test and only a declaration with no test attached stays unnamed.

## Audited tests

| Test | Scenarios claimed | Assertion inspected | Lane | Verdict |
| --- | --- | --- | --- | --- |
| `backend/tests/it/db_occupancy_transitions_tests.rs::when_command_is_illegal_for_the_state_then_nothing_changes` | SC-08-07-01 … SC-08-07-07 | Per illegal command: `CONFLICT` **and** the unit fingerprint is unchanged, for VACANT, OWNER_OCCUPIED, TENANT_OCCUPIED and unowned vacant units | `rust-db-test` | Proves all seven |
| `db_occupancy_transitions_tests.rs::when_title_is_transferred_then_occupancy_follows_the_state_table` | SC-08-09-01 … SC-08-09-04, SC-08-05-08 | Transfer closes the seller's session with an end date, records the buyer, leaves the unit VACANT, buyer move-in works, tenant-buys becomes OWNER_OCCUPIED, selling a vacant unit stays VACANT; an invalid seller-pays override leaves neither transfer nor override row | `rust-db-test` | Proves |
| `db_occupancy_transitions_tests.rs::when_tenant_is_replaced_then_outgoing_tenant_is_settled` | SC-08-08-01 … SC-08-08-03, SC-08-10-04 | Future effective date → 400; a failed second step keeps the session; replacement closes with `exit_balance` 1500.00 and opens the next session on the same date; `OWNER_TAKES_BACK` reopens the owner | `rust-db-test` | Proves |
| `db_advance_exit_settlements_tests.rs::exit_settlement_payout_transfer_and_stale_balance_are_atomic` | SC-09-05-03 … SC-09-05-06 | A frozen exit debt blocks the payout (`Conflict`); payout and transfer need the second approval; a retried request returns the original id; the stale balance is recomputed | `rust-db-test` | Proves |
| `e2e/tests/test_epic01_resident_dues.py::test_overdue_balance_matches_backend_total` | SC-01-01-01, SC-01-02-01, SC-01-03-01, SC-01-04-01 | Asserts the hero balance equals the backend total (and is above 1400.00) for one overdue fixture | `gui-e2e` | Proves SC-01-03-01/SC-01-04-01; **did not prove** SC-01-01-01 (kurus precision) or SC-01-02-01 (penalty exactly 23.33) — corrected in this change |
| `e2e/tests/test_journey_accruals_payments.py::test_multi_site_journey_accruals_and_mixed_payments` | SC-13-13-02, SC-13-13-05, SC-13-14-10, SC-13-26-02, SC-13-25-02, SC-13-25-03, SC-13-25-04, SC-13-25-06, SC-13-25-07 | Inline annotations and assertions for SC-13-25-06, SC-13-25-07, SC-13-14-10, SC-13-25-03, SC-13-25-04, SC-13-13-05; SC-13-13-02, SC-13-26-02 and SC-13-25-02 ride on the same totals without an assertion of their own | `gui-e2e` | Partly proves — follow-up |
| `flutter/test/sp_directory_scaffold_test.dart` (5 declarations) | SC-12-02-01, -02, -03, -04, -08 | Each `// covers:` sits in its own `testWidgets` with `expect` on page range, density and restored state | `flutter-test` | Proves |
| `flutter/test/payments_phase3_test.dart` (5 declarations) | SC-13-03-22, SC-11-02-04, SC-11-05-03 (×2), SC-11-05-04, SC-11-05-05 | Each test asserts widget state: disabled/enabled pay action, a shared due counted once, designated items | `flutter-test` | Proves |

### Tenant isolation (STORY-13-10, all eight scenarios reviewed)

| Scenario | Test | Assertion inspected | Lane |
| --- | --- | --- | --- |
| SC-13-10-01 | `e2e/tests/test_journey_tenant_isolation.py::test_manager_lists_and_searches_are_site_scoped` | Site A's unit ids equal A's own and never intersect B's; searching B's person suffix inside A returns nothing | `gui-e2e` |
| SC-13-10-02 | `...::test_direct_reads_and_downloads_require_site_access` | Cross-site person card, period, receipt and budget return 403/404 and the response body carries no foreign id | `gui-e2e` |
| SC-13-10-03 | `...::test_site_parameter_cannot_widen_manager_permissions` | A `site_id` parameter cannot widen a manager's scope | `gui-e2e` |
| SC-13-10-04 | `...::test_manager_cannot_mutate_another_site_records` | Mutations against another site are refused and leave its rows unchanged | `gui-e2e` |
| SC-13-10-05 | `statement_access_tests.rs::former_tenant_keeps_no_access_to_other_unit_routes`, `...::former_owner_keeps_no_access_to_other_unit_routes`, `test_journey_tenant_isolation.py::test_resident_cannot_read_another_unit_financial_records` | Historical statement access does not widen to dashboard or IBAN routes; another unit's records stay unreachable | `rust-test`, `gui-e2e` |
| SC-13-10-06 | `test_journey_tenant_isolation.py::test_tenant_statement_excludes_owner_private_transactions` | The tenant statement omits the owner's private entries | `gui-e2e` |
| SC-13-10-07 | eight tests in `statement_access_tests.rs` plus `test_journey_tenant_isolation.py::test_replacing_tenant_keeps_history_and_receipts_private` | Each section is filtered to its liable person; former, current, joint-only and staff views are asserted separately | `rust-test`, `gui-e2e` |
| SC-13-10-08 | `test_journey_session_isolation.py::test_late_statement_response_cannot_replace_next_resident` | A late response cannot overwrite the next resident's session state | `gui-e2e` |

All eight prove their rule. No correction was needed.

## Corrections made in this change

- **SC-05-05-01** was linked only to `test_groups_partition_order`, which checks the CI group
  partition and never runs the runner. Added
  `test_run_tests_groups.py::test_one_command_runs_every_lane_and_returns_their_exit_code`,
  which executes `run_tests.main` against stubbed gates: every gate in `ORDER` runs, the
  harness/traceability/Rust/Flutter lanes are among them, a passing run returns 0 and a
  failing gate returns 1.
- **SC-01-02-01** now links the test that asserts the rule —
  `integration_tests.rs::when_overdue_by_10_days_then_calculates_exact_5_percent_pro_rated_penalty`
  (penalty 23.33, total 1423.33) — and the e2e balance test no longer claims it.
- **SC-01-01-01** keeps its named precision test
  (`financial_fixtures.rs::penalty_keeps_kurus_precision_and_does_not_drift_across_recalculations`)
  and no longer claims the e2e balance test.
- **SC-13-03-22**'s declaration inside `statement_access_grants_former_debtors_in_postgresql`
  moved from the middle of the test body to its header, so the report can name the test.

## Follow-ups

- #512 — SC-13-13-02, SC-13-26-02, SC-13-25-02: the multi-site journey test needs an assertion
  for each, or the scenarios need their own tests.
- #513 — fixed in this change: the HTML report now takes link names from
  `test_strategy_scan.resolve_links()`, so the 41 previously blank rows name their test.
