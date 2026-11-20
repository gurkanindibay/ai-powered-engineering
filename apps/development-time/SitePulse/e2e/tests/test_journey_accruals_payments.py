"""Journey test coverage for accrual histories and payment allocation (EPIC-13).

Covers:
- SC-13-02-03: The late fee follows the clock day by day
- SC-13-02-05: A single debt in a previous month stays attached to that month
- SC-13-02-06: A single debt in the current month is the only one in the youngest bucket
- SC-13-04-01: A payment clears the oldest period first
- SC-13-04-02: Paying exactly the whole debt leaves zero and no advance
- SC-13-04-03: One kuruş short leaves one kuruş open
- SC-13-04-04: An overpayment becomes an advance that offsets the next accrual
- SC-13-04-05: Invalid payment amounts are rejected without any side effect
- SC-13-04-06: The bank webhook matches a transfer to the unit and allocates it
"""
from __future__ import annotations

import os
from decimal import Decimal
from pathlib import Path

import pytest

from support.api import ApiError
from support.journey_attempts import (
    JourneyManifest,
    ledger_invariants,
    make_viban,
    site_in_state,
    teardown_with_evidence,
)

E2E = Path(__file__).resolve().parents[1]


@pytest.mark.covers("SC-13-02-03")
@pytest.mark.edge
def test_late_fee_follows_clock_day_by_day(request, api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    fixture = None
    try:
        fixture = site_in_state("F4", api=api, stack=stack, saas=saas, manifest=manifest)
        api.clock.advance_to("2026-11-20")
        api.clock.tick()

        u2 = fixture.unit_ids[1]  # A-2
        stmt = api.resident_statement(fixture.manager, u2)
        debtor = next(d for d in stmt["debtors"] if d["open_items"])
        item = next(i for i in debtor["open_items"] if Decimal(str(i["principal_outstanding"])) == Decimal("1500.00"))
        assert Decimal(str(item["penalty_outstanding"])) == Decimal("102.50")

        ledger_invariants(api, fixture.manager, fixture.site_id, stage="SC-13-02-03")
        october_outstanding = Decimal("0.00")
        for unit_id in fixture.unit_ids:
            statement = api.resident_statement(fixture.manager, unit_id)
            october_outstanding += sum(
                (
                    Decimal(str(item["principal_outstanding"]))
                    + Decimal(str(item["penalty_outstanding"]))
                    for debtor in statement["debtors"]
                    for item in debtor["open_items"]
                    if item["period"] == "Ekim 2026"
                ),
                Decimal("0.00"),
            )
        assert october_outstanding == Decimal("8813.75")
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)


@pytest.mark.covers("SC-13-02-05")
@pytest.mark.core
def test_single_debt_in_previous_month_stays_attached(request, api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    fixture = None
    try:
        fixture = site_in_state("F5", api=api, stack=stack, saas=saas, manifest=manifest)
        u3 = fixture.unit_ids[2]  # A-3

        stmt = api.resident_statement(fixture.manager, u3)
        debtor = next(d for d in stmt["debtors"] if d["debtor_type"] == "OWNER")
        open_items = debtor["open_items"]
        assert len(open_items) == 1
        assert open_items[0]["period"] == "Eylül 2026"
        assert Decimal(str(open_items[0]["principal_outstanding"])) == Decimal("1500.00")
        assert Decimal(str(open_items[0]["penalty_outstanding"])) == Decimal("175.00")

        report = api.debt_aging_report(fixture.manager, fixture.site_id)
        bracket = next(b for b in report["brackets"] if str(b["unit_id"]) == str(u3))
        assert Decimal(str(bracket["overdue_60_plus_days"])) == Decimal("1500.00")
        assert Decimal(str(bracket["accrued_delay_penalty"])) == Decimal("175.00")

        assert Decimal(str(debtor["overdue_61_90_days"])) == Decimal("1500.00")
        assert Decimal(str(debtor["penalty_outstanding"])) == Decimal("175.00")
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)


