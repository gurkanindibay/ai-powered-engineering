"""Backend journey assertions for the payment corner cases of STORY-13-04 (EPIC-13).

Covers:
- SC-13-04-07: The same bank transaction sent twice is applied once
- SC-13-04-08: Two transfers for one unit at the same moment are both applied
- SC-13-04-09: A transfer matched to another site is applied only there
- SC-13-04-11: A correction after a partial payment moves the paid amount to the advance
- SC-13-04-12: The requester of a correction cannot approve it
- SC-13-04-14: A payment reversal restores the debt it settled and the fee it stopped
- SC-13-04-15: A unit-level transfer on a unit with several debtors waits for the manager
- SC-13-04-16: A payment for a unit with no debt becomes the payer's advance
- SC-13-09-07: An unmatched statement item is assigned, then approved exactly once

Expected values come from the F2/F5 fixture plan (docs/testing/journey-plan), never from the
response under test. Money is Decimal only; refusals compare a full financial snapshot.
"""
from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal

import os
from contextlib import contextmanager
from pathlib import Path

import pytest

from support.api import ApiError
from support.journey_attempts import JourneyClock, JourneyManifest, ledger_invariants, make_viban, teardown_sites
from support.journey_occupancy import build_f6
from support.journey_snapshots import (
    financial_snapshot,
    journey_site,
    money,
    open_items,
    second_manager,
    unit_position,
)

D = Decimal
BANK_CODE = "00205"


def _stream_refs(api, manager, reference: str) -> list[dict]:
    stream = api.payment_stream(manager)
    return [e for e in stream.get("entries", []) if e.get("external_reference") == reference]


def _step_up(api, fixture) -> None:
    api.call("POST", "/api/v1/auth/step-up", fixture.manager.token, body={"password": fixture.manager_password})


@pytest.mark.covers("SC-13-04-07")
@pytest.mark.edge
@pytest.mark.role_manager
def test_same_bank_transaction_sent_twice_is_applied_once(request, api, actors, stack):
    with journey_site(request, api, actors, stack, "F5") as (fixture, _):
        a3 = fixture.unit_ids[2]
        viban = make_viban(BANK_CODE, fixture.site_id, "A", 3)

        first = api.webhook_transfer(viban, D("1675.00"), "TX-001")
        assert first["status"] == "CLEARED"
        after_first = financial_snapshot(stack, fixture.site_id)

        second = api.webhook_transfer(viban, D("1675.00"), "TX-001")
        assert second["status"] == "DUPLICATE_IGNORED"  # acknowledged with HTTP 200, not an error to retry

        assert len(_stream_refs(api, fixture.manager, "TX-001")) == 1
        assert unit_position(api, fixture.manager, fixture.site_id, a3) == (D("0.00"), D("0.00"))
        assert financial_snapshot(stack, fixture.site_id) == after_first
        ledger_invariants(api, fixture.manager, fixture.site_id, stage="SC-13-04-07")


@pytest.mark.covers("SC-13-04-08")
@pytest.mark.edge
@pytest.mark.role_manager
def test_two_parallel_transfers_for_one_unit_are_both_applied(request, api, actors, stack):
    with journey_site(request, api, actors, stack, "F5") as (fixture, _):
        a5 = fixture.unit_ids[4]
        viban = make_viban(BANK_CODE, fixture.site_id, "A", 5)

        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [
                pool.submit(api.webhook_transfer, viban, D("1000.00"), reference)
                for reference in ("TX-PAR-1", "TX-PAR-2")
            ]
            results = [future.result() for future in futures]
        assert [r["status"] for r in results] == ["CLEARED", "CLEARED"]

        assert unit_position(api, fixture.manager, fixture.site_id, a5) == (D("2797.50"), D("0.00"))
        for reference in ("TX-PAR-1", "TX-PAR-2"):
            assert len(_stream_refs(api, fixture.manager, reference)) == 1
        rows = stack.sql(
            "SELECT pe.external_reference || '|' || SUM(pa.principal_amount + pa.penalty_amount) "
            "FROM payment_entries pe JOIN payment_allocations pa ON pa.payment_entry_id = pe.id "
            f"WHERE pe.site_id = {int(fixture.site_id)} AND pe.external_reference LIKE 'TX-PAR-%' "
            "GROUP BY pe.external_reference ORDER BY 1;"
        ).splitlines()
        assert rows == ["TX-PAR-1|1000.00", "TX-PAR-2|1000.00"]  # each allocated exactly once
        ledger_invariants(api, fixture.manager, fixture.site_id, stage="SC-13-04-08")


