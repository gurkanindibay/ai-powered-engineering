"""Backend journey assertions for the corner cases of STORY-13-05 (EPIC-13).

Covers:
- SC-13-05-01: Invalid accrual input is rejected and creates nothing
- SC-13-05-03: A duplicate accrual with a different amount is still blocked
- SC-13-05-04: Two admins accruing the same period at the same moment create one set of liabilities
- SC-13-05-07: Moving out with an advance requires a decision before the advance leaves
- SC-13-05-08: Moving out twice and moving in on an occupied unit are refused
- SC-13-05-12: A resident cannot call manager actions
- SC-13-05-13: A manager of another site sees nothing of this site

Expected values come from the F2/F4/F5 fixture plan, never from the response under test. Refusals
compare a full financial and household snapshot before and after.
"""
from __future__ import annotations

import json
from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal

import pytest

from support.api import ApiError, raw_call
from support.journey_attempts import ledger_invariants
from support.journey_snapshots import (
    audit_event_count,
    audit_mark,
    financial_snapshot,
    journey_site,
    new_audit_rows,
    second_manager,
    unit_position,
)

D = Decimal
ZERO_SITE = "0|0|0|0|0|0|0:0:0:0:0|0|0|0"  # no payment, advance, liability or period rows yet


@pytest.mark.covers("SC-13-05-01")
@pytest.mark.edge
@pytest.mark.role_manager
@pytest.mark.parametrize(
    "period, amount, due, reason",
    [
        pytest.param("Ekim 2026", "0.00", "2026-10-10", "amount must be positive", id="zero-amount"),
        pytest.param("Ekim 2026", "-1500.00", "2026-10-10", "amount must be positive", id="negative-amount"),
        pytest.param("Ekim 2026", "1500.00", "2026-02-30", "due_date", id="invalid-date"),
        pytest.param("Ekim 2025", "1500.00", "2026-10-10", "outside period", id="date-outside-period"),
    ],
)
def test_invalid_accrual_input_is_rejected_and_creates_nothing(
    request, api, actors, stack, period, amount, due, reason
):
    with journey_site(request, api, actors, stack, "F2") as (fixture, _):
        before = financial_snapshot(stack, fixture.site_id)
        assert before.startswith(ZERO_SITE)  # F2: no period and no liability yet

        with pytest.raises(ApiError) as refused:
            api.accrue_period(fixture.manager, period, D(amount), due)
        assert reason in str(refused.value)

        assert financial_snapshot(stack, fixture.site_id) == before
        assert stack.sql(f"SELECT COUNT(*) FROM dues_periods WHERE site_id = {int(fixture.site_id)};") == "0"


@pytest.mark.covers("SC-13-05-03")
@pytest.mark.edge
@pytest.mark.role_manager
def test_duplicate_accrual_with_a_different_amount_changes_nothing(request, api, actors, stack):
    with journey_site(request, api, actors, stack, "F4") as (fixture, _):
        before = financial_snapshot(stack, fixture.site_id)
        audit_before = audit_event_count(stack, fixture.site_id)
        audit_before_id = audit_mark(stack, fixture.site_id)
        shares = f"SELECT principal_amount FROM dues_liabilities d JOIN units u ON u.id = d.unit_id " \
                 f"WHERE u.site_id = {int(fixture.site_id)} AND d.period = 'Ekim 2026' ORDER BY d.id;"
        original = stack.sql(shares)
        assert original.splitlines() == ["1500.00"] * 5 + ["2250.00"]  # F4 plan: A-6 pays 2250.00

        again = api.accrue_period(fixture.manager, "Ekim 2026", D("1800.00"), "2026-10-10")
        assert again["already_accrued"] is True
        assert again["newly_accrued_units_count"] == 0
        assert D(str(again["total_amount_accrued"])) == D("0")

        assert stack.sql(shares) == original  # the 1800.00 was not applied to any liability
        assert financial_snapshot(stack, fixture.site_id) == before
        assert audit_event_count(stack, fixture.site_id) == audit_before, new_audit_rows(
            stack, fixture.site_id, audit_before_id
        )


