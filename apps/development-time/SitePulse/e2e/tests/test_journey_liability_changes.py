"""EPIC-13 STORY-13-14: liability through sales, vacancies and move-ins (issue #249).

Executes .specify/features/EPIC-13/STORY-13-14-liability-through-sales-vacancies.feature on two isolated
sites. Expected debtors and amounts come from the journey plan fixture (`support/journey_liability.py`),
never from the response being checked.
"""
from __future__ import annotations

import os
from decimal import Decimal
from pathlib import Path

import pytest

from support.journey_attempts import JourneyManifest, ledger_invariants, teardown_sites
from support.journey_liability import (
    APR, DEBTORS, FEB, JAN, MAR, PEOPLE, LiabilityJourney,
)

E2E = Path(__file__).resolve().parents[1]
D = Decimal


@pytest.fixture
def journey(request, api, actors, stack):
    """Builds both journey sites for one scenario and removes them afterwards (README section 5)."""
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys", run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"))
    holder: list[LiabilityJourney] = []

    def build() -> LiabilityJourney:
        holder.append(LiabilityJourney(api, stack, saas, manifest))
        return holder[0]

    try:
        yield build
    finally:
        manifest.save()
        teardown_sites(stack, manifest, restart=False)


def _breakdown(receipt: dict) -> dict[str, tuple[Decimal, Decimal]]:
    """Principal and fee a receipt allocated per period."""
    out: dict[str, tuple[Decimal, Decimal]] = {}
    for item in receipt["allocation_breakdown"]:
        principal, fee = out.get(item["period"], (D("0"), D("0")))
        out[item["period"]] = (principal + D(str(item["principal_paid"])), fee + D(str(item["penalty_paid"])))
    return out


@pytest.mark.covers("SC-13-14-01")
@pytest.mark.core
@pytest.mark.role_manager
def test_titles_and_occupancies_change_on_their_effective_dates(journey):
    j = journey().run_through("mar_changed")
    # A-01: Ada's title ends and Ben's begins on March 1, Ben moves in, Ada's household is archived.
    assert [(o["name"], o["start"], o["end"], o["active"]) for o in j.ownerships("A-01")] == [
        (PEOPLE["Ada"], "2026-12-01", "2027-03-01", False), (PEOPLE["Ben"], "2027-03-01", "", True)]
    assert [(o["name"], o["type"], o["active"]) for o in j.occupancies("A-01")] == [
        (PEOPLE["Ada"], "OWNER", False), (PEOPLE["Ben"], "OWNER", True)]
    assert j.roster("A-01") == []
    assert j.archived_household("A-01", "Ada") == [PEOPLE["Mina"]]
    # A-02: Dan moved out on March 1 with his household archived; Cara keeps title.
    assert [(o["name"], o["end"], o["active"]) for o in j.occupancies("A-02")] == [(PEOPLE["Dan"], "2027-03-01", False)]
    assert j.roster("A-02") == []
    assert j.archived_household("A-02", "Dan") == [PEOPLE["Dora"]]
    assert [(o["name"], o["active"]) for o in j.ownerships("A-02")] == [(PEOPLE["Cara"], True)]
    # A-03: Fay moved out and retains title.
    assert [(o["name"], o["end"], o["active"]) for o in j.occupancies("A-03")] == [(PEOPLE["Fay"], "2027-03-01", False)]
    assert [(o["name"], o["active"]) for o in j.ownerships("A-03")] == [(PEOPLE["Fay"], True)]
    # B1-01: Hana bought the unit on March 1 and left it vacant; Gus's occupancy is closed.
    assert [(o["name"], o["end"], o["active"]) for o in j.ownerships("B1-01")] == [
        (PEOPLE["Gus"], "2027-03-01", False), (PEOPLE["Hana"], "", True)]
    assert [(o["name"], o["active"]) for o in j.occupancies("B1-01")] == [(PEOPLE["Gus"], False)]
    # B2-01 is untouched: Juno still rents from Ivan.
    assert [(o["name"], o["type"], o["active"]) for o in j.occupancies("B2-01")] == [(PEOPLE["Juno"], "TENANT", True)]
    for site in j.sites.values():
        ledger_invariants(j.api, site.manager, site.site_id, stage="SC-13-14-01")


