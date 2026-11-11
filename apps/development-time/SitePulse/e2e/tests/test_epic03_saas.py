"""EPIC-03 SaaS multi-tenancy."""
import pytest

from pages import SaasAdmin
from support.api import ApiError


@pytest.mark.smoke
@pytest.mark.role_saas
@pytest.mark.gui_id("GUI-03-01")
def test_portfolio_lists_every_site(login_as, page, api, actors):
    session = api.login(**actors["saas"])
    expected_ids = sorted(s["site_id"] for s in api.saas_sites(session))

    login_as("saas")
    assert SaasAdmin(page).wait().site_ids() == expected_ids


@pytest.mark.smoke
@pytest.mark.role_saas
@pytest.mark.gui_id("GUI-03-01")
def test_portfolio_stats_agree_with_site_list(api, actors):
    """The dashboard totals (from /saas/stats) must add up from the site list."""
    session = api.login(**actors["saas"])
    sites = api.saas_sites(session)
    stats = api.saas_stats(session)
    assert stats["total_sites"] == len(sites)
    assert stats["total_units"] == sum(s["total_units"] for s in sites), (stats, [s["total_units"] for s in sites])


@pytest.mark.smoke
@pytest.mark.role_saas
@pytest.mark.gui_id("GUI-03-02")
def test_onboarding_a_site_issues_working_manager_credentials(login_page, page, api, actors, stack):
    # Arrange: the bootstrap password is already replaced (GUI-06-06 covers that flow).
    saas = actors["saas"]
    new_password = "E2E-Saas-Onboard-3"
    api.change_password(saas["email"], saas["password"], new_password)
    login_page.login("saas", saas["email"], new_password)
    portfolio = SaasAdmin(page).wait()
    before = set(portfolio.site_ids())

    credentials = portfolio.open_add_site().fill(
        name="Palmiye Evleri Sitesi", city="İstanbul", address="Kadıköy, Palmiye Sok. No:3",
        blocks="A Blok, B Blok", admin_name="Murat Yıldırım", admin_email="murat.yildirim@e2e.test",
        admin_phone="+90 532 444 55 66").save()
    temporary_password = credentials.password()
    assert len(temporary_password) >= 8, temporary_password
    credentials.close()

    # The new site gets a card in the portfolio ...
    page.wait_for_function(
        "n => document.querySelectorAll('[flt-semantics-identifier^=\"btn_edit_site_\"]').length > n",
        arg=len(before), timeout=15_000)
    new_ids = set(portfolio.site_ids()) - before
    assert len(new_ids) == 1
    # ... the tenant and its manager exist, and the manager must change the issued password ...
    site_id = new_ids.pop()
    assert stack.sql(f"SELECT slug FROM sites WHERE id = {int(site_id)};") == "palmiye-evleri-sitesi"
    assert stack.sql("SELECT role || '|' || must_change_password || '|' || site_id FROM users "
                     "WHERE email = 'murat.yildirim@e2e.test';") == f"SITE_MANAGER|true|{site_id}"
    assert stack.sql(f"SELECT string_agg(block_name, ',' ORDER BY block_name) FROM blocks "
                     f"WHERE site_id = {int(site_id)};") == "A Blok,B Blok"
    # ... and the password shown on screen is the one that works.
    manager = api.login("murat.yildirim@e2e.test", temporary_password)
    assert manager.user["role"] == "SITE_MANAGER" and manager.user["must_change_password"] is True


# ---------------------------------------------------------------- P1 (core)

SAAS_PASSWORD = "E2E-Saas-Core-4"


@pytest.fixture
def saas_ready(api, actors):
    """SaaS admin with the bootstrap password already replaced; returns its API session."""
    saas = actors["saas"]
    return api.change_password(saas["email"], saas["password"], SAAS_PASSWORD)


