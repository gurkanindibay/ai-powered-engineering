"""Independent reconciliation of the zero-to-multi-site journey (issue #250, STORY-13-25).

The expected values below are the approved journey analysis. The model under test derives its numbers
from fixture inputs only and never calls the product, so this module needs no running stack.

Covers:
- SC-13-25-01: posted operating cash equals cumulative gross receipts at every checkpoint
- SC-13-25-02: eleven open rows by site, unit, primary debtor and period
- SC-13-25-03: homeowner totals separate primary debt from joint exposure
- SC-13-25-04: site totals reconcile and count a joint receivable once
- SC-13-25-05: final period status distinguishes partial payment from a missed payment
"""
from __future__ import annotations

from datetime import date
from decimal import Decimal

import pytest

from support.journey_reconciliation import (
    CHECKPOINTS,
    cash_checkpoints,
    fixture_charges,
    reconcile,
    unit_labels,
)


@pytest.fixture(autouse=True)
def fresh_data():
    """Override: this module is pure computation and needs no seeded database."""


@pytest.fixture(autouse=True)
def page_guard():
    """Override: this module opens no browser page."""


D = Decimal
CASH = {
    date(2027, 1, 10): (D("22400.00"), D("48000.00")),
    date(2027, 2, 10): (D("45532.67"), D("94750.00")),
    date(2027, 3, 10): (D("67032.67"), D("141250.00")),
    date(2027, 4, 10): (D("90658.50"), D("189538.75")),
}
OPEN_ROWS = {
    ("A", "A-01", "Ada", "February"): (D("800.00"), D("78.67"), None),
    ("A", "A-01", "Ben", "April"): (D("500.00"), D("0.00"), None),
    ("A", "A-02", "Dan", "February"): (D("750.00"), D("73.75"), "Cara"),
    ("A", "A-02", "Cara", "March"): (D("1000.00"), D("51.67"), None),
    ("A", "A-02", "Eli", "April"): (D("400.00"), D("0.00"), "Cara"),
    ("A", "A-03", "Fay", "February"): (D("1000.00"), D("98.33"), None),
    ("A", "A-03", "Fay", "March"): (D("1000.00"), D("51.67"), None),
    ("B", "B1-01", "Gus", "February"): (D("500.00"), D("49.17"), None),
    ("B", "B1-01", "Hana", "April"): (D("500.00"), D("0.00"), None),
    ("B", "B2-01", "Juno", "February"): (D("750.00"), D("73.75"), "Ivan"),
    ("B", "B2-01", "Juno", "March"): (D("750.00"), D("38.75"), "Ivan"),
}
STATUSES = {
    ("A", "A-01"): ["Paid", "Partial", "Paid", "Partial"],
    ("A", "A-02"): ["Paid", "Partial", "Unpaid", "Partial"],
    ("A", "A-03"): ["Paid", "Unpaid", "Unpaid", "Paid"],
    ("B", "B1-01"): ["Paid", "Partial", "Paid", "Partial"],
    ("B", "B2-01"): ["Paid", "Unpaid", "Unpaid", "Paid"],
}


def test_fixture_shape():
    assert len(unit_labels("A")) == 24 and len(unit_labels("B")) == 64
    charges = fixture_charges()
    assert sum(c.principal for c in charges if c.site == "A") == D("96000.00")
    assert sum(c.principal for c in charges if c.site == "B") == D("192000.00")


@pytest.mark.covers("SC-13-25-01")
@pytest.mark.core
@pytest.mark.parametrize("day", CHECKPOINTS)
def test_cash_equals_cumulative_receipts(day):
    cash = cash_checkpoints()[day]
    assert (cash["A"], cash["B"]) == CASH[day]


@pytest.mark.covers("SC-13-25-02")
@pytest.mark.core
def test_eleven_open_rows():
    rows = {(r.site, r.unit, r.debtor, r.period): (r.principal, r.fee, r.joint_owner) for r in reconcile().open_rows()}
    assert rows == OPEN_ROWS
    assert len(rows) == 11


@pytest.mark.covers("SC-13-25-03")
@pytest.mark.core
def test_homeowner_totals_and_joint_exposure():
    ledger = reconcile()
    assert ledger.primary_debt("Fay") == D("2150.00")
    assert ledger.primary_debt("Cara") == D("1051.67")
    assert ledger.joint_exposure("Cara") == D("1223.75")
    assert ledger.primary_debt("Ivan") == D("0.00")
    assert ledger.joint_exposure("Ivan") == D("1612.50")
    assert (ledger.primary_debt("Ada"), ledger.primary_debt("Gus")) == (D("878.67"), D("549.17"))
    assert (ledger.primary_debt("Ben"), ledger.primary_debt("Hana")) == (D("500.00"), D("500.00"))


@pytest.mark.covers("SC-13-25-04")
@pytest.mark.core
def test_site_totals_count_joint_receivable_once():
    ledger = reconcile()
    a, b = ledger.site_totals("A"), ledger.site_totals("B")
    assert (a["principal_accrued"], a["principal_collected"], a["principal_open"]) == (D("96000.00"), D("90550.00"), D("5450.00"))
    assert (a["fees_collected"], a["fees_open"], a["total_debt_open"]) == (D("108.50"), D("354.09"), D("5804.09"))
    assert (b["principal_accrued"], b["principal_collected"], b["principal_open"]) == (D("192000.00"), D("189500.00"), D("2500.00"))
    assert (b["fees_collected"], b["fees_open"], b["total_debt_open"]) == (D("38.75"), D("161.67"), D("2661.67"))
    for totals in (a, b):
        assert totals["principal_collected"] + totals["fees_collected"] == totals["cash"]
    # Joint exposure is not added again: the open rows already sum to the site totals.
    assert sum(r.total for r in ledger.open_rows() if r.site == "A") == a["total_debt_open"]


@pytest.mark.covers("SC-13-25-05")
@pytest.mark.core
def test_final_period_statuses():
    ledger = reconcile()
    for (site, unit), expected in STATUSES.items():
        assert list(ledger.statuses(site, unit).values()) == expected, (site, unit)
    assert reconcile(date(2027, 1, 10)).statuses("A", "A-01")["January"] == "Partial"