@pytest.mark.covers("SC-13-05-04")
@pytest.mark.edge
@pytest.mark.role_manager
def test_two_managers_accruing_at_once_create_one_set_of_liabilities(request, api, actors, stack):
    with journey_site(request, api, actors, stack, "F2") as (fixture, _):
        reviewer = second_manager(api, stack, fixture)
        first = api.login(fixture.manager_email, fixture.manager_password)
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [
                pool.submit(api.accrue_period, session, "Ekim 2026", None, "2026-10-10")
                for session in (first, reviewer)
            ]
            results = [future.result() for future in futures]

        assert sorted(r["newly_accrued_units_count"] for r in results) == [0, 6]
        assert stack.sql(
            "SELECT COUNT(*) FROM dues_liabilities d JOIN units u ON u.id = d.unit_id "
            f"WHERE u.site_id = {int(fixture.site_id)} AND d.period = 'Ekim 2026';"
        ) == "6"
        ledger_invariants(api, first, fixture.site_id, stage="SC-13-05-04")


@pytest.mark.covers("SC-13-05-07")
@pytest.mark.edge
@pytest.mark.role_manager
@pytest.mark.parametrize("kind", ["PAYOUT", "TRANSFER"])
def test_move_out_with_an_advance_needs_a_second_approver(request, api, actors, stack, kind):
    with journey_site(request, api, actors, stack, "F5") as (fixture, _):
        a2 = fixture.unit_ids[1]
        site = int(fixture.site_id)
        # Selin owes 3122.50 (Ekim and Kasım with fees); 3422.50 clears it and leaves 300.00 advance.
        api.record_manual_payment(fixture.manager, a2, D("3422.50"), "Selin Demir", payer_role="TENANT")
        assert unit_position(api, fixture.manager, fixture.site_id, a2) == (D("0.00"), D("300.00"))
        reviewer = second_manager(api, stack, fixture)
        manager = api.login(fixture.manager_email, fixture.manager_password)

        def tenant_advance() -> str:  # the statement drops a departed tenant, so read the ledger
            return stack.sql(
                f"SELECT COALESCE(SUM(balance), 0) FROM advance_balances WHERE unit_id = {int(a2)} AND debtor_type = 'TENANT';"
            )

        api.call("POST", f"/api/v1/site-admin/units/{a2}/move-out?site_id={fixture.site_id}", manager.token,
                 body={"notes": "moving out"})
        # Keep is the default: the move-out alone neither pays out nor transfers the advance.
        assert tenant_advance() == "300.00"
        assert stack.sql(f"SELECT COUNT(*) FROM advance_exit_settlements WHERE unit_id = {int(a2)};") == "0"

        selin = stack.sql(f"SELECT id FROM persons WHERE site_id = {site} AND full_name = 'Selin Demir';")
        body = {"request_key": f"e2e-{kind}", "kind": kind, "source_debtor": "TENANT",
                "beneficiary_name": "Selin Demir", "beneficiary_person_id": selin, "amount": "300.00"}
        if kind == "TRANSFER":
            body["target_debtor"] = "OWNER"
        created = api.call("POST", f"/api/v1/site-admin/units/{a2}/advance-exit-settlements?site_id={fixture.site_id}",
                           manager.token, body=body)
        assert created["status"] == "PENDING"
        assert tenant_advance() == "300.00"  # nothing leaves yet

        decide = f"/api/v1/site-admin/advance-exit-settlements/{created['id']}/decide"
        approval = {"approve": True, "payment_reference": "E2E-REF-1" if kind == "PAYOUT" else None, "note": None}
        with pytest.raises(ApiError):
            api.call("POST", decide, manager.token, body=approval)  # the requester cannot approve
        assert tenant_advance() == "300.00"

        api.call("POST", decide, reviewer.token, body=approval)
        assert stack.sql(
            f"SELECT COALESCE(SUM(balance), 0) FROM advance_balances WHERE unit_id = {int(a2)} AND debtor_type = 'TENANT';"
        ) == "0.00"
        owner_advance = stack.sql(
            f"SELECT COALESCE(SUM(balance), 0) FROM advance_balances WHERE unit_id = {int(a2)} AND debtor_type = 'OWNER';"
        )
        assert owner_advance == ("300.00" if kind == "TRANSFER" else "0")
        disbursements = stack.sql(
            "SELECT COUNT(*) FROM advance_exit_disbursements d JOIN advance_exit_settlements s ON s.id = d.settlement_id "
            f"WHERE s.unit_id = {int(a2)};"
        )
        assert disbursements == ("1" if kind == "PAYOUT" else "0")
        assert stack.sql(f"SELECT site_id FROM advance_exit_settlements WHERE id = '{created['id']}';") == str(site)


