"""Cross-cutting GUI checks (GUI-X-*)."""
import pytest

from pages import ManagerCockpit, ResidentHome


@pytest.mark.core
@pytest.mark.gui_id("GUI-X-04")
@pytest.mark.parametrize("role, home", [("homeowner", ResidentHome), ("manager", ManagerCockpit)])
def test_mobile_viewport_login_and_dashboard(page, login_as, role, home):
    page.set_viewport_size({"width": 375, "height": 812})
    login_as(role)
    home(page).wait()
    assert page.evaluate("document.documentElement.scrollWidth") <= 375


@pytest.mark.core
@pytest.mark.gui_id("GUI-X-02")
def test_theme_choice_on_login_screen_holds_after_login(login_page, login_as, page):
    from support.flutter import by_id, text_of
    # The toggles carry 'theme:dark' / 'theme:light' in E2E builds (the page itself is canvas-rendered).
    start = text_of(by_id(page, "btn_toggle_theme"))
    by_id(page, "btn_toggle_theme").click()
    page.wait_for_function("t => !(document.querySelector('[flt-semantics-identifier=\"btn_toggle_theme\"]')"
                           "?.getAttribute('aria-label') || '').includes(t)", arg=start, timeout=5_000)
    chosen = text_of(by_id(page, "btn_toggle_theme"))
    assert chosen != start

    login_as("manager")
    ManagerCockpit(page).wait()
    # Theme now lives in the profile sheet (the app bar keeps only the avatar).
    from pages import Shell
    assert text_of(Shell(page).open_profile().theme_toggle) == chosen
