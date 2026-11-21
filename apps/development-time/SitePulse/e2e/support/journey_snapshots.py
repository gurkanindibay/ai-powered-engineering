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



def unit_position(api: Api, manager: Session, site_id: str, unit_id: str) -> tuple[Decimal, Decimal]:
    """The unit's (debt, advance) summed over the debtors of its resident statement."""
    debtors = api.resident_statement(manager, unit_id)["debtors"]
    debt = sum((money(d["total_outstanding"]) for d in debtors), Decimal("0.00"))
    advance = sum((money(d["advance_balance"]) for d in debtors), Decimal("0.00"))
    return debt, advance


def open_items(api: Api, manager: Session, unit_id: str, debtor_type: str) -> list[dict]:
    statement = api.resident_statement(manager, unit_id)
    debtor = next(d for d in statement["debtors"] if d["debtor_type"] == debtor_type)
    return debtor["open_items"]


def second_manager(api: Api, stack: E2EStack, fixture: JourneyFixture, person_name: str = "Ayşe Kaya") -> Session:
    """Promotes a resident account of the isolated site to a second site manager (four-eyes reviewer)."""
    email = stack.sql(
        f"SELECT email FROM persons WHERE site_id = {int(fixture.site_id)} AND full_name = '{person_name}';"
    )
    stack.sql(f"UPDATE users SET role = 'SITE_MANAGER' WHERE lower(email) = lower('{email}');")
    stack.restart_backend()
    return api.login(email, fixture.manager_password)
