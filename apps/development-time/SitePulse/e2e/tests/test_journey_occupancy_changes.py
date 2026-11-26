"""EPIC-13 J-10: residents and owners change after periods were accrued (state F6).

Executes the scenarios of .specify/features/EPIC-13/STORY-13-03-occupancy-changes.feature.
Every scenario builds its own isolated site (README section 5) and asserts `ledger_invariants()`
after each stage (README section 4). SC-13-03-03 is the GUI layer of the per-person split: the
former and the current tenant each sign in and see only the debt that names them.
"""
from __future__ import annotations

import os
from decimal import Decimal
from pathlib import Path

import pytest

from pages import ResidentHome
from pages.login import LoginPage
from support.flutter import by_id, by_id_prefix, text_of
from support.journey_gui import page_lines, resident_email
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
from support.money import format_try, parse_try

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
    # Shares are asserted by role here; SC-13-03-21 proves every liability row names its
    # liable person, and the owner and tenant of record are asserted above.
    assert j.roles(3, "Kasım 2026") == {"OWNER": D("850.00"), "TENANT": D("650.00")}
    j.invariants("SC-13-03-04 before December")
    j.accrue("Aralık 2026", due="2026-12-10")
    assert j.roles(3, "Aralık 2026") == {"TENANT": D("1500.00")}
    j.invariants("SC-13-03-04 after December")


