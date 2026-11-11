"""EPIC-04 invitations: P1 scenarios (unit invite links, rejection, first login of an approved resident)."""
import re

import pytest

from pages import ManagerCockpit, ResidentHome
from support.flutter import by_id, text_of



def _open_unit_invite(page) -> tuple[str, str]:
    by_id(page, "resident_action_invite").click()
    by_id(page, "invite_link_text").wait_for(timeout=10_000)
    return text_of(by_id(page, "invite_link_text")), text_of(by_id(page, "invite_security_notice"))


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-04-01")
@pytest.mark.xfail(strict=True, reason="GAP (STORY-04-01/02): the manager has no site invite link in the UI "
                   "('Davet Linki' exists only for home users); GET /api/v1/registration/invite-link is unused")
def test_manager_shares_a_site_invite_link(login_as, page):
    login_as("manager")
    ManagerCockpit(page).wait()
    page.wait_for_timeout(1_500)
    assert by_id(page, "btn_invite_resident_link").count() == 1


@pytest.mark.core
@pytest.mark.role_homeowner
@pytest.mark.gui_id("GUI-04-06")
def test_unit_invite_link_is_shown_and_copied(login_as, page, browser_name):
    login_as("homeowner")
    ResidentHome(page).wait()
    link, _ = _open_unit_invite(page)
    assert re.fullmatch(r"https://\S+/join/\S+/units/\S+\?token=\S+", link), link

    by_id(page, "btn_copy_invite_link").click()
    if browser_name == "chromium":
        assert page.evaluate("navigator.clipboard.readText()") == link


@pytest.mark.core
@pytest.mark.role_homeowner
@pytest.mark.gui_id("GUI-04-06")
def test_unit_invite_link_targets_the_right_site_and_unit(login_as, page, stack):
    login_as("homeowner")
    ResidentHome(page).wait()
    link, notice = _open_unit_invite(page)
    a14 = stack.sql("SELECT u.id FROM units u JOIN blocks b ON b.id = u.block_id "
                    "WHERE b.block_name = 'A Blok' AND u.unit_number = 14;")

    assert f"/join/begonya-sitesi/units/{a14}?token=" in link, link
    assert "A Blok D:14" in notice, notice
    token = link.rsplit("token=", 1)[1]
    assert stack.sql(f"SELECT count(*) FROM invitation_tokens WHERE token = '{token}';") == "1"


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-04-04")
def test_rejected_registration_leaves_the_queue(login_as, page, api, stack):
    request = api.submit_registration("begonya-sitesi", "Kerem Yılmaz", "kerem.yilmaz@e2e.test", "B Blok", 18)
    login_as("manager")
    ManagerCockpit(page).wait()
    by_id(page, f"btn_reject_{request['request_id']}").click(timeout=5_000)
    page.wait_for_timeout(1_000)
    assert stack.sql(f"SELECT status FROM pending_registrations WHERE request_id = '{request['request_id']}';") \
        == "REJECTED"


@pytest.mark.core
@pytest.mark.role_homeowner
@pytest.mark.gui_id("GUI-04-05")
def test_approved_resident_first_login(login_as, page, api):
    request = api.submit_registration("begonya-sitesi", "Kerem Yılmaz", "kerem.yilmaz@e2e.test", "B Blok", 18)
    login_as("manager")
    password = ManagerCockpit(page).wait().approve(request["request_id"])
    assert api.login("kerem.yilmaz@e2e.test", password).user["must_change_password"] is True
