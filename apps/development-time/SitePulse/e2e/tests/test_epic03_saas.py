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
