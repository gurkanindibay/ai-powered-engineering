"""Backend journey assertions for the financial transitions of STORY-13-09 (EPIC-13).

Covers:
- SC-13-09-02: A partial payment reduces the principal used for later fees
- SC-13-09-06: Concurrent deliveries of the same bank event are credited once
- SC-13-09-07: An unmatched statement item can be approved exactly once (strict xfail, see #296)
- SC-13-09-09: The aging bucket changes at each day boundary

Expected values come from the fee schedule of the journey plan (1/600 a day on the open
principal, 2.50 a day on 1500.00, 5.00 over 3 days on 1000.00), never from the response under test.
"""
from __future__ import annotations

import datetime
from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal

import pytest

from support.journey_attempts import JourneyClock, ledger_invariants, make_viban
from support.journey_snapshots import (
    financial_snapshot,
    journey_site,
    money,
    open_items,
    reconciliation_queue_count,
    unit_position,
)

D = Decimal
ZERO = D("0.00")


@pytest.mark.covers("SC-13-09-02")
@pytest.mark.core
@pytest.mark.role_manager
def test_partial_payment_reduces_the_principal_used_for_later_fees(request, api, actors, stack):
    with journey_site(request, api, actors, stack, "F2") as (fixture, _):
        a5 = fixture.unit_ids[4]
        clock = JourneyClock(api, "2026-11-01")
        api.accrue_period(fixture.manager, "Kasım 2026", None, "2026-11-10")
        clock.advance_to("2026-11-16")
        api.clock.tick()

        receipt = api.record_manual_payment(fixture.manager, a5, D("515.00"), "Deniz Arslan", payer_role="TENANT")
        assert (money(receipt["allocated_penalty"]), money(receipt["allocated_principal"])) == (D("15.00"), D("500.00"))

        clock.advance_to("2026-11-19")
        api.clock.tick()
        accruals = (
            "SELECT COUNT(*) FROM late_fee_accruals WHERE due_id IN "
            f"(SELECT id FROM dues_liabilities WHERE unit_id = {int(a5)});"
        )
        after_job = stack.sql(accruals)
        report = api.clock.tick()  # the fee job is retried at the same instant
        assert report["report"]["late_fee_liabilities"] == 0
        assert stack.sql(accruals) == after_job  # the retry creates no second fee entry

        (item,) = open_items(api, fixture.manager, a5, "TENANT")
        assert money(item["principal_outstanding"]) == D("1000.00")  # 3 days at 1000.00 x 1/600 = 5.00
        assert money(item["penalty_outstanding"]) == D("5.00")
        ledger_invariants(api, fixture.manager, fixture.site_id, stage="SC-13-09-02")


@pytest.mark.covers("SC-13-09-06")
@pytest.mark.edge
@pytest.mark.role_manager
def test_concurrent_deliveries_of_one_bank_event_are_credited_once(request, api, actors, stack):
    with journey_site(request, api, actors, stack, "F5") as (fixture, _):
        a3 = fixture.unit_ids[2]
        viban = make_viban("00205", fixture.site_id, "A", 3)
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(api.webhook_transfer, viban, D("1675.00"), "TX-RACE-1") for _ in range(2)]
            results = [future.result() for future in futures]
        assert sorted(r["status"] for r in results) == ["CLEARED", "DUPLICATE_IGNORED"]

        site = int(fixture.site_id)
        assert stack.sql(
            f"SELECT COUNT(*) FROM payment_entries WHERE site_id = {site} AND external_reference = 'TX-RACE-1';"
        ) == "1"
        assert stack.sql(f"SELECT COUNT(*) FROM payment_receipts WHERE unit_id = {int(a3)} AND total_amount = 1675.00;") == "1"
        assert stack.sql(
            "SELECT COALESCE(SUM(pa.principal_amount + pa.penalty_amount), 0) FROM payment_allocations pa "
            f"JOIN payment_entries pe ON pe.id = pa.payment_entry_id WHERE pe.external_reference = 'TX-RACE-1';"
        ) == "1675.00"
        assert unit_position(api, fixture.manager, fixture.site_id, a3) == (ZERO, ZERO)
        ledger_invariants(api, fixture.manager, fixture.site_id, stage="SC-13-09-06")


def _import_unmatched_item(api, fixture) -> dict:
    content = "2026-11-19;TR120006200000000000001099;FAST TRANSFERI;1675.00"
    api.call("POST", "/api/v1/bank/statements/parse", fixture.manager.token,
             body={"site_id": fixture.site_id, "content": content, "format": "CSV"})
    queue = api.call("GET", f"/api/v1/bank/statements/reconciliation-queue?site_id={fixture.site_id}", fixture.manager.token)
    (item,) = queue
    return item


@pytest.mark.covers("SC-13-09-07")
@pytest.mark.core
@pytest.mark.role_manager
def test_unmatched_statement_item_is_queued_and_changes_no_balance(request, api, actors, stack):
    with journey_site(request, api, actors, stack, "F5") as (fixture, _):
        a3 = fixture.unit_ids[2]
        queue_before = reconciliation_queue_count(stack, fixture.site_id)
        before = financial_snapshot(stack, fixture.site_id).split("|")
        item = _import_unmatched_item(api, fixture)
        assert item["status"] == "UNMATCHED"
        assert money(item["transaction"]["amount"]) == D("1675.00")
        assert unit_position(api, fixture.manager, fixture.site_id, a3) == (D("1675.00"), ZERO)  # A-3 still owes
        queue_after = reconciliation_queue_count(stack, fixture.site_id)
        assert queue_after == queue_before + 1
        after = financial_snapshot(stack, fixture.site_id).split("|")
        assert after[:8] == before[:8]
        assert after[9:] == before[9:]


