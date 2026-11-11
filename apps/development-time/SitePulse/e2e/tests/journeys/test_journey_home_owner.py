"""Home owner journey: temporary password → balance and how to pay → invite household → profile password → sign in again."""
import re
from decimal import Decimal

import pytest

from pages import ResidentHome, Shell
from support.api import ApiError
from support.flutter import by_id, text_of
from support.money import api_amount
from support.journey import Account, push_route, wait_route


@pytest.mark.journey
@pytest.mark.role_homeowner
@pytest.mark.gui_id("GUI-J-03")
def test_home_owner_journey(journey, first_sign_in, sign_in_again, page, api, actors, builders, stack):
    j = journey("home owner")
    owner = actors["homeowner"]
    builders.overdue_dues(unit_number=14, principal=Decimal("1400.00"), days_overdue=10)
    # SQL arrange: an owner whose temporary password was renewed (issuing paths: GUI-04-05, GUI-08-01).
    stack.sql(f"UPDATE users SET must_change_password=true WHERE email='{owner['email']}';")
    account = Account("homeowner", owner["email"], owner["password"], "Journey-Home-Owner-3")
    home = ResidentHome(page)

    first_sign_in(j, account, home_route="/resident/home", wait_home=home.wait,
                  deep_link="/manager/dues", deep_link_lands_on="/resident/home")
    session = api.login(account.email, account.new_password)
    dashboard = api.resident_dashboard(session)

    with j.step("the balance is the backend total with the delay penalty"):
        expected = api_amount(dashboard["total_debt"])
        assert expected > Decimal("1400.00"), dashboard
        assert home.balance() == expected
        assert home.overdue_badge_visible()

    with j.step("the flat's virtual IBAN for paying is shown"):
        assert dashboard["virtual_iban"] in home.iban_text().replace(" ", "")

    with j.step("invite a household member with the flat's invite link"):
        by_id(page, "resident_action_invite").click()
        by_id(page, "invite_link_text").wait_for(timeout=10_000)
        link = text_of(by_id(page, "invite_link_text"))
        assert re.fullmatch(r"https://\S+/join/\S+/units/\S+\?token=\S+", link), link
        page.keyboard.press("Escape")

    with j.step("site manager and SaaS pages stay closed to the owner"):
        for manager_only in ("btn_open_unified_dues_center", "btn_cockpit_manage_residents", "btn_open_add_site"):
            assert by_id(page, manager_only).count() == 0, manager_only
        push_route(page, "/manager/home")
        wait_route(page, "/resident/")
        with pytest.raises(ApiError, match="-> 403"):
            api.call("GET", f"/api/v1/site-admin/home-owners?site_id={session.user['site_id']}", session.token)

    with j.step("change the password again from the profile"):
        home.wait()
        Shell(page).open_profile().change_password(account.new_password, "Journey-Home-Owner-3b")
        account.temporary_password, account.new_password = account.new_password, "Journey-Home-Owner-3b"
        page.keyboard.press("Escape")

    sign_in_again(j, account, wait_home=home.wait)
