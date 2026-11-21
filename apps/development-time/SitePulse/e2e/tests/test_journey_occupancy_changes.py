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
    second_manager,
    sell_unit,
    seed_tenant_occupancy,
    tenant_move_in,
    transition,
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
    ekim = j.shares(2, "Ekim 2026")
    assert ekim == {"Ahmet Yılmaz": D("483.87"), "Selin Demir": D("1016.13")}
    assert sum(ekim.values()) == D("1500.00")
    assert j.shares(2, "Eylül 2026") == {"Ahmet Yılmaz": D("1500.00")}
    assert j.stack.sql(
        "SELECT o.start_date FROM unit_occupancies o JOIN persons p ON p.id = o.person_id "
        f"WHERE o.unit_id = {int(j.unit_id(2))} AND p.full_name = 'Selin Demir' AND o.occupancy_type = 'TENANT' "
        "ORDER BY o.id LIMIT 1;") == "2026-10-11"
    # The accrual records the liable person on tenant rows only: Selin's Ekim row names her.
    assert j.stack.sql(
        f"SELECT liable_person_id FROM dues_liabilities WHERE unit_id = {int(j.unit_id(2))} "
        "AND period = 'Ekim 2026' AND debtor_type = 'TENANT' AND status <> 'CANCELLED';") == j.people["Selin Demir"]
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
    # The re-split rows carry no liable person id (pending SC-13-03-21), so shares are asserted by role;
    # the owner and tenant of record are asserted above.
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
    shares = j.shares(3, period)
    assert shares.get("Burak Şahin", D("0.00")) == D(owner_share)
    assert shares.get("Selin Demir", D("0.00")) == D(tenant_share)
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
    shares = j.shares(3, "Ekim 2026")
    assert shares.get("Burak Şahin", D("0.00")) == D(owner_share)
    assert shares.get("Oya Çelik", D("0.00")) == D(tenant_share)
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
    assert j.shares(3, "Kasım 2026") == {"Burak Şahin": D("750.00")}
    j.invariants("SC-13-03-15")



@pytest.mark.covers("SC-13-03-18")
@pytest.mark.core
@pytest.mark.role_manager
def test_sale_of_a_tenant_occupied_unit_with_the_same_tenant_is_not_split(journey_site):
    j = journey_site("BASE")
    j.clock.advance_to("2026-10-11")
    tenant_move_in(j, 2, "Selin Demir", "selin")
    j.clock.advance_to("2026-12-15")
    sell_unit(j, 2, "Gül Tanrıverdi", "gul", moves_in=False)
    j.accrue("Aralık 2026", due="2026-12-10")

    assert j.shares(2, "Aralık 2026") == {"Selin Demir": D("1500.00")}
    assert j.roles(2, "Aralık 2026") == {"TENANT": D("1500.00")}
    unit = int(j.unit_id(2))
    joint = j.stack.sql(
        "SELECT p.full_name || '|' || jo.liable_from || '|' || jo.liable_through "
        "FROM dues_liability_joint_owners jo JOIN persons p ON p.id = jo.owner_person_id "
        "JOIN dues_liabilities d ON d.id = jo.due_id "
        f"WHERE d.unit_id = {unit} AND d.period = 'Aralık 2026' AND d.status <> 'CANCELLED' "
        "ORDER BY jo.liable_from;").splitlines()
    assert joint == ["Ahmet Yılmaz|2026-12-01|2026-12-14", "Gül Tanrıverdi|2026-12-15|2026-12-31"]
    j.invariants("SC-13-03-18")


@pytest.mark.covers("SC-13-05-18")
@pytest.mark.core
@pytest.mark.role_manager
def test_tenant_left_without_notice_is_moved_out_at_the_real_date(journey_site):
    j = journey_site("F6")
    j.clock.advance_to("2026-12-01")
    j.accrue("Aralık 2026", due="2026-12-10")
    j.clock.advance_to("2026-12-05")
    transition(j, 2, "MOVE_OUT", effective_date="2026-11-25")
    reviewer = second_manager(j)
    for correction in j.api.call("GET", "/api/v1/accrual-corrections", reviewer.token):
        if correction.get("status") == "PENDING":
            j.api.call("POST", f"/api/v1/accrual-corrections/{correction['id']}/decide", reviewer.token,
                       body={"approve": True, "note": "SC-13-05-18 split approved"})

    # November is split between the tenants and the owner; rows re-issued by a correction carry no person (SC-13-03-21).
    assert j.roles(2, "Kasım 2026") == {"TENANT": D("1200.00"), "OWNER": D("300.00")}
    assert j.roles(2, "Aralık 2026") == {"OWNER": D("1500.00")}
    assert {row["due"] for row in j.share_rows(2, "Aralık 2026")} == {"2026-12-05"}
    j.invariants("SC-13-05-18")


@pytest.mark.covers("SC-13-03-11")
@pytest.mark.edge
@pytest.mark.role_manager
def test_duplicate_national_id_returns_match_without_second_person(journey_site):
    j = journey_site("F6")
    mert_id = int(j.people["Mert Kılıç"])
    tckn = "10000000146"

    # Step-up and record national id for Mert Kılıç
    j.api.call("POST", "/api/v1/auth/step-up", j.manager.token, body={"password": j.fixture.manager_password})
    j.api.call(
        "PUT", f"/api/v1/site-admin/persons/{mert_id}/national-id?site_id={j.site_id}", j.manager.token,
        body={"national_id": tckn},
    )
    # Manager moves in a tenant with the national id of "Mert Kılıç" under a different spelling of the name:
    # duplicate check detects the matching national ID
    candidates = j.api.call(
        "POST", f"/api/v1/site-admin/persons/duplicate-check?site_id={j.site_id}", j.manager.token,
        body={"full_name": "Mert Can Kılıç", "national_id": tckn},
    )
    assert len(candidates) >= 1
    match = candidates[0]
    assert match["person"]["person_id"] == mert_id
    assert "SAME_NATIONAL_ID" in match["reasons"]

    # Moving in uses the matched existing person instead of creating a duplicate
    transition(j, 5, "REPLACE_TENANT", person={"kind": "existing", "person_id": mert_id})

    # The people directory still lists one "Mert Kılıç"
    people_resp = j.api.call("GET", f"/api/v1/site-admin/persons?site_id={j.site_id}", j.manager.token)
    items = people_resp.get("items", people_resp) if isinstance(people_resp, dict) else people_resp
    mert_entries = [
        item["card"] if "card" in item else item
        for item in items
        if "mert" in (item.get("card", {}).get("full_name") or item.get("full_name", "")).lower()
    ]
    assert len(mert_entries) == 1
    assert mert_entries[0]["person_id"] == mert_id
    assert j.stack.sql(
        f"SELECT count(*) FROM persons WHERE site_id = {int(j.site_id)} AND deleted_at IS NULL AND lower(full_name) LIKE '%mert%';"
    ) == "1"

    j.invariants("SC-13-03-11")

