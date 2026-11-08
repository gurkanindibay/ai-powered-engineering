"""EPIC-10 Capital expenditure & fixture dues."""
from decimal import ROUND_HALF_UP, Decimal

import pytest

from pages import CapitalProjects, ManagerCockpit, ResidentHome
from support.money import last_amount

BUDGET = Decimal("500000.00")


def _share_from(text: str) -> Decimal:
    # "Arsa Payı: 24/1000 • Toplam Pay: ₺285.714,29" (MoneyFormatter, Turkish format)
    return last_amount(text)


@pytest.mark.smoke
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-10-02")
def test_project_budget_is_split_by_land_share_to_the_kurus(login_as, page, stack):
    shares = dict(line.split("|") for line in stack.sql(
        "SELECT unit_number, land_share FROM units WHERE site_id = 1 AND deleted_at IS NULL;").splitlines())
    total_land = sum(int(v) for v in shares.values())
    login_as("manager")
    ManagerCockpit(page).wait()
    capital = CapitalProjects(page).open()

    capital.create("Asansör Revizyonu", str(BUDGET), by_land_share=True, installments=3)

    project = stack.sql("SELECT status || '|' || total_budget || '|' || allocation_basis FROM capital_projects;")
    assert project == f"ACTIVE|{BUDGET}|BY_LAND_SHARE"
    shown = {key.rsplit("_", 1)[1]: _share_from(text) for key, text in capital.show_unit_shares().unit_share_texts().items()}
    assert sum(shown.values()) == BUDGET  # exact, no kuruş lost or invented
    expected_14 = (BUDGET * int(shares["14"]) / total_land).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
    assert shown["14"] == expected_14


@pytest.mark.smoke
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-10-04")
def test_installment_accrual_charges_owners_only(login_as, page, stack):
    login_as("manager")
    ManagerCockpit(page).wait()
    capital = CapitalProjects(page).open()
    capital.create("Çatı Yalıtımı", "90000.00", by_land_share=True, installments=3)

    capital.accrue_installment(1)

    capital.installment_accrued(1).wait_for(timeout=15_000)
    rows = stack.sql("SELECT debtor_type || '|' || expense_type, count(*), sum(principal_amount) "
                     "FROM dues_liabilities WHERE capital_project_id IS NOT NULL GROUP BY 1;")
    units = stack.sql("SELECT count(*) FROM units WHERE site_id = 1 AND deleted_at IS NULL;")
    assert rows == f"OWNER|CAPITAL_DUES|{units}|30000.00", rows
    assert stack.sql("SELECT is_accrued FROM capital_project_installments WHERE installment_number = 1;") == "t"


# ---------------------------------------------------------------- P1 (core)

from support.flutter import by_id, fill  # noqa: E402


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-10-03")
def test_equal_allocation_gives_every_unit_the_same_share(login_as, page, stack):
    units = int(stack.sql("SELECT count(*) FROM units WHERE site_id = 1 AND deleted_at IS NULL;"))
    budget = Decimal("60000.00")
    login_as("manager")
    ManagerCockpit(page).wait()
    capital = CapitalProjects(page).open()

    capital.create("Kamera Sistemi", str(budget), by_land_share=False, installments=1)

    shown = [_share_from(t) for t in capital.show_unit_shares().unit_share_texts().values()]
    assert shown == [(budget / units).quantize(Decimal("0.01"))] * units
    assert stack.sql("SELECT allocation_basis FROM capital_projects;") == "EQUAL_PER_UNIT"


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-10-06")
@pytest.mark.xfail(strict=True, reason="BUG (STORY-10-05): a ₺120.000,00 contractor disbursement is recorded although the project has collected nothing; there is no overdraw guard")
def test_disbursement_larger_than_collected_cash_is_refused(login_as, page, stack):
    login_as("manager")
    ManagerCockpit(page).wait()
    capital = CapitalProjects(page).open()
    capital.create("Asansör Revizyonu", "500000.00", by_land_share=True, installments=1)

    by_id(page, "subtab_button_2").click()
    by_id(page, "btn_record_disbursement").click()
    by_id(page, "input_disbursement_amount").wait_for(timeout=10_000)
    fill(page, "input_disbursement_milestone", "1. Hakediş")
    fill(page, "input_disbursement_amount", "120000.00")
    fill(page, "input_disbursement_recipient", "Yıldız Asansör Ltd.")
    fill(page, "input_disbursement_iban", "TR330006100519786457841326")
    by_id(page, "btn_submit_disbursement").click()
    page.wait_for_timeout(2_000)

    assert stack.sql("SELECT count(*) FROM capital_contractor_disbursements;") == "0"


@pytest.mark.core
@pytest.mark.role_homeowner
@pytest.mark.gui_id("GUI-10-11")
@pytest.mark.xfail(strict=True, reason="GAP (STORY-10-06, tenant half): no 'Kat Maliki Sorumluluğunda' badge or "
                   "owner-responsibility banner exists for tenants")
