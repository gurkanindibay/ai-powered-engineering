"""EPIC-01 Resident dues & EPIC-07 virtual IBAN on the resident dashboard."""
from decimal import Decimal

import pytest

from pages import ResidentHome
from support.money import api_amount
from support.flutter import by_id, text_of


@pytest.mark.smoke
@pytest.mark.role_homeowner
@pytest.mark.gui_id("GUI-01-02")
@pytest.mark.covers("SC-01-04-02")
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
@pytest.mark.covers("SC-01-01-01")
@pytest.mark.covers("SC-01-02-01")
@pytest.mark.covers("SC-01-03-01")
@pytest.mark.covers("SC-01-04-01")
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
@pytest.mark.covers("SC-07-04-02")
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


# ---------------------------------------------------------------- P1 (core)

@pytest.mark.core
@pytest.mark.role_homeowner
@pytest.mark.gui_id("GUI-01-03")
@pytest.mark.covers("SC-01-05-01")
def test_account_movements_itemise_principal_and_penalty(login_as, page, builders):
    from support.flutter import by_id_prefix, text_of
    builders.overdue_dues(principal=Decimal("1400.00"), days_overdue=10)
    login_as("homeowner")
    ResidentHome(page).wait()
    rows = [text_of(by_id_prefix(page, "ledger_row_").nth(i)) for i in range(by_id_prefix(page, "ledger_row_").count())]

    assert any("₺1.400,00" in r for r in rows), rows
    assert any("Gecikme" in r and "+₺" in r for r in rows), rows


@pytest.mark.core
@pytest.mark.role_homeowner
@pytest.mark.gui_id("GUI-01-04")
@pytest.mark.covers("SC-01-03-02")
def test_site_announcement_reaches_the_resident(api, actors, login_as, page):
    manager = api.login(**actors["manager"])
    api.call("POST", "/api/v1/announcements", manager.token,
             body={"site_id": manager.user["site_id"], "title": "Planlı Su Kesintisi", "body": "Salı 10:00-14:00"})
    login_as("homeowner")
    ResidentHome(page).wait()
    by_id(page, "resident_action_announcements").click()
    assert "Planlı Su Kesintisi" in text_of(by_id(page, "site_announcement_title"))
    assert "Salı 10:00-14:00" in text_of(by_id(page, "site_announcement_body"))


@pytest.mark.core
@pytest.mark.role_homeowner
@pytest.mark.covers("SC-01-04-03")
def test_resident_actions_meet_touch_target_and_hide_unapproved_features(login_as, page):
    from support.flutter import by_id_prefix
    login_as("homeowner")
    ResidentHome(page).wait()
    actions = by_id_prefix(page, "resident_action_")
    assert actions.count() > 0
    # Flutter web renders 1 dp as 1 CSS pixel, so the 48dp target is 48 CSS px.
    for i in range(actions.count()):
        box = actions.nth(i).bounding_box()
        assert box is not None
        assert box["width"] >= 48 and box["height"] >= 48, (actions.nth(i).get_attribute("flt-semantics-identifier"), box)
    body = page.locator("body").inner_text() + " ".join(
        page.locator("[aria-label]").evaluate_all("els => els.map(e => e.getAttribute('aria-label'))"))
    for hidden in ("Sayaç Gir", "Rezervasyon"):
        assert hidden not in body