@pytest.mark.covers("SC-13-03-06")
@pytest.mark.edge
@pytest.mark.role_manager
def test_title_transfer_keeps_the_sellers_advance(journey_site):
    j = journey_site("F2")
    unit = j.unit_id(4)
    j.api.record_manual_payment(
        j.manager, unit, D("500.00"), "Ahmet Yılmaz", payer_role="OWNER",
        idempotency_key="sc-13-03-06-seller-advance",
    )
    assert j.stack.sql(
        f"SELECT balance FROM advance_balances WHERE unit_id = {int(unit)} AND debtor_type = 'OWNER';"
    ) == "500.00"
    j.invariants("SC-13-03-06 before the sale")

    sell_unit(j, 4, "Gül Tanrıverdi", "gul")
    j.invariants("SC-13-03-06 after the sale")

    seller = j.people["Ahmet Yılmaz"]
    assert j.stack.sql(
        "SELECT COALESCE((SELECT balance FROM person_advance_holds "
        f"WHERE unit_id = {int(unit)} AND person_id = {int(seller)} AND debtor_type = 'OWNER'), 0)::text;"
    ) == "500.00"
    assert j.stack.sql(
        "SELECT COALESCE((SELECT balance FROM advance_balances "
        f"WHERE unit_id = {int(unit)} AND debtor_type = 'OWNER'), 0)::text;"
    ) == "0.00"
    flat = next(
        item for item in j.api.site_overview(j.manager, j.site_id)["flats"]
        if str(item["id"]) == str(unit)
    )
    assert D(flat["advance_balance"]) == D("0.00")
    assert D(flat["amount_due"]) == D("0.00")

    # The money is still the seller's: only a second manager can release it.
    reviewer = second_manager(j)
    created = j.api.call(
        "POST",
        f"/api/v1/site-admin/units/{unit}/advance-exit-settlements?site_id={j.site_id}",
        j.manager.token,
        body={
            "request_key": "sc-13-03-06-seller-payout",
            "kind": "PAYOUT",
            "source_debtor": "OWNER",
            "beneficiary_name": "Ahmet Yılmaz",
            "beneficiary_person_id": str(seller),
            "amount": "500.00",
        },
    )
    assert created["status"] == "PENDING"
    assert j.stack.sql(
        "SELECT COALESCE((SELECT balance FROM person_advance_holds "
        f"WHERE unit_id = {int(unit)} AND person_id = {int(seller)} AND debtor_type = 'OWNER'), 0)::text;"
    ) == "500.00", "a pending request moves nothing"
    j.api.call(
        "POST",
        f"/api/v1/site-admin/advance-exit-settlements/{created['id']}/decide",
        reviewer.token,
        body={"approve": True, "payment_reference": "E2E-SELLER-ADVANCE-1", "note": None},
    )
    assert j.stack.sql(
        "SELECT COALESCE((SELECT balance FROM person_advance_holds "
        f"WHERE unit_id = {int(unit)} AND person_id = {int(seller)} AND debtor_type = 'OWNER'), 0)::text;"
    ) == "0.00"
    assert j.stack.sql(
        f"SELECT COUNT(*) FROM advance_exit_disbursements WHERE settlement_id = {int(created['id'])};"
    ) == "1"
    j.invariants("SC-13-03-06 after the payout")


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

    # November is split between the tenants and the owner (SC-13-05-18).
    assert j.shares(2, "Kasım 2026") == {"Selin Demir": D("700.00"), "Mert Kılıç": D("500.00"), "Ahmet Yılmaz": D("300.00")}
    assert j.roles(2, "Kasım 2026") == {"TENANT": D("1200.00"), "OWNER": D("300.00")}
    assert j.shares(2, "Aralık 2026") == {"Ahmet Yılmaz": D("1500.00")}
    assert j.roles(2, "Aralık 2026") == {"OWNER": D("1500.00")}
    assert {row["due"] for row in j.share_rows(2, "Aralık 2026")} == {"2026-12-05"}
    assert [row["name"] for row in j.share_rows(2, "Aralık 2026")] == ["Ahmet Yılmaz"]
    assert [row["name"] for row in j.share_rows(2, "Kasım 2026") if row["debtor"] == "OWNER"] == ["Ahmet Yılmaz"]
    assert {row["due"] for row in j.share_rows(2, "Kasım 2026") if row["debtor"] == "OWNER"} == {"2026-12-05"}
    assert {row["name"] for row in j.share_rows(2, "Kasım 2026") if row["debtor"] == "TENANT"} == {"Selin Demir", "Mert Kılıç"}

    unit = int(j.unit_id(2))
    joint = j.stack.sql(
        "SELECT p.full_name || '|' || tp.full_name || '|' || d.principal_amount "
        "FROM dues_liability_joint_owners jo "
        "JOIN persons p ON p.id = jo.owner_person_id "
        "JOIN persons tp ON tp.id = jo.tenant_person_id "
        "JOIN dues_liabilities d ON d.id = jo.due_id "
        f"WHERE d.unit_id = {unit} AND d.period = 'Kasım 2026' AND d.status <> 'CANCELLED' "
        "ORDER BY d.id;"
    ).splitlines()
    assert "Ahmet Yılmaz|Mert Kılıç|500.00" in joint
    assert "Ahmet Yılmaz|Selin Demir|700.00" in joint

    j.invariants("SC-13-05-18")


@pytest.mark.covers("SC-13-05-18")
@pytest.mark.core
@pytest.mark.role_manager
def test_tenant_left_without_notice_delayed_approval_sets_due_date_to_approval_date(journey_site):
    j = journey_site("F6")
    j.clock.advance_to("2026-12-01")
    j.accrue("Aralık 2026", due="2026-12-10")
    j.clock.advance_to("2026-12-05")
    transition(j, 2, "MOVE_OUT", effective_date="2026-11-25")
    j.clock.advance_to("2026-12-09")
    reviewer = second_manager(j)
    for correction in j.api.call("GET", "/api/v1/accrual-corrections", reviewer.token):
        if correction.get("status") == "PENDING":
            j.api.call("POST", f"/api/v1/accrual-corrections/{correction['id']}/decide", reviewer.token,
                       body={"approve": True, "note": "SC-13-05-18 delayed split approved"})

    assert j.shares(2, "Kasım 2026") == {"Selin Demir": D("700.00"), "Mert Kılıç": D("500.00"), "Ahmet Yılmaz": D("300.00")}
    assert {row["due"] for row in j.share_rows(2, "Aralık 2026")} == {"2026-12-09"}
    assert {row["due"] for row in j.share_rows(2, "Kasım 2026") if row["debtor"] == "OWNER"} == {"2026-12-09"}
    assert [row["name"] for row in j.share_rows(2, "Aralık 2026")] == ["Ahmet Yılmaz"]


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