@pytest.mark.covers("SC-13-14-02")
@pytest.mark.core
@pytest.mark.role_manager
def test_march_charges_follow_the_new_owners_and_the_vacancies(journey):
    j = journey().run_through("mar_accrued")
    # Site totals: one charge per unit of the journey and exact tariff, no joint double counting.
    expected = {"A-01": ("OWNER", D("1000.00")), "A-02": ("OWNER", D("1000.00")), "A-03": ("OWNER", D("1000.00")),
                "B1-01": ("OWNER", D("750.00")), "B2-01": ("TENANT", D("750.00"))}
    for unit, (role, principal) in expected.items():
        march = {key: row for key, row in j.charges(unit).items() if key[0] == MAR}
        assert set(march) == {(MAR, role)}, f"{unit}: March must be billed to the {role} only"
        assert march[(MAR, role)]["principal"] == principal
        assert DEBTORS[(unit, MAR)][0] == role
    # The owner of record at accrual is the March debtor, including for vacant units.
    for unit, person in (("A-01", "Ben"), ("A-02", "Cara"), ("A-03", "Fay"), ("B1-01", "Hana")):
        assert DEBTORS[(unit, MAR)] == ("OWNER", person)
        assert [o["name"] for o in j.ownerships(unit) if o["active"]] == [PEOPLE[person]]
    # Dan's and Gus's and Ada's earlier charges keep their original role and amount.
    assert j.charges("A-02")[(FEB, "TENANT")]["principal"] == D("1000.00")
    assert j.charges("A-01")[(FEB, "OWNER")]["principal"] == D("1000.00")
    assert j.charges("B1-01")[(FEB, "OWNER")]["principal"] == D("750.00")
    for site in j.sites.values():
        ledger_invariants(j.api, site.manager, site.site_id, stage="SC-13-14-02")


@pytest.mark.covers("SC-13-14-03")
@pytest.mark.core
@pytest.mark.role_manager
def test_april_move_ins_redirect_new_charges_and_rosters(journey):
    j = journey().run_through("apr_accrued")
    assert [(o["name"], o["type"], o["start"], o["active"]) for o in j.occupancies("A-02")] == [
        (PEOPLE["Dan"], "TENANT", "2026-12-01", False), (PEOPLE["Eli"], "TENANT", "2027-04-01", True)]
    assert j.roster("A-02") == [PEOPLE["Ela"]]            # Eli's current household only
    assert j.archived_household("A-02", "Dan") == [PEOPLE["Dora"]]
    assert [(o["name"], o["type"], o["start"], o["active"]) for o in j.occupancies("B1-01")] == [
        (PEOPLE["Gus"], "OWNER", "2026-12-01", False), (PEOPLE["Hana"], "OWNER", "2027-04-01", True)]
    assert [o["active"] for o in j.occupancies("A-03")] == [False]      # A-03 stays vacant
    assert j.roster("A-01") == []                                        # Ada's household is not Ben's
    assert j.archived_household("A-01", "Ada") == [PEOPLE["Mina"]]
    # April debtors: Eli (tenant) in A-02, Hana (owner) in B1-01, Fay (owner of the vacant unit) in A-03.
    assert {(p, r) for (p, r) in j.charges("A-02") if p == APR} == {(APR, "TENANT")}
    assert j.charges("A-02")[(APR, "TENANT")]["principal"] == D("1000.00")
    assert j.charges("A-02")[(APR, "TENANT")]["liable"] == PEOPLE["Eli"]
    assert {(p, r) for (p, r) in j.charges("B1-01") if p == APR} == {(APR, "OWNER")}
    assert {(p, r) for (p, r) in j.charges("A-03") if p == APR} == {(APR, "OWNER")}
    # Linked household members receive no independent charge merely because they were added.
    assert PEOPLE["Ela"] not in {row["liable"] for unit in ("A-02",) for row in j.charges(unit).values()}
    for site in j.sites.values():
        ledger_invariants(j.api, site.manager, site.site_id, stage="SC-13-14-03")


@pytest.mark.covers("SC-13-14-04")
@pytest.mark.core
@pytest.mark.role_manager
def test_former_owners_and_tenants_remain_collectible_after_the_changes(journey):
    j = journey().run_through("mar_accrued")
    # Before any March payment the manager's statement lists the predecessor's and the successor's charges.
    expected = {
        "A-01": {(FEB, "OWNER"): D("800.00"), (MAR, "OWNER"): D("1000.00")},
        "A-02": {(FEB, "TENANT"): D("750.00"), (MAR, "OWNER"): D("1000.00")},
        "B1-01": {(FEB, "OWNER"): D("500.00"), (MAR, "OWNER"): D("750.00")},
    }
    for unit, rows in expected.items():
        open_items = j.open_items(unit)
        assert {key: principal for key, (principal, _) in open_items.items()} == rows, unit
        for (period, _), (_, fee) in open_items.items():
            if period == FEB:
                assert fee > D("0.00"), f"{unit} {period}: the overdue predecessor charge keeps accruing its fee"


