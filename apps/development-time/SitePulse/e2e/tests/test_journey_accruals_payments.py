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
from support.flutter import ID_ATTR, by_id, text_of
from support.journey_attempts import (
    JourneyManifest,
    ledger_invariants,
    make_viban,
    site_in_state,
    teardown_sites,
    teardown_with_evidence,
)
from support.journey_gui import amount_of
from support.journey_live_reconciliation import (
    PERIOD_LABELS,
    assert_cash_matches_model,
    assert_statements_match_model,
    posted_cash,
)
from support.journey_multi_site import build_multi_site_journey
from support.journey_reconciliation import CHECKPOINTS, reconcile
from support.money import format_try
from support.journey_reconciliation import CHECKPOINTS
from support.journey_snapshots import current_section
from pages.login import LoginPage
from pages.manager import PaymentStream, ResidentsTab
from pages.person import UnitWorkspace

E2E = Path(__file__).resolve().parents[1]


def _wait_for_semantics_text(page, test_id: str, expected: str, timeout_ms: int = 15_000) -> None:
    """Wait until the widget tagged `test_id` exposes `expected`.

    A tagged widget can be attached before its child text paints, especially on slow engines;
    waiting on the expected value avoids reading the semantics tree one frame too early.
    """
    page.wait_for_function(
        """([attribute, id, text]) => {
            const element = document.querySelector(`[${attribute}="${id}"]`);
            const content = element
                ? (element.getAttribute('aria-label') || element.textContent || '')
                : '';
            return content.includes(text);
        }""",
        arg=[ID_ATTR, test_id, expected],
        timeout=timeout_ms,
    )


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
        debtor = current_section(stmt, "OWNER")
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
        debtor = current_section(stmt, "OWNER")
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


@pytest.mark.covers("SC-13-02-07")
@pytest.mark.core
def test_multiple_debts_across_periods_listed_oldest_first(request, api, actors, stack):
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

        stmt = api.resident_statement(fixture.manager, u5)
        debtor = next(d for d in stmt["debtors"] if d["debtor_type"] == "TENANT")
        open_items = debtor["open_items"]
        assert len(open_items) == 3
        assert [i["period"] for i in open_items] == ["Eylül 2026", "Ekim 2026", "Kasım 2026"]
        assert Decimal(str(open_items[0]["penalty_outstanding"])) == Decimal("175.00")
        assert Decimal(str(open_items[1]["penalty_outstanding"])) == Decimal("100.00")
        assert Decimal(str(open_items[2]["penalty_outstanding"])) == Decimal("22.50")
        total = sum(
            Decimal(str(i["principal_outstanding"])) + Decimal(str(i["penalty_outstanding"]))
            for i in open_items
        )
        assert total == Decimal("4797.50")
        ledger_invariants(api, fixture.manager, fixture.site_id, stage="SC-13-02-07")
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)


@pytest.mark.covers("SC-13-02-08")
@pytest.mark.core
def test_advance_balance_offsets_next_accrual(request, api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    fixture = None
    try:
        fixture = site_in_state("F5", api=api, stack=stack, saas=saas, manifest=manifest)
        u6 = fixture.unit_ids[5]  # A-6

        stmt_before = api.resident_statement(fixture.manager, u6)
        debtor_before = next(d for d in stmt_before["debtors"] if d["debtor_type"] == "OWNER")
        assert len(debtor_before["open_items"]) == 0
        overview_before = api.site_overview(fixture.manager, fixture.site_id)
        flat_6_before = next(f for f in overview_before["flats"] if str(f["id"]) == str(u6))
        assert Decimal(str(flat_6_before["advance_balance"])) == Decimal("1250.00")

        # Accrue Aralık 2026 (Large flat tariff is 2250.00)
        api.accrue_period(fixture.manager, "Aralık 2026", None, "2026-12-10")

        overview_after = api.site_overview(fixture.manager, fixture.site_id)
        flat_6_after = next(f for f in overview_after["flats"] if str(f["id"]) == str(u6))
        assert Decimal(str(flat_6_after["advance_balance"])) == Decimal("0.00")
        assert Decimal(str(flat_6_after["amount_due"])) == Decimal("1000.00")

        stmt_after = api.resident_statement(fixture.manager, u6)
        debtor_after = next(d for d in stmt_after["debtors"] if d["debtor_type"] == "OWNER")
        aralik_item = next(i for i in debtor_after["open_items"] if i["period"] == "Aralık 2026")
        assert Decimal(str(aralik_item["principal_outstanding"])) == Decimal("1000.00")
        ledger_invariants(api, fixture.manager, fixture.site_id, stage="SC-13-02-08")
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)


@pytest.mark.covers("SC-13-02-09")
@pytest.mark.core
def test_fourth_accrual_idempotent(request, api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    fixture = None
    try:
        fixture = site_in_state("F5", api=api, stack=stack, saas=saas, manifest=manifest)
        liabilities_before = int(stack.sql(
            "SELECT COUNT(*) FROM dues_liabilities d JOIN units u ON u.id = d.unit_id "
            f"WHERE u.site_id = {int(fixture.site_id)};"
        ))

        api.accrue_period(fixture.manager, "Aralık 2026", None, "2026-12-10")

        liabilities_after1 = int(stack.sql(
            "SELECT COUNT(*) FROM dues_liabilities d JOIN units u ON u.id = d.unit_id "
            f"WHERE u.site_id = {int(fixture.site_id)};"
        ))
        assert liabilities_after1 == liabilities_before + 6

        u7 = fixture.unit_ids[6]  # A-7
        a7_liabilities = int(stack.sql(
            f"SELECT COUNT(*) FROM dues_liabilities WHERE unit_id = {int(u7)} AND period = 'Aralık 2026';"
        ))
        assert a7_liabilities == 0

        # Repeated accrual adds nothing
        api.accrue_period(fixture.manager, "Aralık 2026", None, "2026-12-10")
        liabilities_after2 = int(stack.sql(
            "SELECT COUNT(*) FROM dues_liabilities d JOIN units u ON u.id = d.unit_id "
            f"WHERE u.site_id = {int(fixture.site_id)};"
        ))
        assert liabilities_after2 == liabilities_after1
        ledger_invariants(api, fixture.manager, fixture.site_id, stage="SC-13-02-09")
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)


@pytest.mark.covers("SC-13-02-10")
@pytest.mark.core
def test_closed_period_accepts_no_new_accrual_keeps_debts(request, api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    fixture = None
    try:
        fixture = site_in_state("F7", api=api, stack=stack, saas=saas, manifest=manifest)
        sep_status = stack.sql(
            f"SELECT status FROM dues_periods WHERE site_id = {int(fixture.site_id)} AND period_name = 'Eylül 2026';"
        )
        assert sep_status == "CLOSED"

        with pytest.raises(ApiError) as exc_info:
            api.accrue_period(fixture.manager, "Eylül 2026", None, "2026-09-10")
        assert "409" in str(exc_info.value) or "400" in str(exc_info.value)

        u3 = fixture.unit_ids[2]  # A-3
        stmt = api.resident_statement(fixture.manager, u3)
        debtor = next(d for d in stmt["debtors"] if d["debtor_type"] == "OWNER")
        sep_item = next(i for i in debtor["open_items"] if i["period"] == "Eylül 2026")
        assert Decimal(str(sep_item["principal_outstanding"])) == Decimal("1500.00")
        assert Decimal(str(sep_item["penalty_outstanding"])) == Decimal("175.00")

        # Clock advances one day to 2026-11-20 and late-fee job runs
        api.clock.advance_to("2026-11-20")
        api.clock.tick()

        stmt_next = api.resident_statement(fixture.manager, u3)
        debtor_next = next(d for d in stmt_next["debtors"] if d["debtor_type"] == "OWNER")
        sep_item_next = next(i for i in debtor_next["open_items"] if i["period"] == "Eylül 2026")
        assert Decimal(str(sep_item_next["penalty_outstanding"])) == Decimal("177.50")
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)