@pytest.mark.covers("SC-13-02-06")
@pytest.mark.core
def test_single_debt_in_current_month_in_youngest_bucket(request, api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    fixture = None
    try:
        fixture = site_in_state("F5", api=api, stack=stack, saas=saas, manifest=manifest)
        u4 = fixture.unit_ids[3]  # A-4

        stmt = api.resident_statement(fixture.manager, u4)
        debtor = next(d for d in stmt["debtors"] if d["debtor_type"] == "OWNER")
        open_items = debtor["open_items"]
        assert len(open_items) == 1
        assert open_items[0]["period"] == "Kasım 2026"
        assert Decimal(str(open_items[0]["principal_outstanding"])) == Decimal("1500.00")
        assert Decimal(str(open_items[0]["penalty_outstanding"])) == Decimal("22.50")

        report = api.debt_aging_report(fixture.manager, fixture.site_id)
        bracket = next(b for b in report["brackets"] if str(b["unit_id"]) == str(u4))
        assert Decimal(str(bracket["overdue_1_30_days"])) == Decimal("1500.00")
        assert Decimal(str(bracket["accrued_delay_penalty"])) == Decimal("22.50")
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)


@pytest.mark.covers("SC-13-04-01")
@pytest.mark.smoke
@pytest.mark.core
def test_payment_clears_oldest_period_first(request, api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    fixture = None
    try:
        fixture = site_in_state("F5", api=api, stack=stack, saas=saas, manifest=manifest)
        u5 = fixture.unit_ids[4]  # A-5

        api.record_manual_payment(fixture.manager, u5, Decimal("2000.00"), "Deniz Arslan", payer_role="TENANT")

        stmt = api.resident_statement(fixture.manager, u5)
        debtor = next(d for d in stmt["debtors"] if d["debtor_type"] == "TENANT")
        open_items = debtor["open_items"]
        assert len(open_items) == 2
        periods = [i["period"] for i in open_items]
        assert "Eylül 2026" not in periods
        assert "Ekim 2026" in periods
        assert "Kasım 2026" in periods

        ekim_item = next(i for i in open_items if i["period"] == "Ekim 2026")
        assert Decimal(str(ekim_item["principal_outstanding"])) == Decimal("1297.50")
        assert Decimal(str(ekim_item["penalty_outstanding"])) == Decimal("0.00")

        kasim_item = next(i for i in open_items if i["period"] == "Kasım 2026")
        assert Decimal(str(kasim_item["principal_outstanding"])) == Decimal("1500.00")
        assert Decimal(str(kasim_item["penalty_outstanding"])) == Decimal("0.00")

        assert Decimal(str(debtor["total_outstanding"])) == Decimal("2797.50")

        ledger_invariants(api, fixture.manager, fixture.site_id, stage="SC-13-04-01")
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)


@pytest.mark.covers("SC-13-04-02")
@pytest.mark.core
def test_exact_payment_settles_debt_leaving_zero(request, api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    fixture = None
    try:
        fixture = site_in_state("F5", api=api, stack=stack, saas=saas, manifest=manifest)
        u5 = fixture.unit_ids[4]  # A-5

        api.record_manual_payment(fixture.manager, u5, Decimal("4797.50"), "Deniz Arslan", payer_role="TENANT")

        stmt = api.resident_statement(fixture.manager, u5)
        debtor = next(d for d in stmt["debtors"] if d["debtor_type"] == "TENANT")
        assert len(debtor["open_items"]) == 0
        assert Decimal(str(debtor["total_outstanding"])) == Decimal("0.00")
        assert Decimal(str(debtor["advance_balance"])) == Decimal("0.00")

        overview = ledger_invariants(api, fixture.manager, fixture.site_id, stage="SC-13-04-02")
        flat5 = next(f for f in overview["flats"] if str(f["id"]) == str(u5))
        assert Decimal(str(flat5["amount_due"])) == Decimal("0.00")
        assert Decimal(str(flat5["advance_balance"])) == Decimal("0.00")
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)


@pytest.mark.covers("SC-13-04-03")
@pytest.mark.edge
def test_one_kurus_short_leaves_one_kurus_open(request, api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    fixture = None
    try:
        fixture = site_in_state("F5", api=api, stack=stack, saas=saas, manifest=manifest)
        u5 = fixture.unit_ids[4]  # A-5

        api.record_manual_payment(fixture.manager, u5, Decimal("4797.49"), "Deniz Arslan", payer_role="TENANT")
        ledger_invariants(api, fixture.manager, fixture.site_id, stage="SC-13-04-03")

        stmt = api.resident_statement(fixture.manager, u5)
        debtor = next(d for d in stmt["debtors"] if d["debtor_type"] == "TENANT")
        assert len(debtor["open_items"]) == 1
        assert debtor["open_items"][0]["period"] == "Kasım 2026"
        assert Decimal(str(debtor["total_outstanding"])) == Decimal("0.01")
        assert Decimal(str(debtor["open_items"][0]["principal_outstanding"])) == Decimal("0.01")
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)