@pytest.mark.covers("SC-13-04-09")
@pytest.mark.edge
@pytest.mark.role_manager
def test_transfer_for_another_site_is_applied_only_there(request, api, actors, stack):
    with journey_site(request, api, actors, stack, "F5") as (home, _):
        with journey_site(request, api, actors, stack, "F5", name_suffix="other") as (other, _):
            a4_other = other.unit_ids[3]  # the one current liability: Kasım 2026, 1500.00 plus 22.50 fee
            before_home = financial_snapshot(stack, home.site_id)
            before_other = financial_snapshot(stack, other.site_id)

            viban = make_viban(BANK_CODE, other.site_id, "A", 4)
            response = api.webhook_transfer(viban, D("1522.50"), "TX-OTHER-1")
            assert response["status"] == "CLEARED"

            assert unit_position(api, other.manager, other.site_id, a4_other) == (D("0.00"), D("0.00"))
            assert len(_stream_refs(api, other.manager, "TX-OTHER-1")) == 1
            assert _stream_refs(api, home.manager, "TX-OTHER-1") == []
            assert financial_snapshot(stack, other.site_id) != before_other
            assert financial_snapshot(stack, home.site_id) == before_home  # no balance of the original site changed
            ledger_invariants(api, home.manager, home.site_id, stage="SC-13-04-09-home")
            ledger_invariants(api, other.manager, other.site_id, stage="SC-13-04-09-other")


@pytest.mark.covers("SC-13-04-11")
@pytest.mark.core
@pytest.mark.role_manager
def test_correction_after_partial_payment_moves_paid_amount_to_advance(request, api, actors, stack):
    with journey_site(request, api, actors, stack, "F2") as (fixture, _):
        a5 = fixture.unit_ids[4]
        clock = JourneyClock(api, "2026-09-01")
        api.accrue_period(fixture.manager, "Eylül 2026", None, "2026-09-10")
        clock.advance_to("2026-09-10")
        receipt = api.record_manual_payment(
            fixture.manager, a5, D("600.00"), "Deniz Arslan", payer_role="TENANT"
        )
        original_receipt = stack.sql(
            f"SELECT id || '|' || total_amount FROM payment_receipts WHERE site_id = {int(fixture.site_id)};"
        )
        assert original_receipt.endswith("|600.00"), receipt

        items = open_items(api, fixture.manager, a5, "TENANT")
        assert [(i["period"], money(i["principal_outstanding"])) for i in items] == [("Eylül 2026", D("900.00"))]
        due_id = items[0]["due_id"]

        reviewer = second_manager(api, stack, fixture)
        fixture_manager = api.login(fixture.manager_email, fixture.manager_password)
        correction = api.call(
            "POST", "/api/v1/accrual-corrections", fixture_manager.token,
            body={"due_id": due_id, "kind": "CANCEL", "reason": "Charged to the wrong unit"},
        )
        decided = api.call(
            "POST", f"/api/v1/accrual-corrections/{correction['id']}/decide", reviewer.token,
            body={"approve": True, "note": "Confirmed"},
        )
        assert decided["status"] == "APPROVED"
        assert money(decided["advance_credited"]) == D("600.00")

        assert stack.sql(f"SELECT status FROM dues_liabilities WHERE id = {int(due_id)};") == "CANCELLED"
        assert open_items(api, fixture_manager, a5, "TENANT") == []  # nothing outstanding
        assert unit_position(api, fixture_manager, fixture.site_id, a5) == (D("0.00"), D("600.00"))
        assert stack.sql(
            f"SELECT COALESCE(SUM(amount), 0) FROM advance_ledger_entries WHERE unit_id = {int(a5)};"
        ) == "600.00"
        assert stack.sql(
            f"SELECT id || '|' || total_amount FROM payment_receipts WHERE site_id = {int(fixture.site_id)};"
        ) == original_receipt  # the original receipt keeps its original amount
        ledger_invariants(api, fixture_manager, fixture.site_id, stage="SC-13-04-11")


