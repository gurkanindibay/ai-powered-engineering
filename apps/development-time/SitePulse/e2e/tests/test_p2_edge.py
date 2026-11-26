"""P2 (edge) scenarios across epics: GUI_TEST_PLAN.md §3, priority P2."""
import re
import os
from datetime import date
from decimal import Decimal

import pytest

from pages import DuesManagement, ManagerCockpit, Occupancy, PaymentStream, ResidentHome, ResidentsTab
from support.api import ApiError
from support.bank_files import StatementRow, kuveyt_xlsx
from support.flutter import by_id, by_id_prefix, fill, input_value, text_of
from support.money import format_try, last_amount

A14_IBAN = "TR620020500009863791600001"


def _unit_id(stack, block: str, number: int) -> str:
    return stack.sql("SELECT u.id FROM units u JOIN blocks b ON b.id = u.block_id "
                     f"WHERE b.block_name = '{block}' AND u.unit_number = {number};")


def _plain(text: str) -> Decimal:
    """Amount after the last '₺' (e.g. 'Vadesi Gelmemiş₺42.000,00Normal döngü')."""
    return last_amount(text)


# ------------------------------------------------------------------ EPIC-06

@pytest.mark.edge
@pytest.mark.role_manager
@pytest.mark.covers("SC-06-02-06")
@pytest.mark.gui_id("GUI-06-04")
def test_empty_credentials_are_rejected_without_a_request(login_page, page):
    login_calls: list[str] = []
    page.on("request", lambda r: login_calls.append(r.url) if "/api/v1/auth/login" in r.url else None)
    by_id(page, "login_tab_siteManager").click()
    fill(page, "login_manager_email", "mehmet.demir@begonya.com")
    for field in ("login_manager_password",):
        by_id(page, field).first.click()
        page.keyboard.press("Control+a")
        page.keyboard.press("Delete")
    assert input_value(page, "login_manager_password") == ""

    by_id(page, "login_manager_submit").click()

    login_page.error_banner.wait_for(timeout=5_000)
    assert "eksiksiz" in text_of(login_page.error_banner)
    assert login_calls == []


@pytest.mark.edge
@pytest.mark.covers("SC-06-03-02")
@pytest.mark.gui_id("GUI-06-11")
def test_google_sign_in_redirects_to_the_provider(login_page, page):
    by_id(page, "login_tab_homeOwner").click()
    by_id(page, "btn_google_sign_in").click()
    # The fake provider is the sign-in host in CI: the browser navigates away
    # from the app and shows its account chooser.
    page.wait_for_url("**/fake-google.html", timeout=15_000)
    assert page.locator("#fake-google-account").is_visible()


# ------------------------------------------------------------------ EPIC-01

@pytest.mark.edge
@pytest.mark.role_homeowner
@pytest.mark.gui_id("GUI-01-05")
@pytest.mark.covers("SC-01-06-01")
def test_offline_state_shows_a_banner_and_keeps_the_balance(login_as, page, context, builders):
    builders.overdue_dues(principal=Decimal("1400.00"), days_overdue=10)
    login_as("homeowner")
    home = ResidentHome(page).wait()
    before = home.balance()

    context.set_offline(True)
    by_id(page, "offline_banner").wait_for(timeout=10_000)

    assert home.balance() == before
    assert by_id(page, "offline_banner").count() == 1


@pytest.mark.edge
@pytest.mark.role_homeowner
@pytest.mark.gui_id("GUI-01-06")
def test_penalty_detail_shows_days_and_the_penalty_amount(login_as, page, builders, api, actors):
    # The SQL builder dates the dues from the fixture day, so the clock has to agree with
    # it; the runner's UTC date is a day behind Istanbul between 21:00 and 24:00 UTC.
    api.clock.set_date(date.fromisoformat(api.stack.fixture_today))
    builders.overdue_dues(principal=Decimal("1400.00"), days_overdue=10)
    dashboard = api.resident_dashboard(api.login(**actors["homeowner"]))
    expected_penalty = Decimal(str(dashboard["total_debt"])) - Decimal("1400.00")
    login_as("homeowner")
    ResidentHome(page).wait()

    by_id(page, "hero_detail_button").click()
    by_id(page, "penalty_formula").wait_for(timeout=10_000)

    assert "10 Gün" in text_of(by_id(page, "penalty_days"))
    formula = text_of(by_id(page, "penalty_formula"))
    assert formula.endswith(format_try(expected_penalty)), (formula, expected_penalty)


