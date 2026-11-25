"""EPIC-08 Occupancy lifecycle & dual ledger."""
from decimal import Decimal

import pytest

from pages import ManagerCockpit, Occupancy, PersonPicker, ResidentsTab, Shell, UnitWorkspace


def _unit_id(stack, block: str, number: int) -> str:
    return stack.sql("SELECT u.id FROM units u JOIN blocks b ON b.id = u.block_id "
                     f"WHERE b.block_name = '{block}' AND u.unit_number = {number};")


def _seed_advance(stack, unit_id: str, debtor: str, amount: str) -> None:
    stack.sql(
        "INSERT INTO advance_balances (unit_id, debtor_type, balance) "
        f"VALUES ({int(unit_id)}, '{debtor}', {amount}) "
        "ON CONFLICT (unit_id, debtor_type) DO UPDATE SET balance = EXCLUDED.balance;"
    )
    stack.sql(
        "INSERT INTO advance_ledger_entries (unit_id, debtor_type, entry_type, amount, description) "
        f"VALUES ({int(unit_id)}, '{debtor}', 'PAYMENT_SURPLUS', {amount}, 'E2E advance seed');"
    )
    stack.restart_backend()


def _move_out_with_advance_choice(page, unit_id: str, choice_id: str, amount: str | None = None) -> None:
    UnitWorkspace(page).open(unit_id).action(unit_id, "move_out")
    by_id(page, choice_id).click()
    if amount is not None:
        from support.flutter import fill

        fill(page, "exit_advance_amount", amount)
    by_id(page, "module_confirm_move_out_btn").click()
    by_id(page, "module_confirm_move_out_btn").wait_for(state="detached", timeout=15_000)
    UnitWorkspace(page).close()


def _second_manager(api, stack, actors):
    # Promote the seeded owner account only in this resettable e2e database.
    stack.sql("UPDATE users SET role = 'SITE_MANAGER' WHERE lower(email) = lower('ahmet.yilmaz@begonya.com');")
    stack.restart_backend()
    return api.login(**actors["homeowner"])


@pytest.mark.smoke
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-08-01")
@pytest.mark.covers("SC-08-04-02")
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
@pytest.mark.covers("SC-08-03-01")
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


@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-08-14")
@pytest.mark.covers("SC-08-03-02")
def test_move_out_keeps_tenant_advance_when_selected(login_as, page, api, actors, stack):
    b3 = _unit_id(stack, "B Blok", 3)
    manager = api.login(**actors["manager"])
    api.move_in(manager, b3, "Zeynep Kaya", "zeynep.kaya@e2e.test")
    _seed_advance(stack, b3, "TENANT", "800.00")
    login_as("manager")
    ManagerCockpit(page).wait()
    ResidentsTab(page).open()

    _move_out_with_advance_choice(page, b3, "exit_advance_keep")

    assert stack.sql(
        f"SELECT balance FROM advance_balances WHERE unit_id = {int(b3)} AND debtor_type = 'TENANT';"
    ) == "800.00"
    assert stack.sql(f"SELECT count(*) FROM advance_exit_settlements WHERE unit_id = {int(b3)};") == "0"


@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-08-14")
@pytest.mark.covers("SC-08-03-03")
def test_move_out_payout_waits_for_second_approver(login_as, page, api, actors, stack):
    b3 = _unit_id(stack, "B Blok", 3)
    manager = api.login(**actors["manager"])
    api.move_in(manager, b3, "Zeynep Kaya", "zeynep.kaya@e2e.test")
    _seed_advance(stack, b3, "TENANT", "800.00")
    reviewer = _second_manager(api, stack, actors)
    login_as("manager")
    ManagerCockpit(page).wait()
    ResidentsTab(page).open()

    _move_out_with_advance_choice(page, b3, "exit_advance_payout", "500")

    settlement_id = stack.sql(
        f"SELECT id FROM advance_exit_settlements WHERE unit_id = {int(b3)} ORDER BY id DESC LIMIT 1;"
    )
    assert stack.sql(
        f"SELECT kind || '|' || status || '|' || amount::text FROM advance_exit_settlements WHERE id = {int(settlement_id)};"
    ) == "PAYOUT|PENDING|500.00"
    assert stack.sql(
        f"SELECT balance FROM advance_balances WHERE unit_id = {int(b3)} AND debtor_type = 'TENANT';"
    ) == "800.00"

    api.call(
        "POST",
        f"/api/v1/site-admin/advance-exit-settlements/{settlement_id}/decide",
        reviewer.token,
        body={"approve": True, "payment_reference": "E2E-PAYOUT-01", "note": None},
    )
    assert stack.sql(
        f"SELECT balance FROM advance_balances WHERE unit_id = {int(b3)} AND debtor_type = 'TENANT';"
    ) == "300.00"
    assert stack.sql(
        f"SELECT count(*) FROM advance_exit_disbursements WHERE settlement_id = {int(settlement_id)};"
    ) == "1"


