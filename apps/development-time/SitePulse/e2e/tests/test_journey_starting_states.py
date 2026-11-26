"""Journey starting states tests covering F0 through F3."""
from __future__ import annotations

import os
from decimal import Decimal
from pathlib import Path

import pytest

from support.api import ApiError
from support.journey_attempts import (
    JourneyClock,
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
        unmatched = [m for m in queue if m.get("status") in ("UNMATCHED", "ESLESTIRILEMEDI", "Unmatched")]
        assert len(unmatched) >= 1
        assert Decimal(str(unmatched[0]["transaction"]["amount"])) == Decimal("1500.00")

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
        res = api.accrue_period(fixture.manager, "Ekim 2026", None, "2026-10-10")
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
        res = api.accrue_period(fixture.manager, "Ekim 2026", None, "2026-10-10")

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


def pin_reference_schedule_and_tariff(api, fixture) -> None:
    """Pin the F3 accrual schedule and house-type tariff the charges must follow.

    Pinning them keeps the expected amounts independent of environment defaults: the
    journey bills on the 10th, so the schedule is set to that and read back, and the
    Flat/Large flat tariffs behind the 1450.00 and 1016.13 amounts are asserted as literals.
    """
    pinned = {
        "accrual_day": 1,
        "due_day": 10,
        "grace_days": 0,
        "catch_up_limit_months": 12,
        "go_live_date": None,
    }
    api.call("PUT", "/api/v1/accrual-schedule", fixture.manager.token, body=pinned)
    stored = api.call("GET", "/api/v1/accrual-schedule", fixture.manager.token)
    for key, value in pinned.items():
        assert stored[key] == value, f"accrual schedule {key} is not pinned"

    tariffs = {
        row["type_name"]: Decimal(str(row["dues_amount"]))
        for row in api.call(
            "GET",
            f"/api/v1/site-admin/house-types?site_id={fixture.site_id}",
            fixture.manager.token,
        )
    }
    assert tariffs == {"Flat": Decimal("1500.00"), "Large flat": Decimal("2250.00")}


def period_liabilities(stack, site_id: str, unit_id: str, period: str) -> str:
    """The stored liability rows of one unit and period, in a stable text form."""
    return stack.sql(
        "SELECT d.principal_amount, d.debtor_type, d.due_date, "
        "COALESCE(d.effective_due_date::text, ''), COALESCE(d.source_period, ''), d.delay_penalty "
        "FROM dues_liabilities d "
        f"WHERE d.unit_id = {int(unit_id)} AND d.period = '{period}' "
        "ORDER BY d.id;"
    )


@pytest.mark.covers("SC-13-01-10")
@pytest.mark.edge
def test_f3_primary_resident_charged_from_start_residing_date(request, api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    try:
        fixture = site_in_state("F3", api=api, stack=stack, saas=saas, manifest=manifest)
        pin_reference_schedule_and_tariff(api, fixture)
        unit_a1 = int(fixture.unit_ids[0])

        # The owner starts residing on 2026-11-02 and the session opens on that day.
        clock = JourneyClock(api, "2026-11-02")
        api.register_home_owner(
            fixture.manager,
            block="A",
            unit_no=1,
            owner_full_name="Ayşe Kaya",
            email=f"{manifest.attempt_id[:8]}.ayse.455@journey.e2e.test",
            is_resident=True,
            house_type="Flat",
            site_id=fixture.site_id,
        )
        assert clock.current_date.isoformat() == "2026-11-02"
        assert stack.sql(
            "SELECT start_date FROM unit_occupancies "
            f"WHERE unit_id = {unit_a1} AND is_active ORDER BY id DESC LIMIT 1;"
        ) == "2026-11-02"

        # October keeps no liability for A-1: its days had nobody to bill.
        assert period_liabilities(stack, fixture.site_id, unit_a1, "Ekim 2026") == ""

        api.accrue_period(fixture.manager, "Kasım 2026", None, "2026-11-10")

        # 29 of 30 days of the 1500.00 Flat tariff, charged from the start residing date.
        assert period_liabilities(stack, fixture.site_id, unit_a1, "Kasım 2026") == (
            "1450.00|OWNER|2026-11-10|2026-11-10||0.00"
        )
        overview = ledger_invariants(api, fixture.manager, fixture.site_id, stage="F3-start-residing")
        flat = next(f for f in overview["flats"] if str(f["id"]) == str(unit_a1))
        assert Decimal(str(flat["amount_due"])) == Decimal("1450.00")
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)


@pytest.mark.covers("SC-13-01-15")
@pytest.mark.edge
def test_f3_backdated_start_residing_date_creates_the_supplementary_charge(request, api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    try:
        fixture = site_in_state("F3", api=api, stack=stack, saas=saas, manifest=manifest)
        pin_reference_schedule_and_tariff(api, fixture)
        unit_a3 = int(fixture.unit_ids[2])

        # October is already an accrued month with its own due date and no A-3 liability.
        assert stack.sql(
            "SELECT due_date FROM dues_periods "
            f"WHERE site_id = {int(fixture.site_id)} AND period_name = 'Ekim 2026';"
        ) == "2026-10-10"
        assert period_liabilities(stack, fixture.site_id, unit_a3, "Ekim 2026") == ""

        # The title is registered on 2026-11-19 without opening a session first.
        clock = JourneyClock(api, "2026-11-19")
        api.register_home_owner(
            fixture.manager,
            block="A",
            unit_no=3,
            owner_full_name="Burak Şahin",
            email=f"{manifest.attempt_id[:8]}.burak.455@journey.e2e.test",
            is_resident=False,
            house_type="Flat",
            site_id=fixture.site_id,
        )
        owner_person_id = stack.sql(f"SELECT owner_person_id FROM units WHERE id = {unit_a3};").strip()
        assert owner_person_id
        assert stack.sql(
            f"SELECT COUNT(*) FROM unit_occupancies WHERE unit_id = {unit_a3};"
        ) == "0"

        # Assigning the owner as a resident effective 2026-10-11 back-dates the session.
        transition = api.call(
            "POST",
            f"/api/v1/site-admin/units/{unit_a3}/occupancy-transitions?site_id={fixture.site_id}",
            fixture.manager.token,
            body={
                "command": "OWNER_MOVE_IN",
                "effective_date": "2026-10-11",
                "person_id": int(owner_person_id),
            },
        )
        assert transition["opened"]["start_date"] == "2026-10-11"

        charges = transition["supplementary_charges"]
        assert len(charges) == 1, "one supplementary charge for the unbilled October days"
        charge = charges[0]
        assert Decimal(str(charge["principal_amount"])) == Decimal("1016.13")
        assert charge["period"] == "Ekim 2026"
        assert charge["debtor_type"] == "OWNER"

        # 21 of 31 days: the days before 2026-10-11 stay charged to nobody, so they carry
        # no liability of their own and no share named anyone else.
        assert period_liabilities(stack, fixture.site_id, unit_a3, "Ekim 2026") == (
            "1016.13|OWNER|2026-10-10|2026-11-19|2026-10|0.00"
        )
        overview = ledger_invariants(api, fixture.manager, fixture.site_id, stage="F3-backdated")
        flat = next(f for f in overview["flats"] if str(f["id"]) == str(unit_a3))
        assert Decimal(str(flat["amount_due"])) == Decimal("1016.13")

        # The charge counts from its 2026-11-19 creation, so ten days later at 2026-11-29
        # it has 16.94: 1016.13 x 5% x 10 / 30.
        clock.set_date("2026-11-29")
        clock.tick()
        assert stack.sql(
            f"SELECT delay_penalty FROM dues_liabilities WHERE id = {int(charge['id'])};"
        ) == "16.94"
        ledger_invariants(api, fixture.manager, fixture.site_id, stage="F3-backdated-late-fee")
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
