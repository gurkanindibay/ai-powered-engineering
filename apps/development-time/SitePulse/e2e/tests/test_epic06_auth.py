"""EPIC-06 Identity & authentication (GUI_TEST_PLAN.md §3)."""
import pytest

from pages import ManagerCockpit, ResidentHome, SaasAdmin, Shell
from support.api import ApiError
from support.flutter import by_id, input_value, nav_tab_count


@pytest.mark.smoke
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-06-01")
def test_manager_login_reaches_cockpit(login_as, page):
    login_as("manager")
    ManagerCockpit(page).wait()


@pytest.mark.smoke
@pytest.mark.role_homeowner
@pytest.mark.gui_id("GUI-06-02")
def test_homeowner_login_reaches_dashboard(login_as, page):
    login_as("homeowner")
    ResidentHome(page).wait()


@pytest.mark.smoke
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-06-03")
def test_wrong_password_shows_error_and_stays_on_login(login_page, actors):
    login_page.login("manager", actors["manager"]["email"], "definitely-wrong-password")
    login_page.error_banner.wait_for(timeout=10_000)
    assert login_page.is_shown()


@pytest.mark.smoke
@pytest.mark.role_homeowner
@pytest.mark.gui_id("GUI-06-08")
def test_logout_returns_to_login_screen(login_as, login_page, page):
    login_as("homeowner")
    ResidentHome(page).wait()
    Shell(page).logout()
    page.wait_for_selector('[flt-semantics-identifier="login_tab_quickAll"]', timeout=10_000)
    assert ResidentHome(page).page.locator('[flt-semantics-identifier="hero_balance_amount"]').count() == 0


@pytest.mark.smoke
@pytest.mark.role_saas
@pytest.mark.gui_id("GUI-06-06")
def test_saas_admin_must_change_bootstrap_password(login_as, login_page, page, api, actors, stack):
    stack.sql("UPDATE users SET must_change_password=true WHERE email='admin@sitepulse.io';")
    login_as("saas")
    saas = SaasAdmin(page)
    saas.must_change_password_banner.wait_for(timeout=10_000)

    new_password = "E2E-Changed-Admin-2"
    saas.change_password(actors["saas"]["password"], new_password)
    saas.must_change_password_banner.wait_for(state="detached", timeout=15_000)

    # The backend now accepts only the new password and no longer asks for a change.
    session = api.login(actors["saas"]["email"], new_password)
    assert session.user["must_change_password"] is False
    with pytest.raises(Exception):
        api.login(actors["saas"]["email"], actors["saas"]["password"])


# ---------------------------------------------------------------- P1 (core)

@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-06-05")
@pytest.mark.parametrize("role, tab", [("homeowner", "homeOwner"), ("manager", "siteManager")])
def test_clear_login_cache_empties_the_fields(login_page, page, role, tab):
    prefix = {"homeowner": "homeowner", "manager": "manager"}[role]
    by_id(page, f"login_tab_{tab}").click()
    by_id(page, f"btn_clear_login_cache_{role}").click()
    page.wait_for_function(
        "id => (document.querySelector(`[flt-semantics-identifier=\"${id}\"] input`)?.value ?? '') === ''",
        arg=f"login_{prefix}_email", timeout=10_000)
    assert input_value(page, f"login_{prefix}_email") == ""
    assert input_value(page, f"login_{prefix}_password") == ""


@pytest.mark.core
@pytest.mark.role_homeowner
@pytest.mark.gui_id("GUI-06-07")
def test_homeowner_changes_password_from_profile_and_logs_in_again(login_as, login_page, page, api, actors):
    homeowner = actors["homeowner"]
    new_password = "E2E-Homeowner-Changed-7"
    login_as("homeowner")
    ResidentHome(page).wait()

    profile = Shell(page).open_profile()
    profile.change_password(homeowner["password"], new_password)
    profile.logout()
    by_id(page, "login_tab_quickAll").wait_for(timeout=10_000)
    login_page.login("homeowner", homeowner["email"], new_password)

    ResidentHome(page).wait()
    with pytest.raises(ApiError):
        api.login(homeowner["email"], homeowner["password"])


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-06-08")
def test_profile_logout_and_browser_back_stay_logged_out(login_as, page):
    login_as("manager")
    ManagerCockpit(page).wait()

    Shell(page).open_profile().logout()
    by_id(page, "login_tab_quickAll").wait_for(timeout=10_000)
    page.go_back()
    page.wait_for_timeout(1_500)
    assert by_id(page, "btn_open_unified_dues_center").count() == 0


@pytest.mark.core
@pytest.mark.role_homeowner
@pytest.mark.gui_id("GUI-06-09")
def test_homeowner_sees_no_manager_actions_and_api_refuses_them(login_as, page, api, actors):
    login_as("homeowner")
    ResidentHome(page).wait()
    for manager_only in ("btn_open_unified_dues_center", "btn_cockpit_manage_residents", "role_path_manager_cockpit",
                         "btn_open_add_site"):
        assert by_id(page, manager_only).count() == 0, manager_only

    homeowner = api.login(**actors["homeowner"])
    with pytest.raises(ApiError, match="-> 403"):
        api.call("GET", f"/api/v1/site-admin/home-owners?site_id={homeowner.user['site_id']}", homeowner.token)


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-06-10")
def test_manager_switches_between_cockpit_and_own_flat(login_as, page):
    login_as("manager")
    ManagerCockpit(page).wait()
    assert nav_tab_count(page) == 3  # Ana Sayfa, Aidat Yönetimi, Sakinler & Malikler (Profile is the avatar)

    by_id(page, "role_path_my_flat").click()
    by_id(page, "btn_open_unified_dues_center").wait_for(state="detached", timeout=10_000)
    assert nav_tab_count(page) == 2  # Ana Sayfa, Dairem: no 'Aidat Yönetimi' in the owner view

    by_id(page, "role_path_manager_cockpit").click()
    ManagerCockpit(page).wait()
    assert nav_tab_count(page) == 3


@pytest.mark.core
@pytest.mark.role_homeowner
@pytest.mark.gui_id("GUI-06-08")
def test_logout_asks_for_confirmation_and_cancel_keeps_the_session(login_as, page):
    login_as("homeowner")
    ResidentHome(page).wait()
    assert by_id(page, "btn_header_logout").count() == 0  # no one-tap logout in the app bar

    Shell(page).open_profile().logout(confirm=False)
    page.wait_for_timeout(500)
    assert by_id(page, "login_tab_quickAll").count() == 0
    by_id(page, "btn_logout").wait_for(timeout=5_000)  # still on the profile sheet, still signed in


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-X-07")
def test_each_tab_has_a_url_and_browser_back_returns_to_it(login_as, page):
    login_as("manager")
    ManagerCockpit(page).wait()
    page.wait_for_url("**/manager/home", timeout=10_000)

    Shell(page).nav("residents")
    page.wait_for_url("**/manager/residents", timeout=10_000)
    Shell(page).nav("dues")
    page.wait_for_url("**/manager/dues", timeout=10_000)

    page.go_back()
    page.wait_for_url("**/manager/residents", timeout=10_000)
    by_id(page, "add_resident_btn").wait_for(timeout=15_000)
