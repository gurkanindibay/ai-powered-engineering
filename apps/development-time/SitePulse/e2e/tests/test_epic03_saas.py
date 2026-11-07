"""EPIC-03 SaaS multi-tenancy."""
import pytest

from pages import SaasAdmin


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
@pytest.mark.xfail(strict=True, reason="BUG: SaasTenantService::get_global_stats returns placeholders "
                   "(total_units = sites * 20, volume = 80000 * sites), backend/src/services/saas_tenant_service.rs:377")
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
