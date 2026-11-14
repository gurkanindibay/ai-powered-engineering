"""Site manager journey: temporary password → cockpit → residents, occupancy, dues → own flat → sign in again."""
import pytest

from pages import DuesManagement, ManagerCockpit, Occupancy, ResidentsTab, Shell
from support.api import ApiError
from support.flutter import by_id, nav_tab_count
from support.journey import Account, push_route, wait_route


def _unit_id(stack, block: str, number: int) -> str:
    return stack.sql("SELECT u.id FROM units u JOIN blocks b ON b.id = u.block_id "
                     f"WHERE b.block_name = '{block}' AND u.unit_number = {number};")


@pytest.mark.journey
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-J-02")
def test_site_manager_journey(journey, first_sign_in, sign_in_again, page, api, actors, stack):
    j = journey("site manager")
    manager = actors["manager"]
    # SQL arrange: the state a SaaS password reset leaves (issuing it through the UI is covered by GUI-J-01).
    stack.sql(f"UPDATE users SET must_change_password=true WHERE email='{manager['email']}';")
    account = Account("manager", manager["email"], manager["password"], "Journey-Site-Manager-2")
    cockpit = ManagerCockpit(page)

    # A SaaS admin link is not the manager's: after the change it falls back to the cockpit.
    first_sign_in(j, account, home_route="/manager/home", wait_home=cockpit.wait,
                  deep_link="/admin/sites", deep_link_lands_on="/manager/home")

    with j.step("residents tab lists every unit of the site and no other site's"):
        expected = set(stack.sql("SELECT id FROM units WHERE site_id = 1;").split())
        assert expected, "seed has units"
        residents = ResidentsTab(page).open()
        assert set(residents.unit_card_ids()) == expected

    with j.step("register a new owner and flat"):
        before = len(residents.unit_card_ids())
        residents.start_add().fill(unit_no="25", full_name="Fatma Şahin", email="fatma.sahin@e2e.test",
                                   phone="05321234567").save()
        page.wait_for_function(
            "n => document.querySelectorAll('[flt-semantics-identifier^=\"unit_actions_\"], [flt-semantics-identifier^=\"delete_ho_\"]').length > n",
            arg=before, timeout=15_000)
        assert stack.sql("SELECT count(*) FROM persons WHERE email = 'fatma.sahin@e2e.test';") == "1"

    with j.step("move a tenant into a flat"):
        b3 = _unit_id(stack, "B Blok", 3)
        Occupancy(page).move_in(b3, "Selin Demir", "selin.demir@e2e.test", "+90 533 123 45 67")
        assert stack.wait_sql(
            f"SELECT occupancy_type FROM unit_occupancies WHERE unit_id = {int(b3)} AND is_active;", "TENANT") \
            == "TENANT"

    with j.step("dues management offers every segment and capital project creation"):
        dues = DuesManagement(page).open()
        assert dues.segment_count() == 5
        dues.segment(DuesManagement.CAPITAL_SEGMENT)
        by_id(page, "btn_open_capital_project_wizard").wait_for(timeout=10_000)

    with j.step("switch to the manager's own flat and back to the cockpit"):
        Shell(page).nav("home")
        cockpit.wait()
        assert nav_tab_count(page) == 3
        by_id(page, "role_path_my_flat").click()
        by_id(page, "btn_open_unified_dues_center").wait_for(state="detached", timeout=10_000)
        assert nav_tab_count(page) == 2
        by_id(page, "role_path_manager_cockpit").click()
        cockpit.wait()

    with j.step("SaaS admin pages stay closed to the site manager"):
        push_route(page, "/admin/sites")
        wait_route(page, "/manager/")
        assert by_id(page, "btn_open_add_site").count() == 0
        session = api.login(account.email, account.new_password)
        with pytest.raises(ApiError, match="-> 403"):
            api.saas_sites(session)

    sign_in_again(j, account, wait_home=cockpit.wait)
