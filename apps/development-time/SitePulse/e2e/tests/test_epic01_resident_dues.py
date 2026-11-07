"""EPIC-01 Resident dues & EPIC-07 virtual IBAN on the resident dashboard."""
from decimal import Decimal

import pytest

from pages import ResidentHome
from support.money import api_amount


@pytest.mark.smoke
@pytest.mark.role_homeowner
@pytest.mark.gui_id("GUI-01-02")
def test_no_dues_shows_zero_balance_without_overdue_badge(login_as, page, api, actors):
    login_as("homeowner")
    home = ResidentHome(page).wait()
    expected = api_amount(api.resident_dashboard(api.login(**actors["homeowner"]))["total_debt"])
    assert expected == Decimal("0.00")
    assert home.balance() == expected
    assert not home.overdue_badge_visible()


@pytest.mark.smoke
@pytest.mark.role_homeowner
@pytest.mark.gui_id("GUI-01-01")
def test_overdue_balance_matches_backend_total(builders, login_as, page, api, actors):
    builders.overdue_dues(unit_number=14, principal=Decimal("1400.00"), days_overdue=10)
    dashboard = api.resident_dashboard(api.login(**actors["homeowner"]))
    expected = api_amount(dashboard["total_debt"])
    # Principal plus a KMK delay penalty; the penalty depends on today's date,
    # so the exact expected value comes from the backend (see GUI_TEST_PLAN.md §4).
    assert expected > Decimal("1400.00"), dashboard

    login_as("homeowner")
    home = ResidentHome(page).wait()
    assert home.balance() == expected


@pytest.mark.smoke
@pytest.mark.role_homeowner
@pytest.mark.gui_id("GUI-07-01")
def test_virtual_iban_shown_and_copied(login_as, page, api, actors, stack, browser_name):
    expected = api.resident_dashboard(api.login(**actors["homeowner"]))["virtual_iban"]
    assert expected == stack.sql("SELECT virtual_iban FROM units WHERE unit_number = 14;")

    login_as("homeowner")
    home = ResidentHome(page).wait()
    assert expected in home.iban_text().replace(" ", "")

    home.copy_iban()
    if browser_name == "chromium":
        page.wait_for_timeout(300)
        assert page.evaluate("navigator.clipboard.readText()") == expected
