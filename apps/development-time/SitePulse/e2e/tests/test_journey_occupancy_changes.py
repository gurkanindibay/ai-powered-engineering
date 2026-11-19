"""EPIC-13 J-10: residents and owners change after periods were accrued (state F6).

Executes the backend scenarios of .specify/features/EPIC-13/STORY-13-03-occupancy-changes.feature.
Every scenario builds its own isolated site (README section 5) and asserts `ledger_invariants()`
after each stage (README section 4).
"""
from __future__ import annotations

import os
from decimal import Decimal
from pathlib import Path

import pytest

from support.journey_attempts import JourneyManifest, teardown_sites
from support.journey_occupancy import (
    OccupancyJourney,
    build_base,
    build_f6,
    seed_tenant_occupancy,
    tenant_move_in,
)

E2E = Path(__file__).resolve().parents[1]
D = Decimal


@pytest.fixture
def journey_site(request, api, actors, stack):
    """Builds an isolated site per scenario and removes it afterwards (README section 5)."""
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys", run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"))
    built: list[OccupancyJourney] = []

    def build(kind: str = "F6", **options: object) -> OccupancyJourney:
        builder = build_f6 if kind == "F6" else build_base
        journey = builder(api=api, stack=stack, saas=saas, manifest=manifest, **options)
        built.append(journey)
        return journey

    try:
        yield build
    finally:
        manifest.save()
        teardown_sites(stack, manifest, restart=False)


def _party_names(j: OccupancyJourney, unit_number: int) -> dict[str, str]:
    """Names of the owner and the active tenant of record for a unit."""
    unit = int(j.unit_id(unit_number))
    return {
        "OWNER": j.stack.sql("SELECT p.full_name FROM unit_ownerships o JOIN persons p ON p.id = o.person_id "
                             f"WHERE o.unit_id = {unit} AND o.is_active ORDER BY o.id LIMIT 1;"),
        "TENANT": j.stack.sql("SELECT p.full_name FROM unit_occupancies o JOIN persons p ON p.id = o.person_id "
                              f"WHERE o.unit_id = {unit} AND o.is_active AND o.occupancy_type = 'TENANT' LIMIT 1;"),
    }


@pytest.mark.covers("SC-13-03-01")
@pytest.mark.smoke
@pytest.mark.core
@pytest.mark.role_manager
def test_mid_month_move_in_splits_the_period(journey_site):
    j = journey_site()
    ekim = j.roles(2, "Ekim 2026")
    assert ekim == {"OWNER": D("483.87"), "TENANT": D("1016.13")}
    assert sum(ekim.values()) == D("1500.00")
    assert j.roles(2, "Eylül 2026") == {"OWNER": D("1500.00")}
    assert j.stack.sql(
        "SELECT o.start_date FROM unit_occupancies o JOIN persons p ON p.id = o.person_id "
        f"WHERE o.unit_id = {int(j.unit_id(2))} AND p.full_name = 'Selin Demir' AND o.occupancy_type = 'TENANT' "
        "ORDER BY o.id LIMIT 1;") == "2026-10-11"
    assert _party_names(j, 2)["OWNER"] == "Ahmet Yılmaz"
    j.invariants("SC-13-03-01")


@pytest.mark.covers("SC-13-03-04")
@pytest.mark.core
@pytest.mark.role_manager
def test_resident_added_after_accruals_is_charged_from_start_date(journey_site):
    j = journey_site()
    unit = int(j.unit_id(3))
    assert j.stack.sql(
        "SELECT o.occupancy_type || '|' || o.start_date || '|' || o.is_active FROM unit_occupancies o "
        f"JOIN persons p ON p.id = o.person_id WHERE o.unit_id = {unit} AND p.full_name = 'Oya Çelik';"
    ) == "TENANT|2026-11-18|true"
    assert j.stack.sql(f"SELECT p.full_name FROM units u JOIN persons p ON p.id = u.tenant_person_id WHERE u.id = {unit};") == "Oya Çelik"
    assert _party_names(j, 3)["OWNER"] == "Burak Şahin"
    assert j.roles(3, "Eylül 2026") == {"OWNER": D("1500.00")}
    assert j.roles(3, "Ekim 2026") == {"OWNER": D("1500.00")}
    assert j.roles(3, "Kasım 2026") == {"OWNER": D("850.00"), "TENANT": D("650.00")}
    j.invariants("SC-13-03-04 before December")
    j.accrue("Aralık 2026", due="2026-12-10")
    assert j.roles(3, "Aralık 2026") == {"TENANT": D("1500.00")}
    j.invariants("SC-13-03-04 after December")


@pytest.mark.covers("SC-13-03-08")
@pytest.mark.edge
@pytest.mark.role_manager
@pytest.mark.parametrize(
    ("period", "due", "move_in", "owner_share", "tenant_share"),
    [
        ("Ekim 2026", "2026-10-10", "2026-10-01", "0.00", "1500.00"),
        ("Ekim 2026", "2026-10-10", "2026-10-31", "1451.61", "48.39"),
        ("Kasım 2026", "2026-11-10", "2026-11-16", "750.00", "750.00"),
        ("Şubat 2028", "2028-02-10", "2028-02-15", "724.14", "775.86"),
        ("Şubat 2027", "2027-02-10", "2027-02-15", "750.00", "750.00"),
    ],
)
def test_proration_respects_month_length_and_edge_days(journey_site, period, due, move_in, owner_share, tenant_share):
    j = journey_site("BASE", vacate_a2=False)
    seed_tenant_occupancy(j, 3, "Selin Demir", move_in)
    j.accrue(period, due=due)
    shares = j.roles(3, period)
    assert shares.get("OWNER", D("0.00")) == D(owner_share)
    assert shares.get("TENANT", D("0.00")) == D(tenant_share)
    assert sum(shares.values()) == D("1500.00")
    j.invariants("SC-13-03-08")


@pytest.mark.covers("SC-13-03-13")
@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.parametrize(
    ("enabled", "owner_share", "tenant_share"),
    [(True, "483.87", "1016.13"), (False, "0.00", "1500.00")],
    ids=["enabled", "disabled"],
)
def test_switching_proration_changes_responsibility(journey_site, enabled, owner_share, tenant_share):
    j = journey_site("BASE", vacate_a2=False, proration=enabled)
    j.clock.advance_to("2026-10-11")
    tenant_move_in(j, 3, "Oya Çelik", "oya")
    j.clock.advance_to("2026-10-20")
    j.accrue("Ekim 2026")
    shares = j.roles(3, "Ekim 2026")
    assert shares.get("OWNER", D("0.00")) == D(owner_share)
    assert shares.get("TENANT", D("0.00")) == D(tenant_share)
    j.invariants("SC-13-03-13")


@pytest.mark.covers("SC-13-03-15")
@pytest.mark.core
@pytest.mark.role_manager
def test_unit_created_mid_month_is_billed_for_chargeable_days(journey_site):
    j = journey_site("BASE", vacate_a2=False)
    unit = int(j.unit_id(3))
    j.stack.sql(f"UPDATE units SET created_at = TIMESTAMPTZ '2026-11-16 09:00:00+03' WHERE id = {unit};")
    j.stack.restart_backend()
    j.manager = j.api.login(j.fixture.manager_email, j.fixture.manager_password)
    j.accrue("Kasım 2026")
    assert j.roles(3, "Kasım 2026") == {"OWNER": D("750.00")}
    j.invariants("SC-13-03-15")