@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-08-14")
@pytest.mark.covers("SC-08-03-04")
def test_move_out_transfer_waits_for_second_approver(login_as, page, api, actors, stack):
    b3 = _unit_id(stack, "B Blok", 3)
    manager = api.login(**actors["manager"])
    api.move_in(manager, b3, "Zeynep Kaya", "zeynep.kaya@e2e.test")
    _seed_advance(stack, b3, "TENANT", "800.00")
    reviewer = _second_manager(api, stack, actors)
    login_as("manager")
    ManagerCockpit(page).wait()
    ResidentsTab(page).open()

    _move_out_with_advance_choice(page, b3, "exit_advance_transfer", "500")

    settlement_id = stack.sql(
        f"SELECT id FROM advance_exit_settlements WHERE unit_id = {int(b3)} ORDER BY id DESC LIMIT 1;"
    )
    assert stack.sql(
        f"SELECT kind || '|' || status || '|' || source_debtor || '|' || target_debtor "
        f"FROM advance_exit_settlements WHERE id = {int(settlement_id)};"
    ) == "TRANSFER|PENDING|TENANT|OWNER"
    assert stack.sql(
        f"SELECT balance FROM advance_balances WHERE unit_id = {int(b3)} AND debtor_type = 'TENANT';"
    ) == "800.00"
    assert stack.sql(
        f"SELECT coalesce((SELECT balance FROM advance_balances WHERE unit_id = {int(b3)} AND debtor_type = 'OWNER'), 0)::text;"
    ) == "0"

    api.call(
        "POST",
        f"/api/v1/site-admin/advance-exit-settlements/{settlement_id}/decide",
        reviewer.token,
        body={"approve": True, "payment_reference": None, "note": None},
    )
    assert stack.sql(
        f"SELECT balance FROM advance_balances WHERE unit_id = {int(b3)} AND debtor_type = 'TENANT';"
    ) == "300.00"
    assert stack.sql(
        f"SELECT balance FROM advance_balances WHERE unit_id = {int(b3)} AND debtor_type = 'OWNER';"
    ) == "500.00"
    assert stack.sql(
        f"SELECT count(*) FROM advance_exit_disbursements WHERE settlement_id = {int(settlement_id)};"
    ) == "0"


# ---------------------------------------------------------------- P1 (core)

