"""EPIC-13: effective dates, due dates and late fees driven by the e2e clock (issue #270).

Every scenario builds an isolated site (README section 5), moves the controllable e2e clock and asserts
what the live API reports at that instant. The clock is a test/e2e build feature; the production
backend always reads the system clock.
"""
from __future__ import annotations

import os
from decimal import Decimal
from pathlib import Path

import pytest

from support.journey_attempts import JourneyManifest, teardown_sites
from support.journey_snapshots import current_section
from support.journey_occupancy import (
    OccupancyJourney,
    build_base,
    build_f6,
    second_manager,
    transition,
)

E2E = Path(__file__).resolve().parents[1]
D = Decimal
PERIOD = "Kasım 2026"
DUE = "2026-11-10"


@pytest.fixture
def clock_site(request, api, actors, stack):
    """Builds an isolated site per scenario and removes it afterwards."""
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys", run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"))

    def build(*, grace: int = 0, start: str = "2026-11-01") -> OccupancyJourney:
        j = build_base(api=api, stack=stack, saas=saas, manifest=manifest, start=start, vacate_a2=False)
        stack.sql(f"UPDATE sites SET grace_days = {int(grace)}, due_day = 10 WHERE id = {int(j.site_id)};")
        stack.restart_backend()
        j.manager = api.login(j.fixture.manager_email, j.fixture.manager_password)
        j.clock.set_date(start)
        return j

    try:
        yield build
    finally:
        manifest.save()
        teardown_sites(stack, manifest, restart=False)


@pytest.fixture
def f6_site(request, api, actors, stack):
    """The F6 reference site (journey plan section 3.1), isolated per scenario."""
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys", run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"))
    try:
        yield lambda: build_f6(api=api, stack=stack, saas=saas, manifest=manifest)
    finally:
        manifest.save()
        teardown_sites(stack, manifest, restart=False)


def rows_of(j: OccupancyJourney, unit_number: int, period: str = PERIOD) -> list[dict]:
    """Non-cancelled operational liabilities of a unit and period, whoever the liable person is."""
    raw = j.stack.sql(
        "SELECT debtor_type || '|' || principal_amount || '|' || due_date || '|' || "
        "COALESCE(effective_due_date::text, '') FROM dues_liabilities "
        f"WHERE unit_id = {int(j.unit_id(unit_number))} AND expense_type = 'OPERATIONAL_DUES' "
        f"AND period = '{period}' AND status <> 'CANCELLED' ORDER BY id;")
    rows = []
    for line in raw.splitlines():
        debtor, principal, due, effective = line.split("|")
        rows.append({"debtor": debtor, "principal": D(principal), "due": due, "effective_due": effective or due})
    return rows


def tenant_item(j: OccupancyJourney, unit_number: int, period: str = PERIOD) -> dict:
    """The tenant debtor's open statement item of a unit and period."""
    statement = j.api.resident_statement(j.manager, j.unit_id(unit_number))
    for debtor in statement["debtors"]:
        if debtor["debtor_type"] == "TENANT":
            for entry in debtor["open_items"]:
                if entry["period"] == period:
                    return entry
    raise AssertionError(f"no tenant item for unit {unit_number} and {period}")


def item(j: OccupancyJourney, unit_number: int, period: str = PERIOD) -> dict:
    """The open statement item of a unit and period (principal and fee outstanding), or an empty paid item."""
    statement = j.api.resident_statement(j.manager, j.unit_id(unit_number))
    for debtor in statement["debtors"]:
        for entry in debtor["open_items"]:
            if entry["period"] == period:
                return entry
    return {"principal_outstanding": "0.00", "penalty_outstanding": "0.00", "status": "PAID"}


def outstanding(entry: dict) -> tuple[Decimal, Decimal]:
    return D(str(entry["principal_outstanding"])), D(str(entry["penalty_outstanding"]))


