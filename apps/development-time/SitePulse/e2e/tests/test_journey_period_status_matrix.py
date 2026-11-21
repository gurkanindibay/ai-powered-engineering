"""Backend journey assertions for the period command matrix of STORY-13-11 (EPIC-13).

Covers:
- SC-13-11-04: Each period status allows only its own commands

Every row builds its own F2 site, brings the period "Ekim 2026" to the row's status through the API
and runs one command. A refusal must leave the period, its liabilities and the audit log unchanged.
"""
from __future__ import annotations

from decimal import Decimal

import pytest

from support.api import raw_call
from support.journey_snapshots import financial_snapshot, journey_site

D = Decimal
PERIOD, DUE = "Ekim 2026", "2026-10-10"


def _status(stack, site: str) -> str:
    return stack.sql(f"SELECT status FROM dues_periods WHERE site_id = {int(site)};")


def _audit_count(stack, site: str) -> str:
    return stack.sql(f"SELECT COUNT(*) FROM audit_events WHERE site_id = {int(site)};")


def _liabilities(stack, site: str) -> str:
    return stack.sql(
        f"SELECT COUNT(*) FROM dues_liabilities d JOIN units u ON u.id = d.unit_id WHERE u.site_id = {int(site)};"
    )


@pytest.mark.covers("SC-13-11-04")
@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.parametrize(
    "status, command",
    [
        ("DRAFT", "accrue"),
        ("DRAFT", "close"),
        ("OPEN", "accrue again"),
        ("OPEN", "close"),
        ("CLOSED", "accrue"),
        ("CLOSED", "close"),
        ("CLOSED", "reopen"),
    ],
)
def test_each_period_status_allows_only_its_own_commands(request, api, actors, stack, status, command):
    with journey_site(request, api, actors, stack, "F2") as (fixture, _):
        site, token = fixture.site_id, fixture.manager.token
        api.create_period(fixture.manager, PERIOD, DUE)
        if status in ("OPEN", "CLOSED"):
            api.accrue_period(fixture.manager, PERIOD, D("0"), DUE)
        period_id = stack.sql(f"SELECT id FROM dues_periods WHERE site_id = {int(site)};")
        if status == "CLOSED":
            assert raw_call(api, "POST", f"/api/v1/dues/periods/{period_id}/close", token, {"site_id": site})[0] == 200
        assert _status(stack, site) == status
        before, audit_before = financial_snapshot(stack, site), _audit_count(stack, site)

        def accrue() -> tuple[int, str]:
            body = {"site_id": site, "period": PERIOD, "amount": "0", "due_date": DUE}
            return raw_call(api, "POST", "/api/v1/dues/accrue-period", token, body)

        def close() -> tuple[int, str]:
            return raw_call(api, "POST", f"/api/v1/dues/periods/{period_id}/close", token, {"site_id": site})

        if (status, command) == ("DRAFT", "accrue"):
            code, body = accrue()
            assert code == 201 or code == 200, body
            assert _status(stack, site) == "OPEN"
            assert _liabilities(stack, site) == "6"
        elif (status, command) == ("OPEN", "close"):
            assert close()[0] == 200
            assert _status(stack, site) == "CLOSED"
            assert stack.sql(f"SELECT COUNT(*) FROM dues_period_snapshots WHERE site_id = {int(site)};") == "1"
        elif (status, command) == ("OPEN", "accrue again"):
            code, body = accrue()
            assert code == 200 and '"already_accrued":true' in body.replace(" ", "")  # a duplicate creates nothing
            assert financial_snapshot(stack, site) == before
            assert _audit_count(stack, site) == audit_before
        elif command == "reopen":
            code, body = raw_call(
                api, "POST", f"/api/v1/dues/periods/{period_id}/reopen", token,
                {"site_id": site, "reason": "Amounts were entered wrongly"},
            )
            assert code in (200, 201, 202), body
            assert _status(stack, site) == "CLOSED"  # pending until a second manager approves
            assert stack.sql(
                f"SELECT status FROM dues_period_reopen_requests WHERE site_id = {int(site)};"
            ) == "PENDING"
        else:  # refused: DRAFT close, CLOSED accrue, CLOSED close
            code, _ = accrue() if command == "accrue" else close()
            assert code == 409
            assert _status(stack, site) == status
            assert financial_snapshot(stack, site) == before
            assert _audit_count(stack, site) == audit_before