# ------------------------------------------------------------------ EPIC-02

@pytest.mark.edge
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-02-04")
@pytest.mark.covers("SC-02-03-02")
def test_adding_a_resident_to_an_occupied_unit_warns_and_saves_nothing(login_as, page, stack):
    a14 = _unit_id(stack, "A Blok", 14)
    owner = stack.sql(f"SELECT owner_person_id FROM units WHERE id = {int(a14)};")
    login_as("manager")
    ManagerCockpit(page).wait()
    form = ResidentsTab(page).open().start_add()
    form.fill(unit_no="14", full_name="Deneme Kişi", email="deneme.kisi@e2e.test", phone="05320000009")

    by_id(page, "module_save_new_resident_btn").click()
    by_id(page, "btn_confirmation_cancel").wait_for(timeout=10_000)
    by_id(page, "btn_confirmation_cancel").click()
    by_id(page, "btn_confirmation_cancel").wait_for(state="detached", timeout=10_000)
    page.wait_for_load_state("networkidle")

    # The card chosen in the picker exists without a role (REQ-042); the unit is untouched.
    person = stack.sql("SELECT id FROM persons WHERE email = 'deneme.kisi@e2e.test';")
    assert stack.sql(f"SELECT count(*) FROM unit_ownerships WHERE person_id = {int(person)};") == "0"
    assert stack.sql(f"SELECT count(*) FROM unit_occupancies WHERE person_id = {int(person)};") == "0"
    assert stack.sql(f"SELECT owner_person_id FROM units WHERE id = {int(a14)};") == owner


# ------------------------------------------------------------------ EPIC-04

@pytest.mark.edge
@pytest.mark.role_homeowner
@pytest.mark.covers("SC-04-07-02")
@pytest.mark.gui_id("GUI-04-07")
def test_co_resident_joins_through_a_unit_invite(login_page, page, api, actors, stack):
    owner = api.login(**actors["homeowner"])
    link = api.call("GET", f"/api/v1/home-residents/invite-link/{owner.user['unit_id']}?site_id=1", owner.token)
    joined = api.call("POST", "/api/v1/home-residents/register", body={
        "token": link["token"], "full_name": "Zeynep Kaya", "email": "zeynep.kaya@e2e.test",
        "phone": "+90 542 333 44 55", "relationship": "SPOUSE"})
    zeynep = api.login("zeynep.kaya@e2e.test", joined["temporary_password"])
    assert zeynep.user["role"] == "HOME_RESIDENT"
    assert zeynep.user["unit_id"] == owner.user["unit_id"]
    # A temporary password must be changed before other authenticated operations.
    api.change_password("zeynep.kaya@e2e.test", joined["temporary_password"], "E2E-Zeynep-Kaya-7")
    zeynep = api.login("zeynep.kaya@e2e.test", "E2E-Zeynep-Kaya-7")
    api.call("GET", f"/api/v1/residents/{zeynep.user['unit_id']}/dashboard", zeynep.token)
    other_unit_id = stack.sql(
        f"SELECT id FROM units WHERE id <> {int(zeynep.user['unit_id'])} ORDER BY id LIMIT 1;"
    )
    assert other_unit_id, "the seed must include another unit for the cross-unit authorization check"
    with pytest.raises(ApiError, match="-> (403|404)"):
        api.call("GET", f"/api/v1/residents/{other_unit_id}/dashboard", zeynep.token)
    login_page.login("homeowner", "zeynep.kaya@e2e.test", "E2E-Zeynep-Kaya-7")
    ResidentHome(page).wait()