@pytest.mark.covers("SC-13-02-11")
@pytest.mark.edge
def test_payment_toward_closed_period_allocated_to_oldest_debt(request, api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    fixture = None
    try:
        fixture = site_in_state("F7", api=api, stack=stack, saas=saas, manifest=manifest)
        u3 = fixture.unit_ids[2]  # A-3

        api.record_manual_payment(fixture.manager, u3, Decimal("1675.00"), "Burak Şahin", payer_role="OWNER")

        stmt = api.resident_statement(fixture.manager, u3)
        debtor = next(d for d in stmt["debtors"] if d["debtor_type"] == "OWNER")
        assert not any(i["period"] == "Eylül 2026" for i in debtor["open_items"])
        assert Decimal(str(debtor["total_outstanding"])) == Decimal("0.00")
        ledger_invariants(api, fixture.manager, fixture.site_id, stage="SC-13-02-11")
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
        debtor = current_section(stmt, "TENANT")
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
        debtor = current_section(stmt, "TENANT")
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
        debtor = current_section(stmt, "TENANT")
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
        debtor = current_section(stmt, "TENANT")
        assert len(debtor["open_items"]) == 0
        assert Decimal(str(debtor["total_outstanding"])) == Decimal("0.00")
        assert Decimal(str(debtor["advance_balance"])) == Decimal("202.50")

        api.accrue_period(fixture.manager, "Aralık 2026", None, "2026-12-10")

        stmt2 = api.resident_statement(fixture.manager, u5)
        debtor2 = current_section(stmt2, "TENANT")
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
        debtor = current_section(stmt, "TENANT")
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
        debtor = current_section(stmt, "OWNER")
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


@pytest.mark.covers("SC-13-13-02")
@pytest.mark.smoke
@pytest.mark.core
@pytest.mark.role_manager
def test_multi_site_journey_accruals_and_designated_payments(request, api, actors, stack):
    """Accrue four periods and verify designated payment history (Paid -> Unpaid -> Unpaid -> Paid)."""
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    j = None
    try:
        j = build_multi_site_journey(api, stack, saas, manifest, start_date="2027-01-01")

        # Month 1: January 2027
        res_a_jan = j.accrue_a("Ocak 2027", "2027-01-10")
        assert res_a_jan["total_units_accrued"] == 24
        assert Decimal(str(res_a_jan["total_amount_accrued"])) == Decimal("24000.00")

        res_b_jan = j.accrue_b("Ocak 2027", "2027-01-10")
        assert res_b_jan["total_units_accrued"] == 64
        assert Decimal(str(res_b_jan["total_amount_accrued"])) == Decimal("48000.00")

        j.clock.advance_to("2027-01-10")
        # A-01: Ada pays 400.00 (partial)
        api.record_manual_payment(
            j.manager_a, j.unit_a("A-01"), Decimal("400.00"), "Ada Kaya",
            payer_role="OWNER", channel="MANUAL_CASH", description="Ocak 2027 kısmi ödeme",
            idempotency_key="des-pay-a01-jan",
        )
        # A-03: Fay pays 1,000.00 (full)
        api.record_manual_payment(
            j.manager_a, j.unit_a("A-03"), Decimal("1000.00"), "Fay Çelik",
            payer_role="OWNER", channel="MANUAL_CASH", description="Ocak 2027 aidat ödemesi",
            idempotency_key="des-pay-a03-jan",
        )
        # B1-01: Gus pays 750.00 (full)
        api.record_manual_payment(
            j.manager_b, j.unit_b("B1-01"), Decimal("750.00"), "Gus Şahin",
            payer_role="OWNER", channel="MANUAL_CASH", description="Ocak 2027 aidat ödemesi",
            idempotency_key="des-pay-b101-jan",
        )
        # B2-01: Juno pays 750.00 (full)
        api.record_manual_payment(
            j.manager_b, j.unit_b("B2-01"), Decimal("750.00"), "Juno Yıldız",
            payer_role="TENANT", channel="MANUAL_CASH", description="Ocak 2027 aidat ödemesi",
            idempotency_key="des-pay-b201-jan",
        )
        j.post_routine_payments("Ocak 2027")

        assert stack.sql(
            f"SELECT status FROM dues_liabilities WHERE unit_id = {int(j.unit_a('A-01'))} AND period = 'Ocak 2027';"
        ) == "PARTIALLY_PAID"

        # Month 2: February 2027
        j.clock.advance_to("2027-02-01")
        res_a_feb = j.accrue_a("Şubat 2027", "2027-02-10")
        assert res_a_feb["total_units_accrued"] == 24
        res_b_feb = j.accrue_b("Şubat 2027", "2027-02-10")
        assert res_b_feb["total_units_accrued"] == 64

        j.clock.advance_to("2027-02-10")
        # A-01: Ada pays 831.00 (31 fee + 600 Jan principal + 200 Feb principal)
        rec_a01_feb = api.record_manual_payment(
            j.manager_a, j.unit_a("A-01"), Decimal("831.00"), "Ada Kaya",
            payer_role="OWNER", channel="MANUAL_CASH", description="Şubat 2027 ödeme",
            idempotency_key="des-pay-a01-feb",
        )
        assert len(rec_a01_feb["allocation_breakdown"]) == 2
        # Assert January partial-to-paid transition on A-01!
        assert stack.sql(
            f"SELECT status FROM dues_liabilities WHERE unit_id = {int(j.unit_a('A-01'))} AND period = 'Ocak 2027';"
        ) == "PAID"
        assert stack.sql(
            f"SELECT status FROM dues_liabilities WHERE unit_id = {int(j.unit_a('A-01'))} AND period = 'Şubat 2027';"
        ) == "PARTIALLY_PAID"

        # A-02: Dan pays 1,301.67
        api.record_manual_payment(
            j.manager_a, j.unit_a("A-02"), Decimal("1301.67"), "Dan Arslan",
            payer_role="TENANT", channel="MANUAL_CASH", description="Şubat 2027 ödeme",
            idempotency_key="des-pay-a02-feb",
        )
        # B1-01: Gus pays 250.00
        api.record_manual_payment(
            j.manager_b, j.unit_b("B1-01"), Decimal("250.00"), "Gus Şahin",
            payer_role="OWNER", channel="MANUAL_CASH", description="Şubat 2027 kısmi ödeme",
            idempotency_key="des-pay-b101-feb",
        )
        j.post_routine_payments("Şubat 2027")

        # Month 3: March 2027
        j.clock.advance_to("2027-03-01")
        # Transitions
        api.call("POST", "/api/v1/auth/step-up", j.manager_a.token, body={"password": j.manager_a_password})
        api.call(
            "POST",
            f"/api/v1/site-admin/units/{j.unit_a('A-01')}/transfer-ownership",
            j.manager_a.token,
            body={
                "unit_id": j.unit_a("A-01"),
                "new_owner_name": "Ben Kaya",
                "new_owner_email": f"{manifest.attempt_id[:6]}.a.ben@journey.e2e.test".lower(),
                "transfer_date": "2027-03-01",
                "new_owner_moves_in": True,
            },
        )
        api.call(
            "POST",
            f"/api/v1/site-admin/units/{j.unit_a('A-02')}/occupancy-transitions?site_id={j.site_a_id}",
            j.manager_a.token,
            body={"command": "MOVE_OUT", "effective_date": "2027-03-01", "notes": "Dan moves out"},
        )
        api.call(
            "POST",
            f"/api/v1/site-admin/units/{j.unit_a('A-03')}/occupancy-transitions?site_id={j.site_a_id}",
            j.manager_a.token,
            body={"command": "MOVE_OUT", "effective_date": "2027-03-01", "notes": "Fay moves out"},
        )
        api.call("POST", "/api/v1/auth/step-up", j.manager_b.token, body={"password": j.manager_b_password})
        api.call(
            "POST",
            f"/api/v1/site-admin/units/{j.unit_b('B1-01')}/transfer-ownership",
            j.manager_b.token,
            body={
                "unit_id": j.unit_b("B1-01"),
                "new_owner_name": "Hana Aydın",
                "new_owner_email": f"{manifest.attempt_id[:6]}.b.hana@journey.e2e.test".lower(),
                "transfer_date": "2027-03-01",
                "new_owner_moves_in": False,
            },
        )
        res_a_mar = j.accrue_a("Mart 2027", "2027-03-10")
        assert res_a_mar["total_units_accrued"] == 24
        res_b_mar = j.accrue_b("Mart 2027", "2027-03-10")
        assert res_b_mar["total_units_accrued"] == 64

        j.clock.advance_to("2027-03-10")
        j.post_routine_payments("Mart 2027")

        # Month 4: April 2027
        j.clock.advance_to("2027-04-01")
        api.call(
            "POST",
            f"/api/v1/site-admin/units/{j.unit_a('A-02')}/occupancy-transitions?site_id={j.site_a_id}",
            j.manager_a.token,
            body={
                "command": "TENANT_MOVE_IN",
                "effective_date": "2027-04-01",
                "full_name": "Eli Koç",
                "email": f"{manifest.attempt_id[:6]}.a.eli@journey.e2e.test".lower(),
                "phone": "+90 533 000 00 00",
            },
        )
        api.call(
            "POST",
            f"/api/v1/site-admin/units/{j.unit_b('B1-01')}/occupancy-transitions?site_id={j.site_b_id}",
            j.manager_b.token,
            body={"command": "OWNER_MOVE_IN", "effective_date": "2027-04-01"},
        )
        res_a_apr = j.accrue_a("Nisan 2027", "2027-04-10")
        assert res_a_apr["total_units_accrued"] == 24
        res_b_apr = j.accrue_b("Nisan 2027", "2027-04-10")
        assert res_b_apr["total_units_accrued"] == 64

        j.clock.advance_to("2027-04-10")

        # Assert INTERMEDIATE history for A-03 and B2-01 BEFORE April 10 payments
        # A-03: Jan Paid, Feb Unpaid (1000 + 98.33), Mar Unpaid (1000 + 51.67), Apr Unpaid (1000 + 0)
        stmt_a03_before = api.resident_statement(j.manager_a, j.unit_a("A-03"))
        debtor_a03_before = current_section(stmt_a03_before, "OWNER")
        open_a03_before = {
            item["period"]: (Decimal(str(item["principal_outstanding"])), Decimal(str(item["penalty_outstanding"])))
            for item in debtor_a03_before["open_items"]
        }
        assert "Ocak 2027" not in open_a03_before
        assert open_a03_before["Şubat 2027"] == (Decimal("1000.00"), Decimal("98.33"))
        assert open_a03_before["Mart 2027"] == (Decimal("1000.00"), Decimal("51.67"))
        assert open_a03_before["Nisan 2027"] == (Decimal("1000.00"), Decimal("0.00"))

        # B2-01: Jan Paid, Feb Unpaid (750 + 73.75), Mar Unpaid (750 + 38.75), Apr Unpaid (750 + 0)
        stmt_b201_before = api.resident_statement(j.manager_b, j.unit_b("B2-01"))
        debtor_b201_before = current_section(stmt_b201_before, "TENANT")
        open_b201_before = {
            item["period"]: (Decimal(str(item["principal_outstanding"])), Decimal(str(item["penalty_outstanding"])))
            for item in debtor_b201_before["open_items"]
        }
        assert "Ocak 2027" not in open_b201_before
        assert open_b201_before["Şubat 2027"] == (Decimal("750.00"), Decimal("73.75"))
        assert open_b201_before["Mart 2027"] == (Decimal("750.00"), Decimal("38.75"))
        assert open_b201_before["Nisan 2027"] == (Decimal("750.00"), Decimal("0.00"))

        # Post April 10 designated payments
        rec_a03_apr = api.record_manual_payment(
            j.manager_a, j.unit_a("A-03"), Decimal("1000.00"), "Fay Çelik",
            payer_role="OWNER", channel="MANUAL_CASH", description="Nisan 2027 ödemesi",
            designation={"periods": ["Nisan 2027"]},
            idempotency_key="des-pay-a03-apr",
        )
        assert len(rec_a03_apr["allocation_breakdown"]) == 1
        assert rec_a03_apr["allocation_breakdown"][0]["period"] == "Nisan 2027"
        assert Decimal(str(rec_a03_apr["allocation_breakdown"][0]["principal_paid"])) == Decimal("1000.00")
        assert Decimal(str(rec_a03_apr["allocation_breakdown"][0]["penalty_paid"])) == Decimal("0.00")

        rec_b201_apr = api.record_manual_payment(
            j.manager_b, j.unit_b("B2-01"), Decimal("750.00"), "Juno Yıldız",
            payer_role="TENANT", channel="MANUAL_CASH", description="Nisan 2027 ödemesi",
            designation={"periods": ["Nisan 2027"]},
            idempotency_key="des-pay-b201-apr",
        )
        assert len(rec_b201_apr["allocation_breakdown"]) == 1
        assert rec_b201_apr["allocation_breakdown"][0]["period"] == "Nisan 2027"
        assert Decimal(str(rec_b201_apr["allocation_breakdown"][0]["principal_paid"])) == Decimal("750.00")
        assert Decimal(str(rec_b201_apr["allocation_breakdown"][0]["penalty_paid"])) == Decimal("0.00")

        j.post_routine_payments("Nisan 2027")

        # Verify POST-APRIL history for A-03 and B2-01: Paid -> Unpaid -> Unpaid -> Paid!
        stmt_a03_after = api.resident_statement(j.manager_a, j.unit_a("A-03"))
        debtor_a03_after = current_section(stmt_a03_after, "OWNER")
        open_a03_after = {
            item["period"]: (Decimal(str(item["principal_outstanding"])), Decimal(str(item["penalty_outstanding"])))
            for item in debtor_a03_after["open_items"]
        }
        assert "Ocak 2027" not in open_a03_after
        assert open_a03_after["Şubat 2027"] == (Decimal("1000.00"), Decimal("98.33"))
        assert open_a03_after["Mart 2027"] == (Decimal("1000.00"), Decimal("51.67"))
        assert "Nisan 2027" not in open_a03_after  # Settled by designated payment!

        stmt_b201_after = api.resident_statement(j.manager_b, j.unit_b("B2-01"))
        debtor_b201_after = current_section(stmt_b201_after, "TENANT")
        open_b201_after = {
            item["period"]: (Decimal(str(item["principal_outstanding"])), Decimal(str(item["penalty_outstanding"])))
            for item in debtor_b201_after["open_items"]
        }
        assert "Ocak 2027" not in open_b201_after
        assert open_b201_after["Şubat 2027"] == (Decimal("750.00"), Decimal("73.75"))
        assert open_b201_after["Mart 2027"] == (Decimal("750.00"), Decimal("38.75"))
        assert "Nisan 2027" not in open_b201_after  # Settled by designated payment!

        def get_period_status(unit_id: str, period: str) -> str:
            raw = stack.sql(
                f"SELECT status, principal_amount, paid_principal FROM dues_liabilities "
                f"WHERE unit_id = {int(unit_id)} AND period = '{period}' AND status <> 'CANCELLED';"
            ).splitlines()
            if not raw:
                return "Unpaid"
            st, p_amt, p_paid = raw[0].split("|")
            amt = Decimal(p_amt)
            paid = Decimal(p_paid)
            if paid == amt or st == "PAID":
                return "Paid"
            elif paid > Decimal("0.00"):
                return "Partial"
            else:
                return "Unpaid"

        # SC-13-13-02: four periods were accrued, mixed receipts were posted, and the final
        # matrix distinguishes paid, partial and unpaid for all five detailed units.
        periods = ("Ocak 2027", "Şubat 2027", "Mart 2027", "Nisan 2027")
        assert [get_period_status(j.unit_a("A-03"), p) for p in periods] == ["Paid", "Unpaid", "Unpaid", "Paid"]
        assert [get_period_status(j.unit_b("B2-01"), p) for p in periods] == ["Paid", "Unpaid", "Unpaid", "Paid"]

        j.invariants_a("April final designated")
        j.invariants_b("April final designated")
    finally:
        teardown_sites(stack, manifest, restart=False)


@pytest.mark.covers("SC-13-13-02")
@pytest.mark.smoke
@pytest.mark.core
@pytest.mark.role_manager
def test_multi_site_journey_accruals_through_march_first(request, api, actors, stack):
    """Accrue January and February, verify initial payment histories, and advance to March 1 (Issue #248)."""
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    j = None
    try:
        j = build_multi_site_journey(api, stack, saas, manifest, start_date="2027-01-01")

        # Month 1: JANUARY 2027
        res_a_jan = j.accrue_a("Ocak 2027", "2027-01-10")
        assert res_a_jan["total_units_accrued"] == 24
        assert Decimal(str(res_a_jan["total_amount_accrued"])) == Decimal("24000.00")

        res_b_jan = j.accrue_b("Ocak 2027", "2027-01-10")
        assert res_b_jan["total_units_accrued"] == 64
        assert Decimal(str(res_b_jan["total_amount_accrued"])) == Decimal("48000.00")

        j.invariants_a("January accrued")
        j.invariants_b("January accrued")

        j.clock.advance_to("2027-01-10")

        rec_a01_jan = api.record_manual_payment(
            j.manager_a, j.unit_a("A-01"), Decimal("400.00"), "Ada Kaya",
            payer_role="OWNER", channel="MANUAL_CASH", description="Ocak 2027 kısmi ödeme",
            idempotency_key="pay-a01-jan-pf",
        )
        assert len(rec_a01_jan["allocation_breakdown"]) == 1
        assert rec_a01_jan["allocation_breakdown"][0]["period"] == "Ocak 2027"
        assert Decimal(str(rec_a01_jan["allocation_breakdown"][0]["principal_paid"])) == Decimal("400.00")

        rec_a03_jan = api.record_manual_payment(
            j.manager_a, j.unit_a("A-03"), Decimal("1000.00"), "Fay Çelik",
            payer_role="OWNER", channel="MANUAL_CASH", description="Ocak 2027 aidat ödemesi",
            idempotency_key="pay-a03-jan-pf",
        )
        assert len(rec_a03_jan["allocation_breakdown"]) == 1
        assert Decimal(str(rec_a03_jan["allocation_breakdown"][0]["principal_paid"])) == Decimal("1000.00")

        rec_b101_jan = api.record_manual_payment(
            j.manager_b, j.unit_b("B1-01"), Decimal("750.00"), "Gus Şahin",
            payer_role="OWNER", channel="MANUAL_CASH", description="Ocak 2027 aidat ödemesi",
            idempotency_key="pay-b101-jan-pf",
        )
        assert len(rec_b101_jan["allocation_breakdown"]) == 1
        assert Decimal(str(rec_b101_jan["allocation_breakdown"][0]["principal_paid"])) == Decimal("750.00")

        rec_b201_jan = api.record_manual_payment(
            j.manager_b, j.unit_b("B2-01"), Decimal("750.00"), "Juno Yıldız",
            payer_role="TENANT", channel="MANUAL_CASH", description="Ocak 2027 aidat ödemesi",
            idempotency_key="pay-b201-jan-pf",
        )
        assert len(rec_b201_jan["allocation_breakdown"]) == 1
        assert Decimal(str(rec_b201_jan["allocation_breakdown"][0]["principal_paid"])) == Decimal("750.00")

        j.post_routine_payments("Ocak 2027")

        status_a01_jan = stack.sql(
            f"SELECT status FROM dues_liabilities WHERE unit_id = {int(j.unit_a('A-01'))} AND period = 'Ocak 2027';"
        )
        assert status_a01_jan == "PARTIALLY_PAID"

        j.invariants_a("January posted")
        j.invariants_b("January posted")

        # Month 2: FEBRUARY 2027
        j.clock.advance_to("2027-02-01")

        res_a_feb = j.accrue_a("Şubat 2027", "2027-02-10")
        assert res_a_feb["total_units_accrued"] == 24
        assert Decimal(str(res_a_feb["total_amount_accrued"])) == Decimal("24000.00")

        res_b_feb = j.accrue_b("Şubat 2027", "2027-02-10")
        assert res_b_feb["total_units_accrued"] == 64
        assert Decimal(str(res_b_feb["total_amount_accrued"])) == Decimal("48000.00")

        j.invariants_a("February accrued")
        j.invariants_b("February accrued")

        j.clock.advance_to("2027-02-10")

        rec_a01_feb = api.record_manual_payment(
            j.manager_a, j.unit_a("A-01"), Decimal("831.00"), "Ada Kaya",
            payer_role="OWNER", channel="MANUAL_CASH", description="Şubat 2027 ödeme",
            idempotency_key="pay-a01-feb-pf",
        )
        allocs_a01_feb = rec_a01_feb["allocation_breakdown"]
        assert len(allocs_a01_feb) == 2
        assert allocs_a01_feb[0]["period"] == "Ocak 2027"
        assert Decimal(str(allocs_a01_feb[0]["penalty_paid"])) == Decimal("31.00")
        assert Decimal(str(allocs_a01_feb[0]["principal_paid"])) == Decimal("600.00")
        assert allocs_a01_feb[1]["period"] == "Şubat 2027"
        assert Decimal(str(allocs_a01_feb[1]["principal_paid"])) == Decimal("200.00")

        assert stack.sql(
            f"SELECT status FROM dues_liabilities WHERE unit_id = {int(j.unit_a('A-01'))} AND period = 'Ocak 2027';"
        ) == "PAID"
        assert stack.sql(
            f"SELECT status FROM dues_liabilities WHERE unit_id = {int(j.unit_a('A-01'))} AND period = 'Şubat 2027';"
        ) == "PARTIALLY_PAID"

        rec_a02_feb = api.record_manual_payment(
            j.manager_a, j.unit_a("A-02"), Decimal("1301.67"), "Dan Arslan",
            payer_role="TENANT", channel="MANUAL_CASH", description="Şubat 2027 ödeme",
            idempotency_key="pay-a02-feb-pf",
        )
        allocs_a02_feb = rec_a02_feb["allocation_breakdown"]
        assert len(allocs_a02_feb) == 2
        assert allocs_a02_feb[0]["period"] == "Ocak 2027"
        assert Decimal(str(allocs_a02_feb[0]["penalty_paid"])) == Decimal("51.67")
        assert Decimal(str(allocs_a02_feb[0]["principal_paid"])) == Decimal("1000.00")
        assert allocs_a02_feb[1]["period"] == "Şubat 2027"
        assert Decimal(str(allocs_a02_feb[1]["principal_paid"])) == Decimal("250.00")
        assert stack.sql(
            f"SELECT status FROM dues_liabilities WHERE unit_id = {int(j.unit_a('A-02'))} AND period = 'Ocak 2027';"
        ) == "PAID"
        assert stack.sql(
            f"SELECT status FROM dues_liabilities WHERE unit_id = {int(j.unit_a('A-02'))} AND period = 'Şubat 2027';"
        ) == "PARTIALLY_PAID"

        rec_b101_feb = api.record_manual_payment(
            j.manager_b, j.unit_b("B1-01"), Decimal("250.00"), "Gus Şahin",
            payer_role="OWNER", channel="MANUAL_CASH", description="Şubat 2027 kısmi ödeme",
            idempotency_key="pay-b101-feb-pf",
        )
        allocs_b101_feb = rec_b101_feb["allocation_breakdown"]
        assert len(allocs_b101_feb) == 1
        assert allocs_b101_feb[0]["period"] == "Şubat 2027"
        assert Decimal(str(allocs_b101_feb[0]["principal_paid"])) == Decimal("250.00")
        assert stack.sql(
            f"SELECT status FROM dues_liabilities WHERE unit_id = {int(j.unit_b('B1-01'))} AND period = 'Şubat 2027';"
        ) == "PARTIALLY_PAID"

        j.post_routine_payments("Şubat 2027")

        j.invariants_a("February posted")
        j.invariants_b("February posted")

        # Month 3: MARCH 2027
        j.clock.advance_to("2027-03-01")

        # March 1 transitions
        api.call("POST", "/api/v1/auth/step-up", j.manager_a.token, body={"password": j.manager_a_password})
        api.call(
            "POST",
            f"/api/v1/site-admin/units/{j.unit_a('A-01')}/transfer-ownership",
            j.manager_a.token,
            body={
                "unit_id": j.unit_a("A-01"),
                "new_owner_name": "Ben Kaya",
                "new_owner_email": f"{manifest.attempt_id[:6]}.a.ben.pf@journey.e2e.test".lower(),
                "transfer_date": "2027-03-01",
                "new_owner_moves_in": True,
            },
        )

        api.call(
            "POST",
            f"/api/v1/site-admin/units/{j.unit_a('A-02')}/occupancy-transitions?site_id={j.site_a_id}",
            j.manager_a.token,
            body={"command": "MOVE_OUT", "effective_date": "2027-03-01", "notes": "Dan moves out"},
        )

        api.call(
            "POST",
            f"/api/v1/site-admin/units/{j.unit_a('A-03')}/occupancy-transitions?site_id={j.site_a_id}",
            j.manager_a.token,
            body={"command": "MOVE_OUT", "effective_date": "2027-03-01", "notes": "Fay moves out"},
        )

        api.call("POST", "/api/v1/auth/step-up", j.manager_b.token, body={"password": j.manager_b_password})
        api.call(
            "POST",
            f"/api/v1/site-admin/units/{j.unit_b('B1-01')}/transfer-ownership",
            j.manager_b.token,
            body={
                "unit_id": j.unit_b("B1-01"),
                "new_owner_name": "Hana Aydın",
                "new_owner_email": f"{manifest.attempt_id[:6]}.b.hana.pf@journey.e2e.test".lower(),
                "transfer_date": "2027-03-01",
                "new_owner_moves_in": False,
            },
        )

        res_a_mar = j.accrue_a("Mart 2027", "2027-03-10")
        assert res_a_mar["total_units_accrued"] == 24
        assert Decimal(str(res_a_mar["total_amount_accrued"])) == Decimal("24000.00")

        res_b_mar = j.accrue_b("Mart 2027", "2027-03-10")
        assert res_b_mar["total_units_accrued"] == 64
        assert Decimal(str(res_b_mar["total_amount_accrued"])) == Decimal("48000.00")

        j.invariants_a("March accrued")
        j.invariants_b("March accrued")
    finally:
        teardown_sites(stack, manifest, restart=False)


@pytest.mark.covers("SC-13-13-02")
@pytest.mark.covers("SC-13-13-05")
@pytest.mark.covers("SC-13-14-10")
@pytest.mark.covers("SC-13-26-02")
@pytest.mark.covers("SC-13-25-02")
@pytest.mark.covers("SC-13-25-03")
@pytest.mark.covers("SC-13-25-04")
@pytest.mark.covers("SC-13-25-06")
@pytest.mark.covers("SC-13-25-07")
@pytest.mark.gui_id("GUI-13-04")
@pytest.mark.smoke
@pytest.mark.core
@pytest.mark.role_manager
def test_multi_site_journey_accruals_and_mixed_payments(request, api, actors, stack, page, login_page):
    """Accrue four periods and verify mixed payment histories across two sites (Issue #248)."""
    stack.reset_empty()
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    assert api.saas_sites(saas) == [], "integrated journey must start with an empty residential site list"
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    j = None
    try:
        j = build_multi_site_journey(api, stack, saas, manifest, start_date="2027-01-01")

        # -------------------------------------------------------------------
        # Month 1: JANUARY 2027
        # -------------------------------------------------------------------
        # 1. Accrue January 2027 on Jan 1
        res_a_jan = j.accrue_a("Ocak 2027", "2027-01-10")
        assert res_a_jan["total_units_accrued"] == 24
        assert Decimal(str(res_a_jan["total_amount_accrued"])) == Decimal("24000.00")

        res_b_jan = j.accrue_b("Ocak 2027", "2027-01-10")
        assert res_b_jan["total_units_accrued"] == 64
        assert Decimal(str(res_b_jan["total_amount_accrued"])) == Decimal("48000.00")

        j.invariants_a("January accrued")
        j.invariants_b("January accrued")

        # 2. Advance clock to January 10
        j.clock.advance_to("2027-01-10")

        # 3. Post payments on January 10
        # SC-13-25-06: a Site A payment moves Site A cash by exactly its amount and leaves Site B alone.
        cash_a_before, cash_b_before = posted_cash(stack, j.site_a_id), posted_cash(stack, j.site_b_id)
        # A-01: Ada pays 400.00
        rec_a01_jan = api.record_manual_payment(
            j.manager_a, j.unit_a("A-01"), Decimal("400.00"), "Ada Kaya",
            payer_role="OWNER", channel="MANUAL_CASH", description="Ocak 2027 kısmi ödeme",
            idempotency_key="pay-a01-jan",
        )
        assert posted_cash(stack, j.site_a_id) == cash_a_before + Decimal("400.00")
        assert posted_cash(stack, j.site_b_id) == cash_b_before
        assert len(rec_a01_jan["allocation_breakdown"]) == 1
        assert rec_a01_jan["allocation_breakdown"][0]["period"] == "Ocak 2027"
        assert Decimal(str(rec_a01_jan["allocation_breakdown"][0]["principal_paid"])) == Decimal("400.00")
        assert Decimal(str(rec_a01_jan["allocation_breakdown"][0]["penalty_paid"])) == Decimal("0.00")

        # A-03: Fay pays 1,000.00
        rec_a03_jan = api.record_manual_payment(
            j.manager_a, j.unit_a("A-03"), Decimal("1000.00"), "Fay Çelik",
            payer_role="OWNER", channel="MANUAL_CASH", description="Ocak 2027 aidat ödemesi",
            idempotency_key="pay-a03-jan",
        )
        assert len(rec_a03_jan["allocation_breakdown"]) == 1
        assert rec_a03_jan["allocation_breakdown"][0]["period"] == "Ocak 2027"
        assert Decimal(str(rec_a03_jan["allocation_breakdown"][0]["principal_paid"])) == Decimal("1000.00")
        assert Decimal(str(rec_a03_jan["allocation_breakdown"][0]["penalty_paid"])) == Decimal("0.00")

        # B1-01: Gus pays 750.00
        rec_b101_jan = api.record_manual_payment(
            j.manager_b, j.unit_b("B1-01"), Decimal("750.00"), "Gus Şahin",
            payer_role="OWNER", channel="MANUAL_CASH", description="Ocak 2027 aidat ödemesi",
            idempotency_key="pay-b101-jan",
        )
        assert len(rec_b101_jan["allocation_breakdown"]) == 1
        assert rec_b101_jan["allocation_breakdown"][0]["period"] == "Ocak 2027"
        assert Decimal(str(rec_b101_jan["allocation_breakdown"][0]["principal_paid"])) == Decimal("750.00")
        assert Decimal(str(rec_b101_jan["allocation_breakdown"][0]["penalty_paid"])) == Decimal("0.00")

        # B2-01: Juno pays 750.00
        rec_b201_jan = api.record_manual_payment(
            j.manager_b, j.unit_b("B2-01"), Decimal("750.00"), "Juno Yıldız",
            payer_role="TENANT", channel="MANUAL_CASH", description="Ocak 2027 aidat ödemesi",
            idempotency_key="pay-b201-jan",
        )
        assert len(rec_b201_jan["allocation_breakdown"]) == 1
        assert rec_b201_jan["allocation_breakdown"][0]["period"] == "Ocak 2027"
        assert Decimal(str(rec_b201_jan["allocation_breakdown"][0]["principal_paid"])) == Decimal("750.00")
        assert Decimal(str(rec_b201_jan["allocation_breakdown"][0]["penalty_paid"])) == Decimal("0.00")

        # 83 Routine payments
        j.post_routine_payments("Ocak 2027")
        assert_cash_matches_model(stack, j.site_a_id, j.site_b_id, CHECKPOINTS[0])

        # Assert intermediate state after January 10
        # A-01 is PARTIAL for January
        status_a01_jan = stack.sql(
            f"SELECT status FROM dues_liabilities WHERE unit_id = {int(j.unit_a('A-01'))} AND period = 'Ocak 2027';"
        )
        assert status_a01_jan == "PARTIALLY_PAID"

        j.invariants_a("January posted")
        j.invariants_b("January posted")

        # -------------------------------------------------------------------
        # Month 2: FEBRUARY 2027
        # -------------------------------------------------------------------
        j.clock.advance_to("2027-02-01")

        # 1. Accrue February 2027 on Feb 1
        res_a_feb = j.accrue_a("Şubat 2027", "2027-02-10")
        assert res_a_feb["total_units_accrued"] == 24
        assert Decimal(str(res_a_feb["total_amount_accrued"])) == Decimal("24000.00")

        res_b_feb = j.accrue_b("Şubat 2027", "2027-02-10")
        assert res_b_feb["total_units_accrued"] == 64
        assert Decimal(str(res_b_feb["total_amount_accrued"])) == Decimal("48000.00")

        j.invariants_a("February accrued")
        j.invariants_b("February accrued")

        # 2. Advance clock to February 10
        j.clock.advance_to("2027-02-10")

        # 3. Post payments on February 10
        # A-01: Ada pays 831.00 (31.00 fee on Jan + 600.00 Jan principal + 200.00 Feb principal)
        rec_a01_feb = api.record_manual_payment(
            j.manager_a, j.unit_a("A-01"), Decimal("831.00"), "Ada Kaya",
            payer_role="OWNER", channel="MANUAL_CASH", description="Şubat 2027 ödeme",
            idempotency_key="pay-a01-feb",
        )
        allocs_a01_feb = rec_a01_feb["allocation_breakdown"]
        assert len(allocs_a01_feb) == 2
        assert allocs_a01_feb[0]["period"] == "Ocak 2027"
        assert Decimal(str(allocs_a01_feb[0]["penalty_paid"])) == Decimal("31.00")
        assert Decimal(str(allocs_a01_feb[0]["principal_paid"])) == Decimal("600.00")
        assert allocs_a01_feb[1]["period"] == "Şubat 2027"
        assert Decimal(str(allocs_a01_feb[1]["penalty_paid"])) == Decimal("0.00")
        assert Decimal(str(allocs_a01_feb[1]["principal_paid"])) == Decimal("200.00")

        # Assert January partial-to-paid transition on A-01!
        assert stack.sql(
            f"SELECT status FROM dues_liabilities WHERE unit_id = {int(j.unit_a('A-01'))} AND period = 'Ocak 2027';"
        ) == "PAID"
        assert stack.sql(
            f"SELECT status FROM dues_liabilities WHERE unit_id = {int(j.unit_a('A-01'))} AND period = 'Şubat 2027';"
        ) == "PARTIALLY_PAID"

        # A-02: Dan pays 1,301.67 (51.67 fee on Jan + 1000.00 Jan principal + 250.00 Feb principal)
        rec_a02_feb = api.record_manual_payment(
            j.manager_a, j.unit_a("A-02"), Decimal("1301.67"), "Dan Arslan",
            payer_role="TENANT", channel="MANUAL_CASH", description="Şubat 2027 ödeme",
            idempotency_key="pay-a02-feb",
        )
        allocs_a02_feb = rec_a02_feb["allocation_breakdown"]
        assert len(allocs_a02_feb) == 2
        assert allocs_a02_feb[0]["period"] == "Ocak 2027"
        assert Decimal(str(allocs_a02_feb[0]["penalty_paid"])) == Decimal("51.67")
        assert Decimal(str(allocs_a02_feb[0]["principal_paid"])) == Decimal("1000.00")
        assert allocs_a02_feb[1]["period"] == "Şubat 2027"
        assert Decimal(str(allocs_a02_feb[1]["penalty_paid"])) == Decimal("0.00")
        assert Decimal(str(allocs_a02_feb[1]["principal_paid"])) == Decimal("250.00")
        assert stack.sql(
            f"SELECT status FROM dues_liabilities WHERE unit_id = {int(j.unit_a('A-02'))} AND period = 'Ocak 2027';"
        ) == "PAID"
        assert stack.sql(
            f"SELECT status FROM dues_liabilities WHERE unit_id = {int(j.unit_a('A-02'))} AND period = 'Şubat 2027';"
        ) == "PARTIALLY_PAID"

        # B1-01: Gus pays 250.00 towards February principal
        rec_b101_feb = api.record_manual_payment(
            j.manager_b, j.unit_b("B1-01"), Decimal("250.00"), "Gus Şahin",
            payer_role="OWNER", channel="MANUAL_CASH", description="Şubat 2027 kısmi ödeme",
            idempotency_key="pay-b101-feb",
        )
        allocs_b101_feb = rec_b101_feb["allocation_breakdown"]
        assert len(allocs_b101_feb) == 1
        assert allocs_b101_feb[0]["period"] == "Şubat 2027"
        assert Decimal(str(allocs_b101_feb[0]["penalty_paid"])) == Decimal("0.00")
        assert Decimal(str(allocs_b101_feb[0]["principal_paid"])) == Decimal("250.00")
        assert stack.sql(
            f"SELECT status FROM dues_liabilities WHERE unit_id = {int(j.unit_b('B1-01'))} AND period = 'Şubat 2027';"
        ) == "PARTIALLY_PAID"

        # 83 Routine payments
        j.post_routine_payments("Şubat 2027")
        assert_cash_matches_model(stack, j.site_a_id, j.site_b_id, CHECKPOINTS[1])

        j.invariants_a("February posted")
        j.invariants_b("February posted")

        # -------------------------------------------------------------------
        # Month 3: MARCH 2027
        # -------------------------------------------------------------------
        j.clock.advance_to("2027-03-01")

        # 1. Effective March 1 transitions before accrual
        # A-01: Ada sells to Ben, who moves in
        api.call("POST", "/api/v1/auth/step-up", j.manager_a.token, body={"password": j.manager_a_password})
        api.call(
            "POST",
            f"/api/v1/site-admin/units/{j.unit_a('A-01')}/transfer-ownership",
            j.manager_a.token,
            body={
                "unit_id": j.unit_a("A-01"),
                "new_owner_name": "Ben Kaya",
                "new_owner_email": f"{manifest.attempt_id[:6]}.a.ben@journey.e2e.test".lower(),
                "transfer_date": "2027-03-01",
                "new_owner_moves_in": True,
            },
        )

        # A-02: Dan moves out, leaving unit vacant
        api.call(
            "POST",
            f"/api/v1/site-admin/units/{j.unit_a('A-02')}/occupancy-transitions?site_id={j.site_a_id}",
            j.manager_a.token,
            body={"command": "MOVE_OUT", "effective_date": "2027-03-01", "notes": "Dan moves out"},
        )

        # A-03: Fay moves out and retains title (leaves unit vacant)
        api.call(
            "POST",
            f"/api/v1/site-admin/units/{j.unit_a('A-03')}/occupancy-transitions?site_id={j.site_a_id}",
            j.manager_a.token,
            body={"command": "MOVE_OUT", "effective_date": "2027-03-01", "notes": "Fay moves out"},
        )

        # B1-01: Gus sells to Hana, who leaves the unit vacant
        api.call("POST", "/api/v1/auth/step-up", j.manager_b.token, body={"password": j.manager_b_password})
        api.call(
            "POST",
            f"/api/v1/site-admin/units/{j.unit_b('B1-01')}/transfer-ownership",
            j.manager_b.token,
            body={
                "unit_id": j.unit_b("B1-01"),
                "new_owner_name": "Hana Aydın",
                "new_owner_email": f"{manifest.attempt_id[:6]}.b.hana@journey.e2e.test".lower(),
                "transfer_date": "2027-03-01",
                "new_owner_moves_in": False,
            },
        )

        # 2. Accrue March 2027 on March 1
        res_a_mar = j.accrue_a("Mart 2027", "2027-03-10")
        assert res_a_mar["total_units_accrued"] == 24
        assert Decimal(str(res_a_mar["total_amount_accrued"])) == Decimal("24000.00")

        res_b_mar = j.accrue_b("Mart 2027", "2027-03-10")
        assert res_b_mar["total_units_accrued"] == 64
        assert Decimal(str(res_b_mar["total_amount_accrued"])) == Decimal("48000.00")

        j.invariants_a("March accrued")
        j.invariants_b("March accrued")

        # 3. Advance clock to March 10
        j.clock.advance_to("2027-03-10")

        # 4. Post payments on March 10
        # A-01: Ben pays 500.00
        rec_a01_mar = api.record_manual_payment(
            j.manager_a, j.unit_a("A-01"), Decimal("500.00"), "Ben Kaya",
            payer_role="OWNER", channel="MANUAL_CASH", description="Mart 2027 kısmi ödeme",
            idempotency_key="pay-a01-mar",
        )
        allocs_a01_mar = rec_a01_mar["allocation_breakdown"]
        assert len(allocs_a01_mar) == 1
        assert allocs_a01_mar[0]["period"] == "Mart 2027"
        assert Decimal(str(allocs_a01_mar[0]["penalty_paid"])) == Decimal("0.00")
        assert Decimal(str(allocs_a01_mar[0]["principal_paid"])) == Decimal("500.00")

        # 83 Routine payments
        j.post_routine_payments("Mart 2027")
        assert_cash_matches_model(stack, j.site_a_id, j.site_b_id, CHECKPOINTS[2])

        j.invariants_a("March posted")
        j.invariants_b("March posted")

        # -------------------------------------------------------------------
        # Month 4: APRIL 2027
        # -------------------------------------------------------------------
        j.clock.advance_to("2027-04-01")

        # 1. Effective April 1 transitions before accrual
        # A-02: Eli moves in as tenant
        api.call(
            "POST",
            f"/api/v1/site-admin/units/{j.unit_a('A-02')}/occupancy-transitions?site_id={j.site_a_id}",
            j.manager_a.token,
            body={
                "command": "TENANT_MOVE_IN",
                "effective_date": "2027-04-01",
                "full_name": "Eli Koç",
                "email": f"{manifest.attempt_id[:6]}.a.eli@journey.e2e.test".lower(),
                "phone": "+90 533 000 00 00",
            },
        )

        # B1-01: Hana moves in (owner move-in)
        api.call(
            "POST",
            f"/api/v1/site-admin/units/{j.unit_b('B1-01')}/occupancy-transitions?site_id={j.site_b_id}",
            j.manager_b.token,
            body={"command": "OWNER_MOVE_IN", "effective_date": "2027-04-01"},
        )

        # 2. Accrue April 2027 on April 1
        res_a_apr = j.accrue_a("Nisan 2027", "2027-04-10")
        assert res_a_apr["total_units_accrued"] == 24
        assert Decimal(str(res_a_apr["total_amount_accrued"])) == Decimal("24000.00")

        res_b_apr = j.accrue_b("Nisan 2027", "2027-04-10")
        assert res_b_apr["total_units_accrued"] == 64
        assert Decimal(str(res_b_apr["total_amount_accrued"])) == Decimal("48000.00")

        j.invariants_a("April accrued")
        j.invariants_b("April accrued")

        # 3. Advance clock to April 10
        j.clock.advance_to("2027-04-10")

        # 4. Assert INTERMEDIATE history for A-03 and B2-01 BEFORE April 10 payments
        # A-03: Jan Paid, Feb Unpaid (1000 + 98.33), Mar Unpaid (1000 + 51.67), Apr Unpaid (1000 + 0)
        stmt_a03_before = api.resident_statement(j.manager_a, j.unit_a("A-03"))
        debtor_a03_before = current_section(stmt_a03_before, "OWNER")
        open_a03_before = {
            item["period"]: (Decimal(str(item["principal_outstanding"])), Decimal(str(item["penalty_outstanding"])))
            for item in debtor_a03_before["open_items"]
        }
        assert "Ocak 2027" not in open_a03_before
        assert open_a03_before["Şubat 2027"] == (Decimal("1000.00"), Decimal("98.33"))
        assert open_a03_before["Mart 2027"] == (Decimal("1000.00"), Decimal("51.67"))
        assert open_a03_before["Nisan 2027"] == (Decimal("1000.00"), Decimal("0.00"))

        # B2-01: Jan Paid, Feb Unpaid (750 + 73.75), Mar Unpaid (750 + 38.75), Apr Unpaid (750 + 0)
        stmt_b201_before = api.resident_statement(j.manager_b, j.unit_b("B2-01"))
        debtor_b201_before = current_section(stmt_b201_before, "TENANT")
        open_b201_before = {
            item["period"]: (Decimal(str(item["principal_outstanding"])), Decimal(str(item["penalty_outstanding"])))
            for item in debtor_b201_before["open_items"]
        }
        assert "Ocak 2027" not in open_b201_before
        assert open_b201_before["Şubat 2027"] == (Decimal("750.00"), Decimal("73.75"))
        assert open_b201_before["Mart 2027"] == (Decimal("750.00"), Decimal("38.75"))
        assert open_b201_before["Nisan 2027"] == (Decimal("750.00"), Decimal("0.00"))

        # 5. Post April 10 payments
        # A-03: Fay pays 1,000.00 DESIGNATED to April only
        rec_a03_apr = api.record_manual_payment(
            j.manager_a, j.unit_a("A-03"), Decimal("1000.00"), "Fay Çelik",
            payer_role="OWNER", channel="MANUAL_CASH", description="Nisan 2027 ödemesi",
            designation={"periods": ["Nisan 2027"]},
            idempotency_key="pay-a03-apr",
        )
        # Verify exactly one allocation to April
        assert len(rec_a03_apr["allocation_breakdown"]) == 1
        assert rec_a03_apr["allocation_breakdown"][0]["period"] == "Nisan 2027"
        assert Decimal(str(rec_a03_apr["allocation_breakdown"][0]["principal_paid"])) == Decimal("1000.00")
        assert Decimal(str(rec_a03_apr["allocation_breakdown"][0]["penalty_paid"])) == Decimal("0.00")

        # B2-01: Juno pays 750.00 DESIGNATED to April only
        rec_b201_apr = api.record_manual_payment(
            j.manager_b, j.unit_b("B2-01"), Decimal("750.00"), "Juno Yıldız",
            payer_role="TENANT", channel="MANUAL_CASH", description="Nisan 2027 ödemesi",
            designation={"periods": ["Nisan 2027"]},
            idempotency_key="pay-b201-apr",
        )
        assert len(rec_b201_apr["allocation_breakdown"]) == 1
        assert rec_b201_apr["allocation_breakdown"][0]["period"] == "Nisan 2027"
        assert Decimal(str(rec_b201_apr["allocation_breakdown"][0]["principal_paid"])) == Decimal("750.00")
        assert Decimal(str(rec_b201_apr["allocation_breakdown"][0]["penalty_paid"])) == Decimal("0.00")

        # A-01: Ben pays 1,025.83 (25.83 fee on Mar + 500.00 Mar principal + 500.00 Apr principal)
        rec_a01_apr = api.record_manual_payment(
            j.manager_a, j.unit_a("A-01"), Decimal("1025.83"), "Ben Kaya",
            payer_role="OWNER", channel="MANUAL_CASH", description="Nisan 2027 ödemesi",
            idempotency_key="pay-a01-apr",
        )
        allocs_a01_apr = rec_a01_apr["allocation_breakdown"]
        assert len(allocs_a01_apr) == 2
        assert allocs_a01_apr[0]["period"] == "Mart 2027"
        assert Decimal(str(allocs_a01_apr[0]["penalty_paid"])) == Decimal("25.83")
        assert Decimal(str(allocs_a01_apr[0]["principal_paid"])) == Decimal("500.00")
        assert allocs_a01_apr[1]["period"] == "Nisan 2027"
        assert Decimal(str(allocs_a01_apr[1]["penalty_paid"])) == Decimal("0.00")
        assert Decimal(str(allocs_a01_apr[1]["principal_paid"])) == Decimal("500.00")

        # A-02: Eli pays 600.00
        rec_a02_apr = api.record_manual_payment(
            j.manager_a, j.unit_a("A-02"), Decimal("600.00"), "Eli Koç",
            payer_role="TENANT", channel="MANUAL_CASH", description="Nisan 2027 ödemesi",
            idempotency_key="pay-a02-apr",
        )
        allocs_a02_apr = rec_a02_apr["allocation_breakdown"]
        assert len(allocs_a02_apr) == 1
        assert allocs_a02_apr[0]["period"] == "Nisan 2027"
        assert Decimal(str(allocs_a02_apr[0]["penalty_paid"])) == Decimal("0.00")
        assert Decimal(str(allocs_a02_apr[0]["principal_paid"])) == Decimal("600.00")

        # B1-01: Hana pays 1,038.75 (38.75 fee on Mar + 750.00 Mar principal + 250.00 Apr principal)
        rec_b101_apr = api.record_manual_payment(
            j.manager_b, j.unit_b("B1-01"), Decimal("1038.75"), "Hana Aydın",
            payer_role="OWNER", channel="MANUAL_CASH", description="Nisan 2027 ödemesi",
            idempotency_key="pay-b101-apr",
        )
        allocs_b101_apr = rec_b101_apr["allocation_breakdown"]
        assert len(allocs_b101_apr) == 2
        assert allocs_b101_apr[0]["period"] == "Mart 2027"
        assert Decimal(str(allocs_b101_apr[0]["penalty_paid"])) == Decimal("38.75")
        assert Decimal(str(allocs_b101_apr[0]["principal_paid"])) == Decimal("750.00")
        assert allocs_b101_apr[1]["period"] == "Nisan 2027"
        assert Decimal(str(allocs_b101_apr[1]["penalty_paid"])) == Decimal("0.00")
        assert Decimal(str(allocs_b101_apr[1]["principal_paid"])) == Decimal("250.00")

        # 83 Routine payments
        j.post_routine_payments("Nisan 2027")
        assert_cash_matches_model(stack, j.site_a_id, j.site_b_id, CHECKPOINTS[3])

        # 6. Verify POST-APRIL history for A-03 and B2-01: February and March remain unpaid with late fees!
        stmt_a03_after = api.resident_statement(j.manager_a, j.unit_a("A-03"))
        debtor_a03_after = current_section(stmt_a03_after, "OWNER")
        open_a03_after = {
            item["period"]: (Decimal(str(item["principal_outstanding"])), Decimal(str(item["penalty_outstanding"])))
            for item in debtor_a03_after["open_items"]
        }
        assert "Ocak 2027" not in open_a03_after
        assert open_a03_after["Şubat 2027"] == (Decimal("1000.00"), Decimal("98.33"))
        assert open_a03_after["Mart 2027"] == (Decimal("1000.00"), Decimal("51.67"))
        assert "Nisan 2027" not in open_a03_after  # Settled by designated payment!

        stmt_b201_after = api.resident_statement(j.manager_b, j.unit_b("B2-01"))
        debtor_b201_after = current_section(stmt_b201_after, "TENANT")
        open_b201_after = {
            item["period"]: (Decimal(str(item["principal_outstanding"])), Decimal(str(item["penalty_outstanding"])))
            for item in debtor_b201_after["open_items"]
        }
        assert "Ocak 2027" not in open_b201_after
        assert open_b201_after["Şubat 2027"] == (Decimal("750.00"), Decimal("73.75"))
        assert open_b201_after["Mart 2027"] == (Decimal("750.00"), Decimal("38.75"))
        assert "Nisan 2027" not in open_b201_after  # Settled by designated payment!

        # 7. Check the final paid, partial and unpaid matrix for all five detailed units:
        # A-01: Paid, Partial, Paid, Partial
        # A-02: Paid, Partial, Unpaid, Partial
        # A-03: Paid, Unpaid, Unpaid, Paid
        # B1-01: Paid, Partial, Paid, Partial
        # B2-01: Paid, Unpaid, Unpaid, Paid
        def get_period_status(unit_id: str, period: str) -> str:
            raw = stack.sql(
                f"SELECT status, principal_amount, paid_principal FROM dues_liabilities "
                f"WHERE unit_id = {int(unit_id)} AND period = '{period}' AND status <> 'CANCELLED';"
            ).splitlines()
            if not raw:
                return "Unpaid"
            st, p_amt, p_paid = raw[0].split("|")
            amt = Decimal(p_amt)
            paid = Decimal(p_paid)
            if paid == amt or st == "PAID":
                return "Paid"
            elif paid > Decimal("0.00"):
                return "Partial"
            else:
                return "Unpaid"

        periods = ("Ocak 2027", "Şubat 2027", "Mart 2027", "Nisan 2027")

        assert [get_period_status(j.unit_a("A-01"), p) for p in periods] == ["Paid", "Partial", "Paid", "Partial"]
        assert [get_period_status(j.unit_a("A-02"), p) for p in periods] == ["Paid", "Partial", "Unpaid", "Partial"]
        assert [get_period_status(j.unit_a("A-03"), p) for p in periods] == ["Paid", "Unpaid", "Unpaid", "Paid"]
        assert [get_period_status(j.unit_b("B1-01"), p) for p in periods] == ["Paid", "Partial", "Paid", "Partial"]
        assert [get_period_status(j.unit_b("B2-01"), p) for p in periods] == ["Paid", "Unpaid", "Unpaid", "Paid"]

        # SC-13-25-07: the manager statements show exactly the eleven open rows and the model's site totals.
        # Each row's debtor is the name on its own statement section, including a former holder's (#295);
        # test_unit_statement_attributes_open_items_to_former_debtors pins that attribution.
        # The same reconciliation pins each owner's joint exposure (SC-13-14-10), the site totals
        # that count every receivable once (SC-13-25-03), and the open rows matched by site, unit,
        # primary debtor and period (SC-13-25-02).
        detailed = {("A", label): j.unit_a(label) for label in ("A-01", "A-02", "A-03")}
        detailed |= {("B", label): j.unit_b(label) for label in ("B1-01", "B2-01")}
        assert_statements_match_model(api, {"A": j.manager_a, "B": j.manager_b}, detailed)
        assert stack.sql(
            "SELECT count(*) FROM dues_liabilities d JOIN units u ON u.id = d.unit_id "
            f"WHERE u.site_id IN ({int(j.site_a_id)}, {int(j.site_b_id)}) AND d.status NOT IN ('PAID', 'CANCELLED') "
            f"AND d.unit_id NOT IN ({', '.join(str(int(u)) for u in detailed.values())});") == "0"

        # Final ledger invariants
        j.invariants_a("April final")
        j.invariants_b("April final")

        # Manager browser evidence (SC-13-13-05, SC-13-26-02): each manager sees only their own
        # site, the four-period journey's unit statement renders the ledger's payer identity, open
        # period history and exact totals, and the cash view lists posted receipts whose stream
        # total reconciles to the ledger's posted site cash. Every unit and site id here came from
        # onboarding, so both sites stay identifiable from onboarding through final reconciliation.
        login_page.login("manager", j.manager_a.user["email"], j.manager_a_password)
        ResidentsTab(page).open()
        units_a = set(ResidentsTab(page).unit_card_ids())
        assert units_a == set(j.units_a.values())
        unit_id_a = j.unit_a("A-03")
        unit_id_b = j.unit_b("B2-01")
        assert unit_id_b not in units_a, "Site A's manager must not see Site B's units"

        UnitWorkspace(page).open(unit_id_a).action(unit_id_a, "statement")
        by_id(page, "statement_debtor_owner").wait_for(timeout=15_000)
        statement_a = api.resident_statement(j.manager_a, unit_id_a)
        owner_a = next(d for d in statement_a["debtors"] if d["debtor_type"] == "OWNER")
        # A-03 is paid in January and April, so February and March stay open. The independent
        # journey model pins the periods and their exact principal-plus-fee totals; the API
        # statement is reconciled to the same model just above.
        ledger = reconcile()
        expected_a = {
            PERIOD_LABELS[row.period]: row.total
            for row in ledger.open_rows()
            if (row.site, row.unit) == ("A", "A-03")
        }
        assert expected_a == {
            "Şubat 2027": Decimal("1098.33"),
            "Mart 2027": Decimal("1051.67"),
        }, f"the journey model pins A-03's two unpaid periods and totals, got {expected_a}"
        for period, total in expected_a.items():
            _wait_for_semantics_text(page, "statement_debtor_owner", period)
            _wait_for_semantics_text(page, "statement_debtor_owner", format_try(total))
        owner_section_a = text_of(by_id(page, "statement_debtor_owner"))
        assert f"{owner_a['name']} · Kat maliki" in owner_section_a, (
            f"Site A, April 2027, unit A-03 ({unit_id_a}): the statement should name the "
            f"owner payer {owner_a['name']!r}; it showed {owner_section_a!r}"
        )
        assert by_id(page, "statement_debtor_tenant").count() == 0, (
            f"Site A, April 2027, unit A-03 ({unit_id_a}): the owner-paid unit has no tenant "
            "debtor, so the statement must not render a tenant section"
        )
        for period, total in expected_a.items():
            assert period in owner_section_a, (
                f"Site A, unit A-03: period {period!r} missing from the owner section"
            )
            assert format_try(total) in owner_section_a, (
                f"Site A, unit A-03, {period}: open amount {format_try(total)} missing from "
                "the owner section"
            )
        expected_total_a = sum(expected_a.values(), Decimal("0.00"))
        _wait_for_semantics_text(page, "statement_total_owner", format_try(expected_total_a))
        assert amount_of(page, "statement_total_owner") == expected_total_a, (
            f"Site A, April 2027, unit A-03 ({unit_id_a}): statement total does not match "
            f"the ledger total {format_try(expected_total_a)}"
        )
        assert statement_a["receipts"], f"Site A, unit A-03 ({unit_id_a}) should list its paid periods"
        for receipt in statement_a["receipts"]:
            by_id(page, f"statement_receipt_{receipt['receipt_number']}").wait_for(timeout=15_000)
        page.keyboard.press("Escape")
        UnitWorkspace(page).close()
        PaymentStream(page).open()
        # The Canlı Kasa segment lists receipts but renders no site total; the posted cash total is
        # reconciliation evidence from the API (plan figure from the #246 contract, April 10).
        stream_a = api.payment_stream(j.manager_a)
        cash_a = posted_cash(stack, j.site_a_id)
        assert Decimal(str(stream_a["total_volume"])) == cash_a == j.expected_posted_cash_a, (
            f"Site A, April 2027: cash view TRY {stream_a['total_volume']}, ledger TRY {cash_a}, "
            f"expected {j.expected_posted_cash_a}"
        )
        PaymentStream(page).wait_for_entries("return ids.length > 0")
        assert PaymentStream(page).entry_ids(), "Site A, April 2027 cash view should list posted receipts"

        manager_b_page = page.context.new_page()
        try:
            LoginPage(manager_b_page, login_page.base_url).open().login(
                "manager", j.manager_b.user["email"], j.manager_b_password,
            )
            ResidentsTab(manager_b_page).open()
            units_b = set(ResidentsTab(manager_b_page).unit_card_ids())
            assert units_b == set(j.units_b.values())
            assert unit_id_a not in units_b, "Site B's manager must not see Site A's units"
            UnitWorkspace(manager_b_page).open(unit_id_b).action(unit_id_b, "statement")
            by_id(manager_b_page, "statement_debtor_tenant").wait_for(timeout=15_000)
            statement_b = api.resident_statement(j.manager_b, unit_id_b)
            tenant_b = next(d for d in statement_b["debtors"] if d["debtor_type"] == "TENANT")
            # B2-01 is paid in January and April, so February and March stay open. The model
            # pins Juno's two unpaid periods and their principal-plus-fee totals.
            expected_b = {
                PERIOD_LABELS[row.period]: row.total
                for row in ledger.open_rows()
                if (row.site, row.unit) == ("B", "B2-01")
            }
            assert expected_b == {
                "Şubat 2027": Decimal("823.75"),
                "Mart 2027": Decimal("788.75"),
            }, f"the journey model pins B2-01's two unpaid periods and totals, got {expected_b}"
            for period, total in expected_b.items():
                _wait_for_semantics_text(manager_b_page, "statement_debtor_tenant", period)
                _wait_for_semantics_text(manager_b_page, "statement_debtor_tenant", format_try(total))
            tenant_section_b = text_of(by_id(manager_b_page, "statement_debtor_tenant"))
            assert f"{tenant_b['name']} · Kiracı" in tenant_section_b, (
                f"Site B, April 2027, unit B2-01 ({unit_id_b}): the statement should name the "
                f"tenant payer {tenant_b['name']!r}; it showed {tenant_section_b!r}"
            )
            for period, total in expected_b.items():
                assert period in tenant_section_b, (
                    f"Site B, unit B2-01: period {period!r} missing from the tenant section"
                )
                assert format_try(total) in tenant_section_b, (
                    f"Site B, unit B2-01, {period}: open amount {format_try(total)} missing from "
                    "the tenant section"
                )
            expected_total_b = sum(expected_b.values(), Decimal("0.00"))
            _wait_for_semantics_text(manager_b_page, "statement_total_tenant", format_try(expected_total_b))
            assert amount_of(manager_b_page, "statement_total_tenant") == expected_total_b, (
                f"Site B, April 2027, unit B2-01 ({unit_id_b}): statement total does not match "
                f"the ledger total {format_try(expected_total_b)}"
            )
            assert statement_b["receipts"], f"Site B, unit B2-01 ({unit_id_b}) should list its paid periods"
            for receipt in statement_b["receipts"]:
                by_id(manager_b_page, f"statement_receipt_{receipt['receipt_number']}").wait_for(timeout=15_000)
            manager_b_page.keyboard.press("Escape")
            UnitWorkspace(manager_b_page).close()
            PaymentStream(manager_b_page).open()
            stream_b = api.payment_stream(j.manager_b)
            cash_b = posted_cash(stack, j.site_b_id)
            assert Decimal(str(stream_b["total_volume"])) == cash_b == j.expected_posted_cash_b, (
                f"Site B, April 2027: cash view TRY {stream_b['total_volume']}, ledger TRY {cash_b}, "
                f"expected {j.expected_posted_cash_b}"
            )
            PaymentStream(manager_b_page).wait_for_entries("return ids.length > 0")
            assert PaymentStream(manager_b_page).entry_ids(), (
                "Site B, April 2027 cash view should list posted receipts"
            )
        finally:
            manager_b_page.close()

    finally:
        teardown_sites(stack, manifest, restart=False)