@pytest.mark.covers("SC-13-04-12")
@pytest.mark.edge
@pytest.mark.role_manager
def test_requester_of_a_correction_cannot_approve_it(request, api, actors, stack):
    with journey_site(request, api, actors, stack, "F5") as (fixture, _):
        a5 = fixture.unit_ids[4]
        due_id = open_items(api, fixture.manager, a5, "TENANT")[0]["due_id"]
        correction = api.call(
            "POST", "/api/v1/accrual-corrections", fixture.manager.token,
            body={"due_id": due_id, "kind": "CREDIT_NOTE", "amount": "500.00", "reason": "Billing error"},
        )
        assert correction["status"] == "PENDING"
        before = financial_snapshot(stack, fixture.site_id)

        with pytest.raises(ApiError) as refused:
            api.call(
                "POST", f"/api/v1/accrual-corrections/{correction['id']}/decide", fixture.manager.token,
                body={"approve": True, "note": "self approval"},
            )
        assert "four-eyes" in str(refused.value)

        assert stack.sql(f"SELECT status FROM accrual_corrections WHERE id = {int(correction['id'])};") == "PENDING"
        assert financial_snapshot(stack, fixture.site_id) == before  # the liability is unchanged
        ledger_invariants(api, fixture.manager, fixture.site_id, stage="SC-13-04-12")


@pytest.mark.covers("SC-13-04-14")
@pytest.mark.core
@pytest.mark.role_manager
def test_payment_reversal_restores_the_debt_and_the_fee(request, api, actors, stack):
    with journey_site(request, api, actors, stack, "F5") as (fixture, _):
        a3 = fixture.unit_ids[2]
        site = int(fixture.site_id)
        before_payment = financial_snapshot(stack, fixture.site_id)
        paid = api.record_manual_payment(
            fixture.manager, a3, D("1675.00"), "Burak Şahin", payer_role="OWNER"
        )
        assert unit_position(api, fixture.manager, fixture.site_id, a3) == (D("0.00"), D("0.00"))
        receipt_number = stack.sql(
            f"SELECT receipt_number FROM payment_receipts WHERE site_id = {site} AND receipt_type = 'COLLECTION' "
            f"AND unit_id = {int(a3)} AND total_amount = 1675.00;"
        )
        assert receipt_number, paid

        _step_up(api, fixture)
        reversal = api.call(
            "POST", "/api/v1/payments/reverse", fixture.manager.token,
            body={"receipt": receipt_number, "reason": "bounced transfer"},
        )
        assert reversal["reversed_receipt_number"] == receipt_number

        assert unit_position(api, fixture.manager, fixture.site_id, a3) == (D("1675.00"), D("0.00"))
        (item,) = open_items(api, fixture.manager, a3, "OWNER")
        assert item["period"] == "Eylül 2026"
        assert money(item["principal_outstanding"]) == D("1500.00")
        assert money(item["penalty_outstanding"]) == D("175.00")  # the fee still runs from the original due date
        assert str(item["due_date"]) == str(item["effective_due_date"]) == "2026-09-10"

        reversed_row = stack.sql(
            "SELECT r.receipt_type || '|' || o.receipt_number FROM payment_receipts r "
            f"JOIN payment_receipts o ON o.id = r.reverses_receipt_id WHERE r.site_id = {site};"
        )
        assert reversed_row == f"REVERSAL|{receipt_number}"
        entry = stack.sql(
            "SELECT reversal_reason || '|' || COALESCE(recorded_by, '') FROM payment_entries "
            f"WHERE site_id = {site} AND entry_type = 'REVERSAL';"
        )
        reason, operator = entry.split("|")
        assert reason == "bounced transfer"
        assert operator, "the reversal records the operator"

        after_reversal = financial_snapshot(stack, fixture.site_id)
        replay = api.call(
            "POST", "/api/v1/payments/reverse", fixture.manager.token,
            body={"receipt": receipt_number, "reason": "bounced transfer again"},
        )
        # A receipt is reversed at most once: the retry returns the first reversal and writes nothing.
        assert replay["reversal_receipt"]["receipt_number"] == reversal["reversal_receipt"]["receipt_number"]
        assert financial_snapshot(stack, fixture.site_id) == after_reversal
        assert after_reversal != before_payment  # the reversal itself is recorded
        ledger_invariants(api, fixture.manager, fixture.site_id, stage="SC-13-04-14")


