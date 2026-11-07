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


# ---------------------------------------------------------------- P1 (core)

from pages import CapitalProjects, DuesManagement, Shell  # noqa: E402
from support.flutter import by_id, by_id_prefix, fill, text_of  # noqa: E402
from support.known_issues import LIABILITY_ID_SEQUENCE, OPERATIONAL_DUES_DEBTOR  # noqa: E402


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-08-02")
@pytest.mark.xfail(strict=True, reason=LIABILITY_ID_SEQUENCE)
def test_operational_dues_go_to_the_tenant_and_capital_dues_to_the_owner(login_as, page, api, actors, stack):
    b3 = _unit_id(stack, "B Blok", 3)
    manager = api.login(**actors["manager"])
    api.move_in(manager, b3, "Selin Demir", "selin.demir@e2e.test")
    api.create_period(manager, "Ekim 2026", "2026-10-15")
    login_as("manager")
    ManagerCockpit(page).wait()
    DuesManagement(page).open().accrue_selected_period()
    capital = CapitalProjects(page).open()
    capital.create("Çatı Yalıtımı", "42000.00", by_land_share=True, installments=1)
    capital.accrue_installment(1)
    capital.installment_accrued(1).wait_for(timeout=15_000)

    tenant = stack.sql("SELECT id FROM persons WHERE email = 'selin.demir@e2e.test';")
    owner = stack.sql(f"SELECT owner_person_id FROM units WHERE id = {int(b3)};")
    operational = stack.sql(f"SELECT debtor_type || '|' || coalesce(liable_person_id::text, '') FROM dues_liabilities "
                            f"WHERE unit_id = {int(b3)} AND expense_type = 'OPERATIONAL_DUES';")
    capital_row = stack.sql(f"SELECT debtor_type FROM dues_liabilities "
                            f"WHERE unit_id = {int(b3)} AND expense_type = 'CAPITAL_DUES';")
    assert operational.split("|")[0] == "TENANT"
    assert operational.split("|")[1] in ("", tenant), (operational, tenant, owner)
    assert capital_row == "OWNER"


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-08-02")
@pytest.mark.xfail(strict=True, reason=OPERATIONAL_DUES_DEBTOR)
def test_owner_occupied_unit_operational_dues_go_to_the_owner(login_as, page, api, actors, stack):
    a14 = _unit_id(stack, "A Blok", 14)
    manager = api.login(**actors["manager"])
    api.create_period(manager, "Ekim 2026", "2026-10-15")
    login_as("manager")
    ManagerCockpit(page).wait()
    DuesManagement(page).open().accrue_selected_period()

    assert stack.sql(f"SELECT debtor_type FROM dues_liabilities WHERE unit_id = {int(a14)};") == "OWNER"


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-08-05")
def test_history_lists_previous_tenant_with_exit_balance_and_the_new_one(login_as, page, api, actors, builders, stack):
    b3 = _unit_id(stack, "B Blok", 3)
    manager = api.login(**actors["manager"])
    api.move_in(manager, b3, "Selin Demir", "selin.demir@e2e.test")
    builders.tenant_debt(b3, Decimal("1500.00"))
    manager = api.login(**actors["manager"])  # the arrange step restarted the backend
    api.move_out(manager, b3)
    api.move_in(manager, b3, "Can Demir", "can.demir@e2e.test")
    login_as("manager")
    ManagerCockpit(page).wait()
    ResidentsTab(page).open()

    by_id(page, f"module_history_ho_{b3}").click()
    by_id_prefix(page, "history_item_").first.wait_for(timeout=10_000)
    items = [text_of(by_id_prefix(page, "history_item_").nth(i))
             for i in range(by_id_prefix(page, "history_item_").count())]

    selin = next(t for t in items if "Selin Demir" in t)
    can = next(t for t in items if "Can Demir" in t)
    assert "1.500,00" in selin or "1500" in selin, selin
    assert "Çıkış" in selin and "Çıkış" not in can, (selin, can)


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-08-06")
def test_ownership_transfer_keeps_the_previous_owner_in_history(login_as, page, stack):
    a14 = _unit_id(stack, "A Blok", 14)
    old_owner = stack.sql(f"SELECT owner_person_id FROM units WHERE id = {int(a14)};")
    login_as("manager")
    ManagerCockpit(page).wait()
    ResidentsTab(page).open()

    by_id(page, f"transfer_ownership_{a14}").click()
    by_id(page, "module_transfer_new_owner_name_input").wait_for(timeout=10_000)
    fill(page, "module_transfer_new_owner_name_input", "Selim Evsahibi")
    fill(page, "module_transfer_new_owner_phone_input", "+90 532 555 66 77")
    fill(page, "module_transfer_new_owner_email_input", "selim.evsahibi@e2e.test")
    by_id(page, "module_confirm_transfer_ownership_btn").click()
    by_id(page, "module_confirm_transfer_ownership_btn").wait_for(state="detached", timeout=15_000)

    assert stack.sql(f"SELECT p.full_name FROM units u JOIN persons p ON p.id = u.owner_person_id "
                     f"WHERE u.id = {int(a14)};") == "Selim Evsahibi"
    assert stack.sql(f"SELECT count(*) FROM persons WHERE id = {int(old_owner)};") == "1"  # nobody is deleted


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-08-06")
@pytest.mark.xfail(strict=True, reason="BUG (STORY-08-05): an ownership transfer writes a unit_ownerships row for the "
                   "new owner only; the previous owner gets no closed row, so their ownership period is lost (the seed "
                   "also creates no initial ownership rows)")
