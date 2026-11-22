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
from support.journey_attempts import make_viban
from support.journey_snapshots import (
    audit_event_count,
    audit_mark,
    financial_snapshot,
    journey_site,
    money,
    new_audit_rows,
    open_items,
    second_manager,
)

D = Decimal
PERIOD, DUE = "Ekim 2026", "2026-10-10"


def _step_up(api, fixture) -> None:
    api.call("POST", "/api/v1/auth/step-up", fixture.manager.token, body={"password": fixture.manager_password})



def _status(stack, site: str) -> str:
    return stack.sql(f"SELECT status FROM dues_periods WHERE site_id = {int(site)};")


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
            api.accrue_period(fixture.manager, PERIOD, None, DUE)
        period_id = stack.sql(f"SELECT id FROM dues_periods WHERE site_id = {int(site)};")
        if status == "CLOSED":
            assert raw_call(api, "POST", f"/api/v1/dues/periods/{period_id}/close", token, {"site_id": site})[0] == 200
        assert _status(stack, site) == status
        before, audit_before = financial_snapshot(stack, site), audit_event_count(stack, site)
        audit_before_id = audit_mark(stack, site)

        def accrue() -> tuple[int, str]:
            body = {"site_id": site, "period": PERIOD, "due_date": DUE}
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
            assert audit_event_count(stack, site) == audit_before, new_audit_rows(stack, site, audit_before_id)
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
            assert audit_event_count(stack, site) == audit_before, new_audit_rows(stack, site, audit_before_id)


@pytest.mark.covers("SC-13-11-02")
@pytest.mark.edge
@pytest.mark.role_manager
@pytest.mark.parametrize(
    "unit_name, period, status, command",
    [
        ("A-1", "Eylül 2026", "PAID", "records a 100.00 payment designating"),
        ("A-1", "Eylül 2026", "PAID", "requests a 100.00 credit note on"),
        ("A-5", "Eylül 2026", "CANCELLED", "records a 100.00 payment designating"),
        ("A-5", "Eylül 2026", "CANCELLED", "requests cancellation of"),
    ],
)
def test_settled_or_cancelled_liability_cannot_be_paid_or_corrected(
    request, api, actors, stack, unit_name, period, status, command
):
    with journey_site(request, api, actors, stack, "F5") as (fixture, _):
        site, token = fixture.site_id, fixture.manager.token
        unit_idx = int(unit_name.split("-")[1]) - 1
        unit_id = fixture.unit_ids[unit_idx]

        due_row = stack.sql(
            f"SELECT id, status FROM dues_liabilities WHERE unit_id = {int(unit_id)} AND period = '{period}' ORDER BY id LIMIT 1;"
        )
        assert due_row, f"Due for {unit_name} {period} not found"
        due_id, initial_status = due_row.split("|")

        if status == "CANCELLED":
            reviewer = second_manager(api, stack, fixture)
            mgr = api.login(fixture.manager_email, fixture.manager_password)
            corr = api.call(
                "POST",
                "/api/v1/accrual-corrections",
                mgr.token,
                body={"due_id": due_id, "kind": "CANCEL", "reason": "Approved cancellation setup"},
            )
            api.call(
                "POST",
                f"/api/v1/accrual-corrections/{corr['id']}/decide",
                reviewer.token,
                body={"approve": True, "note": "Approved"},
            )
            assert stack.sql(f"SELECT status FROM dues_liabilities WHERE id = {int(due_id)};") == "CANCELLED"
        else:
            assert initial_status == status

        before_snap = financial_snapshot(stack, site)
        before_pay_count = stack.sql(f"SELECT count(*) FROM payment_entries WHERE site_id = {int(site)};")
        before_alloc_count = stack.sql(
            f"SELECT count(*) FROM payment_allocations WHERE dues_liability_id = {int(due_id)};"
        )
        before_adv_count = stack.sql(f"SELECT count(*) FROM advance_ledger_entries WHERE unit_id = {int(unit_id)};")
        before_corr_count = stack.sql(f"SELECT count(*) FROM accrual_corrections WHERE site_id = {int(site)};")

        payer_role = "TENANT" if unit_name == "A-5" else "OWNER"
        payer_name = "Deniz Arslan" if unit_name == "A-5" else "Ayşe Kaya"

        if command == "records a 100.00 payment designating":
            code, body = raw_call(
                api,
                "POST",
                "/api/v1/payments/record-manual",
                token,
                {
                    "site_id": site,
                    "unit_id": unit_id,
                    "amount": "100.00",
                    "payer_name": payer_name,
                    "payer_role": payer_role,
                    "payment_channel": "BANK_TRANSFER",
                    "designation": {
                        "due_ids": [str(due_id)],
                        "periods": [period],
                    },
                },
            )
        elif command == "requests a 100.00 credit note on":
            code, body = raw_call(
                api,
                "POST",
                "/api/v1/accrual-corrections",
                token,
                {"due_id": str(due_id), "kind": "CREDIT_NOTE", "amount": "100.00", "reason": "Test credit note"},
            )
        elif command == "requests cancellation of":
            code, body = raw_call(
                api,
                "POST",
                "/api/v1/accrual-corrections",
                token,
                {"due_id": str(due_id), "kind": "CANCEL", "reason": "Test cancel again"},
            )
        else:
            raise ValueError(f"Unknown command: {command}")

        assert code == 409, f"Expected 409 Conflict, got {code}: {body}"
        assert status in body.upper(), f"Expected reason naming status {status}, got: {body}"

        assert stack.sql(f"SELECT count(*) FROM payment_entries WHERE site_id = {int(site)};") == before_pay_count
        assert (
            stack.sql(f"SELECT count(*) FROM payment_allocations WHERE dues_liability_id = {int(due_id)};")
            == before_alloc_count
        )
        assert stack.sql(f"SELECT count(*) FROM advance_ledger_entries WHERE unit_id = {int(unit_id)};") == before_adv_count
        assert stack.sql(f"SELECT count(*) FROM accrual_corrections WHERE site_id = {int(site)};") == before_corr_count
        assert financial_snapshot(stack, site) == before_snap


