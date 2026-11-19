"""EPIC-04 Invitation & approval workflow."""
import pytest

from pages import ManagerCockpit



@pytest.fixture
def two_registrations(api):
    """Two self-registrations waiting for the manager (STORY-04-03 public form, via the API)."""
    return [
        api.submit_registration("begonya-sitesi", "Kerem Yılmaz", "kerem.yilmaz@e2e.test", "B Blok", 18, floor=5),
        api.submit_registration("begonya-sitesi", "Selin Ak", "selin.ak@e2e.test", "A Blok", 7, floor=2,
                                is_resident=True),
    ]


@pytest.mark.smoke
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-04-02")
@pytest.mark.covers("SC-04-04-01")
def test_pending_registrations_are_listed_for_the_manager(login_as, page, two_registrations):
    login_as("manager")
    cockpit = ManagerCockpit(page).wait()
    page.wait_for_timeout(2_000)  # give the queue time to load; the count is the assertion
    assert cockpit.pending_count() == 2
    for request in two_registrations:
        assert cockpit.pending_card(request["request_id"]).count() == 1


@pytest.mark.smoke
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-04-03")
@pytest.mark.covers("SC-04-05-01")
def test_approving_a_registration_creates_an_active_account(login_as, page, two_registrations, api, stack):
    login_as("manager")
    cockpit = ManagerCockpit(page).wait()
    kerem = two_registrations[0]
    cockpit.pending_card(kerem["request_id"]).wait_for(timeout=10_000)

    temporary_password = cockpit.approve(kerem["request_id"])

    page.wait_for_function("() => document.querySelector('[flt-semantics-identifier=\"pending_count_badge\"]')"
                           "?.textContent.trim() === '1'", timeout=10_000)
    assert stack.sql("SELECT count(*) FROM users WHERE email = 'kerem.yilmaz@e2e.test';") == "1"
    assert api.login("kerem.yilmaz@e2e.test", temporary_password).user["must_change_password"] is True


@pytest.mark.core
@pytest.mark.covers("SC-04-03-01")
def test_home_owner_submits_online_registration(api):
    req = api.submit_registration("begonya-sitesi", "Kerem Yılmaz", "kerem.submit@e2e.test", "B Blok", 18)
    assert req.get("status") == "PENDING"
    assert req.get("request_id") is not None