@pytest.mark.covers("SC-13-04-10")
@pytest.mark.edge
@pytest.mark.role_manager
@pytest.mark.parametrize("grace,paid_on,fee,remaining", [
    (0, "2026-11-10", "0.00", "0.00"),
    (0, "2026-11-11", "2.50", "2.50"),
    (5, "2026-11-10", "0.00", "0.00"),
    (5, "2026-11-15", "0.00", "0.00"),
    (5, "2026-11-16", "15.00", "15.00"),
])
def test_grace_boundary_decides_whether_a_late_fee_is_charged(clock_site, grace, paid_on, fee, remaining):
    j = clock_site(grace=grace)
    j.accrue(PERIOD, DUE)
    j.clock.set_date(paid_on)
    j.api.record_manual_payment(j.manager, j.unit_id(1), D("1500.00"), "Ayşe Kaya", payment_date=f"{paid_on}T00:00:00Z")
    principal, penalty = outstanding(item(j, 1))
    assert principal == D(remaining)
    assert penalty == D("0.00")
    cleared = j.stack.sql(
        "SELECT COALESCE(sum(a.penalty_amount), 0) FROM payment_allocations a "
        "JOIN dues_liabilities d ON d.id = a.dues_liability_id "
        f"WHERE d.unit_id = {int(j.unit_id(1))} AND d.period = '{PERIOD}';")
    assert D(cleared) == D(fee)
    j.invariants("SC-13-04-10")


def cleared_fee(j: OccupancyJourney, unit_number: int, period: str = PERIOD) -> Decimal:
    """Late fee the payments of a unit's period cleared."""
    return D(j.stack.sql(
        "SELECT COALESCE(sum(a.penalty_amount), 0) FROM payment_allocations a "
        "JOIN dues_liabilities d ON d.id = a.dues_liability_id "
        f"WHERE d.unit_id = {int(j.unit_id(unit_number))} AND d.period = '{period}';"))


def status_of(entry: dict) -> str:
    """PENDING until a late fee starts to run, then OVERDUE; a settled liability has no open item."""
    if D(str(entry["principal_outstanding"])) == 0:
        return "PAID"
    return "OVERDUE" if D(str(entry["penalty_outstanding"])) > 0 else "PENDING"


@pytest.mark.covers("SC-13-11-01")
@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.parametrize("grace,event,status,total", [
    (0, "read:2026-11-09", "PENDING", "1500.00"),
    (0, "read:2026-11-10", "PENDING", "1500.00"),
    (0, "read:2026-11-11", "OVERDUE", "1502.50"),
    (5, "read:2026-11-15", "PENDING", "1500.00"),
    (5, "read:2026-11-16", "OVERDUE", "1515.00"),
    (0, "pay:500.00:2026-11-10", "PENDING", "1000.00"),
    (0, "pay:1500.00:2026-11-10", "PAID", "0.00"),
    (0, "pay:1502.50:2026-11-11", "PAID", "0.00"),
    (0, "cancel:2026-11-12", "CANCELLED", "0.00"),
])
def test_liability_moves_through_pending_overdue_paid_and_cancelled(clock_site, grace, event, status, total):
    j = clock_site(grace=grace)
    j.accrue(PERIOD, DUE)
    kind, *args = event.split(":")
    day = args[-1]
    j.clock.set_date(day)
    j.clock.tick()
    if kind == "pay":
        j.api.record_manual_payment(j.manager, j.unit_id(1), D(args[0]), "Ayşe Kaya", payment_date=f"{day}T00:00:00Z")
    if kind == "cancel":
        due_id = j.api.resident_statement(j.manager, j.unit_id(1))["debtors"][0]["open_items"][0]["due_id"]
        j.api.call("POST", "/api/v1/accrual-corrections", j.manager.token,
                   body={"due_id": due_id, "kind": "CANCEL", "reason": "Cancelled by the manager"})
        reviewer = second_manager(j)
        pending = [c for c in j.api.call("GET", "/api/v1/accrual-corrections", reviewer.token) if c.get("status") == "PENDING"]
        for correction in pending:
            j.api.call("POST", f"/api/v1/accrual-corrections/{correction['id']}/decide", reviewer.token,
                       body={"approve": True, "note": "Cancellation approved"})
        row = j.stack.sql(
            f"SELECT status FROM dues_liabilities WHERE unit_id = {int(j.unit_id(1))} AND period = '{PERIOD}' "
            "AND debtor_type = 'OWNER' ORDER BY id LIMIT 1;")
        assert row == "CANCELLED"
        assert D(str(outstanding(item(j, 1))[0])) == D("0.00")
        return
    entry = item(j, 1)
    assert status_of(entry) == status
    assert sum(outstanding(entry)) == D(total)