@pytest.mark.covers("SC-13-11-03")
@pytest.mark.core
@pytest.mark.role_manager
def test_reversal_moves_paid_liability_back_to_overdue(request, api, actors, stack):
    with journey_site(request, api, actors, stack, "F5") as (fixture, _):
        site = int(fixture.site_id)
        a3 = fixture.unit_ids[2]
        due_row = stack.sql(
            f"SELECT id, status FROM dues_liabilities WHERE unit_id = {int(a3)} AND period = 'Eylül 2026';"
        )
        due_id, initial_status = due_row.split("|")
        assert initial_status == "OVERDUE"

        paid = api.record_manual_payment(
            fixture.manager,
            a3,
            D("1675.00"),
            "Burak Şahin",
            payer_role="OWNER",
            description="Eylül 2026 in full",
        )
        assert stack.sql(f"SELECT status FROM dues_liabilities WHERE id = {int(due_id)};") == "PAID"
        receipt_number = paid["receipt_number"]

        _step_up(api, fixture)
        reversal = api.call(
            "POST",
            "/api/v1/payments/reverse",
            fixture.manager.token,
            body={"receipt": receipt_number, "reason": "Bounced transfer"},
        )
        assert reversal["reversed_receipt_number"] == receipt_number

        assert stack.sql(f"SELECT status FROM dues_liabilities WHERE id = {int(due_id)};") == "OVERDUE"
        (item,) = open_items(api, fixture.manager, a3, "OWNER")
        assert item["period"] == "Eylül 2026"
        assert money(item["principal_outstanding"]) == D("1500.00")
        assert money(item["penalty_outstanding"]) == D("175.00")
        assert money(item["principal_outstanding"]) + money(item["penalty_outstanding"]) == D("1675.00")

        reversed_link = stack.sql(
            "SELECT r.receipt_type || '|' || o.receipt_number FROM payment_receipts r "
            f"JOIN payment_receipts o ON o.id = r.reverses_receipt_id WHERE r.site_id = {site};"
        )
        assert reversed_link == f"REVERSAL|{receipt_number}"
        entry = stack.sql(
            "SELECT entry_type || '|' || reversal_reason FROM payment_entries "
            f"WHERE site_id = {site} AND entry_type = 'REVERSAL';"
        )
        assert entry == "REVERSAL|Bounced transfer"