# The assignment half of SC-13-09-07 is covered by
# test_journey_payment_corner_cases.py::test_unmatched_statement_item_is_assigned_and_approved_exactly_once,
# which drives the assignment API; the former xfail duplicate (#296) was removed with that fix.

AGING_ROWS = [
    (0, "current", "current", "0.00"),
    (1, "overdue_1_30_days", "overdue_1_30_days", "2.50"),
    (30, "overdue_1_30_days", "overdue_1_30_days", "75.00"),
    (31, "overdue_31_60_days", "overdue_31_60_days", "77.50"),
    (60, "overdue_31_60_days", "overdue_31_60_days", "150.00"),
    (61, "overdue_60_plus_days", "overdue_61_90_days", "152.50"),
    (90, "overdue_60_plus_days", "overdue_61_90_days", "225.00"),
    (91, "overdue_60_plus_days", "overdue_90_plus_days", "227.50"),
]
ADMIN_BUCKETS = ("current_due", "overdue_1_30_days", "overdue_31_60_days", "overdue_60_plus_days")
STATEMENT_BUCKETS = ("current_due", "overdue_1_30_days", "overdue_31_60_days", "overdue_61_90_days", "overdue_90_plus_days")


@pytest.mark.covers("SC-13-09-09")
@pytest.mark.edge
@pytest.mark.role_manager
@pytest.mark.parametrize("days, admin_bucket, statement_bucket, fee", AGING_ROWS)
def test_aging_bucket_changes_at_each_day_boundary(
    request, api, actors, stack, days, admin_bucket, statement_bucket, fee
):
    admin_bucket = "current_due" if admin_bucket == "current" else admin_bucket
    statement_bucket = "current_due" if statement_bucket == "current" else statement_bucket
    with journey_site(request, api, actors, stack, "F2") as (fixture, _):
        a5 = fixture.unit_ids[4]  # tenant Deniz Arslan: one liability of 1500.00, no grace days
        clock = JourneyClock(api, "2026-11-01")
        api.accrue_period(fixture.manager, "Kasım 2026", None, "2026-11-10")
        clock.advance_to((datetime.date(2026, 11, 10) + datetime.timedelta(days=days)).isoformat())

        report = api.debt_aging_report(fixture.manager, fixture.site_id)
        bracket = next((b for b in report["brackets"] if str(b["unit_id"]) == str(a5) and b["debtor_type"] == "TENANT"), None)
        assert bracket is not None, f"Unit {a5} tenant bracket not found in aging report"
        for name in ADMIN_BUCKETS:
            assert money(bracket[name]) == (D("1500.00") if name == admin_bucket else ZERO), name
        assert money(bracket["accrued_delay_penalty"]) == D(fee)

        statement = api.resident_statement(fixture.manager, a5)
        debtor = next((d for d in statement["debtors"] if d["debtor_type"] == "TENANT"), None)
        assert debtor is not None, f"Unit {a5} tenant debtor not found in resident statement"
        for name in STATEMENT_BUCKETS:
            assert money(debtor[name]) == (D("1500.00") if name == statement_bucket else ZERO), name
        assert money(debtor["penalty_outstanding"]) == D(fee)


@pytest.mark.covers("SC-13-09-08")
@pytest.mark.core
@pytest.mark.role_manager
def test_operational_and_capital_balances_separate_for_tenant(request, api, actors, stack):
    with journey_site(request, api, actors, stack, "F2") as (fixture, _):
        manager = fixture.manager
        a2 = fixture.unit_ids[1]

        clock = JourneyClock(api, "2026-11-19")
        api.accrue_period(manager, "Kasım 2026", None, "2026-11-30")

        proj = api.create_capital_project(
            manager, "Çatı Onarımı", D("7000.00"), basis="EQUAL_PER_UNIT", installments=1, first_due="2026-11-30"
        )
        api.accrue_installment(manager, str(proj.get("id") or proj.get("project_id")), 1)

        stmt_initial = api.resident_statement(manager, a2)
        tenant_d = next(d for d in stmt_initial["debtors"] if d["debtor_type"] == "TENANT")
        owner_d = next(d for d in stmt_initial["debtors"] if d["debtor_type"] == "OWNER")
        assert money(tenant_d["total_outstanding"]) == D("1500.00")
        assert money(owner_d["total_outstanding"]) == D("1000.00")

        rec_op = api.record_manual_payment(
            manager,
            a2,
            D("1500.00"),
            "Selin Demir",
            payer_role="TENANT",
            description="Kira aidat",
            settles_owner_capital_dues=False,
        )

        stmt_mid = api.resident_statement(manager, a2)
        tenant_mid = next(d for d in stmt_mid["debtors"] if d["debtor_type"] == "TENANT")
        owner_mid = next(d for d in stmt_mid["debtors"] if d["debtor_type"] == "OWNER")
        assert money(tenant_mid["total_outstanding"]) == ZERO
        assert money(owner_mid["total_outstanding"]) == D("1000.00")

        rec_cap = api.record_manual_payment(
            manager,
            a2,
            D("400.00"),
            "Selin Demir",
            payer_role="TENANT",
            description="Demirbaş payı",
            settles_owner_capital_dues=True,
        )

        stmt_final = api.resident_statement(manager, a2)
        tenant_final = next(d for d in stmt_final["debtors"] if d["debtor_type"] == "TENANT")
        owner_final = next(d for d in stmt_final["debtors"] if d["debtor_type"] == "OWNER")
        assert money(owner_final["total_outstanding"]) == D("600.00")
        assert money(tenant_final["total_outstanding"]) == ZERO

        assert rec_cap["payer_name"] == "Selin Demir"
        assert rec_cap["on_behalf_of_name"] == "Ahmet Yılmaz"

        ledger_invariants(api, manager, fixture.site_id, stage="SC-13-09-08")