@pytest.mark.covers("SC-13-04-04")
@pytest.mark.core
def test_overpayment_becomes_advance_offsetting_next_accrual(request, api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    fixture = None
    try:
        fixture = site_in_state("F5", api=api, stack=stack, saas=saas, manifest=manifest)
        u5 = fixture.unit_ids[4]  # A-5

        api.record_manual_payment(fixture.manager, u5, Decimal("5000.00"), "Deniz Arslan", payer_role="TENANT")
        ledger_invariants(api, fixture.manager, fixture.site_id, stage="SC-13-04-04-payment")

        stmt = api.resident_statement(fixture.manager, u5)
        debtor = next(d for d in stmt["debtors"] if d["debtor_type"] == "TENANT")
        assert len(debtor["open_items"]) == 0
        assert Decimal(str(debtor["total_outstanding"])) == Decimal("0.00")
        assert Decimal(str(debtor["advance_balance"])) == Decimal("202.50")

        api.accrue_period(fixture.manager, "Aralık 2026", Decimal("0.00"), "2026-12-10")

        stmt2 = api.resident_statement(fixture.manager, u5)
        debtor2 = next(d for d in stmt2["debtors"] if d["debtor_type"] == "TENANT")
        assert len(debtor2["open_items"]) == 1
        assert debtor2["open_items"][0]["period"] == "Aralık 2026"
        assert Decimal(str(debtor2["open_items"][0]["principal_outstanding"])) == Decimal("1297.50")
        assert Decimal(str(debtor2["total_outstanding"])) == Decimal("1297.50")
        assert Decimal(str(debtor2["advance_balance"])) == Decimal("0.00")

        ledger_invariants(api, fixture.manager, fixture.site_id, stage="SC-13-04-04")
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)


@pytest.mark.covers("SC-13-04-05")
@pytest.mark.edge
def test_invalid_payment_amounts_rejected(request, api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    fixture = None
    try:
        fixture = site_in_state("F5", api=api, stack=stack, saas=saas, manifest=manifest)
        u5 = fixture.unit_ids[4]  # A-5

        initial_receipts = stack.sql(f"SELECT COUNT(*) FROM payment_receipts WHERE site_id = {int(fixture.site_id)};")

        invalid_amounts = [
            Decimal("0.00"),
            Decimal("-100.00"),
            Decimal("10.005"),
        ]
        for amount in invalid_amounts:
            with pytest.raises(ApiError):
                api.record_manual_payment(fixture.manager, u5, amount, "Deniz Arslan", payer_role="TENANT")

        current_receipts = stack.sql(f"SELECT COUNT(*) FROM payment_receipts WHERE site_id = {int(fixture.site_id)};")
        assert current_receipts == initial_receipts
        ledger_invariants(api, fixture.manager, fixture.site_id, stage="SC-13-04-05-rejected-payments")

        stmt = api.resident_statement(fixture.manager, u5)
        debtor = next(d for d in stmt["debtors"] if d["debtor_type"] == "TENANT")
        assert Decimal(str(debtor["total_outstanding"])) == Decimal("4797.50")
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)


@pytest.mark.covers("SC-13-04-06")
@pytest.mark.core
def test_bank_webhook_matches_transfer_and_allocates(request, api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    fixture = None
    try:
        fixture = site_in_state("F5", api=api, stack=stack, saas=saas, manifest=manifest)
        u3 = fixture.unit_ids[2]  # A-3

        viban = make_viban("00205", fixture.site_id, "A", 3)
        api.webhook_transfer(viban, Decimal("1675.00"), "TX-001")
        ledger_invariants(api, fixture.manager, fixture.site_id, stage="SC-13-04-06")

        stmt = api.resident_statement(fixture.manager, u3)
        debtor = next(d for d in stmt["debtors"] if d["debtor_type"] == "OWNER")
        assert len(debtor["open_items"]) == 0
        assert Decimal(str(debtor["total_outstanding"])) == Decimal("0.00")

        stream = api.payment_stream(fixture.manager)
        tx_entries = [e for e in stream.get("entries", []) if e.get("external_reference") == "TX-001"]
        assert len(tx_entries) == 1

        allocations = stack.sql(
            "SELECT dl.period, pa.principal_amount, pa.penalty_amount "
            "FROM payment_allocations pa "
            "JOIN dues_liabilities dl ON dl.id = pa.dues_liability_id "
            "JOIN payment_entries pe ON pe.id = pa.payment_entry_id "
            "WHERE pe.external_reference = 'TX-001';"
        )
        assert "Eylül 2026" in allocations
        assert "1500.00" in allocations
        assert "175.00" in allocations
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)
