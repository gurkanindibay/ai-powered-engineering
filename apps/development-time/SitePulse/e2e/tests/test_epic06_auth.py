"""EPIC-06 Identity & authentication (GUI_TEST_PLAN.md §3)."""
import pytest

from pages import ManagerCockpit, ResidentHome, SaasAdmin, Shell


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
def test_saas_admin_must_change_bootstrap_password(login_as, login_page, page, api, actors):
    login_as("saas")
    saas = SaasAdmin(page).wait()
    saas.must_change_password_banner.wait_for(timeout=10_000)

    new_password = "E2E-Changed-Admin-2"
    saas.change_password(actors["saas"]["password"], new_password)
    saas.must_change_password_banner.wait_for(state="detached", timeout=15_000)

    # The backend now accepts only the new password and no longer asks for a change.
    session = api.login(actors["saas"]["email"], new_password)
    assert session.user["must_change_password"] is False
    with pytest.raises(Exception):
        api.login(actors["saas"]["email"], actors["saas"]["password"])