@pytest.mark.covers("SC-13-05-08")
@pytest.mark.edge
@pytest.mark.role_manager
def test_second_move_out_and_move_in_on_an_occupied_unit_are_refused(request, api, actors, stack):
    with journey_site(request, api, actors, stack, "F5") as (fixture, _):
        a5, a1 = fixture.unit_ids[4], fixture.unit_ids[0]
        site = fixture.site_id
        token = fixture.manager.token
        status, _ = raw_call(api, "POST", f"/api/v1/site-admin/units/{a5}/move-out?site_id={site}", token, {"notes": "x"})
        assert status == 200
        after_first = financial_snapshot(stack, site)

        status, body = raw_call(api, "POST", f"/api/v1/site-admin/units/{a5}/move-out?site_id={site}", token, {"notes": "x"})
        assert status == 409
        assert "not allowed while the unit is VACANT" in body

        selin = stack.sql(f"SELECT id FROM persons WHERE site_id = {int(site)} AND full_name = 'Selin Demir';")
        state = json.loads(raw_call(api, "GET", f"/api/v1/site-admin/units/{a1}/occupancy-state?site_id={site}", token)[1])
        assert state["occupancy"] == "OWNER_OCCUPIED"
        assert "TENANT_MOVE_IN" not in state["allowed_commands"]
        status, body = raw_call(
            api, "POST", f"/api/v1/site-admin/units/{a1}/occupancy-transitions?site_id={site}", token,
            {"command": "TENANT_MOVE_IN", "effective_date": "2026-11-19", "person_id": int(selin)},
        )
        assert status == 409
        assert "not allowed while the unit is OWNER_OCCUPIED" in body

        assert financial_snapshot(stack, site) == after_first  # no financial, occupancy or household row changed


@pytest.mark.covers("SC-13-05-12")
@pytest.mark.core
@pytest.mark.role_resident
def test_resident_cannot_call_manager_actions(request, api, actors, stack):
    with journey_site(request, api, actors, stack, "F5") as (fixture, _):
        site = fixture.site_id
        a5 = fixture.unit_ids[4]
        email = stack.sql(f"SELECT email FROM persons WHERE site_id = {int(site)} AND full_name = 'Deniz Arslan';")
        deniz = api.login(email, fixture.manager_password)
        assert deniz.user["role"] == "HOME_RESIDENT"
        before = financial_snapshot(stack, site)

        calls = [
            ("POST", "/api/v1/dues/accrue-period",
             {"site_id": site, "period": "Aralık 2026", "due_date": "2026-12-10"}),
            ("POST", "/api/v1/payments/record-manual",
             {"site_id": site, "unit_id": a5, "amount": "100.00", "payer_name": "Deniz Arslan", "payer_role": "TENANT",
              "payment_channel": "MANUAL_CASH", "idempotency_key": "resident-denied"}),
            ("POST", f"/api/v1/site-admin/units/{a5}/move-out?site_id={site}", {"notes": "x"}),
        ]
        for method, path, body in calls:
            assert raw_call(api, method, path, deniz.token, body)[0] == 403, path
        assert financial_snapshot(stack, site) == before


@pytest.mark.covers("SC-13-05-13")
@pytest.mark.core
@pytest.mark.role_manager
def test_manager_of_another_site_sees_nothing_of_this_site(request, api, actors, stack):
    with journey_site(request, api, actors, stack, "F5") as (home, _):
        with journey_site(request, api, actors, stack, "F5", name_suffix="other") as (other, _):
            for owner, intruder in ((home, other), (other, home)):
                site = owner.site_id
                unit = owner.unit_ids[4]
                person = stack.sql(f"SELECT id FROM persons WHERE site_id = {int(site)} AND full_name = 'Deniz Arslan';")
                email = stack.sql(f"SELECT email FROM persons WHERE id = {int(person)};")
                paths = [
                    f"/api/v1/site-admin/units?site_id={site}",
                    f"/api/v1/site-admin/persons?site_id={site}",
                    f"/api/v1/site-admin/persons/{person}?site_id={site}",
                    f"/api/v1/site-admin/persons/{person}/card?site_id={site}",
                    f"/api/v1/residents/{unit}/statement",
                    f"/api/v1/payments/stream?site_id={site}",
                    f"/api/v1/site-admin/overview?site_id={site}",
                    f"/api/v1/payments/debt-aging?site_id={site}",
                    f"/api/v1/site-admin/units/{unit}/occupancy-state?site_id={site}",
                ]
                for path in paths:
                    status, body = raw_call(api, "GET", path, intruder.manager.token)
                    assert status in (403, 404), (path, status)
                    assert "Deniz Arslan" not in body and email not in body, path
            ledger_invariants(api, home.manager, home.site_id, stage="SC-13-05-13-home")
            ledger_invariants(api, other.manager, other.site_id, stage="SC-13-05-13-other")
