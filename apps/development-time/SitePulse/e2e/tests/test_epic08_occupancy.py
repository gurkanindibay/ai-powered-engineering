"""EPIC-08 Occupancy lifecycle & dual ledger."""
from decimal import Decimal

import pytest

from pages import ManagerCockpit, Occupancy, ResidentsTab


def _unit_id(stack, block: str, number: int) -> str:
    return stack.sql("SELECT u.id FROM units u JOIN blocks b ON b.id = u.block_id "
                     f"WHERE b.block_name = '{block}' AND u.unit_number = {number};")


@pytest.mark.smoke
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-08-01")
def test_tenant_move_in(login_as, page, stack):
    b3 = _unit_id(stack, "B Blok", 3)
    login_as("manager")
    ManagerCockpit(page).wait()
    ResidentsTab(page).open()

    Occupancy(page).move_in(b3, "Selin Demir", "selin.demir@e2e.test", "+90 533 123 45 67")

    row = stack.sql("SELECT o.occupancy_type || '|' || o.is_active || '|' || p.full_name FROM unit_occupancies o "
                    f"JOIN persons p ON p.id = o.person_id WHERE o.unit_id = {int(b3)} AND o.is_active;")
    assert row == "TENANT|true|Selin Demir"
    assert stack.sql(f"SELECT p.email FROM units u JOIN persons p ON p.id = u.tenant_person_id "
                     f"WHERE u.id = {int(b3)};") == "selin.demir@e2e.test"


@pytest.mark.smoke
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-08-04")
def test_tenant_move_out_keeps_history_and_debt(login_as, page, api, actors, builders, stack):
    b3 = _unit_id(stack, "B Blok", 3)
    manager = api.login(**actors["manager"])
    api.move_in(manager, b3, "Selin Demir", "selin.demir@e2e.test")
    debt = builders.tenant_debt(b3, Decimal("1500.00"))
    login_as("manager")
    ManagerCockpit(page).wait()
    ResidentsTab(page).open()

    Occupancy(page).move_out(b3)

    occupancy = stack.sql("SELECT is_active || '|' || (end_date IS NOT NULL) || '|' || coalesce(exit_balance::text, '') "
                          f"FROM unit_occupancies WHERE id = {int(debt['occupancy_id'])};")
    assert occupancy == "false|true|1500.00", occupancy
    assert stack.sql(f"SELECT tenant_person_id IS NULL FROM units WHERE id = {int(b3)};") == "t"
    # Nothing is deleted: the person and the unpaid liability stay on record.
    assert stack.sql(f"SELECT principal_amount - paid_amount FROM dues_liabilities "
                     f"WHERE id = {int(debt['liability_id'])};") == "1500.00"
    assert stack.sql(f"SELECT count(*) FROM persons WHERE id = {int(debt['person_id'])};") == "1"
