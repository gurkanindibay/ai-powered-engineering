"""SPEC-007 payments phase 2 in the GUI: resident statement, card payment on the
provider's hosted page, receipt PDF, receipt reversal and the işletme projesi."""
from decimal import Decimal

import pytest

from pages import ManagerCockpit, PaymentStream, ResidentHome
from support.flutter import by_id, by_id_prefix, fill, text_of
from support.money import last_amount


def _a14(stack) -> str:
    return stack.sql("SELECT u.id FROM units u JOIN blocks b ON b.id = u.block_id "
                     "WHERE b.block_name = 'A Blok' AND u.unit_number = 14;")


@pytest.mark.core
@pytest.mark.role_homeowner
@pytest.mark.gui_id("GUI-09-03")
@pytest.mark.covers("SC-09-03-02")
def test_resident_statement_ages_overdue_dues_with_the_penalty(login_as, page, stack):
    stack.sql(f"INSERT INTO dues_liabilities (unit_id, period, principal_amount, due_date, status, debtor_type, expense_type) "
              f"VALUES ({int(_a14(stack))}, 'Eylül 2026', 1400.00, CURRENT_DATE - 45, 'PENDING', 'OWNER', 'OPERATIONAL_DUES');")
    stack.restart_backend()
    login_as("homeowner")
    ResidentHome(page).wait()
    by_id(page, "resident_statement_entry").click()
    owner = by_id(page, "statement_debtor_owner")
    owner.wait_for(timeout=15_000)
    total = last_amount(text_of(by_id(page, "statement_total_owner")))
    assert total > Decimal("1400.00"), f"45 days overdue accrue the KMK 20 penalty: {total}"
    assert "Eylül 2026" in text_of(owner)
    assert by_id_prefix(page, "statement_debtor_tenant").count() == 0, "an owner sees only the owner's account"


@pytest.mark.core
@pytest.mark.role_homeowner
@pytest.mark.gui_id("GUI-01-03")
@pytest.mark.covers("SC-09-04-04")
def test_card_payment_on_the_provider_page_issues_a_receipt(login_as, page, builders, stack):
    builders.overdue_dues(unit_number=14, principal=Decimal("1400.00"), days_overdue=3, period="Ekim 2026")
    login_as("homeowner")
    ResidentHome(page).wait()
    by_id(page, "btn_pay_now").click()
    start = by_id(page, "card_payment_start")
    start.wait_for(timeout=10_000)
    with page.context.expect_page() as popup_info:
        start.click()
    provider = popup_info.value
    provider.wait_for_load_state()
    assert provider.locator("input[name=card], input[autocomplete^=cc]").count() == 0, "no card fields"
    provider.locator("#sandbox_approve").click()
    provider.wait_for_load_state()
    provider.close()

    by_id(page, "card_payment_captured").wait_for(timeout=20_000)
    row = stack.sql("SELECT pi.status || '|' || r.payment_channel FROM payment_intents pi "
                    "JOIN payment_receipts r ON r.receipt_number = pi.receipt_number AND r.site_id = pi.site_id "
                    "ORDER BY pi.id DESC LIMIT 1;")
    assert row == "CAPTURED|CREDIT_CARD", row
    assert stack.sql(f"SELECT status FROM dues_liabilities WHERE unit_id = {int(_a14(stack))} "
                     "AND period = 'Ekim 2026';") == "PAID"


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-09-04")
@pytest.mark.covers("SC-09-04-02")
def test_manager_downloads_the_receipt_pdf_and_reverses_the_receipt(login_as, page, api, actors, stack):
    manager = api.login(**actors["manager"])
    receipt = api.record_manual_payment(manager, _a14(stack), Decimal("750.00"), "Ahmet Yılmaz")
    login_as("manager")
    ManagerCockpit(page).wait()
    from pages.shell import Shell
    Shell(page).verify_sensitive(actors["manager"]["password"])
    PaymentStream(page).open()
    by_id_prefix(page, "payment_entry_").first.click()
    by_id(page, "receipt_number").wait_for(timeout=10_000)

    with page.expect_download() as download_info:
        by_id(page, "btn_share_receipt").click()
    download = download_info.value
    assert download.suggested_filename == f"{receipt['receipt_number']}.pdf"
    with open(download.path(), "rb") as fh:
        assert fh.read(4) == b"%PDF"

    by_id(page, "btn_reverse_receipt").click()
    fill(page, "reverse_reason_input", "Hatalı kayıt")
    by_id(page, "reverse_confirm_button").click()
    status = stack.wait_sql(f"SELECT settlement_status FROM payment_entries WHERE receipt_id = {int(receipt['id'])};",
                            "REVERSED", timeout_s=15)
    assert status == "REVERSED"
    assert stack.sql("SELECT count(*) FROM payment_receipts WHERE receipt_type = 'REVERSAL';") == "1"


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-02-06")
def test_interim_operating_budget_becomes_the_legal_basis_of_accrued_dues(login_as, page, api, actors, stack):
    login_as("manager")
    ManagerCockpit(page).wait()
    by_id(page, "cockpit_operating_budget").click()
    by_id(page, "budget_compliance").wait_for(timeout=15_000)
    by_id(page, "budget_new_button").click()
    fill(page, "budget_line_amount_0", "12000.00")  # below the current tariffs' run-rate: within the cap
    by_id(page, "budget_save_button").click()
    card = by_id_prefix(page, "budget_card_").first
    card.wait_for(timeout=15_000)
    budget_id = card.get_attribute("flt-semantics-identifier").removeprefix("budget_card_")
    by_id(page, f"budget_issue_interim_{budget_id}").click()
    status = stack.wait_sql(f"SELECT status FROM operating_budgets WHERE id = {int(budget_id)};", "INTERIM", timeout_s=15)
    assert status == "INTERIM"

    manager = api.login(**actors["manager"])
    due = stack.sql("SELECT (CURRENT_DATE + 10)::text;")
    period_key = stack.sql("SELECT to_char(CURRENT_DATE + 10, 'YYYY-MM');")  # a canonical month (STORY-07-08)
    api.accrue_period(manager, period_key, Decimal("0"), due)
    row = stack.sql("SELECT count(*) || '|' || count(*) FILTER (WHERE operating_budget_id = "
                    f"{int(budget_id)}) FROM dues_liabilities WHERE period_key = '{period_key}';")
    count, linked = row.split("|")
    assert int(count) > 0 and count == linked, row
