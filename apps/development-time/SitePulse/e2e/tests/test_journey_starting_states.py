"""Journey starting states tests covering F0 through F3."""
from __future__ import annotations

import os
from decimal import Decimal
from pathlib import Path

import pytest

from support.api import ApiError
from support.journey_attempts import (
    JourneyManifest,
    ledger_invariants,
    site_in_state,
    teardown_with_evidence,
)

E2E = Path(__file__).resolve().parents[1]


@pytest.mark.covers("SC-13-01-02")
@pytest.mark.core
def test_f0_accrue_period_refused_no_units(request, api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    try:
        fixture = site_in_state("F0", api=api, stack=stack, saas=saas, manifest=manifest)
        with pytest.raises(ApiError) as exc_info:
            api.accrue_period(
                fixture.manager,
                period="Kasım 2026",
                amount=Decimal("1500.00"),
                due_date="2026-11-10",
            )
        assert "404" in str(exc_info.value) or "daire bulunamadı" in str(exc_info.value)

        site_id = int(fixture.site_id)
        assert stack.sql(f"SELECT COUNT(*) FROM dues_periods WHERE site_id = {site_id};") == "0"
        assert stack.sql(
            "SELECT COUNT(*) FROM dues_liabilities d JOIN units u ON u.id = d.unit_id "
            f"WHERE u.site_id = {site_id};"
        ) == "0"
        assert stack.sql(f"SELECT COUNT(*) FROM payment_receipts WHERE site_id = {site_id};") == "0"
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)


@pytest.mark.covers("SC-13-01-03")
@pytest.mark.edge
def test_f0_unknown_virtual_iban_payment_stored_unmatched(request, api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    try:
        fixture = site_in_state("F0", api=api, stack=stack, saas=saas, manifest=manifest)

        # Import statement with an unknown virtual IBAN and 1500.00 transfer
        csv_content = "2026-10-15;TR120006200000000000001099;FAST TRANSFERI;1500.00"
        resp = api.call(
            "POST",
            "/api/v1/bank/statements/parse",
            fixture.manager.token,
            body={
                "site_id": fixture.site_id,
                "content": csv_content,
                "format": "CSV",
            },
        )
        assert resp is not None

        # Check reconciliation queue
        queue = api.call(
            "GET",
            f"/api/v1/bank/statements/reconciliation-queue?site_id={fixture.site_id}",
            fixture.manager.token,
        )
        assert len(queue) >= 1
        unmatched = [m for m in queue if m.get("status") in ("ESLESTIRILEMEDI", "Unmatched")]
        assert len(unmatched) >= 1
        assert Decimal(str(unmatched[0]["amount"])) == Decimal("1500.00")

        # Verify no balances changed
        overview = api.site_overview(fixture.manager, fixture.site_id)
        assert Decimal(str(overview["summary"]["total_overdue_with_interest"])) == Decimal("0.00")
        assert Decimal(str(overview["summary"]["total_advance_balance"])) == Decimal("0.00")
        assert stack.sql(f"SELECT COUNT(*) FROM payment_receipts WHERE site_id = {int(fixture.site_id)};") == "0"
        ledger_invariants(api, fixture.manager, fixture.site_id, stage="F0-unmatched")
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)