from pages import CapitalProjects, DuesManagement, Shell  # noqa: E402
from support.flutter import by_id, by_id_prefix, text_of  # noqa: E402


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-08-02")
@pytest.mark.covers("SC-08-01-01")
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
@pytest.mark.covers("SC-08-04-01")
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

    UnitWorkspace(page).open(b3).action(b3, "history")
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
@pytest.mark.covers("SC-08-05-01")
@pytest.mark.covers("SC-12-06-04")
def test_ownership_transfer_keeps_the_previous_owner_in_history(login_as, page, stack, actors):
    a14 = _unit_id(stack, "A Blok", 14)
    old_owner = stack.sql(f"SELECT owner_person_id FROM units WHERE id = {int(a14)};")
    login_as("manager")
    ManagerCockpit(page).wait()
    from pages.shell import Shell
    Shell(page).verify_sensitive(actors["manager"]["password"])
    ResidentsTab(page).open()

    UnitWorkspace(page).open(a14).action(a14, "transfer_ownership")
    by_id(page, "module_transfer_new_owner_name_input").wait_for(timeout=10_000)
    for legacy in ("module_transfer_new_owner_phone_input", "module_transfer_new_owner_email_input"):
        assert by_id(page, legacy).count() == 0, legacy  # REQ-042: no person text inputs
    PersonPicker(page, "module_transfer_new_owner_name_input").create(
        "Selim Evsahibi", phone="+90 532 555 66 77", email="selim.evsahibi@e2e.test")
    by_id(page, "module_confirm_transfer_ownership_btn").click()
    by_id(page, "module_confirm_transfer_ownership_btn").wait_for(state="detached", timeout=15_000)

    assert stack.sql(f"SELECT p.full_name FROM units u JOIN persons p ON p.id = u.owner_person_id "
                     f"WHERE u.id = {int(a14)};") == "Selim Evsahibi"
    assert stack.sql(f"SELECT count(*) FROM persons WHERE id = {int(old_owner)};") == "1"  # nobody is deleted


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-08-06")
def test_ownership_transfer_records_the_previous_owners_period(login_as, page, stack, actors):
    a14 = _unit_id(stack, "A Blok", 14)
    old_owner = stack.sql(f"SELECT owner_person_id FROM units WHERE id = {int(a14)};")
    login_as("manager")
    ManagerCockpit(page).wait()
    from pages.shell import Shell
    Shell(page).verify_sensitive(actors["manager"]["password"])
    ResidentsTab(page).open()
    UnitWorkspace(page).open(a14).action(a14, "transfer_ownership")
    PersonPicker(page, "module_transfer_new_owner_name_input").create(
        "Selim Evsahibi", email="selim.evsahibi@e2e.test")
    by_id(page, "module_confirm_transfer_ownership_btn").click()
    by_id(page, "module_confirm_transfer_ownership_btn").wait_for(state="detached", timeout=15_000)

    assert stack.sql(f"SELECT count(*) FROM unit_ownerships WHERE unit_id = {int(a14)} "
                     f"AND person_id = {int(old_owner)} AND end_date IS NOT NULL;") == "1"


@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-08-15")
@pytest.mark.covers("SC-08-05-03")
def test_previous_owner_advance_transfer_waits_for_second_approver(login_as, page, api, stack, actors):
    a14 = _unit_id(stack, "A Blok", 14)
    old_owner = stack.sql(f"SELECT owner_person_id FROM units WHERE id = {int(a14)};")
    _seed_advance(stack, a14, "OWNER", "800.00")
    reviewer = _second_manager(api, stack, actors)
    login_as("manager")
    ManagerCockpit(page).wait()
    Shell(page).verify_sensitive(actors["manager"]["password"])
    ResidentsTab(page).open()

    UnitWorkspace(page).open(a14).action(a14, "transfer_ownership")
    PersonPicker(page, "module_transfer_new_owner_name_input").create(
        "Selim Evsahibi", phone="+90 532 555 66 77", email="selim.evsahibi@e2e.test")
    by_id(page, "exit_advance_transfer").click()
    from support.flutter import fill

    fill(page, "exit_advance_amount", "500")
    by_id(page, "module_confirm_transfer_ownership_btn").click()
    by_id(page, "module_confirm_transfer_ownership_btn").wait_for(state="detached", timeout=15_000)

    settlement_id = stack.sql(
        f"SELECT id FROM advance_exit_settlements WHERE unit_id = {int(a14)} ORDER BY id DESC LIMIT 1;"
    )
    assert stack.sql(
        f"SELECT kind || '|' || status || '|' || source_debtor || '|' || target_debtor "
        f"FROM advance_exit_settlements WHERE id = {int(settlement_id)};"
    ) == "TRANSFER|PENDING|OWNER|TENANT"
    # The sale moved the seller's advance to a hold: the buyer's owner bucket is
    # empty and the money is still the previous owner's (issue #448).
    assert stack.sql(
        f"SELECT COALESCE((SELECT balance FROM advance_balances WHERE unit_id = {int(a14)} AND debtor_type = 'OWNER'), 0)::text;"
    ) == "0.00"
    assert stack.sql(
        "SELECT COALESCE((SELECT balance FROM person_advance_holds "
        f"WHERE unit_id = {int(a14)} AND person_id = {int(old_owner)} AND debtor_type = 'OWNER'), 0)::text;"
    ) == "800.00"

    api.call(
        "POST",
        f"/api/v1/site-admin/advance-exit-settlements/{settlement_id}/decide",
        reviewer.token,
        body={"approve": True, "payment_reference": None, "note": None},
    )
    assert stack.sql(
        f"SELECT balance FROM advance_balances WHERE unit_id = {int(a14)} AND debtor_type = 'OWNER';"
    ) == "0.00"
    assert stack.sql(
        f"SELECT balance FROM advance_balances WHERE unit_id = {int(a14)} AND debtor_type = 'TENANT';"
    ) == "500.00"
    assert stack.sql(
        "SELECT COALESCE((SELECT balance FROM person_advance_holds "
        f"WHERE unit_id = {int(a14)} AND person_id = {int(old_owner)} AND debtor_type = 'OWNER'), 0)::text;"
    ) == "300.00"
    assert stack.sql(
        f"SELECT owner_person_id = {int(old_owner)} FROM units WHERE id = {int(a14)};"
    ) == "f"