def test_tenant_sees_capital_project_as_owner_responsibility(login_as, page):
    login_as("homeowner")
    page.wait_for_timeout(2_000)
    assert by_id(page, "capital_owner_badge").count() == 1


A14_IBAN = "TR620020500009863791600001"


def _metric(page, metric_id: str) -> Decimal:
    """Capital tile value, e.g. 'Tahsil Edilen₺4.000,00' -> Decimal('4000.00')."""
    from support.flutter import text_of
    return last_amount(text_of(by_id(page, f"capital_metric_{metric_id}")))


@pytest.fixture
def owner_paid_installment(api, actors):
    """Project ₺42.000,00 by land share, installment 1 accrued, A Blok D:14's owner pays ₺4.000,00 by FAST."""
    manager = api.login(**actors["manager"])
    project = api.create_capital_project(manager, "Çatı Yalıtımı", Decimal("42000.00"))
    project_id = str(project.get("id") or project.get("project_id"))
    api.accrue_installment(manager, project_id, 1)
    api.webhook_transfer(A14_IBAN, Decimal("4000.00"), "E2E-FAST-CAPEX-1", "AHMET YILMAZ DEMIRBAS 1. TAKSIT")
    return project_id


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-10-07")
def test_owner_fast_payment_raises_the_projects_collected_amount(login_as, page, owner_paid_installment, stack):
    login_as("manager")
    ManagerCockpit(page).wait()
    CapitalProjects(page).open()
    by_id(page, "capital_metric_collected").wait_for(timeout=10_000)

    assert _metric(page, "collected") == Decimal("4000.00")
    assert stack.sql("SELECT sum(paid_amount) FROM dues_liabilities WHERE expense_type = 'CAPITAL_DUES';") == "4000.00"


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-10-05")
def test_disbursement_within_collected_cash_updates_the_reserve(login_as, page, owner_paid_installment, stack):
    login_as("manager")
    ManagerCockpit(page).wait()
    CapitalProjects(page).open()
    by_id(page, "subtab_button_2").click()
    by_id(page, "btn_record_disbursement").click()
    by_id(page, "input_disbursement_amount").wait_for(timeout=10_000)
    fill(page, "input_disbursement_milestone", "1. Hakediş")
    fill(page, "input_disbursement_amount", "1000.00")
    fill(page, "input_disbursement_recipient", "Yıldız Yalıtım Ltd.")
    fill(page, "input_disbursement_iban", "TR330006100519786457841326")
    by_id(page, "btn_submit_disbursement").click()
    by_id(page, "btn_submit_disbursement").wait_for(state="detached", timeout=10_000)

    # Amounts are Turkish-formatted ("₺1.000,00"), so wait for that form, in the text or the label.
    page.wait_for_function("() => { const e = document.querySelector('[flt-semantics-identifier=\"capital_metric_disbursed\"]');"
                           " return !!e && ((e.textContent || '') + ' ' + (e.getAttribute('aria-label') || '')).includes('1.000,00'); }",
                           timeout=10_000)
    assert _metric(page, "disbursed") == Decimal("1000.00")
    assert _metric(page, "reserve") == Decimal("3000.00")
    assert stack.sql("SELECT amount FROM capital_contractor_disbursements;") == "1000.00"


@pytest.mark.core
@pytest.mark.role_homeowner
@pytest.mark.gui_id("GUI-10-10")
@pytest.mark.xfail(strict=True, reason="GAP (STORY-10-06): the owner's dashboard folds capital dues into one balance; "
                   "there is no separate capital line or project breakdown (capital balances are shown separately only "
                   "on the manager's resident cards)")
def test_owner_dashboard_shows_capital_dues_separately(login_as, page, owner_paid_installment, api, actors):
    login_as("homeowner")
    home = ResidentHome(page).wait()
    assert home.balance() > Decimal("0.00")
    assert by_id(page, "hero_capital_balance").count() == 1


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-10-09")
@pytest.mark.xfail(strict=True, reason="BUG (STORY-10-04): the virman dialog offers hard-coded units ('d-14' "
                   "'Mevcut Avans: ₺3.000,00', 'd-1') instead of the site's units and their real advance balances")
def test_virman_dialog_offers_real_units_and_advances(login_as, page, api):
    api.webhook_transfer(A14_IBAN, Decimal("3500.00"), "E2E-FAST-ADV-1", "AHMET YILMAZ AVANS")  # no dues: all advance
    login_as("manager")
    ManagerCockpit(page).wait()
    from pages import DuesManagement
    from support.flutter import text_of
    DuesManagement(page).open()
    by_id(page, "btn_dues_more_actions").click()
    by_id(page, "menu_item_virman").click()
    dropdown = by_id(page, "virman_unit_dropdown")
    dropdown.wait_for(timeout=10_000)
    assert "₺3.500,00" in text_of(dropdown)
