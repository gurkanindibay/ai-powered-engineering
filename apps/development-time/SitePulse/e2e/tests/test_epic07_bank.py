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


@pytest.mark.covers("SC-07-02-01")
@pytest.mark.smoke
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-07-03")
def test_statement_upload_matches_known_sender_and_flags_unknown(login_as, page, tmp_path, october_dues):
    login_as("manager")
    ManagerCockpit(page).wait()

    summary = DuesManagement(page).open().upload_statement(_statement(tmp_path))

    # Amounts are printed by MoneyFormatter ("₺1.400,00") and parsed back exactly.
    assert summary.matched() == (1, Decimal("1400.00"))
    assert summary.unmatched() == (1, Decimal("250.00"))


@pytest.mark.smoke
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-07-03")
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


@pytest.mark.covers("SC-07-07-01")
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


# ---------------------------------------------------------------- P1 (core)

from pages import ResidentHome  # noqa: E402
from support.flutter import by_id, text_of  # noqa: E402
from support.money import api_amount, parse_try  # noqa: E402

A14_IBAN = "TR620020500009863791600001"


@pytest.mark.covers("SC-07-04-01")
@pytest.mark.core
@pytest.mark.role_homeowner
@pytest.mark.gui_id("GUI-07-02")
def test_checkout_offers_fast_to_the_virtual_iban(login_as, page, builders):
    builders.overdue_dues(principal=DUES, days_overdue=10)
    login_as("homeowner")
    ResidentHome(page).wait()

    by_id(page, "btn_pay_now").click()
    by_id(page, "checkout_option_virtual_iban").click()

    note = by_id(page, "checkout_fast_note")
    note.wait_for(timeout=10_000)
    assert "gerek yoktur" in text_of(note)


@pytest.mark.covers("SC-07-02-02")
@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-07-04")
def test_approved_statement_match_clears_the_homeowners_balance(login_as, login_page, page, tmp_path, october_dues,
                                                               api, actors):
    login_as("manager")
    ManagerCockpit(page).wait()
    DuesManagement(page).open().upload_statement(_statement(tmp_path)).confirm_matched()
    page.wait_for_timeout(2_000)
    homeowner = api.login(**actors["homeowner"])
    assert api_amount(api.resident_dashboard(homeowner)["total_debt"]) == Decimal("0.00")


@pytest.mark.covers("SC-07-06-02")
@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-07-07")
def test_wrong_statement_format_is_rejected_and_excel_accepted(login_as, page, tmp_path, october_dues):
    mt940 = tmp_path / "ekstre.sta"
    mt940.write_text(":20:E2E\n:25:TR620020500009863791600001\n:61:261015C1400,00NTRFNONREF\n"
                     ":86:AHMET YILMAZ A BLOK D:14 EKIM AIDAT\n-", encoding="utf-8")
    login_as("manager")
    ManagerCockpit(page).wait()
    dues = DuesManagement(page).open()

    by_id(page, "btn_open_bank_import").click()
    with page.expect_file_chooser() as chooser:
        by_id(page, "btn_import_pick_file").click()
    chooser.value.set_files(str(mt940))
    error = by_id(page, "snackbar_import_error")
    error.wait_for(timeout=10_000)
    assert "Format Reddedildi" in text_of(error)
    assert by_id(page, "import_summary_matched").count() == 0
    error.wait_for(state="detached", timeout=15_000)

    assert dues.upload_statement(_statement(tmp_path)).matched()[0] == 1


