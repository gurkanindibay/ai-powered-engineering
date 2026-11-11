"""Home resident journey: joins through the owner's invite → temporary password → the flat's balance → sign in again."""
from decimal import Decimal

import pytest

from pages import ResidentHome
from support.api import ApiError
from support.flutter import by_id
from support.money import api_amount
from support.journey import Account, push_route, wait_route

RESIDENT_EMAIL = "elif.yilmaz@e2e.test"


@pytest.mark.journey
@pytest.mark.role_resident
@pytest.mark.gui_id("GUI-J-04")
def test_home_resident_journey(journey, first_sign_in, sign_in_again, page, api, actors, builders):
    j = journey("home resident")
    builders.overdue_dues(unit_number=14, principal=Decimal("1400.00"), days_overdue=10)
    # Real issuing path: the owner's unit invite, then the resident's registration returns a temporary password.
    owner = api.login(**actors["homeowner"])
    invite = api.call("GET", f"/api/v1/home-residents/invite-link/{owner.user['unit_id']}", owner.token)
    joined = api.call("POST", "/api/v1/home-residents/register", body={
        "token": invite["token"], "full_name": "Elif Yılmaz", "email": RESIDENT_EMAIL, "relationship": "CHILD"})
    assert joined["role"] == "HOME_RESIDENT"
    account = Account("resident", RESIDENT_EMAIL, joined["temporary_password"], "Journey-Resident-4")
    home = ResidentHome(page)

    first_sign_in(j, account, home_route="/resident/home", wait_home=home.wait,
                  deep_link="/manager/home", deep_link_lands_on="/resident/home")
    session = api.login(account.email, account.new_password)

    with j.step("the resident sees the flat's balance as the backend reports it"):
        assert session.user["unit_id"] == owner.user["unit_id"]
        expected = api_amount(api.resident_dashboard(session)["total_debt"])
        assert expected > Decimal("1400.00")
        assert home.balance() == expected

    with j.step("household management is the owner's: no invite for a resident"):
        assert by_id(page, "resident_action_invite").count() == 0
        with pytest.raises(ApiError, match="-> 403"):
            api.call("GET", f"/api/v1/home-residents/invite-link/{session.user['unit_id']}", session.token)

    with j.step("site manager pages stay closed to the resident"):
        push_route(page, "/manager/residents")
        wait_route(page, "/resident/")
        assert by_id(page, "add_resident_btn").count() == 0
        with pytest.raises(ApiError, match="-> 403"):
            api.call("GET", f"/api/v1/site-admin/home-owners?site_id={session.user['site_id']}", session.token)

    sign_in_again(j, account, wait_home=home.wait)