@pytest.fixture
def saas_ui(saas_ready, login_page, page, actors):
    login_page.login("saas", actors["saas"]["email"], SAAS_PASSWORD)
    return SaasAdmin(page).wait()


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-03-03")
@pytest.mark.gui_id("GUI-X-03")  # zero-data site: guidance instead of errors
def test_new_manager_must_change_password_and_lands_on_an_empty_site(login_page, page, api, saas_ready):
    from pages import ManagerCockpit, ResidentsTab
    created = api.create_site(saas_ready, "Palmiye Evleri", "murat.yildirim@e2e.test")

    login_page.login("manager", "murat.yildirim@e2e.test", created["temporary_password"])
    # A temporary password opens only the change screen, never the cockpit.
    SaasAdmin(page).must_change_password_banner.wait_for(timeout=10_000)
    SaasAdmin(page).change_password(created["temporary_password"], "E2E-New-Manager-5")
    SaasAdmin(page).must_change_password_banner.wait_for(state="detached", timeout=15_000)
    ManagerCockpit(page).wait()

    assert ResidentsTab(page).open().unit_card_ids() == []  # zero-data site: no unit cards
    assert api.login("murat.yildirim@e2e.test", "E2E-New-Manager-5").user["must_change_password"] is False


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-03-04")
def test_manager_never_sees_another_sites_units(login_as, page, builders, stack):
    from pages import ManagerCockpit, ResidentsTab
    foreign_unit = builders.foreign_site_unit()
    begonya_units = set(stack.sql("SELECT id FROM units WHERE site_id = 1;").split())

    login_as("manager")
    ManagerCockpit(page).wait()
    shown = set(ResidentsTab(page).open().unit_card_ids())

    assert shown == begonya_units
    assert foreign_unit not in shown


@pytest.mark.core
@pytest.mark.role_saas
@pytest.mark.gui_id("GUI-03-05")
def test_edit_site_updates_the_card(saas_ui, stack):
    saas_ui.edit_site("1", "Begonya Sitesi Evleri", "Ataşehir, Yeni Sok. No:1, İstanbul", "+90 532 999 88 77")

    saas_ui.page.wait_for_function(
        "() => document.querySelector('[flt-semantics-identifier=\"site_card_name_1\"]')"
        "?.textContent.includes('Begonya Sitesi Evleri')", timeout=15_000)
    assert stack.sql("SELECT name FROM sites WHERE id = 1;") == "Begonya Sitesi Evleri"


@pytest.mark.core
@pytest.mark.role_saas
@pytest.mark.gui_id("GUI-03-06")
def test_empty_site_can_be_deleted(api, saas_ready, login_page, page, actors, stack):
    site_id = str(api.create_site(saas_ready, "Silinecek Site", "silinecek@e2e.test")["site_id"])
    login_page.login("saas", actors["saas"]["email"], SAAS_PASSWORD)
    portfolio = SaasAdmin(page).wait()
    assert site_id in portfolio.site_ids()

    portfolio.delete_site(site_id)

    page.locator(f'[flt-semantics-identifier="btn_edit_site_{site_id}"]').wait_for(state="detached", timeout=15_000)
    assert stack.sql(f"SELECT count(*) FROM sites WHERE id = {int(site_id)} AND status <> 'DELETED';") == "0"


@pytest.mark.core
@pytest.mark.role_saas
@pytest.mark.gui_id("GUI-03-07")
def test_site_with_units_cannot_be_deleted(saas_ui):
    assert saas_ui.page.locator('[flt-semantics-identifier="site_delete_locked_1"]').count() == 1
    assert saas_ui.page.locator('[flt-semantics-identifier="btn_delete_site_1"]').count() == 0


@pytest.mark.core
@pytest.mark.role_saas
@pytest.mark.gui_id("GUI-03-08")
def test_admin_password_reset_issues_a_new_password_and_retires_the_old(saas_ui, api, actors):
    from pages.shell import Shell
    Shell(saas_ui.page).verify_sensitive(SAAS_PASSWORD)
    manager = actors["manager"]
    new_password = saas_ui.reset_admin_password("1").password()

    assert new_password and new_password != manager["password"]
    assert api.login(manager["email"], new_password).user["must_change_password"] is True
    with pytest.raises(ApiError):
        api.login(manager["email"], manager["password"])