@pytest.mark.covers("SC-07-03-01")
@pytest.mark.core
@pytest.mark.role_homeowner
@pytest.mark.gui_id("GUI-07-08")
# Fixed by SPEC-005 R1/R3: the webhook settles through the canonical path, penalty first.
def test_fast_webhook_pays_the_balance_once(login_as, page, builders, api, actors, stack):
    builders.overdue_dues(principal=DUES, days_overdue=10)
    homeowner = api.login(**actors["homeowner"])
    total = api_amount(api.resident_dashboard(homeowner)["total_debt"])
    assert total > DUES  # principal plus the KMK penalty

    api.webhook_transfer(A14_IBAN, total, "E2E-FAST-0001", "AHMET YILMAZ AIDAT")
    replay = api.webhook_transfer(A14_IBAN, total, "E2E-FAST-0001", "AHMET YILMAZ AIDAT")
    assert "DUPLICATE" in str(replay).upper(), replay

    login_as("homeowner")
    assert ResidentHome(page).wait().balance() == Decimal("0.00")
    assert stack.sql("SELECT count(*) FROM processed_bank_webhooks;") == "1"
    assert stack.sql("SELECT sum(amount) FROM payment_entries;") == str(total)


@pytest.mark.covers("SC-07-05-01")
@pytest.mark.core
@pytest.mark.role_homeowner
@pytest.mark.gui_id("GUI-07-09")
# Fixed by SPEC-005 R1/R3: the webhook settles through the canonical path, penalty first.
def test_overpayment_becomes_an_advance(login_as, page, builders, api, actors):
    builders.overdue_dues(principal=DUES, days_overdue=10)
    homeowner = api.login(**actors["homeowner"])
    total = api_amount(api.resident_dashboard(homeowner)["total_debt"])
    paid = Decimal("2860.67")

    api.webhook_transfer(A14_IBAN, paid, "E2E-FAST-0002", "AHMET YILMAZ AVANS")

    login_as("homeowner")
    home = ResidentHome(page).wait()
    by_id(page, "hero_advance_pill").wait_for(timeout=10_000)
    assert home.balance() == paid - total


@pytest.mark.covers("SC-07-02-04")
@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-07-05")
def test_unmatched_row_is_assigned_to_a_unit_by_hand(login_as, page, tmp_path, october_dues, stack):
    a14 = stack.sql("SELECT u.id FROM units u JOIN blocks b ON b.id = u.block_id "
                    "WHERE b.block_name = 'A Blok' AND u.unit_number = 14;")
    login_as("manager")
    ManagerCockpit(page).wait()
    dues = DuesManagement(page).open()
    dues.upload_statement(_statement(tmp_path))
    page.keyboard.press("Escape")  # leave the summary without confirming

    dues.segment(3)
    pending = page.locator('[flt-semantics-identifier^="btn_assign_unmatched_"]')
    pending.first.wait_for(timeout=10_000)
    assert pending.count() == 1
    pending.first.click()
    by_id(page, f"assign_flat_{a14}").click()
    by_id(page, "btn_confirm_assignment").click()

    pending.first.wait_for(state="detached", timeout=10_000)


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-07-05")
def test_manual_assignment_records_the_payment(login_as, page, tmp_path, october_dues, stack):
    a14 = stack.sql("SELECT u.id FROM units u JOIN blocks b ON b.id = u.block_id "
                    "WHERE b.block_name = 'A Blok' AND u.unit_number = 14;")
    login_as("manager")
    ManagerCockpit(page).wait()
    dues = DuesManagement(page).open()
    dues.upload_statement(_statement(tmp_path))
    page.keyboard.press("Escape")
    dues.segment(3)
    page.locator('[flt-semantics-identifier^="btn_assign_unmatched_"]').first.click()
    by_id(page, f"assign_flat_{a14}").click()
    by_id(page, "btn_confirm_assignment").click()
    page.wait_for_timeout(2_000)

    assert stack.sql("SELECT count(*) FROM payment_entries WHERE amount = 250.00;") == "1"


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-07-05")
def test_confirming_matched_rows_keeps_the_unmatched_ones(login_as, page, tmp_path, october_dues):
    login_as("manager")
    ManagerCockpit(page).wait()
    dues = DuesManagement(page).open()
    dues.upload_statement(_statement(tmp_path)).confirm_matched()
    page.wait_for_timeout(1_500)
    dues.segment(3)
    page.locator('[flt-semantics-identifier^="btn_assign_unmatched_"]').first.wait_for(timeout=5_000)
