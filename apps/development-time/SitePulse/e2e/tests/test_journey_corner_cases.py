"""EPIC-13 J-12: corner cases of residents leaving with debt (STORY-13-05), backend scenarios."""
from __future__ import annotations

import os
from decimal import Decimal
from pathlib import Path

import pytest

from support.journey_attempts import JourneyManifest, ledger_invariants, site_in_state, teardown_with_evidence

E2E = Path(__file__).resolve().parents[1]
D = Decimal


@pytest.mark.covers("SC-13-05-06")
@pytest.mark.edge
@pytest.mark.role_manager
def test_moving_out_with_debt_keeps_the_debt_and_the_history(request, api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys", run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"))
    try:
        fixture = site_in_state("F5", api=api, stack=stack, saas=saas, manifest=manifest)
        unit = fixture.unit_ids[4]  # A-5: tenant "Deniz Arslan", owner "Can Öztürk"
        # The daily run covers the days up to 2026-11-30; 2026-12-01 is reached before any December accrual.
        api.e2e_clock("set_date", "2026-11-30")
        api.e2e_clock("tick")
        api.e2e_clock("set_date", "2026-12-01")

        result = api.call(
            "POST", f"/api/v1/site-admin/units/{unit}/occupancy-transitions?site_id={fixture.site_id}",
            fixture.manager.token, body={"command": "MOVE_OUT", "effective_date": "2026-12-01"})
        assert result["closed"]["person_name"] == "Deniz Arslan"
        assert D(str(result["closed"]["exit_balance"])) == D("4880.00")  # 4500.00 principal + the fee accrued to 2026-11-30

        assert api.get_unit_occupancy_state(fixture.manager, unit, fixture.site_id)["occupancy"] == "VACANT"
        statement = api.resident_statement(fixture.manager, unit)
        debtors = {d["debtor_type"]: d for d in statement["debtors"]}
        tenant, owner = debtors["TENANT"], debtors["OWNER"]
        assert D(str(tenant["principal_outstanding"])) == D("4500.00")
        assert D(str(tenant["total_outstanding"])) == D("4500.00") + D(str(tenant["penalty_outstanding"]))
        assert D(str(tenant["advance_balance"])) == D("0.00")  # nothing is paid out

        # One liability per period, all still Deniz's: moving out neither cancels nor re-issues them.
        rows = stack.sql(
            "SELECT p.full_name || '|' || d.debtor_type || '|' || d.principal_amount FROM dues_liabilities d "
            f"JOIN persons p ON p.id = d.liable_person_id WHERE d.unit_id = {int(unit)} AND d.status <> 'CANCELLED' "
            "ORDER BY d.id;").splitlines()
        assert rows == ["Deniz Arslan|TENANT|1500.00"] * 3

        # The owner is shown as jointly liable for the same debt without a second liability of their own.
        assert D(str(owner["principal_outstanding"])) == D("0.00")
        assert D(str(owner["jointly_liable_total"])) == D(str(tenant["total_outstanding"]))
        assert len(owner["jointly_liable_open_items"]) == 3
        ledger_invariants(api, fixture.manager, fixture.site_id, stage="SC-13-05-06")
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)
