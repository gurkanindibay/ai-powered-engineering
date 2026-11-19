"""Reference fixture coverage for the Site Admin journey suite."""
from __future__ import annotations

import os
from decimal import Decimal
from pathlib import Path

import pytest

from support.journey_attempts import (
    JourneyManifest,
    ledger_invariants,
    site_in_state,
    teardown_with_evidence,
)

E2E = Path(__file__).resolve().parents[1]
EXPECTED = {
    "F0": {"blocks": 0, "units": 0, "people": 0, "accounts": 0},
    "F1": {"blocks": 1, "units": 7, "people": 0, "accounts": 0},
    "F2": {"blocks": 1, "units": 7, "people": 7, "accounts": 7},
}


@pytest.mark.covers("SC-13-07-01")
@pytest.mark.core
@pytest.mark.parametrize("state", ["F0", "F1", "F2"])
def test_site_admin_reference_fixtures(state, request, api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    fixture = None
    try:
        fixture = site_in_state(state, api=api, stack=stack, saas=saas, manifest=manifest)
        overview = ledger_invariants(api, fixture.manager, fixture.site_id, stage=state)
        expected = EXPECTED[state]

        assert len(overview["flats"]) == expected["units"]
        assert len(fixture.unit_ids) == expected["units"]
        assert stack.sql(f"SELECT COUNT(*) FROM blocks WHERE site_id = {int(fixture.site_id)};") == str(expected["blocks"])
        assert Decimal(str(overview["summary"]["total_overdue_with_interest"])) == Decimal("0.00")
        assert Decimal(str(overview["summary"]["total_advance_balance"])) == Decimal("0.00")
        assert not overview["available_periods"]
        assert stack.sql(
            f"SELECT COUNT(*) FROM persons WHERE site_id = {int(fixture.site_id)} "
            "AND person_type IN ('HOME_OWNER', 'HOME_RESIDENT');"
        ) == str(expected["people"])
        assert stack.sql(
            f"SELECT COUNT(*) FROM users WHERE site_id = {int(fixture.site_id)} "
            "AND role IN ('HOME_OWNER', 'HOME_RESIDENT') AND is_active AND NOT must_change_password;"
        ) == str(expected["accounts"])
        assert stack.sql(f"SELECT COUNT(*) FROM dues_periods WHERE site_id = {int(fixture.site_id)};") == "0"
        assert stack.sql(
            "SELECT COUNT(*) FROM dues_liabilities d JOIN units u ON u.id = d.unit_id "
            f"WHERE u.site_id = {int(fixture.site_id)};"
        ) == "0"
        assert stack.sql(f"SELECT COUNT(*) FROM payment_receipts WHERE site_id = {int(fixture.site_id)};") == "0"
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
    else:
        site_ids = list(manifest.site_ids)
        user_ids = list(manifest.user_ids)
        person_ids = list(manifest.person_ids)
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)
        assert all(stack.sql(f"SELECT COUNT(*) FROM sites WHERE id = {int(site_id)};") == "0" for site_id in site_ids)
        if user_ids:
            assert stack.sql(f"SELECT COUNT(*) FROM users WHERE id IN ({', '.join(user_ids)});") == "0"
        if person_ids:
            assert stack.sql(f"SELECT COUNT(*) FROM persons WHERE id IN ({', '.join(person_ids)});") == "0"
