"""Read-only snapshots and small actors shared by the EPIC-13 backend journey assertions.

A snapshot captures the financial and household rows of one site so a refusal scenario can assert
that nothing changed. Expected values never come from the response under test.
"""
from __future__ import annotations

import os
from contextlib import contextmanager
from decimal import Decimal
from pathlib import Path
from typing import Iterator

from support.api import Api, Session
from support.journey_attempts import (
    JourneyFixture,
    JourneyManifest,
    site_in_state,
    teardown_with_evidence,
)
from support.stack import E2EStack

E2E = Path(__file__).resolve().parents[1]


@contextmanager
def journey_site(
    request, api: Api, actors: dict, stack: E2EStack, state: str, *, name_suffix: str = ""
) -> Iterator[tuple[JourneyFixture, JourneyManifest]]:
    """Builds an isolated site in a reference state and always tears it down with evidence."""
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    try:
        fixture = site_in_state(state, api=api, stack=stack, saas=saas, manifest=manifest, name_suffix=name_suffix)
        yield fixture, manifest
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
        raise
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)


def money(value: object) -> Decimal:
    return Decimal(str(value))


def financial_snapshot(stack: E2EStack, site_id: str) -> str:
    """One text row of counts and sums over every financial and household table of a site."""
    site = int(site_id)
    return stack.sql(
        "SELECT "
        f"(SELECT COUNT(*) FROM payment_entries WHERE site_id = {site}), "
        f"(SELECT COUNT(*) FROM payment_receipts WHERE site_id = {site}), "
        "(SELECT COUNT(*) FROM payment_allocations pa JOIN payment_entries pe ON pe.id = pa.payment_entry_id "
        f"  WHERE pe.site_id = {site}), "
        "(SELECT COALESCE(SUM(pa.principal_amount + pa.penalty_amount), 0) FROM payment_allocations pa "
        f"  JOIN payment_entries pe ON pe.id = pa.payment_entry_id WHERE pe.site_id = {site}), "
        "(SELECT COALESCE(SUM(ab.balance), 0) FROM advance_balances ab JOIN units u ON u.id = ab.unit_id "
        f"  WHERE u.site_id = {site}), "
        "(SELECT COUNT(*) FROM advance_ledger_entries al JOIN units u ON u.id = al.unit_id "
        f"  WHERE u.site_id = {site}), "
        "(SELECT COUNT(*) || ':' || COALESCE(SUM(d.principal_amount), 0) || ':' || COALESCE(SUM(d.paid_amount), 0) "
        "  || ':' || COALESCE(SUM(d.delay_penalty), 0) || ':' || COUNT(*) FILTER (WHERE d.status = 'CANCELLED') "
        f"  FROM dues_liabilities d JOIN units u ON u.id = d.unit_id WHERE u.site_id = {site}), "
        f"(SELECT COUNT(*) FROM dues_periods WHERE site_id = {site}), "
        f"(SELECT COUNT(*) FROM reconciliation_queue WHERE site_id = {site}), "
        f"(SELECT COUNT(*) FROM accrual_corrections WHERE site_id = {site}), "
        "(SELECT COUNT(*) FROM unit_occupancies o JOIN units u ON u.id = o.unit_id "
        f"  WHERE u.site_id = {site} AND o.is_active), "
        f"(SELECT COUNT(*) FROM unit_occupancies o JOIN units u ON u.id = o.unit_id WHERE u.site_id = {site}), "
        f"(SELECT COUNT(*) FROM persons WHERE site_id = {site});"
    )


def reconciliation_queue_count(stack: E2EStack, site_id: str) -> int:
    """The number of bank statement items awaiting reconciliation for this site."""
    return int(stack.sql(f"SELECT COUNT(*) FROM reconciliation_queue WHERE site_id = {int(site_id)};"))


def audit_event_count(stack: E2EStack, site_id: str) -> str:
    """The number of audit rows for a site; a refusal or duplicate must not add one."""
    return stack.sql(f"SELECT COUNT(*) FROM audit_events WHERE site_id = {int(site_id)};")


def audit_mark(stack: E2EStack, site_id: str) -> str:
    """The current newest audit event id, so rows written later can be listed by name."""
    return stack.sql(f"SELECT COALESCE(MAX(event_id), 0) FROM audit_events WHERE site_id = {int(site_id)};")


def new_audit_rows(stack: E2EStack, site_id: str, mark: str) -> str:
    """The audit rows written after `mark`, named for an assertion failure message."""
    return stack.sql(
        "SELECT COALESCE(string_agg(action || ' on ' || resource_type || ' #' || "
        f"COALESCE(resource_id, '?'), ', '), 'none') FROM audit_events "
        f"WHERE site_id = {int(site_id)} AND event_id > {int(mark)};"
    )


def unit_position(api: Api, manager: Session, site_id: str, unit_id: str) -> tuple[Decimal, Decimal]:
    """The unit's (debt, advance) summed over the debtors of its resident statement."""
    debtors = api.resident_statement(manager, unit_id)["debtors"]
    debt = sum((money(d["total_outstanding"]) for d in debtors), Decimal("0.00"))
    advance = sum((money(d["advance_balance"]) for d in debtors), Decimal("0.00"))
    return debt, advance


def open_items(api: Api, manager: Session, unit_id: str, debtor_type: str) -> list[dict]:
    """All open items of a role, across the current holder's and predecessors' sections.

    A role can have several statement sections since #295: the current holder's
    and one per former liable person. The manager view lists them all, so a
    role-level item list must collect every section, oldest due date first.
    """
    statement = api.resident_statement(manager, unit_id)
    items = [
        item
        for debtor in statement["debtors"]
        if debtor["debtor_type"] == debtor_type
        for item in debtor["open_items"]
    ]
    return sorted(items, key=lambda item: (item.get("due_date") or "", item.get("period") or ""))


def section_of(statement: dict, debtor_type: str, first_name: str) -> dict:
    """The statement section of one named person in a role.

    A role can have the current holder's section and one per former liable
    person who still owes, so a test about a particular person must select that
    person's section by name instead of taking the first of the role.
    """
    sections = [
        d for d in statement["debtors"]
        if d["debtor_type"] == debtor_type and d["name"].split()[0] == first_name
    ]
    assert len(sections) == 1, (
        f"expected one {debtor_type} section for {first_name}, found "
        f"{[(d['name'], d.get('is_former')) for d in sections]}"
    )
    return sections[0]


def current_section(statement: dict, debtor_type: str, *, required: bool = True) -> dict | None:
    """The statement section owned by the unit's current holder of a role.

    A role can have several sections since #295: the current holder's section
    and one per former liable person who still owes. A test that means the
    holder's own balance must select that section, not merely the first one.
    """
    sections = [d for d in statement["debtors"] if d["debtor_type"] == debtor_type]
    current = [d for d in sections if not d.get("is_former")]
    if current:
        return current[0]
    if not sections:
        if not required:
            return None
        raise AssertionError(f"statement has no {debtor_type} section: {[d['debtor_type'] for d in statement['debtors']]}")
    return sections[0]


def second_manager(api: Api, stack: E2EStack, fixture: JourneyFixture, person_name: str = "Ayşe Kaya") -> Session:
    """Promotes a resident account of the isolated site to a second site manager (four-eyes reviewer)."""
    email = stack.sql(
        f"SELECT email FROM persons WHERE site_id = {int(fixture.site_id)} AND full_name = '{person_name}';"
    )
    stack.sql(f"UPDATE users SET role = 'SITE_MANAGER' WHERE lower(email) = lower('{email}');")
    stack.restart_backend()
    return api.login(email, fixture.manager_password)
