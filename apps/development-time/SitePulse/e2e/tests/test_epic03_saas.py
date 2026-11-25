"""EPIC-03 SaaS multi-tenancy."""
import uuid

import pytest

from pages import SaasAdmin
from support.api import ApiError
from support.flutter import by_id


@pytest.mark.covers("SC-03-02-01")
@pytest.mark.smoke
@pytest.mark.role_saas
@pytest.mark.gui_id("GUI-03-01")
def test_portfolio_lists_every_site(login_as, page, api, actors):
    session = api.login(**actors["saas"])
    expected_ids = sorted(s["site_id"] for s in api.saas_sites(session))

    login_as("saas")
    assert SaasAdmin(page).wait().site_ids() == expected_ids


@pytest.mark.covers("SC-03-02-02")
@pytest.mark.smoke
@pytest.mark.role_saas
@pytest.mark.gui_id("GUI-03-01")
def test_portfolio_stats_agree_with_site_list(api, actors):
    """The dashboard totals (from /saas/stats) must add up from the site list."""
    session = api.login(**actors["saas"])
    sites = api.saas_sites(session)
    stats = api.saas_stats(session)
    assert stats["total_sites"] == len(sites)
    assert stats["total_units"] == sum(s["total_units"] for s in sites), (stats, [s["total_units"] for s in sites])


@pytest.mark.covers("SC-03-03-01")
@pytest.mark.covers("SC-03-04-01")
@pytest.mark.smoke
@pytest.mark.role_saas
@pytest.mark.gui_id("GUI-03-02")
def test_onboarding_a_site_issues_working_manager_credentials(login_page, page, api, actors, stack):
    # Arrange: the bootstrap password is already replaced (GUI-06-06 covers that flow).
    saas = actors["saas"]
    new_password = "E2E-Saas-Onboard-3"
    api.change_password(saas["email"], saas["password"], new_password)
    login_page.login("saas", saas["email"], new_password)
    portfolio = SaasAdmin(page).wait()
    before = set(portfolio.site_ids())

    credentials = portfolio.open_add_site().fill(
        name="Palmiye Evleri Sitesi", city="İstanbul", address="Kadıköy, Palmiye Sok. No:3",
        blocks="A Blok, B Blok", admin_name="Murat Yıldırım", admin_email="murat.yildirim@e2e.test",
        admin_phone="+90 532 444 55 66").save()
    temporary_password = credentials.password()
    assert len(temporary_password) >= 8, temporary_password
    credentials.close()

    # The new site gets a card in the portfolio ...
    page.wait_for_function(
        "n => document.querySelectorAll('[flt-semantics-identifier^=\"btn_edit_site_\"]').length > n",
        arg=len(before), timeout=15_000)
    new_ids = set(portfolio.site_ids()) - before
    assert len(new_ids) == 1
    # ... the tenant and its manager exist, and the manager must change the issued password ...
    site_id = new_ids.pop()
    assert stack.sql(f"SELECT slug FROM sites WHERE id = {int(site_id)};") == "palmiye-evleri-sitesi"
    assert stack.sql("SELECT role || '|' || must_change_password || '|' || site_id FROM users "
                     "WHERE email = 'murat.yildirim@e2e.test';") == f"SITE_MANAGER|true|{site_id}"
    assert stack.sql(f"SELECT string_agg(block_name, ',' ORDER BY block_name) FROM blocks "
                     f"WHERE site_id = {int(site_id)};") == "A Blok,B Blok"
    # ... and the password shown on screen is the one that works.
    manager = api.login("murat.yildirim@e2e.test", temporary_password)
    assert manager.user["role"] == "SITE_MANAGER" and manager.user["must_change_password"] is True