@pytest.mark.covers("SC-13-11-06")
@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.parametrize(
    "case, expected_status, expected_payments",
    [
        ("pending", "PENDING_APPROVAL", 0),
        ("approved", "APPROVED", 1),
        ("rejected", "REJECTED", 0),
        ("unmatched", "UNMATCHED", 0),
        ("already_processed", "ALREADY_PROCESSED", 1),
    ],
)
def test_bank_statement_item_reconciliation_statuses(
    request, api, actors, stack, case, expected_status, expected_payments
):
    with journey_site(request, api, actors, stack, "F5") as (fixture, _):
        site = int(fixture.site_id)
        a3 = fixture.unit_ids[2]
        viban_a3 = make_viban("00205", fixture.site_id, "A", 3)
        unknown_iban = "TR120006200000000000001099"

        if case in ("pending", "approved", "rejected", "already_processed"):
            target_iban = viban_a3
        else:
            target_iban = unknown_iban

        ref = f"STMT-1106-{case}"
        content = f"2026-11-19;{target_iban};REF-{ref};1675.00"
        parsed = api.call(
            "POST",
            "/api/v1/bank/statements/parse",
            fixture.manager.token,
            body={"site_id": fixture.site_id, "content": content, "format": "CSV"},
        )
        queue = api.call(
            "GET",
            f"/api/v1/bank/statements/reconciliation-queue?site_id={fixture.site_id}",
            fixture.manager.token,
        )
        item = next(m for m in queue if ref in str(m.get("transaction", {})))
        match_id = item["match_id"]

        if case == "pending":
            assert item["status"] == "PENDING_APPROVAL"
        elif case == "approved":
            api.call(
                "POST",
                "/api/v1/bank/statements/confirm-reconciliation",
                fixture.manager.token,
                body={"site_id": fixture.site_id, "match_ids": [match_id]},
            )
            queue_after = api.call(
                "GET",
                f"/api/v1/bank/statements/reconciliation-queue?site_id={fixture.site_id}",
                fixture.manager.token,
            )
            item_after = next(m for m in queue_after if m["match_id"] == match_id)
            assert item_after["status"] == "APPROVED"
        elif case == "rejected":
            api.call(
                "POST",
                f"/api/v1/bank/statements/reconciliation-queue/{match_id}/reject",
                fixture.manager.token,
                body={"site_id": fixture.site_id, "reason": "Not recognized"},
            )
            queue_after = api.call(
                "GET",
                f"/api/v1/bank/statements/reconciliation-queue?site_id={fixture.site_id}",
                fixture.manager.token,
            )
            item_after = next(m for m in queue_after if m["match_id"] == match_id)
            assert item_after["status"] == "REJECTED"
        elif case == "unmatched":
            assert item["status"] == "UNMATCHED"
        elif case == "already_processed":
            api.call(
                "POST",
                "/api/v1/bank/statements/confirm-reconciliation",
                fixture.manager.token,
                body={"site_id": fixture.site_id, "match_ids": [match_id]},
            )
            parsed2 = api.call(
                "POST",
                "/api/v1/bank/statements/parse",
                fixture.manager.token,
                body={"site_id": fixture.site_id, "content": content, "format": "CSV"},
            )
            matches2 = parsed2.get("matches", [])
            assert matches2, "expected parsed matches"
            assert matches2[0]["status"] == "ALREADY_PROCESSED"

        payments = int(
            stack.sql(f"SELECT count(*) FROM payment_receipts WHERE unit_id = {int(a3)} AND total_amount = 1675.00;")
        )
        assert payments == expected_payments


