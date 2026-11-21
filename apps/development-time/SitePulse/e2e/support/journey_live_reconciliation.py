"""Reads the live two-site journey back from the product and compares it with the independent model.

The expected values come from `support.journey_reconciliation` (fixture inputs only); the actual values
come from posted receipts and the manager's unit statements, so a mismatch names the site, period, unit
and debtor of the first difference (STORY-13-25, SC-13-25-06 and SC-13-25-07).
"""
from __future__ import annotations

from datetime import date
from decimal import Decimal

from support.journey_reconciliation import PERIODS, cash_checkpoints, reconcile

D = Decimal
PERIOD_LABELS = {"January": "Ocak 2027", "February": "Şubat 2027", "March": "Mart 2027", "April": "Nisan 2027"}
LABEL_PERIODS = {label: name for name, label in PERIOD_LABELS.items()}


def posted_cash(stack, site_id: str) -> Decimal:
    """Posted operating cash of one site: the sum of its receipts (no expenses, zero opening cash)."""
    return D(stack.sql(f"SELECT COALESCE(sum(total_amount), 0) FROM payment_receipts WHERE site_id = {int(site_id)};"))


def assert_cash_matches_model(stack, site_a_id: str, site_b_id: str, day: date) -> None:
    expected = cash_checkpoints()[day]
    actual = {"A": posted_cash(stack, site_a_id), "B": posted_cash(stack, site_b_id)}
    assert actual == {"A": expected["A"], "B": expected["B"]}, (
        f"posted operating cash on {day} differs from the independent reconciliation: {actual} != {dict(expected)}")


def live_open_rows(api, stack, sessions: dict[str, object], units: dict[tuple[str, str], str]) -> dict:
    """(site, unit, debtor first name, period) -> (principal, fee, jointly liable owner first name or None)."""
    rows: dict = {}
    for (site, label), unit_id in sorted(units.items()):
        statement = api.resident_statement(sessions[site], unit_id)
        joint: dict[str, str] = {}
        for debtor in statement["debtors"]:
            for item in debtor["jointly_liable_open_items"]:
                joint[str(item["due_id"])] = debtor["name"].split()[0]
        for debtor in statement["debtors"]:
            for item in debtor["open_items"]:
                # The resident statement groups items by role (OWNER / TENANT) under the unit's
                # current occupant name (unit.owner_user_id / tenant_user_id). When ownership has
                # transferred (e.g. A-01: Ada sold to Ben on March 1), Ada's February due is listed
                # under the statement's OWNER card, but the primary debtor person at accrual time is
                # recorded in dues_liabilities.liable_person_id. We look up the person to attribute the row.
                name = stack.sql(
                    "SELECT p.full_name FROM dues_liabilities d JOIN persons p ON p.id = d.liable_person_id "
                    f"WHERE d.id = {int(item['due_id'])};").split()[0]
                key = (site, label, name, LABEL_PERIODS[item["period"]])
                rows[key] = (D(str(item["principal_outstanding"])), D(str(item["penalty_outstanding"])),
                             joint.get(str(item["due_id"])))
    return rows


def assert_statements_match_model(api, stack, sessions: dict[str, object], units: dict[tuple[str, str], str]) -> None:
    """The eleven open rows and both site totals on the final checkpoint equal the model."""
    ledger = reconcile()
    expected = {(r.site, r.unit, r.debtor, r.period): (r.principal, r.fee, r.joint_owner) for r in ledger.open_rows()}
    actual = live_open_rows(api, stack, sessions, units)
    for key in sorted(set(expected) | set(actual)):
        site, unit, debtor, period = key
        assert actual.get(key) == expected.get(key), (
            f"site {site}, period {period}, unit {unit}, debtor {debtor}: statement {actual.get(key)} "
            f"!= reconciliation {expected.get(key)}")
    for site in ("A", "B"):
        totals = ledger.site_totals(site)
        statement_total = sum((p + f for (s, *_), (p, f, _) in actual.items() if s == site), D("0.00"))
        assert statement_total == totals["total_debt_open"], (
            f"site {site}: statements total {statement_total} != reconciliation {totals['total_debt_open']}")