@pytest.mark.covers("SC-13-01-07")
@pytest.mark.core
def test_f2_first_accrual_charges_units_tariffs_and_debtors(request, api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    try:
        fixture = site_in_state("F2", api=api, stack=stack, saas=saas, manifest=manifest)
        api.create_period(fixture.manager, "Ekim 2026", "2026-10-10")
        res = api.accrue_period(fixture.manager, "Ekim 2026", Decimal("0.00"), "2026-10-10")
        assert res is not None

        # In F2:
        # 6 liabilities exist, one for each of A-1 to A-6
        # A-6 owes 2250.00, A-1..A-5 owe 1500.00
        # Debtor is owner for A-1, A-3, A-4, A-6, tenant for A-2, A-5
        rows = stack.sql(
            "SELECT u.unit_number, d.principal_amount, d.debtor_type "
            "FROM dues_liabilities d JOIN units u ON u.id = d.unit_id "
            f"WHERE u.site_id = {int(fixture.site_id)} "
            "ORDER BY u.unit_number;"
        ).splitlines()
        assert len(rows) == 6

        parsed_rows = {}
        for row in rows:
            parts = [p.strip() for p in row.split("|")]
            unit_no = int(parts[0])
            amount = Decimal(parts[1])
            debtor_type = parts[2]
            parsed_rows[unit_no] = (amount, debtor_type)

        assert set(parsed_rows.keys()) == {1, 2, 3, 4, 5, 6}
        for u in (1, 2, 3, 4, 5):
            assert parsed_rows[u][0] == Decimal("1500.00")
        assert parsed_rows[6][0] == Decimal("2250.00")

        assert parsed_rows[1][1] == "OWNER"
        assert parsed_rows[2][1] == "TENANT"
        assert parsed_rows[3][1] == "OWNER"
        assert parsed_rows[4][1] == "OWNER"
        assert parsed_rows[5][1] == "TENANT"
        assert parsed_rows[6][1] == "OWNER"

        ledger_invariants(api, fixture.manager, fixture.site_id, stage="F2-accrual")
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)


@pytest.mark.covers("SC-13-01-08")
@pytest.mark.edge
def test_f2_units_without_owner_reported_separately(request, api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    try:
        fixture = site_in_state("F2", api=api, stack=stack, saas=saas, manifest=manifest)
        api.create_period(fixture.manager, "Ekim 2026", "2026-10-10")
        res = api.accrue_period(fixture.manager, "Ekim 2026", Decimal("0.00"), "2026-10-10")

        # No liability for unit A-7
        assert stack.sql(
            "SELECT COUNT(*) FROM dues_liabilities d JOIN units u ON u.id = d.unit_id "
            f"WHERE u.site_id = {int(fixture.site_id)} AND u.unit_number = 7;"
        ) == "0"

        # Separate list "units_without_owner" containing "A-7"
        units_without_owner = res.get("units_without_owner", [])
        assert "A-7" in units_without_owner
        assert res.get("newly_accrued_units_count") == 6
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)


@pytest.mark.covers("SC-13-01-09")
@pytest.mark.core
def test_f3_period_exists_open_zero_liabilities(request, api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    try:
        fixture = site_in_state("F3", api=api, stack=stack, saas=saas, manifest=manifest)

        # Period "Ekim 2026" exists and is OPEN
        status = stack.sql(
            f"SELECT status FROM dues_periods WHERE site_id = {int(fixture.site_id)} "
            "AND period_name = 'Ekim 2026';"
        ).strip()
        assert status in ("OPEN", "ACTIVE")

        # 0 liabilities exist for it
        assert stack.sql(
            "SELECT COUNT(*) FROM dues_liabilities d JOIN units u ON u.id = d.unit_id "
            f"WHERE u.site_id = {int(fixture.site_id)};"
        ) == "0"

        # Dashboard shows total outstanding 0.00
        overview = api.site_overview(fixture.manager, fixture.site_id)
        assert Decimal(str(overview["summary"]["total_overdue_with_interest"])) == Decimal("0.00")
        ledger_invariants(api, fixture.manager, fixture.site_id, stage="F3-initial")
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)


@pytest.mark.covers("SC-13-01-13")
@pytest.mark.edge
@pytest.mark.parametrize("state", ["F0", "F1", "F2", "F3"])
def test_starting_states_survive_backend_restart(state, request, api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    try:
        fixture = site_in_state(state, api=api, stack=stack, saas=saas, manifest=manifest)
        before_overview = api.site_overview(fixture.manager, fixture.site_id)

        stack.restart_backend()

        manager = api.login(fixture.manager_email, fixture.manager_password)
        after_overview = api.site_overview(manager, fixture.site_id)

        assert after_overview["summary"] == before_overview["summary"]
        assert after_overview["flats"] == before_overview["flats"]
        assert after_overview["available_periods"] == before_overview["available_periods"]
        ledger_invariants(api, manager, fixture.site_id, stage=f"{state}-after-restart")
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)