@pytest.mark.edge
@pytest.mark.role_manager
@pytest.mark.covers("SC-04-02-02")
@pytest.mark.gui_id("GUI-04-08")
def test_empty_approval_queue_shows_zero(login_as, page):
    login_as("manager")
    assert ManagerCockpit(page).wait().pending_count() == 0
    assert by_id_prefix(page, "pending_card_").count() == 0


# ------------------------------------------------------------------ EPIC-07

@pytest.mark.edge
@pytest.mark.role_manager
@pytest.mark.covers("SC-07-02-05")
@pytest.mark.gui_id("GUI-07-06")
def test_payer_name_alias_auto_matches_the_transfer(login_as, login_page, page, api, actors, tmp_path):
    homeowner = api.login(**actors["homeowner"])
    api.call("PUT", f"/api/v1/residents/{homeowner.user['unit_id']}/matching-criteria/payer-names", homeowner.token,
             body={"payer_names": ["Ahmet Yılmaz", "Ayse Yilmaz"]})
    statement = kuveyt_xlsx(tmp_path / "alias.xlsx", [StatementRow(
        "15.10.2026", "KT0010", "Para Transferi, Gönderen: Ayse Yilmaz , Alıcı: BEGONYA SITESI", Decimal("1400.00"))])
    login_as("manager")
    ManagerCockpit(page).wait()

    summary = DuesManagement(page).open().upload_statement(statement)
    assert summary.matched()[0] == 1


# ------------------------------------------------------------------ EPIC-08

@pytest.mark.edge
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-08-08")
def test_remove_tenant_only_keeps_the_owner(login_as, page, api, actors, stack):
    b3 = _unit_id(stack, "B Blok", 3)
    owner = stack.sql(f"SELECT owner_person_id FROM units WHERE id = {int(b3)};")
    api.move_in(api.login(**actors["manager"]), b3, "Selin Demir", "selin.demir@e2e.test")
    login_as("manager")
    ManagerCockpit(page).wait()
    ResidentsTab(page).open()

    query = f"SELECT owner_person_id || '|' || coalesce(tenant_person_id::text, '') FROM units WHERE id = {int(b3)};"
    # Removing only the tenant is the unit's move-out: the owner keeps the unit.
    Occupancy(page).move_out(b3)
    stack.wait_sql(query, f"{owner}|", timeout_s=10)
    assert stack.sql(query) == f"{owner}|", (
        f"tenant still set; occupancies: {stack.sql(f'SELECT id, occupancy_type, is_active FROM unit_occupancies WHERE unit_id = {int(b3)};')!r}")
    assert stack.sql(f"SELECT is_active FROM unit_occupancies WHERE unit_id = {int(b3)} "
                     "AND occupancy_type = 'TENANT';") == "f"


# ------------------------------------------------------------------ EPIC-09 / EPIC-10

@pytest.fixture
def tenant_paid_capital(api, actors, stack):
    """Tenant on B Blok D:3 pays ₺1.000,00 of an accrued capital installment ('Asansör Demirbaş')."""
    b3 = _unit_id(stack, "B Blok", 3)
    manager = api.login(**actors["manager"])
    api.move_in(manager, b3, "Selin Demir", "selin.demir@e2e.test")
    project = api.create_capital_project(manager, "Asansör Revizyonu", Decimal("42000.00"))
    api.accrue_installment(manager, str(project.get("id") or project.get("project_id")), 1)
    return api.record_manual_payment(manager, b3, Decimal("1000.00"), "Selin Demir", payer_role="TENANT",
                                     description="Asansör Demirbaş 1. Taksit",
                                     settles_owner_capital_dues=True)


