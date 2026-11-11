"""EPIC-02 Site manager operations & EPIC-10 capital segment entry point."""
import pytest

from pages import DuesManagement, ManagerCockpit, ResidentsTab
from support.flutter import by_id
from support.money import last_amount


@pytest.mark.smoke
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-02-03")
def test_manager_adds_owner_resident(login_as, page, stack):
    login_as("manager")
    ManagerCockpit(page).wait()
    residents = ResidentsTab(page).open()
    before = set(residents.unit_card_ids())

    residents.start_add().fill(
        unit_no="25", full_name="Fatma Şahin", email="fatma.sahin@e2e.test", phone="05321234567").save()

    # A new unit card appears and the person + unit exist in the database.
    page.wait_for_function(
        "n => document.querySelectorAll('[flt-semantics-identifier^=\"delete_ho_\"]').length > n",
        arg=len(before), timeout=15_000)
    assert stack.sql("SELECT count(*) FROM persons WHERE email = 'fatma.sahin@e2e.test';") == "1"
    assert stack.sql("SELECT count(*) FROM units WHERE unit_number = 25;") == "1"


@pytest.mark.smoke
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-10-01")
def test_capital_segment_offers_project_creation(login_as, page):
    login_as("manager")
    ManagerCockpit(page).wait()
    dues = DuesManagement(page).open()
    assert dues.segment_count() == 5
    dues.segment(DuesManagement.CAPITAL_SEGMENT)
    by_id(page, "btn_open_capital_project_wizard").wait_for(timeout=10_000)
    # Empty site: the first-project call to action is offered as well.
    assert by_id(page, "btn_open_first_capital_project").count() == 1


# ---------------------------------------------------------------- P1 (core)

from decimal import Decimal  # noqa: E402

from support.flutter import by_id_prefix, fill, text_of  # noqa: E402


@pytest.fixture
def october_dues_b3_paid(api, actors):
    """Both units owe October dues (due 2026-10-15, so overdue); B Blok D:3 paid its principal."""
    manager = api.login(**actors["manager"])
    api.create_period(manager, "Ekim 2026", "2026-10-15")
    api.accrue_period(manager, "Ekim 2026", Decimal("1400.00"), "2026-10-15")
    return manager


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-02-02")
def test_overdue_filter_lists_every_overdue_flat(login_as, page, api, october_dues_b3_paid, stack):
    api.record_manual_payment(october_dues_b3_paid, "1", Decimal("1400.00"), "Mehmet Öz", payer_role="OWNER")
    overdue_units = set(stack.sql(
        "SELECT unit_id FROM dues_liabilities WHERE due_date < CURRENT_DATE "
        "AND paid_amount < principal_amount + delay_penalty;").split())
    login_as("manager")
    ManagerCockpit(page).wait()
    DuesManagement(page).open()

    by_id(page, "dues_filter_OVERDUE").click()
    page.wait_for_timeout(1_000)
    shown = {i.removeprefix("dues_flat_resident_module_") for i in page.eval_on_selector_all(
        '[flt-semantics-identifier^="dues_flat_resident_module_"]',
        "els => els.map(e => e.getAttribute('flt-semantics-identifier'))")}
    assert text_of(by_id(page, "dues_filter_OVERDUE")).endswith(f"({len(overdue_units)})")
    assert shown == overdue_units


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-02-05")
def test_resident_without_history_can_be_deleted(login_as, page, stack):
    login_as("manager")
    ManagerCockpit(page).wait()
    residents = ResidentsTab(page).open()
    before = set(residents.unit_card_ids())
    residents.start_add().fill(unit_no="25", full_name="Fatma Şahin", email="fatma.sahin@e2e.test",
                               phone="05321234567").save()
    page.wait_for_function("n => document.querySelectorAll('[flt-semantics-identifier^=\"delete_ho_\"]').length > n",
                           arg=len(before), timeout=15_000)
    (card_id,) = set(residents.unit_card_ids()) - before
    unit_id = stack.sql("SELECT id FROM units WHERE unit_number = 25;")

    by_id(page, f"delete_ho_{card_id}").click()
    by_id(page, "btn_confirmation_confirm").click()

    by_id(page, f"delete_ho_{card_id}").wait_for(state="detached", timeout=15_000)
    page.wait_for_timeout(1_000)  # the delete call must finish before the database check
    assert stack.sql(f"SELECT count(*) FROM units WHERE id = {int(unit_id)} AND deleted_at IS NULL;") == "0"


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-02-05")
# Zero data loss: a unit with ledger history is refused (409) and its card stays.
def test_refused_delete_keeps_the_resident_card(login_as, page, october_dues_b3_paid, stack):
    login_as("manager")
    ManagerCockpit(page).wait()
    ResidentsTab(page).open()

    by_id(page, "delete_ho_1").click()
    by_id(page, "btn_confirmation_confirm").click()
    page.wait_for_timeout(2_000)

    assert stack.sql("SELECT deleted_at IS NULL FROM units WHERE id = 1;") == "t"
    assert by_id(page, "delete_ho_1").count() == 1


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-02-06")
@pytest.mark.xfail(strict=True, reason="GAP (STORY-02-04): no payment reminder or direct message action exists")
def test_manager_can_send_a_payment_reminder(login_as, page):
    login_as("manager")
    ManagerCockpit(page).wait()
    DuesManagement(page).open().segment(2)  # aging
    page.wait_for_timeout(1_500)
    assert by_id_prefix(page, "btn_remind_").count() > 0


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-02-07")
@pytest.mark.xfail(strict=True, reason="GAP (STORY-02-05): announcements are display-only; there is no create UI "
                   "and no backend route")
