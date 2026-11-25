"""Auditor journey: temporary password → read-only finance desk (books, collections, KVKK log) → sign in again."""
import pytest

from support.api import ApiError
from support.flutter import by_id, by_id_prefix
from support.journey import Account, push_route, wait_route

AUDITOR_EMAIL = "denetci.journey@e2e.test"
AUDITOR_TEMPORARY = "mehmet123"  # SQL arrange reuses the seed manager's password hash


def _create_auditor(stack) -> None:
    """SQL arrange: no API issues auditor accounts yet (role grants cover owners and residents only)."""
    stack.sql(
        "INSERT INTO users (site_id, email, password_hash, role, must_change_password) "
        "SELECT site_id, '" + AUDITOR_EMAIL + "', password_hash, 'AUDITOR', true "
        "FROM users WHERE email = 'mehmet.demir@begonya.com';")
    stack.restart_backend()


@pytest.mark.journey
@pytest.mark.role_auditor
@pytest.mark.covers("SC-06-06-05")
@pytest.mark.gui_id("GUI-J-05")
def test_auditor_journey(journey, first_sign_in, sign_in_again, page, api, stack):
    j = journey("auditor")
    _create_auditor(stack)
    account = Account("auditor", AUDITOR_EMAIL, AUDITOR_TEMPORARY, "Journey-Auditor-5")
    desk = lambda: by_id(page, "finance_tab_ledger").wait_for(timeout=20_000)  # noqa: E731

    first_sign_in(j, account, home_route="/auditor/home", wait_home=desk,
                  deep_link="/manager/dues", deep_link_lands_on="/auditor/home")
    session = api.login(account.email, account.new_password)

    with j.step("the ledger shows the trial balance the API returns"):
        rows = api.call("GET", "/api/v1/accounting/trial-balance", session.token)["rows"]
        by_id(page, "finance_tab_ledger").click()
        if rows:
            by_id_prefix(page, "trial_balance_").first.wait_for(timeout=15_000)
        else:
            page.wait_for_load_state("networkidle")
        assert by_id(page, "finance_section_error").count() == 0
        assert by_id_prefix(page, "trial_balance_").count() == len(rows)

    with j.step("the desk is read-only: no resident requests, dunning or notice publishing"):
        assert by_id(page, "finance_tab_requests").count() == 0
        by_id(page, "finance_tab_collections").click()
        page.wait_for_load_state("networkidle")
        page.evaluate("() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))")
        assert by_id(page, "finance_section_error").count() == 0
        assert by_id(page, "finance_run_dunning").count() == 0
        by_id(page, "finance_tab_kvkk").click()
        page.wait_for_load_state("networkidle")
        page.evaluate("() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))")
        assert by_id(page, "finance_section_error").count() == 0
        assert by_id(page, "kvkk_publish_notice").count() == 0

    with j.step("manager and resident pages stay closed to the auditor"):
        push_route(page, "/manager/residents")
        wait_route(page, "/auditor/")
        for other in ("add_resident_btn", "btn_open_unified_dues_center", "hero_balance_amount"):
            assert by_id(page, other).count() == 0, other
        with pytest.raises(ApiError, match="-> 403"):
            api.call("GET", "/api/v1/site-admin/home-owners?site_id=1", session.token)

    sign_in_again(j, account, wait_home=desk)