@pytest.fixture
def two_household_members(login_as, page, stack):
    a14 = _unit_id(stack, "A Blok", 14)
    login_as("manager")
    ManagerCockpit(page).wait()
    ResidentsTab(page).open()
    for name, phone, email in (("Ali Kaya", "05320000001", "ali.kaya@e2e.test"),
                               ("Can Kaya", "05320000002", "can.kaya@e2e.test")):
        UnitWorkspace(page).open(a14).action(a14, "add_member")
        PersonPicker(page, "module_member_name_input").create(name, phone=phone, email=email)
        by_id(page, "module_save_household_btn").click()
        by_id(page, "module_save_household_btn").wait_for(state="detached", timeout=10_000)
        UnitWorkspace(page).close()
    return a14


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-08-03")
@pytest.mark.covers("SC-08-02-01")
def test_household_members_are_added(two_household_members, api, actors):
    manager = api.login(**actors["manager"])
    members = api.call("GET", f"/api/v1/home-residents/members/{two_household_members}?site_id=1", manager.token)
    assert sorted(m["full_name"] for m in members) == ["Ali Kaya", "Can Kaya"]


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-08-03")
def test_household_members_survive_a_backend_restart(two_household_members, api, actors, stack):
    stack.restart_backend()
    manager = api.login(**actors["manager"])
    members = api.call("GET", f"/api/v1/home-residents/members/{two_household_members}?site_id=1", manager.token)
    assert sorted(m["full_name"] for m in members) == ["Ali Kaya", "Can Kaya"]


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-08-03")
@pytest.mark.covers("SC-08-02-02")
def test_household_members_are_archived_on_move_out(two_household_members, api, actors, stack):
    a14 = two_household_members
    manager = api.login(**actors["manager"])
    api.move_out(manager, a14)

    members = api.call("GET", f"/api/v1/home-residents/members/{a14}?site_id=1", manager.token)
    assert members == []
    archived_count = stack.sql(
        f"SELECT count(*) FROM occupancy_members om "
        f"JOIN unit_occupancies uo ON uo.id = om.occupancy_id "
        f"WHERE uo.unit_id = {int(a14)} AND uo.is_active = FALSE;"
    )
    assert int(archived_count) >= 2


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-08-06")
@pytest.mark.covers("SC-08-05-02")
def test_capital_dues_after_transfer_billed_to_new_owner(api, stack, actors):
    a14 = _unit_id(stack, "A Blok", 14)
    manager = api.login(**actors["manager"])
    api.call("POST", "/api/v1/auth/step-up", manager.token, body={"password": actors["manager"]["password"]})
    api.call("POST", f"/api/v1/site-admin/units/{a14}/transfer-ownership", manager.token, body={
        "unit_id": str(a14),
        "new_owner_name": "Selim Evsahibi",
        "new_owner_email": "selim.evsahibi@e2e.test",
    })
    project = api.create_capital_project(manager, "Asansör Yenileme", Decimal("30000.00"), basis="BY_LAND_SHARE", installments=1)
    api.accrue_installment(manager, project["id"], 1)

    selim_id = stack.sql("SELECT id FROM persons WHERE email = 'selim.evsahibi@e2e.test';")
    capital_due_owner = stack.sql(
        f"SELECT liable_person_id FROM dues_liabilities "
        f"WHERE unit_id = {int(a14)} AND expense_type = 'CAPITAL_DUES' "
        f"ORDER BY id DESC LIMIT 1;"
    )
    assert capital_due_owner == selim_id