@pytest.mark.covers("SC-03-04-03")
@pytest.mark.core
@pytest.mark.role_saas
def test_onboarding_dispatches_the_manager_credential_sms(api, actors, stack):
    """The new manager's own mobile gets the credential alert, through the fake gateway."""
    from support.stack import SMS_GATEWAY_TOKEN

    saas = api.login(**actors["saas"])
    suffix = uuid.uuid4().hex[:6]
    email = f"sms.onboarding.{suffix}@e2e.test"
    phone = "+90 532 904 13 07"
    site_name = f"SMS Onboarding Site {suffix}"
    stack.sms.clear()

    created = api.call("POST", "/api/v1/saas/sites", saas.token, body={
        "site_name": site_name, "address": "Kadıköy, İstanbul",
        "site_admin_full_name": "Sude Yönetici", "site_admin_email": email,
        "site_admin_phone": phone, "plan_type": "STANDARD", "blocks": ["A Blok"],
    })

    messages = [
        message for message in stack.sms.received()
        if message["payload"].get("channel") == "SMS"
        and message["payload"].get("recipient", {}).get("email") == email
    ]
    assert len(messages) == 1, f"expected one credential SMS, got {stack.sms.received()}"
    sent = messages[0]
    assert sent["path"] == "/sms"
    assert sent["authorization"] == f"Bearer {SMS_GATEWAY_TOKEN}"
    payload = sent["payload"]
    assert payload["recipient"]["reference"] == str(created["admin_user_id"])
    assert payload["recipient"]["phone"] == phone
    assert payload["recipient"]["name"] == "Sude Yönetici"
    assert "SitePulse" in payload["subject"]
    assert created["temporary_password"] in payload["body"]
    assert email in payload["body"]
    assert "/#/login" in payload["body"]


# ---------------------------------------------------------------- P1 (core)

SAAS_PASSWORD = "E2E-Saas-Core-4"


@pytest.fixture
def saas_ready(api, actors):
    """SaaS admin with the bootstrap password already replaced; returns its API session."""
    saas = actors["saas"]
    return api.change_password(saas["email"], saas["password"], SAAS_PASSWORD)


@pytest.fixture
def saas_ui(saas_ready, login_page, page, actors):
    login_page.login("saas", actors["saas"]["email"], SAAS_PASSWORD)
    return SaasAdmin(page).wait()


@pytest.mark.covers("SC-03-04-02")
@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-03-03")
@pytest.mark.gui_id("GUI-X-03")  # zero-data site: guidance instead of errors
def test_new_manager_must_change_password_and_lands_on_an_empty_site(login_page, page, api, saas_ready):
    from pages import ManagerCockpit, ResidentsTab
    created = api.create_site(saas_ready, "Palmiye Evleri", "murat.yildirim@e2e.test")

    login_page.login("manager", "murat.yildirim@e2e.test", created["temporary_password"])
    # A temporary password opens only the change screen, never the cockpit.
    SaasAdmin(page).must_change_password_banner.wait_for(timeout=10_000)
    SaasAdmin(page).change_password(created["temporary_password"], "E2E-New-Manager-5")
    SaasAdmin(page).must_change_password_banner.wait_for(state="detached", timeout=15_000)
    ManagerCockpit(page).wait()

    assert ResidentsTab(page).open().unit_card_ids() == []  # zero-data site: no unit cards
    assert api.login("murat.yildirim@e2e.test", "E2E-New-Manager-5").user["must_change_password"] is False


@pytest.mark.covers("SC-03-01-01")
@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-03-04")
def test_manager_never_sees_another_sites_units(login_as, page, builders, stack):
    from pages import ManagerCockpit, ResidentsTab
    foreign_unit = builders.foreign_site_unit()
    begonya_units = set(stack.sql("SELECT id FROM units WHERE site_id = 1;").split())

    login_as("manager")
    ManagerCockpit(page).wait()
    shown = set(ResidentsTab(page).open().unit_card_ids())

    assert shown == begonya_units
    assert foreign_unit not in shown