def test_manager_can_create_an_announcement(login_as, page):
    login_as("manager")
    ManagerCockpit(page).wait()
    page.wait_for_timeout(1_500)
    assert by_id(page, "btn_create_announcement").count() == 1


def _open_house_types(page):
    by_id(page, "btn_cockpit_house_types").click()
    by_id(page, "btn_edit_house_type_2+1").wait_for(timeout=10_000)
    by_id(page, "btn_edit_house_type_2+1").click()
    by_id(page, "house_type_amount_field").wait_for(timeout=10_000)


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-02-08")
def test_house_type_tariff_is_saved_and_negative_amount_rejected(login_as, page, stack):
    login_as("manager")
    ManagerCockpit(page).wait()
    _open_house_types(page)

    fill(page, "house_type_amount_field", "-5")
    by_id(page, "btn_save_house_type").click()
    by_id(page, "house_type_error").wait_for(timeout=5_000)
    assert stack.sql("SELECT dues_amount FROM house_types WHERE site_id = 1 AND type_name = '2+1';") == "1400.00"

    fill(page, "house_type_amount_field", "1450.50")
    by_id(page, "btn_save_house_type").click()
    by_id(page, "btn_save_house_type").wait_for(state="detached", timeout=10_000)
    page.wait_for_timeout(1_000)
    assert stack.sql("SELECT dues_amount FROM house_types WHERE site_id = 1 AND type_name = '2+1';") == "1450.50"


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-02-08")
def test_house_type_tariff_rejects_more_than_two_decimals(login_as, page, stack):
    login_as("manager")
    ManagerCockpit(page).wait()
    _open_house_types(page)

    fill(page, "house_type_amount_field", "1400.555")
    by_id(page, "btn_save_house_type").click()
    page.wait_for_timeout(1_500)

    assert by_id(page, "house_type_error").count() == 1
    assert stack.sql("SELECT dues_amount FROM house_types WHERE site_id = 1 AND type_name = '2+1';") == "1400.00"


# ---------------------------------------------------------------- GUI-02-01 (P0)

def _cockpit_amount(page, test_id: str) -> Decimal:
    # e.g. '₺1.400,00' or '/ ₺2.800,00' (MoneyFormatter, kuruş kept)
    return last_amount(text_of(by_id(page, test_id)))


def _accrue_october(api, actors, amount: Decimal):
    manager = api.login(**actors["manager"])
    api.create_period(manager, "Ekim 2026", "2026-11-30")  # not yet due: no penalty
    api.accrue_period(manager, "Ekim 2026", amount, "2026-11-30")
    return manager


def _cockpit_figures(login_as, page) -> tuple[Decimal, Decimal, str]:
    login_as("manager")
    ManagerCockpit(page).wait()
    by_id(page, "cockpit_collection_badge").wait_for(timeout=15_000)
    return (_cockpit_amount(page, "cockpit_collected_amount"), _cockpit_amount(page, "cockpit_expected_amount"),
            text_of(by_id(page, "cockpit_collection_badge")))


@pytest.mark.smoke
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-02-01")
def test_cockpit_shows_the_accrued_total_before_any_payment(login_as, page, api, actors, stack):
    _accrue_october(api, actors, Decimal("1400.00"))
    expected = Decimal(stack.sql("SELECT sum(principal_amount) FROM dues_liabilities WHERE period = 'Ekim 2026';"))

    collected, shown_expected, badge = _cockpit_figures(login_as, page)

    assert (collected, shown_expected) == (Decimal("0"), expected)
    assert badge.startswith("%0 ")


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-02-01")
def test_cockpit_counts_a_payment_as_collected(login_as, page, api, actors, stack):
    manager = _accrue_october(api, actors, Decimal("1400.00"))
    b3 = stack.sql("SELECT u.id FROM units u JOIN blocks b ON b.id = u.block_id "
                   "WHERE b.block_name = 'B Blok' AND u.unit_number = 3;")
    api.record_manual_payment(manager, b3, Decimal("1400.00"), "Mehmet Öz", payer_role="OWNER")
    expected = Decimal(stack.sql("SELECT sum(principal_amount) FROM dues_liabilities WHERE period = 'Ekim 2026';"))
    collected = Decimal(stack.sql("SELECT sum(paid_amount) FROM dues_liabilities WHERE period = 'Ekim 2026';"))
    rate = (collected * 100 / expected).quantize(Decimal("1"))

    shown = _cockpit_figures(login_as, page)

    assert shown[:2] == (collected, expected) and shown[2].startswith(f"%{rate}"), (shown, collected, expected, rate)


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-02-01")
def test_cockpit_amounts_keep_kurus(login_as, page, api, actors):
    _accrue_october(api, actors, Decimal("1400.55"))
    _, shown_expected, _ = _cockpit_figures(login_as, page)
    assert shown_expected == Decimal("2801.10")