@pytest.mark.covers("SC-13-05-09")
@pytest.mark.edge
@pytest.mark.role_manager
def test_move_out_after_accrual_resplits_open_liability(journey_site):
    j = journey_site("F6")
    j.clock.advance_to("2026-11-26")

    shares_before = j.shares(2, "Kasım 2026")
    transition(j, 2, "MOVE_OUT", effective_date="2026-11-25")

    reviewer = second_manager(j)
    pending = [
        c for c in j.api.call("GET", "/api/v1/accrual-corrections", reviewer.token)
        if c.get("status") == "PENDING"
    ]
    assert len(pending) >= 1
    assert j.shares(2, "Kasım 2026") == shares_before

    for correction in pending:
        j.api.call(
            "POST",
            f"/api/v1/accrual-corrections/{correction['id']}/decide",
            reviewer.token,
            body={"approve": True, "note": "SC-13-05-09 split approved"},
        )

    assert j.shares(2, "Kasım 2026") == {
        "Selin Demir": D("700.00"),
        "Mert Kılıç": D("500.00"),
        "Ahmet Yılmaz": D("300.00"),
    }
    kasim_rows = j.share_rows(2, "Kasım 2026")
    owner_row = next(r for r in kasim_rows if r["debtor"] == "OWNER")
    mert_row = next(r for r in kasim_rows if r["name"] == "Mert Kılıç")
    assert owner_row["due"] == "2026-11-26"
    assert (mert_row["effective_due"] or mert_row["due"]) == "2026-11-15"

    j.invariants("SC-13-05-09")


@pytest.mark.covers("SC-13-03-02")
@pytest.mark.core
@pytest.mark.role_manager
def test_tenant_replaced_mid_month_keeps_the_old_debt_with_the_old_tenant(journey_site):
    j = journey_site()
    assert j.shares(2, "Kasım 2026") == {"Selin Demir": D("700.00"), "Mert Kılıç": D("800.00")}

    ekim = j.share_rows(2, "Ekim 2026")
    selin_row = next(row for row in ekim if row["debtor"] == "TENANT")
    assert selin_row["name"] == "Selin Demir"
    assert selin_row["principal"] == D("1016.13")
    assert selin_row["effective_due"] == "2026-10-11", "October was accrued on the 11th"

    # Mert replaced Selin on 2026-11-15: nothing before that day is his.
    earlier = j.share_rows(2, "Eylül 2026") + ekim
    assert all(row["name"] != "Mert Kılıç" for row in earlier), earlier

    # The fee counts 39 days from the effective due date (2026-10-11), not 2026-10-10.
    j.clock.tick()
    assert _penalty(j, 2, "Ekim 2026") == D("66.05")
    j.invariants("SC-13-03-02")


@pytest.mark.covers("SC-13-03-07")
@pytest.mark.edge
@pytest.mark.role_manager
def test_handover_on_the_same_day_splits_the_month(journey_site):
    j = journey_site()
    j.clock.advance_to("2026-12-12")
    tenant_move_in(j, 2, "Nil Acar", "nil")
    j.accrue("Aralık 2026", due="2026-12-10")

    sessions = j.stack.sql(
        "SELECT p.full_name || '|' || o.start_date || '|' || COALESCE(o.end_date::text, '') "
        "FROM unit_occupancies o JOIN persons p ON p.id = o.person_id "
        f"WHERE o.unit_id = {int(j.unit_id(2))} ORDER BY o.start_date, o.id;"
    ).splitlines()
    assert "Mert Kılıç|2026-11-15|2026-12-12" in sessions, sessions
    assert "Nil Acar|2026-12-12|" in sessions, sessions

    shares = j.shares(2, "Aralık 2026")
    assert shares == {"Mert Kılıç": D("532.26"), "Nil Acar": D("967.74")}
    assert sum(shares.values()) == D("1500.00"), "no day is charged to two debtors and none to nobody"
    j.invariants("SC-13-03-07")