@pytest.mark.core
@pytest.mark.role_saas
@pytest.mark.gui_id("GUI-03-05")
def test_edit_site_updates_the_card(saas_ui, stack):
    saas_ui.edit_site("1", "Begonya Sitesi Evleri", "Ataşehir, Yeni Sok. No:1, İstanbul", "+90 532 999 88 77")

    saas_ui.page.wait_for_function(
        "() => document.querySelector('[flt-semantics-identifier=\"site_card_name_1\"]')"
        "?.textContent.includes('Begonya Sitesi Evleri')", timeout=15_000)
    assert stack.sql("SELECT name FROM sites WHERE id = 1;") == "Begonya Sitesi Evleri"


@pytest.mark.covers("SC-03-06-01")
@pytest.mark.core
@pytest.mark.role_saas
@pytest.mark.gui_id("GUI-03-06")
def test_empty_site_can_be_deleted(api, saas_ready, login_page, page, actors, stack):
    site_id = str(api.create_site(saas_ready, "Silinecek Site", "silinecek@e2e.test")["site_id"])
    login_page.login("saas", actors["saas"]["email"], SAAS_PASSWORD)
    portfolio = SaasAdmin(page).wait()
    assert site_id in portfolio.site_ids()

    portfolio.open_add_site().fill(
        "Duplicate Site", "İstanbul", "Kadıköy", "A Blok", "Yeni Yönetici",
        "silinecek@e2e.test", "+90 532 000 0000")
    by_id(page, "btn_save_new_site").click()
    page.get_by_text("Bu e-posta adresi başka bir hesapta kullanılıyor.", exact=True).wait_for(timeout=15_000)
    page.get_by_text("Vazgeç", exact=True).last.click()

    portfolio.delete_site(site_id)

    page.locator(f'[flt-semantics-identifier="btn_edit_site_{site_id}"]').wait_for(state="detached", timeout=15_000)
    assert stack.sql(f"SELECT count(*) FROM sites WHERE id = {int(site_id)} AND status <> 'DELETED';") == "0"

    replacement = api.create_site(saas_ready, "Yeni Site", "silinecek@e2e.test")
    assert str(replacement["site_id"]) != site_id
    assert stack.sql(
        "SELECT count(*) FROM users WHERE lower(email) = 'silinecek@e2e.test' AND is_active;"
    ) == "1"


@pytest.mark.covers("SC-03-06-02")
@pytest.mark.core
@pytest.mark.role_saas
@pytest.mark.gui_id("GUI-03-07")
def test_site_with_units_cannot_be_deleted(saas_ui):
    assert saas_ui.page.locator('[flt-semantics-identifier="site_delete_locked_1"]').count() == 1
    assert saas_ui.page.locator('[flt-semantics-identifier="btn_delete_site_1"]').count() == 0


@pytest.mark.covers("SC-03-07-01")
@pytest.mark.core
@pytest.mark.role_saas
@pytest.mark.gui_id("GUI-03-08")
def test_admin_password_reset_issues_a_new_password_and_retires_the_old(saas_ui, api, actors):
    from pages.shell import Shell
    Shell(saas_ui.page).verify_sensitive(SAAS_PASSWORD)
    manager = actors["manager"]
    new_password = saas_ui.reset_admin_password("1").password()

    assert new_password and new_password != manager["password"]
    assert api.login(manager["email"], new_password).user["must_change_password"] is True
    with pytest.raises(ApiError):
        api.login(manager["email"], manager["password"])


@pytest.mark.covers("SC-03-07-02")
@pytest.mark.role_saas
def test_reset_admin_password_non_existent_site_fails(api, saas_ready):
    api.call("POST", "/api/v1/auth/step-up", saas_ready.token, body={"password": SAAS_PASSWORD})
    with pytest.raises(ApiError) as exc_info:
        api.call("POST", "/api/v1/saas/sites/999999/reset-admin-password", saas_ready.token)
    assert "404" in str(exc_info.value)
