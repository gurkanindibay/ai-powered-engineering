"""EPIC-09 allocation, statements and receipts (P1)."""
from decimal import Decimal

import pytest

from pages import ManagerCockpit, PaymentStream, ResidentHome, ResidentsTab, UnitWorkspace
from support.flutter import by_id, by_id_prefix, text_of
from support.money import last_amount

PERIOD = "Ekim 2026"


def _amount(text: str) -> Decimal:
    """'Gecikme Zammı (KMK %5):₺53,67' -> Decimal('53.67')."""
    return last_amount(text)


@pytest.fixture
def overdue_payment(api, actors, stack, builders):
    """October dues overdue since 2026-10-15, then a ₺2.000,00 payment on A Blok D:14."""
    manager = api.login(**actors["manager"])
    api.create_period(manager, PERIOD, "2026-10-15")
    api.accrue_period(manager, PERIOD, Decimal("1400.00"), "2026-10-15")
    builders.overdue_since_period_due_date(PERIOD)
    manager = api.login(**actors["manager"])
    a14 = stack.sql("SELECT u.id FROM units u JOIN blocks b ON b.id = u.block_id "
                    "WHERE b.block_name = 'A Blok' AND u.unit_number = 14;")
    return api.record_manual_payment(manager, a14, Decimal("2000.00"), "Ahmet Yılmaz", payer_role="OWNER")


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-09-02")
@pytest.mark.gui_id("GUI-09-04")
@pytest.mark.covers("SC-09-02-01")
@pytest.mark.covers("SC-09-04-03")
def test_receipt_shows_number_and_penalty_principal_advance_split(login_as, page, overdue_payment):
    login_as("manager")
    ManagerCockpit(page).wait()
    PaymentStream(page).open()
    by_id_prefix(page, "payment_entry_").first.click()
    by_id(page, "receipt_number").wait_for(timeout=10_000)

    assert text_of(by_id(page, "receipt_number")) == overdue_payment["receipt_number"]
    assert overdue_payment["receipt_number"].startswith("TAH-2026-")
    penalty = _amount(text_of(by_id(page, "receipt_allocated_penalty")))
    principal = _amount(text_of(by_id(page, "receipt_allocated_principal")))
    advance = _amount(text_of(by_id(page, "receipt_allocated_advance")))
    assert penalty == Decimal(overdue_payment["allocated_penalty"]) > 0
    assert principal == Decimal(overdue_payment["allocated_principal"])
    assert advance == Decimal(overdue_payment["allocated_advance"])
    assert penalty + principal + advance == Decimal("2000.00") == _amount(text_of(by_id(page, "receipt_total")))


@pytest.mark.core
@pytest.mark.role_homeowner
@pytest.mark.gui_id("GUI-09-04")
@pytest.mark.covers("SC-09-04-01")
def test_homeowner_receipt_shows_the_issued_receipt_number(login_as, page, api):
    issued = api.webhook_transfer("TR620020500009863791600001", Decimal("500.00"), "E2E-FAST-RCPT", "AHMET YILMAZ")
    login_as("homeowner")
    ResidentHome(page).wait()
    by_id(page, "ledger_row_0").click()
    by_id(page, "home_receipt_number").wait_for(timeout=10_000)
    assert text_of(by_id(page, "home_receipt_number")).endswith(issued["receipt_id"])


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-09-03")
@pytest.mark.covers("SC-09-03-01")
def test_tenant_statement_lists_operational_items_only(login_as, page, api, actors, builders, stack):
    """STORY-09-03: the unit's statement shows each debtor's own items; the tenant's are operational only."""
    b3 = stack.sql("SELECT u.id FROM units u JOIN blocks b ON b.id = u.block_id "
                   "WHERE b.block_name = 'B Blok' AND u.unit_number = 3;")
    manager = api.login(**actors["manager"])
    api.move_in(manager, b3, "Selin Demir", "selin.demir@e2e.test")
    builders.tenant_debt(b3, Decimal("1500.00"))
    stack.sql(f"INSERT INTO dues_liabilities (unit_id, period, principal_amount, due_date, status, debtor_type, expense_type) "
              f"VALUES ({int(b3)}, 'Asansör Taksit 1', 700.00, DATE '{stack.fixture_today}' + 10, 'PENDING', 'OWNER', 'CAPITAL_DUES');")
    stack.restart_backend()
    login_as("manager")
    ManagerCockpit(page).wait()
    ResidentsTab(page).open()
    UnitWorkspace(page).open(b3).action(b3, "statement")
    tenant = by_id(page, "statement_debtor_tenant")
    tenant.wait_for(timeout=15_000)
    tenant_text = text_of(tenant)
    owner_text = text_of(by_id(page, "statement_debtor_owner"))
    assert "Ekim 2026" in tenant_text and "Demirbaş" not in tenant_text, tenant_text
    assert "Asansör Taksit 1" in owner_text and "Ekim 2026" not in owner_text, owner_text