@pytest.mark.covers("SC-13-03-09")
@pytest.mark.edge
@pytest.mark.role_manager
@pytest.mark.parametrize(
    ("tariff", "move_ins", "shares"),
    [
        ("1500.01", [("2026-11-16", "Selin Demir", "selin")],
         [("Burak Şahin", "750.01"), ("Selin Demir", "750.00")]),
        ("1000.00", [("2026-11-11", "Selin Demir", "selin"), ("2026-11-21", "Mert Kılıç", "mert")],
         [("Burak Şahin", "333.33"), ("Selin Demir", "333.33"), ("Mert Kılıç", "333.34")]),
    ],
    ids=["two-segments", "three-segments"],
)
def test_a_tariff_that_does_not_divide_evenly_keeps_every_kurus(journey_site, tariff, move_ins, shares):
    j = journey_site("BASE", vacate_a2=False)
    unit = int(j.unit_id(3))
    j.stack.sql(
        "BEGIN; "
        f"DELETE FROM unit_occupancies WHERE unit_id = {unit}; "
        "UPDATE units SET tenant_person_id = NULL, occupancy_status = 'VACANT', "
        f"monthly_tariff_override = {tariff} WHERE id = {unit}; COMMIT;"
    )
    j.stack.restart_backend()
    j.clock.set_date(j.clock.current_date.isoformat())
    j.manager = j.api.login(j.fixture.manager_email, j.fixture.manager_password)

    for move_in, name, key in move_ins:
        j.clock.advance_to(move_in)
        tenant_move_in(j, 3, name, key)
    j.accrue("Kasım 2026")

    rows = [(row["name"], f"{row['principal']:.2f}") for row in j.share_rows(3, "Kasım 2026")]
    assert rows == shares, "shares are in day order and the last one carries the remainder"
    assert sum(D(amount) for _, amount in rows) == D(tariff)
    j.invariants("SC-13-03-09")


@pytest.mark.covers("SC-13-03-21")
@pytest.mark.core
@pytest.mark.role_manager
def test_every_liability_row_names_the_person_who_owes_it(journey_site):
    j = journey_site()
    for unit_number, expected in [(2, "Ahmet Yılmaz"), (3, "Burak Şahin")]:
        owner_rows = [
            row
            for period in ("Eylül 2026", "Ekim 2026", "Kasım 2026")
            for row in j.share_rows(unit_number, period)
            if row["debtor"] == "OWNER"
        ]
        assert owner_rows, f"A-{unit_number} has owner liabilities"
        assert {row["name"] for row in owner_rows} == {expected}, owner_rows

    # A-4 was sold on 2026-11-05: the seller keeps the months accrued before it, and the
    # sale month splits by day between the seller (days 1-4) and the buyer (days 5-30).
    for period, expected in [
        ("Eylül 2026", {"Ahmet Yılmaz": D("1500.00")}),
        ("Ekim 2026", {"Ahmet Yılmaz": D("1500.00")}),
        ("Kasım 2026", {"Ahmet Yılmaz": D("200.00"), "Gül Tanrıverdi": D("1300.00")}),
    ]:
        owner_rows = [row for row in j.share_rows(4, period) if row["debtor"] == "OWNER"]
        assert {row["name"]: row["principal"] for row in owner_rows} == expected, (period, owner_rows)

    # No operational liability is left without the person who owes it.
    for unit_number in (2, 3, 4):
        for period in ("Eylül 2026", "Ekim 2026", "Kasım 2026"):
            rows = j.share_rows(unit_number, period)
            assert all(row["name"] for row in rows), (unit_number, period, rows)

    assert j.shares(3, "Kasım 2026") == {"Oya Çelik": D("650.00"), "Burak Şahin": D("850.00")}
    assert j.shares(3, "Eylül 2026") == {"Burak Şahin": D("1500.00")}
    assert j.shares(3, "Ekim 2026") == {"Burak Şahin": D("1500.00")}
    assert all(row["name"] != "Oya Çelik" for row in j.share_rows(3, "Ekim 2026"))
    j.invariants("SC-13-03-21")