@pytest.mark.covers("SC-13-09-03")
@pytest.mark.core
@pytest.mark.role_manager
def test_backdated_payment_recalculates_fees_using_its_value_date(clock_site):
    j = clock_site()
    j.accrue(PERIOD, DUE)
    j.clock.set_date("2026-11-19")
    j.clock.tick()
    assert outstanding(item(j, 1)) == (D("1500.00"), D("22.50"))
    j.api.record_manual_payment(j.manager, j.unit_id(1), D("1500.00"), "Ayşe Kaya", payment_date="2026-11-10T00:00:00Z")
    assert outstanding(item(j, 1)) == (D("0.00"), D("0.00"))
    adjustment = j.stack.sql(
        "SELECT kind || '|' || amount FROM ledger_adjustments a JOIN dues_liabilities d ON d.id = a.due_id "
        f"WHERE d.unit_id = {int(j.unit_id(1))} AND d.period = '{PERIOD}' ORDER BY a.id;")
    assert adjustment == "PENALTY_REEVALUATION|22.50"
    receipts = j.stack.sql(f"SELECT count(*) FROM payment_receipts WHERE unit_id = {int(j.unit_id(1))};")
    assert receipts == "1"
    j.invariants("SC-13-09-03")


@pytest.mark.covers("SC-13-05-15")
@pytest.mark.edge
@pytest.mark.role_manager
def test_late_fee_never_reopens_a_settled_liability(clock_site):
    j = clock_site()
    j.accrue(PERIOD, DUE)
    j.clock.set_date("2026-11-10")
    j.api.record_manual_payment(j.manager, j.unit_id(3), D("1500.00"), "Burak Şahin", payment_date="2026-11-10T00:00:00Z")
    assert outstanding(item(j, 3)) == (D("0.00"), D("0.00"))
    j.clock.advance_to("2026-12-10")
    j.clock.tick()
    assert outstanding(item(j, 3)) == (D("0.00"), D("0.00"))
    j.invariants("SC-13-05-15")


@pytest.mark.covers("SC-13-05-14")
@pytest.mark.edge
@pytest.mark.role_manager
def test_month_boundary_uses_istanbul_time_not_utc(clock_site):
    j = clock_site(start="2026-11-01")
    j.stack.sql(f"UPDATE sites SET accrual_day = 1 WHERE id = {int(j.site_id)};")
    j.stack.restart_backend()
    j.manager = j.api.login(j.fixture.manager_email, j.fixture.manager_password)
    j.clock.set_date("2026-11-01")
    j.clock.tick()
    december = "Aralık 2026"

    def december_rows() -> int:
        return int(j.stack.sql(
            "SELECT count(*) FROM dues_liabilities d JOIN units u ON u.id = d.unit_id "
            f"WHERE u.site_id = {int(j.site_id)} AND d.period = '{december}';"))

    j.clock.set_instant("2026-11-30T20:30:00Z")   # 23:30 in Istanbul, still November
    j.clock.tick()
    assert december_rows() == 0
    j.clock.set_instant("2026-11-30T21:30:00Z")   # 00:30 on 1 December in Istanbul, still 30 November UTC
    j.clock.tick()
    first = december_rows()
    assert first > 0
    j.clock.tick()
    assert december_rows() == first              # exactly once
    j.invariants("SC-13-05-14")


@pytest.mark.covers("SC-13-03-12")
@pytest.mark.core
@pytest.mark.role_manager
def test_owner_moves_in_after_the_tenant_leaves_and_takes_the_dues_back(f6_site):
    j = f6_site()
    j.clock.advance_to("2026-12-01")
    transition(j, 2, "MOVE_OUT")
    transition(j, 2, "OWNER_MOVE_IN", person_id=int(j.people["Ahmet Yılmaz"]))
    j.accrue("Aralık 2026", "2026-12-10")
    assert j.shares(2, "Aralık 2026") == {"Ahmet Yılmaz": D("1500.00")}
    assert j.roles(2, "Aralık 2026") == {"OWNER": D("1500.00")}
    j.invariants("SC-13-03-12")


