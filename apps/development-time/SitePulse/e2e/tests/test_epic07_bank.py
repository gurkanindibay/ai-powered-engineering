"""EPIC-07 Bank integration & reconciliation, STORY-07-07 period accrual."""
from decimal import Decimal

import pytest

from pages import DuesManagement, ManagerCockpit
from support.bank_files import StatementRow, kuveyt_xlsx

PERIOD = "Ekim 2026"
DUES = Decimal("1400.00")


@pytest.fixture
def manager_session(api, actors):
    return api.login(**actors["manager"])


@pytest.fixture
def october_dues(api, manager_session):
    """Every unit owes the October operational dues (period + accrual through the API)."""
    api.create_period(manager_session, PERIOD, "2026-10-15")
    return api.accrue_period(manager_session, PERIOD, DUES, "2026-10-15")


def _statement(tmp_path):
    """One transfer that names A Blok D:14's owner, one from an unknown sender."""
    return kuveyt_xlsx(tmp_path / "hesap-ekstresi.xlsx", [
        StatementRow("15.10.2026", "KT0001", "HAVALE - Gönderen: AHMET YILMAZ, A BLOK D:14 EKIM AIDAT", DUES),
        StatementRow("15.10.2026", "KT0002", "Para Transferi, Gönderen: BILINMEYEN KISI , Alıcı: SITE",
                     Decimal("250.00")),
    ])


@pytest.mark.smoke
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-07-03")
def test_statement_upload_matches_known_sender_and_flags_unknown(login_as, page, tmp_path, october_dues):
    login_as("manager")
    ManagerCockpit(page).wait()

    summary = DuesManagement(page).open().upload_statement(_statement(tmp_path))

    # Amounts in this dialog are printed with toStringAsFixed ("1400.00"), not the Turkish format.
    assert summary.matched() == (1, "1400.00")
    assert summary.unmatched() == (1, "250.00")


@pytest.mark.smoke
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-07-03")
@pytest.mark.xfail(strict=True, reason="BUG: confirming matched statement rows only updates client state; "
                   "DashboardController.confirmReconciliation sends nothing to the backend, so no payment, "
                   "receipt or liability change is stored (flutter/lib/ui/dashboard/dashboard_controller.dart)")
def test_confirming_matched_rows_records_the_payment(login_as, page, tmp_path, october_dues, stack):
    login_as("manager")
    ManagerCockpit(page).wait()
    DuesManagement(page).open().upload_statement(_statement(tmp_path)).confirm_matched()
    page.wait_for_timeout(2_000)  # no UI signal for persistence; the database is the assertion

    a14 = stack.sql("SELECT u.id FROM units u JOIN blocks b ON b.id = u.block_id "
                    "WHERE b.block_name = 'A Blok' AND u.unit_number = 14;")
    assert stack.sql(f"SELECT count(*) FROM payment_entries WHERE unit_id = {int(a14)};") == "1"
    assert stack.sql(f"SELECT paid_amount FROM dues_liabilities WHERE unit_id = {int(a14)} "
                     f"AND period = '{PERIOD}';") == str(DUES)


@pytest.mark.smoke
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-07-10")
def test_period_accrual_charges_every_unit_once(login_as, page, api, manager_session, stack):
    api.create_period(manager_session, PERIOD, "2026-10-15")
    units = int(stack.sql("SELECT count(*) FROM units WHERE site_id = 1 AND deleted_at IS NULL;"))
    login_as("manager")
    ManagerCockpit(page).wait()
    dues = DuesManagement(page).open()

    period, message = dues.accrue_selected_period()
    assert period == PERIOD
    assert f"{units} daireye" in message, message
    assert stack.sql(f"SELECT count(*) FROM dues_liabilities WHERE period = '{PERIOD}';") == str(units)

    _, message = dues.accrue_selected_period()
    assert "Mükerrer tahakkuk engellendi" in message, message
    assert stack.sql(f"SELECT count(*) FROM dues_liabilities WHERE period = '{PERIOD}';") == str(units)