def _penalty(j: OccupancyJourney, unit_number: int, period: str) -> Decimal:
    return D(j.stack.sql(
        "SELECT delay_penalty FROM dues_liabilities "
        f"WHERE unit_id = {int(j.unit_id(unit_number))} AND period = '{period}' "
        "AND debtor_type = 'TENANT' AND status <> 'CANCELLED' ORDER BY id LIMIT 1;"
    ))



def _login_account(j: OccupancyJourney, full_name: str) -> None:
    """Gives a person recorded by an occupancy transition a login, as a resident needs one."""
    person = int(j.people[full_name])
    email = j.stack.sql(f"SELECT email FROM persons WHERE id = {person};")
    password_hash = j.stack.sql(
        f"SELECT password_hash FROM users WHERE id = {int(j.manifest.user_ids[0])};")
    j.stack.sql(
        "INSERT INTO users (site_id, email, password_hash, role, is_active, must_change_password, person_id) "
        f"VALUES ({int(j.site_id)}, '{email}', '{password_hash}', 'HOME_RESIDENT', TRUE, FALSE, {person});"
    )
    j.stack.restart_backend()
    j.clock.set_date(j.clock.current_date.isoformat())
    j.manager = j.api.login(j.fixture.manager_email, j.fixture.manager_password)


def _resident_statement(page, login_page, j, person_name: str) -> tuple[list[str], Decimal, list[tuple[str, str]]]:
    """Signs a resident in and reads the statement their dashboard opens.

    Returns the page's visible lines, the tenant section's total, and the period rows the
    statement attributes to that person.
    """
    email = resident_email(j.stack, j.fixture, person_name)
    session = j.api.login(email, j.fixture.manager_password)
    statement = j.api.call(
        "GET", f"/api/v1/residents/{j.unit_id(2)}/statement?site_id={j.site_id}", session.token)
    tenant = next(debtor for debtor in statement["debtors"] if debtor["debtor_type"] == "TENANT")
    expected = [
        (item["period"], D(str(item["total_outstanding"]))) for item in tenant["open_items"]
    ]

    resident = page.context.new_page()
    try:
        LoginPage(resident, login_page.base_url).open().login("resident", email, j.fixture.manager_password)
        ResidentHome(resident).wait()
        by_id(resident, "resident_statement_entry").click()
        total_element = by_id_prefix(resident, "statement_total_tenant").first
        total_element.wait_for(timeout=20_000)
        return page_lines(resident), parse_try(text_of(total_element)), expected
    finally:
        resident.close()


@pytest.mark.covers("SC-13-03-03")
@pytest.mark.role_resident
def test_former_and_current_tenant_see_only_their_own_debt(journey_site, page, login_page):
    j = journey_site()
    # The transition records the incoming tenant as a person; the scenario needs both residents
    # to sign in, so this one gets a login the way the second manager does.
    _login_account(j, "Mert Kılıç")

    # Selin owes her Ekim share with its penalty and her Kasım share, and nothing later.
    selin, selin_total, selin_rows = _resident_statement(page, login_page, j, "Selin Demir")
    assert [period for period, _ in selin_rows] == ["Ekim 2026", "Kasım 2026"], "her own periods only"
    assert selin_total == sum(amount for _, amount in selin_rows), selin
    for period, amount in selin_rows:
        assert f"{period} · {format_try(amount)}" in selin, selin
    assert "Aralık 2026" not in selin, "nothing after her 2026-11-14 share is hers"

    # Mert owes only the days he held the unit.
    mert, mert_total, mert_rows = _resident_statement(page, login_page, j, "Mert Kılıç")
    assert [period for period, _ in mert_rows] == ["Kasım 2026"], "the replaced tenant's October debt is not his"
    assert mert_total == sum(amount for _, amount in mert_rows), mert
    assert f"Kasım 2026 · {format_try(mert_rows[0][1])}" in mert, mert
    assert "Ekim 2026" not in mert, mert
    assert selin_total > mert_total
