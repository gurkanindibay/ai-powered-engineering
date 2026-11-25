"""EPIC-13 journey: a confirmed bank transfer appears consistently in both views.

Covers SC-13-04-13: a resident's confirmed payment appears in their statement,
the manager's collection total and the manager's unit view, while the resident
dashboard keeps showing the remaining debt.
"""
from __future__ import annotations

import os
from decimal import Decimal
from pathlib import Path

import pytest

from pages import DuesManagement, ManagerCockpit, ResidentHome, ResidentsTab, UnitWorkspace
from pages.login import LoginPage
from support.flutter import by_id
from support.journey_attempts import (
    JourneyManifest,
    ledger_invariants,
    make_viban,
    site_in_state,
    teardown_with_evidence,
)
from support.journey_gui import amount_of, page_lines, resident_email
from support.money import format_try

E2E = Path(__file__).resolve().parents[1]
PAYMENT = Decimal("1675.00")


@pytest.mark.covers("SC-13-04-13")
@pytest.mark.core
@pytest.mark.role_resident
def test_confirmed_payment_appears_in_resident_and_manager_views(
    request, api, actors, stack, page, login_page
):
    """SC-13-04-13: one webhook receipt reduces both views by the same amount and is listed in both."""
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    fixture = None
    try:
        fixture = site_in_state("F5", api=api, stack=stack, saas=saas, manifest=manifest)
        unit_id = fixture.unit_ids[4]  # A-5: tenant Deniz Arslan
        resident_login = resident_email(stack, fixture, "Deniz Arslan")

        # Before the transfer: the manager's debt-aging grand total.
        login_page.login("manager", fixture.manager_email, fixture.manager_password)
        ManagerCockpit(page).wait()
        DuesManagement(page).open().segment(2)
        by_id(page, "aging_grand_total").wait_for(timeout=15_000)
        collection_before = amount_of(page, "aging_grand_total")

        # The resident's statement total before the transfer. The hero card shows the primary
        # (newest) liability, so the multi-period total is asserted on the statement itself.
        resident = page.context.new_page()
        try:
            LoginPage(resident, login_page.base_url).open().login(
                "resident", resident_login, fixture.manager_password
            )
            ResidentHome(resident).wait()
            by_id(resident, "resident_statement_entry").click()
            by_id(resident, "statement_debtor_tenant").wait_for(timeout=15_000)
            statement_total_before = amount_of(resident, "statement_total_tenant")
        finally:
            resident.close()
        assert statement_total_before > PAYMENT, (
            f"F5 unit A-5 must start with an open tenant total, got TRY {statement_total_before}"
        )

        # The bank confirms a 1675.00 FAST transfer to the unit's virtual IBAN.
        viban = make_viban("00205", fixture.site_id, "A", 5)
        api.webhook_transfer(viban, PAYMENT, "TX-SC-13-04-13", "DENIZ ARSLAN AIDAT")
        ledger_invariants(api, fixture.manager, fixture.site_id, stage="SC-13-04-13")

        statement = api.resident_statement(fixture.manager, unit_id)
        payment_receipts = [
            item for item in statement["receipts"]
            if Decimal(str(item["total_amount"])) == PAYMENT
        ]
        assert len(payment_receipts) == 1, (
            f"the confirmed TRY {PAYMENT} payment must issue one receipt; got {statement['receipts']}"
        )
        receipt_number = payment_receipts[0]["receipt_number"]

        # Resident view: the statement total drops by the same amount, the dashboard still
        # shows the remaining primary liability, and the statement lists the receipt.
        resident = page.context.new_page()
        try:
            LoginPage(resident, login_page.base_url).open().login(
                "resident", resident_login, fixture.manager_password
            )
            home = ResidentHome(resident).wait()
            assert home.balance() > Decimal("0.00"), "the resident dashboard still shows the remaining debt"
            by_id(resident, "resident_statement_entry").click()
            by_id(resident, "statement_debtor_tenant").wait_for(timeout=15_000)
            statement_total_after = amount_of(resident, "statement_total_tenant")
            assert statement_total_after == statement_total_before - PAYMENT, (
                "the resident statement total must drop by exactly the confirmed transfer"
            )
            resident_receipt = by_id(resident, f"statement_receipt_{receipt_number}")
            resident_receipt.wait_for(timeout=15_000)
            assert any(
                receipt_number in line and format_try(PAYMENT) in line
                for line in page_lines(resident)
            ), "the resident's Makbuzlar section must show the confirmed receipt and its amount"
        finally:
            resident.close()

        # Manager view: the collection total drops by the payment and the unit statement lists
        # the same receipt the resident saw.
        login_page.open().login("manager", fixture.manager_email, fixture.manager_password)
        ManagerCockpit(page).wait()
        DuesManagement(page).open().segment(2)
        by_id(page, "aging_grand_total").wait_for(timeout=15_000)
        assert amount_of(page, "aging_grand_total") == collection_before - PAYMENT, (
            "the manager's collection total must drop by exactly the confirmed transfer"
        )
        ResidentsTab(page).open()
        UnitWorkspace(page).open(unit_id).action(unit_id, "statement")
        manager_receipt = by_id(page, f"statement_receipt_{receipt_number}")
        manager_receipt.wait_for(timeout=15_000)
        assert any(
            receipt_number in line and format_try(PAYMENT) in line
            for line in page_lines(page)
        ), "the manager's unit statement must show the same receipt and amount"
        assert amount_of(page, "statement_total_tenant") == statement_total_after, (
            "the manager's unit statement must show the same tenant total the resident sees"
        )
        page.keyboard.press("Escape")
        UnitWorkspace(page).close()
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
        raise
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)
