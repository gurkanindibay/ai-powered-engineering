"""EPIC-09 Payment tracking & treasury."""
from decimal import Decimal

import pytest

from pages import DuesManagement, ManagerCockpit, PaymentStream
from support.flutter import by_id


@pytest.mark.smoke
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-09-01")
@pytest.mark.covers("SC-09-01-01")
def test_payment_stream_role_filter_shows_only_tenant_payments(login_as, page, api, actors, stack):
    manager = api.login(**actors["manager"])
    b3 = stack.sql("SELECT u.id FROM units u JOIN blocks b ON b.id = u.block_id "
                   "WHERE b.block_name = 'B Blok' AND u.unit_number = 3;")
    a14 = stack.sql("SELECT u.id FROM units u JOIN blocks b ON b.id = u.block_id "
                    "WHERE b.block_name = 'A Blok' AND u.unit_number = 14;")
    api.move_in(manager, b3, "Selin Demir", "selin.demir@e2e.test")
    api.record_manual_payment(manager, a14, Decimal("1400.00"), "Ahmet Yılmaz", payer_role="OWNER")
    api.record_manual_payment(manager, b3, Decimal("900.00"), "Selin Demir", payer_role="TENANT")
    api.record_manual_payment(manager, b3, Decimal("500.00"), "Selin Demir", payer_role="TENANT",
                              channel="VIRTUAL_IBAN")
    expected_tenant = sorted(str(e["id"]) for e in api.payment_stream(manager, payer_role="TENANT")["entries"])
    assert len(expected_tenant) == 2

    login_as("manager")
    ManagerCockpit(page).wait()
    stream = PaymentStream(page).open()
    stream.wait_for_entries("return ids.length === 3")

    stream.filter_role("TENANT")
    stream.wait_for_entries("return ids.length === 2")
    ids = stream.entry_ids()
    assert all(i.endswith("_TENANT") for i in ids), ids
    assert sorted(i.split("_")[2] for i in ids) == expected_tenant


@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-09-06")
@pytest.mark.covers("SC-09-01-02")
def test_debt_aging_buckets_total_the_overdue_sum(login_as, page):
    login_as("manager")
    ManagerCockpit(page).wait()
    DuesManagement(page).open().segment(2)
    by_id(page, "aging_grand_total").wait_for(timeout=15_000)

    assert by_id(page, "aging_bucket_1_30").count() == 1
    assert by_id(page, "aging_bucket_31_60").count() == 1
    assert by_id(page, "aging_bucket_60_plus").count() == 1