@pytest.mark.covers("SC-13-14-05")
@pytest.mark.core
@pytest.mark.role_manager
def test_receipts_before_the_changes_allocate_to_the_paying_debtor(journey):
    j = journey().run_through("feb_paid")
    assert _breakdown(j.posting("A-01", "Ada", JAN).receipt) == {JAN: (D("400.00"), D("0.00"))}
    assert _breakdown(j.posting("A-01", "Ada", FEB).receipt) == {JAN: (D("600.00"), D("31.00")), FEB: (D("200.00"), D("0.00"))}
    assert _breakdown(j.posting("A-02", "Dan", FEB).receipt) == {JAN: (D("1000.00"), D("51.67")), FEB: (D("250.00"), D("0.00"))}
    assert _breakdown(j.posting("B1-01", "Gus", FEB).receipt) == {FEB: (D("250.00"), D("0.00"))}
    # Posted operating cash equals the cumulative gross receipts; accruals and no-payment months add nothing.
    assert j.cash("A") == D("400.00") + D("1000.00") + D("831.00") + D("1301.67")
    assert j.cash("B") == D("750.00") + D("750.00") + D("250.00")


@pytest.mark.covers("SC-13-14-06")
@pytest.mark.core
@pytest.mark.role_manager
def test_designated_april_receipts_leave_february_and_march_unpaid(journey):
    j = journey().run_through("apr_paid")
    for unit, payer, principal_open in (("A-03", "Fay", D("1000.00")), ("B2-01", "Juno", D("750.00"))):
        role = DEBTORS[(unit, JAN)][0]
        history = {stage: {p: v for (p, r), v in snapshot[unit].items() if r == role} for stage, snapshot in j.history.items()}
        assert history["jan_paid"] == {}, f"{unit}: January is paid in full"
        assert set(history["feb_accrued"]) == {FEB} and set(history["feb_paid"]) == {FEB}
        assert set(history["mar_accrued"]) == {FEB, MAR} and set(history["mar_paid"]) == {FEB, MAR}
        assert set(history["apr_accrued"]) == {FEB, MAR, APR}, f"{unit}: April unpaid before its receipt"
        assert set(history["apr_paid"]) == {FEB, MAR}, f"{unit}: April paid after its designated receipt"
        assert history["apr_paid"][FEB][0] == principal_open and history["apr_paid"][MAR][0] == principal_open
        posting = j.posting(unit, payer, APR)
        assert _breakdown(posting.receipt) == {APR: (principal_open, D("0.00"))}, "exactly one allocation, to April"
        assert len(posting.receipt["allocation_breakdown"]) == 1
    # February and March accrue their own fees (5% per 30 days on 1,000.00 and 750.00 at April 10).
    assert j.open_items("A-03")[(FEB, "OWNER")][1] == D("98.33") and j.open_items("A-03")[(MAR, "OWNER")][1] == D("51.67")
    assert j.open_items("B2-01")[(FEB, "TENANT")][1] == D("73.75") and j.open_items("B2-01")[(MAR, "TENANT")][1] == D("38.75")


@pytest.mark.covers("SC-13-14-07")
@pytest.mark.core
@pytest.mark.role_manager
def test_ownership_and_occupancy_changes_do_not_move_money(journey):
    j = journey().run_through("feb_paid")
    cash = {key: j.cash(key) for key in j.sites}
    j.run_through("mar_accrued")
    assert {key: j.cash(key) for key in j.sites} == cash, "title transfers, move-outs and accrual create no cash movement"
    j.run_through("apr_paid")
    # A site A receipt never moves site B cash and vice versa.
    for posting in j.postings:
        assert posting.other_site_cash_before == posting.other_site_cash_after, (posting.unit, posting.payer, posting.month)
    assert j.cash("A") == sum(D(str(p.receipt["total_amount"])) for p in j.postings if p.unit.startswith("A"))
    assert j.cash("B") == sum(D(str(p.receipt["total_amount"])) for p in j.postings if not p.unit.startswith("A"))


RECEIPTS_BY_LIABLE_PERSON = {
    ("A-01", "Ben", MAR): {MAR: (D("500.00"), D("0.00"))},
    ("A-01", "Ben", APR): {MAR: (D("500.00"), D("25.83")), APR: (D("500.00"), D("0.00"))},
    ("A-02", "Eli", APR): {APR: (D("600.00"), D("0.00"))},
    ("B1-01", "Hana", APR): {MAR: (D("750.00"), D("38.75")), APR: (D("250.00"), D("0.00"))},
}