@pytest.mark.edge
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-09-05")
@pytest.mark.gui_id("GUI-10-08")
@pytest.mark.covers("SC-10-03-02")
def test_tenant_capital_payment_receipt_names_the_owner_and_rent_offset(login_as, page, tenant_paid_capital, stack):
    login_as("manager")
    ManagerCockpit(page).wait()
    PaymentStream(page).open()
    by_id_prefix(page, "payment_entry_").first.click()
    by_id(page, "receipt_on_behalf").wait_for(timeout=10_000)

    assert tenant_paid_capital["on_behalf_of_name"] in text_of(by_id(page, "receipt_on_behalf"))
    assert "TBK md. 314" in text_of(by_id(page, "receipt_rent_offset_note"))
    # The tenant's operational ledger is untouched: the payment went to the owner's capital due.
    assert stack.sql("SELECT count(*) FROM dues_liabilities WHERE debtor_type = 'TENANT' AND paid_amount > 0;") == "0"


@pytest.mark.edge
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-09-06")
def test_debt_aging_buckets_add_up_to_the_grand_total(login_as, page, tenant_paid_capital, stack):
    open_total = Decimal(stack.sql("SELECT sum(principal_amount + delay_penalty - paid_amount) FROM dues_liabilities;"))
    login_as("manager")
    ManagerCockpit(page).wait()
    DuesManagement(page).open().segment(2)
    by_id(page, "aging_grand_total").wait_for(timeout=10_000)

    buckets = sum(_plain(text_of(by_id(page, f"aging_bucket_{b}"))) for b in ("current", "1_30", "31_60", "60_plus"))
    penalty = _plain(text_of(by_id(page, "aging_total_penalty")))
    grand = _plain(text_of(by_id(page, "aging_grand_total")))
    assert buckets + penalty == grand
    assert open_total > 0


@pytest.mark.edge
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-09-06")
# Fixed by SPEC-005 R5: the aging report uses outstanding amounts (partial payments count).
def test_debt_aging_total_matches_the_open_ledger(login_as, page, tenant_paid_capital, stack):
    open_total = Decimal(stack.sql("SELECT sum(principal_amount + delay_penalty - paid_amount) FROM dues_liabilities;"))
    login_as("manager")
    ManagerCockpit(page).wait()
    DuesManagement(page).open().segment(2)
    by_id(page, "aging_grand_total").wait_for(timeout=10_000)
    assert _plain(text_of(by_id(page, "aging_grand_total"))) == open_total


@pytest.mark.edge
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-09-07")
def test_virman_moves_advance_to_the_capital_due(login_as, page, api):
    api.webhook_transfer(A14_IBAN, Decimal("3500.00"), "E2E-FAST-VIRMAN", "AHMET YILMAZ AVANS")  # no dues: all advance
    login_as("manager")
    ManagerCockpit(page).wait()
    DuesManagement(page).open()
    by_id(page, "btn_dues_more_actions").click()
    by_id(page, "menu_item_virman").click()
    by_id(page, "virman_unit_dropdown").wait_for(timeout=10_000)
    assert "₺3.500,00" in text_of(by_id(page, "virman_unit_dropdown"))


# ------------------------------------------------------------------ Cross-cutting

@pytest.mark.edge
@pytest.mark.gui_id("GUI-X-05")
def test_reload_never_leaves_a_broken_screen(login_as, page):
    login_as("manager")
    ManagerCockpit(page).wait()
    page.reload()
    page.wait_for_selector('[flt-semantics-identifier="login_tab_quickAll"], '
                           '[flt-semantics-identifier="btn_open_unified_dues_center"]', timeout=20_000)


@pytest.mark.edge
@pytest.mark.gui_id("GUI-X-06")
def test_every_amount_uses_the_turkish_format(login_as, page, tenant_paid_capital):
    login_as("manager")
    ManagerCockpit(page).wait()
    DuesManagement(page).open().segment(2)
    by_id(page, "aging_grand_total").wait_for(timeout=10_000)
    texts = page.eval_on_selector_all("flt-semantics", "els => els.map(e => e.textContent || '')")
    amounts = {m for t in texts for m in re.findall(r"₺\s?[0-9][0-9.,]*", t)}
    bad = sorted(a for a in amounts if not re.fullmatch(r"₺\s?[0-9]{1,3}(\.[0-9]{3})*,[0-9]{2}", a))
    assert bad == [], bad