@pytest.mark.covers("SC-13-04-16")
@pytest.mark.edge
@pytest.mark.role_manager
def test_payment_for_unit_without_debt_becomes_the_payers_advance(request, api, actors, stack):
    with journey_site(request, api, actors, stack, "F5") as (fixture, _):
        a1 = fixture.unit_ids[0]
        api.record_manual_payment(fixture.manager, a1, D("500.00"), "Ayşe Kaya", payer_role="OWNER")

        assert unit_position(api, fixture.manager, fixture.site_id, a1) == (D("0.00"), D("500.00"))
        assert stack.sql(
            f"SELECT debtor_type || '|' || balance FROM advance_balances WHERE unit_id = {int(a1)};"
        ) == "OWNER|500.00"
        receipt = stack.sql(
            "SELECT payer_name || '|' || allocated_principal || '|' || allocated_penalty || '|' || allocated_advance "
            f"FROM payment_receipts WHERE unit_id = {int(a1)} AND total_amount = 500.00;"
        )
        assert receipt == "Ayşe Kaya|0.00|0.00|500.00"  # the receipt shows the amount as an advance
        ledger_invariants(api, fixture.manager, fixture.site_id, stage="SC-13-04-16")


@contextmanager
def _multi_debtor_unit(request, api, actors, stack):
    """F6 pinned to 2026-11-18; yields the journey and unit A-2 (owner plus two tenants with open shares)."""
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = JourneyManifest.create(
        Path(__file__).resolve().parents[1] / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    try:
        j = build_f6(api=api, stack=stack, saas=saas, manifest=manifest)
        j.clock.set_date("2026-11-18")  # the four-eyes setup restarted the backend; pin the fixture date again
        yield j, j.unit_id(2)
    finally:
        manifest.save()
        teardown_sites(stack, manifest, restart=False)


def _debtor_items(api, j, unit_id: str, debtor_type: str) -> list[tuple[str, Decimal, Decimal]]:
    return [
        (i["period"], money(i["principal_outstanding"]), money(i["penalty_outstanding"]))
        for i in open_items(api, j.manager, unit_id, debtor_type)
    ]


def _hold_transfer(api, stack, j, a2: str) -> dict:
    viban = make_viban(BANK_CODE, j.site_id, "A", 2)
    held = api.webhook_transfer(viban, D("800.00"), "TX-MD-1")
    assert held["status"] == "UNMATCHED"
    assert held["message"] == "several open debtors"
    queue = api.call("GET", f"/api/v1/bank/statements/reconciliation-queue?site_id={j.site_id}", j.manager.token)
    (item,) = [m for m in queue if m["transaction"]["transaction_id"] == "TX-MD-1"]
    return item


@pytest.mark.covers("SC-13-04-15")
@pytest.mark.core
@pytest.mark.role_manager
def test_transfer_on_unit_with_several_debtors_is_held_for_the_manager(request, api, actors, stack):
    with _multi_debtor_unit(request, api, actors, stack) as (j, a2):
        owner_before = _debtor_items(api, j, a2, "OWNER")
        tenant_before = _debtor_items(api, j, a2, "TENANT")
        # Owner Ahmet Yılmaz, tenant Selin Demir (Ekim share) and tenant Mert Kılıç (Kasım share) all owe.
        assert [(p, pr) for p, pr, _ in owner_before] == [("Eylül 2026", D("1500.00")), ("Ekim 2026", D("483.87"))]
        assert [(p, pr) for p, pr, _ in tenant_before] == [("Ekim 2026", D("1016.13")), ("Kasım 2026", D("1500.00"))]
        before = financial_snapshot(stack, j.site_id)

        item = _hold_transfer(api, stack, j, a2)
        assert item["status"] == "UNMATCHED"
        assert item["notes"] == "several open debtors"
        assert money(item["transaction"]["amount"]) == D("800.00")

        assert _debtor_items(api, j, a2, "OWNER") == owner_before  # no share of any debtor is reduced
        assert _debtor_items(api, j, a2, "TENANT") == tenant_before
        assert stack.sql(f"SELECT COUNT(*) FROM payment_receipts WHERE site_id = {int(j.site_id)};") == "0"
        after = financial_snapshot(stack, j.site_id).split("|")
        expected = before.split("|")
        expected[8] = str(int(expected[8]) + 1)  # only the reconciliation queue gained the held item
        assert after == expected
        j.invariants("SC-13-04-15-held")


@pytest.mark.covers("SC-13-04-15")
@pytest.mark.core
@pytest.mark.role_manager
def test_approved_held_transfer_settles_only_the_assigned_person(request, api, actors, stack):
    with _multi_debtor_unit(request, api, actors, stack) as (j, a2):
        item = _hold_transfer(api, stack, j, a2)
        # The closest the API offers to "assign to Mert Kılıç" is the TENANT role (he is the current tenant).
        api.call(
            "POST", "/api/v1/bank/statements/confirm-reconciliation", j.manager.token,
            body={"site_id": j.site_id, "match_ids": [item["match_id"]],
                  "debtor_assignments": {item["match_id"]: "TENANT"}},
        )

        def paid(person: str, period: str) -> Decimal:
            return D(stack.sql(
                "SELECT COALESCE(SUM(d.paid_amount), 0) FROM dues_liabilities d JOIN persons p ON p.id = d.liable_person_id "
                f"WHERE d.unit_id = {int(a2)} AND p.full_name = '{person}' AND d.period = '{period}';"
            ))

        # 800.00 clears Mert's Kasım fee and principal; Selin's Ekim share and Ahmet's shares stay untouched.
        assert paid("Mert Kılıç", "Kasım 2026") == D("800.00")
        assert paid("Selin Demir", "Ekim 2026") == D("0.00")
        assert paid("Ahmet Yılmaz", "Eylül 2026") == D("0.00")
        assert paid("Ahmet Yılmaz", "Ekim 2026") == D("0.00")
        assert stack.sql(f"SELECT COALESCE(SUM(allocated_advance), 0) FROM payment_receipts WHERE site_id = {int(j.site_id)};") == "0.00"
        assert stack.sql(f"SELECT payer_name || '|' || payer_role FROM payment_receipts WHERE site_id = {int(j.site_id)};") == "Mert Kılıç|TENANT"
        j.invariants("SC-13-04-15-approved")


def _statement_counts(stack, unit_id: str) -> tuple[int, int, Decimal]:
    """Receipts, payment entries and allocated money of one unit."""
    unit = int(unit_id)
    row = stack.sql(
        "SELECT (SELECT COUNT(*) FROM payment_receipts WHERE unit_id = {unit}) || '|' || "
        "(SELECT COUNT(*) FROM payment_entries WHERE unit_id = {unit}) || '|' || "
        "(SELECT COALESCE(SUM(a.principal_amount + a.penalty_amount), 0) FROM payment_allocations a "
        "JOIN payment_entries e ON e.id = a.payment_entry_id WHERE e.unit_id = {unit});".format(unit=unit)
    )
    receipts, entries, allocated = row.split("|")
    return int(receipts), int(entries), D(allocated)


@pytest.mark.covers("SC-13-09-07")
@pytest.mark.core
@pytest.mark.role_manager
def test_unmatched_statement_item_is_assigned_and_approved_exactly_once(request, api, actors, stack):
    with journey_site(request, api, actors, stack, "F5") as (fixture, _):
        a3 = fixture.unit_ids[2]
        # F5: A-3 owes the September principal 1500.00 plus the 175.00 fee at the pinned date.
        assert unit_position(api, fixture.manager, fixture.site_id, a3) == (D("1675.00"), D("0.00"))

        # An imported statement line with an unknown sender and no unit narrative.
        parsed = api.call(
            "POST", "/api/v1/bank/statements/parse", fixture.manager.token,
            body={
                "site_id": fixture.site_id,
                "content": "2026-11-19;TR120006200000000000001099;FAST TRANSFERI;1675.00",
                "format": "CSV",
            },
        )
        (item,) = [m for m in parsed["matches"] if m["status"] == "UNMATCHED"]
        match_id = item["match_id"]
        assert item["matched_unit_id"] is None

        queue = api.call(
            "GET", f"/api/v1/bank/statements/reconciliation-queue?site_id={fixture.site_id}", fixture.manager.token,
        )
        assert [m["match_id"] for m in queue if m["status"] == "UNMATCHED"] == [match_id]
        assert unit_position(api, fixture.manager, fixture.site_id, a3) == (D("1675.00"), D("0.00"))
        # A-3's earlier paid months stay untouched until the assignment is approved.
        baseline = _statement_counts(stack, a3)

        assigned = api.call(
            "POST", f"/api/v1/bank/statements/reconciliation-queue/{match_id}/assign", fixture.manager.token,
            body={"site_id": fixture.site_id, "unit_id": a3, "debtor_role": "OWNER"},
        )
        assert assigned["match_id"] == match_id
        assert assigned["assigned_unit_id"] == a3
        assert assigned["assigned_debtor_role"] == "OWNER"
        # Assigning the same pair again is idempotent and settles nothing yet.
        again = api.call(
            "POST", f"/api/v1/bank/statements/reconciliation-queue/{match_id}/assign", fixture.manager.token,
            body={"site_id": fixture.site_id, "unit_id": a3, "debtor_role": "OWNER"},
        )
        assert again["assigned_unit_id"] == a3
        assert unit_position(api, fixture.manager, fixture.site_id, a3) == (D("1675.00"), D("0.00"))
        assert _statement_counts(stack, a3) == baseline

        confirmed = api.call(
            "POST", "/api/v1/bank/statements/confirm-reconciliation", fixture.manager.token,
            body={"site_id": fixture.site_id, "match_ids": [match_id]},
        )
        assert confirmed["confirmed_count"] == 1
        assert unit_position(api, fixture.manager, fixture.site_id, a3) == (D("0.00"), D("0.00"))
        settled = _statement_counts(stack, a3)
        assert (settled[0], settled[1]) == (baseline[0] + 1, baseline[1] + 1)
        assert settled[2] == baseline[2] + D("1675.00")

        # A repeated approval returns the same single settlement, not a second one.
        retry = api.call(
            "POST", "/api/v1/bank/statements/confirm-reconciliation", fixture.manager.token,
            body={"site_id": fixture.site_id, "match_ids": [match_id]},
        )
        assert retry["confirmed_count"] == 1
        assert _statement_counts(stack, a3) == settled
        assert unit_position(api, fixture.manager, fixture.site_id, a3) == (D("0.00"), D("0.00"))
        ledger_invariants(api, fixture.manager, fixture.site_id, stage="SC-13-09-07")