def test_ownership_transfer_records_the_previous_owners_period(login_as, page, stack):
    a14 = _unit_id(stack, "A Blok", 14)
    old_owner = stack.sql(f"SELECT owner_person_id FROM units WHERE id = {int(a14)};")
    login_as("manager")
    ManagerCockpit(page).wait()
    ResidentsTab(page).open()
    by_id(page, f"transfer_ownership_{a14}").click()
    by_id(page, "module_transfer_new_owner_name_input").wait_for(timeout=10_000)
    fill(page, "module_transfer_new_owner_name_input", "Selim Evsahibi")
    fill(page, "module_transfer_new_owner_email_input", "selim.evsahibi@e2e.test")
    by_id(page, "module_confirm_transfer_ownership_btn").click()
    by_id(page, "module_confirm_transfer_ownership_btn").wait_for(state="detached", timeout=15_000)

    assert stack.sql(f"SELECT count(*) FROM unit_ownerships WHERE unit_id = {int(a14)} "
                     f"AND person_id = {int(old_owner)} AND end_date IS NOT NULL;") == "1"


@pytest.fixture
def two_household_members(login_as, page, stack):
    a14 = _unit_id(stack, "A Blok", 14)
    login_as("manager")
    ManagerCockpit(page).wait()
    ResidentsTab(page).open()
    for name, phone, email in (("Ali Kaya", "05320000001", "ali.kaya@e2e.test"),
                               ("Can Kaya", "05320000002", "can.kaya@e2e.test")):
        by_id(page, f"add_resident_member_to_{a14}").click()
        by_id(page, "household_name_field").wait_for(timeout=10_000)
        fill(page, "household_name_field", name)
        fill(page, "household_phone_field", phone)
        fill(page, "household_email_field", email)
        by_id(page, "household_save_button").click()
        by_id(page, "household_save_button").wait_for(state="detached", timeout=10_000)
    return a14


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-08-03")
def test_household_members_are_added(two_household_members, api, actors):
    manager = api.login(**actors["manager"])
    members = api.call("GET", f"/api/v1/home-residents/members/{two_household_members}?site_id=1", manager.token)
    assert sorted(m["full_name"] for m in members) == ["Ali Kaya", "Can Kaya"]


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-08-03")
@pytest.mark.xfail(strict=True, reason="BUG: household members live only in backend memory (no occupancy_members or "
                   "persons row, resident_id '0', a placeholder e-mail when none is given) and vanish on restart")
def test_household_members_survive_a_backend_restart(two_household_members, api, actors, stack):
    stack.restart_backend()
    manager = api.login(**actors["manager"])
    members = api.call("GET", f"/api/v1/home-residents/members/{two_household_members}?site_id=1", manager.token)
    assert sorted(m["full_name"] for m in members) == ["Ali Kaya", "Can Kaya"]