@pytest.mark.covers("SC-13-11-07")
@pytest.mark.edge
@pytest.mark.role_manager
def test_rejected_or_approved_statement_item_cannot_change_status_again(request, api, actors, stack):
    with journey_site(request, api, actors, stack, "F5") as (fixture, _):
        site, token = fixture.site_id, fixture.manager.token
        a3 = fixture.unit_ids[2]
        viban_a3 = make_viban("00205", site, "A", 3)

        content = f"2026-11-19;{viban_a3};REF-ITEM-1;1675.00\n2026-11-19;{viban_a3};REF-ITEM-2;1675.00"
        api.call(
            "POST",
            "/api/v1/bank/statements/parse",
            token,
            body={"site_id": site, "content": content, "format": "CSV"},
        )
        queue = api.call("GET", f"/api/v1/bank/statements/reconciliation-queue?site_id={site}", token)
        item1 = next(m for m in queue if "ITEM-1" in str(m.get("transaction", {})))
        item2 = next(m for m in queue if "ITEM-2" in str(m.get("transaction", {})))
        id1, id2 = item1["match_id"], item2["match_id"]

        api.call(
            "POST",
            "/api/v1/bank/statements/confirm-reconciliation",
            token,
            body={"site_id": site, "match_ids": [id1]},
        )
        api.call(
            "POST",
            f"/api/v1/bank/statements/reconciliation-queue/{id2}/reject",
            token,
            body={"site_id": site, "reason": "Incorrect payment"},
        )

        queue_mid = api.call("GET", f"/api/v1/bank/statements/reconciliation-queue?site_id={site}", token)
        assert next(m["status"] for m in queue_mid if m["match_id"] == id1) == "APPROVED"
        assert next(m["status"] for m in queue_mid if m["match_id"] == id2) == "REJECTED"

        code_approve_rejected, _ = raw_call(
            api,
            "POST",
            "/api/v1/bank/statements/confirm-reconciliation",
            token,
            {"site_id": site, "match_ids": [id2]},
        )
        assert code_approve_rejected == 409

        code_reject_approved, _ = raw_call(
            api,
            "POST",
            f"/api/v1/bank/statements/reconciliation-queue/{id1}/reject",
            token,
            {"site_id": site, "reason": "Attempt reject approved"},
        )
        assert code_reject_approved == 409

        queue_final = api.call("GET", f"/api/v1/bank/statements/reconciliation-queue?site_id={site}", token)
        assert next(m["status"] for m in queue_final if m["match_id"] == id1) == "APPROVED"
        assert next(m["status"] for m in queue_final if m["match_id"] == id2) == "REJECTED"

        assert (
            int(
                stack.sql(
                    f"SELECT count(*) FROM payment_receipts WHERE unit_id = {int(a3)} AND total_amount = 1675.00;"
                )
            )
            == 1
        )


@pytest.mark.covers("SC-13-11-08")
@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.parametrize(
    "unit_name, expected_state, refused_cmd, refused_kind",
    [
        ("A-7", "no owner", "move in tenant", "TENANT_MOVE_IN"),
        ("A-3", "owned, vacant", "move out tenant", "MOVE_OUT"),
        ("A-1", "owner-occupied", "move in tenant", "TENANT_MOVE_IN"),
        ("A-2", "tenant-occupied", "move in owner", "OWNER_MOVE_IN"),
    ],
)
def test_unit_occupancy_allowed_commands(
    request, api, actors, stack, unit_name, expected_state, refused_cmd, refused_kind
):
    with journey_site(request, api, actors, stack, "F5") as (fixture, _):
        site, token = fixture.site_id, fixture.manager.token
        unit_idx = int(unit_name.split("-")[1]) - 1
        unit_id = fixture.unit_ids[unit_idx]

        state_resp = api.call(
            "GET", f"/api/v1/site-admin/units/{unit_id}/occupancy-state?site_id={site}", token
        )
        allowed = state_resp.get("allowed_commands", [])

        if expected_state == "no owner":
            assert allowed == ["REGISTER_OWNER"]
        elif expected_state == "owned, vacant":
            assert allowed == ["TENANT_MOVE_IN", "OWNER_MOVE_IN", "TITLE_TRANSFER"]
        elif expected_state == "owner-occupied":
            assert allowed == ["MOVE_OUT", "OWNER_RENTS_OUT", "TITLE_TRANSFER"]
        elif expected_state == "tenant-occupied":
            assert allowed == ["MOVE_OUT", "REPLACE_TENANT", "OWNER_TAKES_BACK", "TITLE_TRANSFER"]

        occ_count = stack.sql(f"SELECT count(*) FROM unit_occupancies WHERE unit_id = {int(unit_id)};")
        own_count = stack.sql(f"SELECT count(*) FROM unit_ownerships WHERE unit_id = {int(unit_id)};")
        person_count = stack.sql(f"SELECT count(*) FROM persons WHERE site_id = {int(site)};")
        fin_snap = financial_snapshot(stack, site)

        body = {"command": refused_kind}
        if refused_kind == "TENANT_MOVE_IN":
            body["full_name"] = "Refused Tenant"
            body["email"] = "refused@example.com"
        code, err_body = raw_call(
            api, "POST", f"/api/v1/site-admin/units/{unit_id}/occupancy-transitions?site_id={site}", token, body
        )
        assert code == 409

        assert stack.sql(f"SELECT count(*) FROM unit_occupancies WHERE unit_id = {int(unit_id)};") == occ_count
        assert stack.sql(f"SELECT count(*) FROM unit_ownerships WHERE unit_id = {int(unit_id)};") == own_count
        assert stack.sql(f"SELECT count(*) FROM persons WHERE site_id = {int(site)};") == person_count
        assert financial_snapshot(stack, site) == fin_snap


