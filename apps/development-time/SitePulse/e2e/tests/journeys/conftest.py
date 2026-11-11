"""Shared parts of the per-role user journeys (docs/GUI_TEST_PLAN.md §9).

Every journey starts the way a real account starts: the first sign-in uses a
temporary password. `first_sign_in` walks the STORY-06-06 gate and checks it the way
a user would notice a fault: the change screen is the only thing on screen,
nothing else is fetched, links wait, and once the password is set the role's
home page loads with no refused calls. `sign_in_again` closes every journey.
"""
from __future__ import annotations

from typing import Callable

import pytest

from pages import LoginPage, Shell
from pages.onboarding import ForcePasswordChange
from support.api import Api, ApiError
from support.journey import Account, Journey, NetworkLog, assert_no_failures, push_route, route, wait_route

TEMPORARY_SETTLE_MS = 1_500  # time for a faulty client to fire its dashboard calls


@pytest.fixture
def net(page) -> NetworkLog:
    return NetworkLog.attach(page)


@pytest.fixture
def journey(request) -> Callable[[str], Journey]:
    return lambda role: Journey(request, role)


@pytest.fixture
def first_sign_in(page, net: NetworkLog, login_page: LoginPage):
    """Run the STORY-06-06 gate for `account`; ends on the role's home page with real data loaded."""

    def _run(j: Journey, account: Account, *, home_route: str, wait_home: Callable[[], object],
             deep_link: str | None = None, deep_link_lands_on: str | None = None) -> int:
        gate = ForcePasswordChange(page)

        with j.step("sign in with the temporary password opens only the change screen"):
            mark = net.mark()
            login_page.login(account.login_role, account.email, account.temporary_password)
            gate.wait()
            page.wait_for_timeout(TEMPORARY_SETTLE_MS)
            assert route(page) == "/change-password", route(page)
            assert gate.visible_dashboard_markers() == [], gate.visible_dashboard_markers()
            business = net.business_calls_since(mark)
            assert business == [], f"business calls with a temporary password: {[(c.method, c.path, c.status) for c in business]}"

        with j.step("a link to another page waits behind the change screen"):
            mark = net.mark()
            push_route(page, deep_link or home_route)
            page.wait_for_timeout(1_000)
            gate.wait()
            assert route(page) == "/change-password", route(page)
            assert net.business_calls_since(mark) == []

        with j.step("the form rejects an unsafe new password without calling the server"):
            mark = net.mark()
            error = gate.submit_invalid(account.temporary_password, "kisa", "kisa")
            assert "10" in error, error
            error = gate.submit_invalid(account.temporary_password, account.temporary_password + "-x1",
                                        account.temporary_password + "-x2")
            assert "uyuşmuyor" in error, error
            assert "/api/v1/auth/change-password" not in net.paths_since(mark)

        with j.step("setting a permanent password opens the role home with its data"):
            mark = net.mark()
            gate.change(account.temporary_password, account.new_password)
            gate.wait_gone()
            wait_home()
            expected = deep_link_lands_on or home_route
            wait_route(page, expected)
            assert net.business_calls_since(mark), "no data was requested after the password change"
            assert_no_failures(net, mark, "home page after the password change")
        return mark

    return _run


@pytest.fixture
def sign_in_again(page, net: NetworkLog, login_page: LoginPage, api: Api):
    """Log out, sign in with the new password straight to the home page; the temporary one is dead."""

    def _run(j: Journey, account: Account, *, wait_home: Callable[[], object]) -> None:
        with j.step("log out from the profile sheet"):
            Shell(page).logout()
            page.wait_for_selector('[flt-semantics-identifier="login_tab_quickAll"]', timeout=10_000)

        with j.step("sign in with the new password goes straight to the home page"):
            mark = net.mark()
            login_page.login(account.login_role, account.email, account.new_password)
            wait_home()
            assert ForcePasswordChange(page).screen.count() == 0
            assert_no_failures(net, mark, "home page on the next sign-in")
            assert api.login(account.email, account.new_password).user["must_change_password"] is False

        with j.step("the temporary password no longer signs in"):
            with pytest.raises(ApiError, match=r"-> 40[01]"):
                api.login(account.email, account.temporary_password)

    return _run