@pytest.mark.covers("SC-13-14-08")
@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.parametrize(("unit", "payer", "month"), list(RECEIPTS_BY_LIABLE_PERSON), ids=lambda v: str(v))
def test_a_successors_receipt_settles_only_the_successors_charges(journey, unit, payer, month):
    j = journey().run_through("apr_paid")
    posting = j.posting(unit, payer, month)
    # The debtor of every allocation is the paying person: each allocated period is one of the payer's charges.
    for period in _breakdown(posting.receipt):
        assert DEBTORS[(unit, period)][1] == payer, f"{unit} {period} is owed by {DEBTORS[(unit, period)][1]}, not {payer}"
    assert _breakdown(posting.receipt) == RECEIPTS_BY_LIABLE_PERSON[(unit, payer, month)]
    # Other debtors' principal, fees and payment history are identical before and after the receipt.
    for (period, role), values in posting.before["open"].items():
        if DEBTORS[(unit, period)][1] != payer:
            assert posting.after["open"].get((period, role)) == values, f"{unit} {period}: another debtor's balance moved"
    for key, row in posting.before["charges"].items():
        if DEBTORS[(unit, key[0])][1] != payer:
            assert posting.after["charges"][key] == row, f"{unit} {key[0]}: another debtor's payment history moved"


FINAL_OPEN = {  # (unit, period) -> (principal, fee) after the April 10 receipts, from the journey plan
    ("A-01", FEB): (D("800.00"), D("78.67")), ("A-01", APR): (D("500.00"), D("0.00")),
    ("A-02", FEB): (D("750.00"), D("73.75")), ("A-02", MAR): (D("1000.00"), D("51.67")),
    ("A-02", APR): (D("400.00"), D("0.00")),
    ("A-03", FEB): (D("1000.00"), D("98.33")), ("A-03", MAR): (D("1000.00"), D("51.67")),
    ("B1-01", FEB): (D("500.00"), D("49.17")), ("B1-01", APR): (D("500.00"), D("0.00")),
    ("B2-01", FEB): (D("750.00"), D("73.75")), ("B2-01", MAR): (D("750.00"), D("38.75")),
}


@pytest.mark.covers("SC-13-14-09")
@pytest.mark.core
@pytest.mark.role_manager
def test_final_open_debt_stays_with_each_former_and_current_debtor(journey):
    j = journey().run_through("apr_paid")
    for unit in ("A-01", "A-02", "A-03", "B1-01", "B2-01"):
        actual = {period: values for (period, _), values in j.open_items(unit).items()}
        expected = {period: values for (u, period), values in FINAL_OPEN.items() if u == unit}
        assert actual == expected, f"{unit}: open principal and fees per period"
    assert sum(p for (u, _), (p, _) in FINAL_OPEN.items() if u.startswith("A")) == D("5450.00")
    assert sum(f for (u, _), (_, f) in FINAL_OPEN.items() if u.startswith("A")) == D("354.09")
    assert sum(p for (u, _), (p, _) in FINAL_OPEN.items() if not u.startswith("A")) == D("2500.00")
    assert sum(f for (u, _), (_, f) in FINAL_OPEN.items() if not u.startswith("A")) == D("161.67")


@pytest.mark.covers("SC-13-25-07")
@pytest.mark.core
@pytest.mark.role_manager
def test_unit_statement_attributes_open_items_to_former_debtors(journey):
    """SC-13-25-07: reading the manager statements including former debtors attributes open charges to their debtor."""
    j = journey().run_through("apr_paid")
    stmt = j.statement("A-01")
    debtor_names = {d["name"].split()[0]: d for d in stmt["debtors"]}
    assert "Ada" in debtor_names, (
        f"site A, period Şubat 2027, unit A-01, debtor Ada: statement lists former owner charge under {list(debtor_names.keys())}"
    )
    assert debtor_names["Ada"]["is_former"] is True, "Ada no longer holds the title, so her section is a former one"
    assert debtor_names["Ben"]["is_former"] is False, "Ben holds the title, so his section is the current one"
    ada_open = {item["period"]: item for item in debtor_names["Ada"]["open_items"]}
    assert "Şubat 2027" in ada_open, (
        f"site A, period Şubat 2027, unit A-01, debtor Ada: February open item missing from Ada's statement items"
    )
    ben_open = {item["period"] for item in debtor_names["Ben"]["open_items"]}
    assert "Şubat 2027" not in ben_open, (
        f"site A, period Şubat 2027, unit A-01, debtor Ben: Ada's February item must not appear on the successor's section"
    )
