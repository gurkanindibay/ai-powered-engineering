"""SaaS admin journey: bootstrap password → portfolio → onboard, reset and remove sites → sign in again."""
import pytest

from pages import SaasAdmin, Shell
from support.api import ApiError
from support.flutter import by_id
from support.journey import Account, push_route, wait_route

NEW_SITE_ADMIN = "journey.manager@e2e.test"


@pytest.mark.journey
@pytest.mark.role_saas
@pytest.mark.gui_id("GUI-J-01")
def test_saas_admin_journey(journey, first_sign_in, sign_in_again, page, api, actors, stack):
    j = journey("SaaS admin")
    saas = actors["saas"]
    # The bootstrap admin always starts with the password printed at first boot (01-system-seed.sql).
    stack.sql(f"UPDATE users SET must_change_password=true WHERE email='{saas['email']}';")
    account = Account("saas", saas["email"], saas["password"], "Journey-Saas-Admin-1")
    portfolio = SaasAdmin(page)

    first_sign_in(j, account, home_route="/admin/home", wait_home=portfolio.wait,
                  deep_link="/admin/sites", deep_link_lands_on="/admin/sites")
    session = api.login(account.email, account.new_password)

    with j.step("the portfolio lists every site the API returns"):
        expected = sorted(s["site_id"] for s in api.saas_sites(session))
        assert expected, "seed has sites"
        assert portfolio.site_ids() == expected

    with j.step("a site with units cannot be removed"):
        assert by_id(page, "site_delete_locked_1").count() == 1
        assert by_id(page, "btn_delete_site_1").count() == 0

    with j.step("onboard a new site and receive its manager's temporary password"):
        before = set(portfolio.site_ids())
        credentials = portfolio.open_add_site().fill(
            name="Yolculuk Evleri", city="İzmir", address="Bornova, Yolculuk Sok. No:1", blocks="A Blok",
            admin_name="Deniz Arslan", admin_email=NEW_SITE_ADMIN, admin_phone="+90 532 111 22 33").save()
        issued = credentials.password()
        credentials.close()
        page.wait_for_function(
            "n => document.querySelectorAll('[flt-semantics-identifier^=\"btn_edit_site_\"]').length > n",
            arg=len(before), timeout=15_000)
        new_site = (set(portfolio.site_ids()) - before).pop()
        manager = api.login(NEW_SITE_ADMIN, issued)
        assert manager.user["must_change_password"] is True
        # The new manager is held at the gate by the server as well, not only by the client.
        with pytest.raises(ApiError, match="PASSWORD_CHANGE_REQUIRED"):
            api.call("GET", "/api/v1/site-admin/overview", manager.token)

    with j.step("an empty site can be removed"):
        portfolio.delete_site(new_site)
        by_id(page, f"btn_edit_site_{new_site}").wait_for(state="detached", timeout=15_000)

    with j.step("reset a site manager's password after re-entering the admin password"):
        Shell(page).verify_sensitive(account.new_password)
        credentials = portfolio.reset_admin_password("1")
        reset = credentials.password()
        credentials.close()
        assert api.login(actors["manager"]["email"], reset).user["must_change_password"] is True

    with j.step("site manager and resident pages stay closed to the SaaS admin"):
        for manager_only in ("btn_open_unified_dues_center", "add_resident_btn", "hero_balance_amount"):
            assert by_id(page, manager_only).count() == 0, manager_only
        push_route(page, "/manager/home")
        wait_route(page, "/admin/")
        with pytest.raises(ApiError, match="-> 40[03]"):
            api.call("GET", "/api/v1/site-admin/home-owners?site_id=1", session.token)

    sign_in_again(j, account, wait_home=portfolio.wait)