@pytest.mark.covers("SC-13-03-10")
@pytest.mark.edge
@pytest.mark.role_manager
def test_one_person_who_owns_one_unit_and_rents_another_is_billed_in_each_role(f6_site):
    j = f6_site()
    j.clock.advance_to("2026-12-01")
    transition(j, 2, "MOVE_OUT")
    transition(j, 5, "REPLACE_TENANT", person_id=int(j.people["Ahmet Yılmaz"]))
    j.accrue("Aralık 2026", "2026-12-10")
    assert j.roles(2, "Aralık 2026") == {"OWNER": D("1500.00")}
    assert j.shares(5, "Aralık 2026") == {"Ahmet Yılmaz": D("1500.00")}
    assert j.roles(5, "Aralık 2026") == {"TENANT": D("1500.00")}
    listed = {debtor["debtor_type"] for debtor in j.api.resident_statement(j.manager, j.unit_id(5))["debtors"]}
    assert "TENANT" in listed
    assert {debtor["debtor_type"] for debtor in j.api.resident_statement(j.manager, j.unit_id(2))["debtors"]} >= {"OWNER"}
    people = j.stack.sql(f"SELECT count(*) FROM persons WHERE site_id = {int(j.site_id)} AND full_name = 'Ahmet Yılmaz';")
    assert people == "1"
    j.invariants("SC-13-03-10")


@pytest.mark.covers("SC-13-03-17")
@pytest.mark.edge
@pytest.mark.role_manager
@pytest.mark.parametrize("start,created,share,share_due,fee", [
    ("2026-11-05", "2026-11-05", "1300.00", "2026-11-10", "19.50"),
    ("2026-11-15", "2026-11-15", "800.00", "2026-11-15", "5.33"),
    ("2026-11-18", "2026-11-18", "650.00", "2026-11-18", "1.08"),
    ("2026-11-05", "2026-11-18", "1300.00", "2026-11-18", "2.17"),
])
def test_share_starting_after_the_period_due_date_is_not_late_before_it_existed(
        clock_site, start, created, share, share_due, fee):
    j = clock_site()
    j.accrue(PERIOD, DUE)
    j.clock.set_date(created)
    j.api.call(
        "POST", f"/api/v1/site-admin/units/{j.unit_id(3)}/occupancy-transitions?site_id={j.site_id}", j.manager.token,
        body={"command": "TENANT_MOVE_IN", "effective_date": start, "full_name": "Oya Çelik",
              "email": f"{j.manifest.attempt_id[:8]}.oya@journey.e2e.test".lower(), "phone": "+90 533 000 00 00"})
    reviewer = second_manager(j)
    for correction in j.api.call("GET", "/api/v1/accrual-corrections", reviewer.token):
        if correction.get("status") == "PENDING":
            j.api.call("POST", f"/api/v1/accrual-corrections/{correction['id']}/decide", reviewer.token,
                       body={"approve": True, "note": "Split approved"})
    j.clock.set_date("2026-11-19")
    j.clock.tick()
    rows = rows_of(j, 3)
    tenant_row = next((r for r in rows if r["debtor"] == "TENANT"), None)
    assert tenant_row is not None, rows
    assert tenant_row["principal"] == D(share), rows
    assert tenant_row["effective_due"] == share_due
    assert D(str(tenant_item(j, 3)["penalty_outstanding"])) == D(fee)
    j.invariants("SC-13-03-17")


@pytest.mark.covers("SC-13-03-20")
@pytest.mark.core
@pytest.mark.role_manager
def test_resplit_share_keeps_an_effective_due_date_and_a_late_fee_that_follow_its_creation(f6_site):
    j = f6_site()
    j.clock.set_date("2026-11-19")
    j.clock.tick()
    rows = rows_of(j, 3)
    by_role = {r["debtor"]: r for r in rows}
    oya, burak = by_role.get("TENANT"), by_role.get("OWNER")
    assert oya is not None and burak is not None, rows
    assert oya["effective_due"] == "2026-11-18", rows
    assert burak["effective_due"] == "2026-11-15", rows
    assert burak["principal"] == D("850.00"), rows
    statement = j.api.resident_statement(j.manager, j.unit_id(3))
    assert D(str(tenant_item(j, 3)["penalty_outstanding"])) == D("1.08")
    owner = current_section(statement, "OWNER")
    owner_fee = sum(D(str(i["penalty_outstanding"])) for i in owner["open_items"] if i["period"] == PERIOD)
    assert owner_fee == D("5.67")
    j.invariants("SC-13-03-20")
