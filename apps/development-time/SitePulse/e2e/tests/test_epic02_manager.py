"""EPIC-02 Site manager operations & EPIC-10 capital segment entry point."""
import pytest
from playwright.sync_api import expect

from pages import DuesManagement, ManagerCockpit, ResidentsTab, UnitWorkspace
from support.flutter import by_id
from support.money import last_amount


@pytest.mark.smoke
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-02-03")
@pytest.mark.covers("SC-02-03-01")
def test_manager_adds_owner_resident(login_as, page, stack):
    login_as("manager")
    ManagerCockpit(page).wait()
    residents = ResidentsTab(page).open()
    before = set(residents.unit_card_ids())

    residents.start_add().fill(
        unit_no="25", full_name="Fatma Şahin", email="fatma.sahin@e2e.test", phone="05321234567").save()

    # A new unit card appears and the person + unit exist in the database.
    page.wait_for_function(
        "n => document.querySelectorAll('[flt-semantics-identifier^=\"module_unit_actions_\"]').length > n",
        arg=len(before), timeout=15_000)
    assert stack.sql("SELECT count(*) FROM persons WHERE email = 'fatma.sahin@e2e.test';") == "1"
    assert stack.sql("SELECT count(*) FROM units WHERE unit_number = 25;") == "1"


@pytest.mark.smoke
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-10-01")
@pytest.mark.covers("SC-10-07-01")
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
def october_dues_b3_paid(api, actors, builders):
    """Both units owe October dues (due 2026-10-15, so overdue); B Blok D:3 paid its principal."""
    manager = api.login(**actors["manager"])
    api.create_period(manager, "Ekim 2026", "2026-10-15")
    api.accrue_period(manager, "Ekim 2026", Decimal("1400.00"), "2026-10-15")
    builders.overdue_since_period_due_date("Ekim 2026")
    return api.login(**actors["manager"])


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-02-02")
@pytest.mark.covers("SC-02-02-01")
def test_overdue_filter_lists_every_overdue_flat(login_as, page, api, october_dues_b3_paid, stack):
    api.record_manual_payment(october_dues_b3_paid, "1", Decimal("1400.00"), "Mehmet Öz", payer_role="OWNER")
    overdue_units = set(stack.sql(
        f"SELECT unit_id FROM dues_liabilities WHERE due_date < DATE '{stack.fixture_today}' "
        "AND paid_amount < principal_amount + delay_penalty;").split())
    login_as("manager")
    ManagerCockpit(page).wait()
    DuesManagement(page).open()

    by_id(page, "dues_filter_OVERDUE").click()
    page.wait_for_function(
        "n => (document.querySelector('[flt-semantics-identifier=\"dues_filter_OVERDUE\"]')?.getAttribute('aria-label') || "
        "document.querySelector('[flt-semantics-identifier=\"dues_filter_OVERDUE\"]')?.textContent || '').trim().endsWith(`(${n})`)",
        arg=len(overdue_units),
        timeout=10_000,
    )
    shown = {i.removeprefix("dues_flat_resident_module_") for i in page.eval_on_selector_all(
        '[flt-semantics-identifier^="dues_flat_resident_module_"]',
        "els => els.map(e => e.getAttribute('flt-semantics-identifier'))")}
    assert text_of(by_id(page, "dues_filter_OVERDUE")).endswith(f"({len(overdue_units)})")
    assert shown == overdue_units


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-02-02")
@pytest.mark.covers("SC-02-02-02")
def test_overdue_badge_shows_the_exact_days_overdue(login_as, page, builders, stack):
    """SC-02-02-02: the overdue filter renders each flat's exact day count in its danger badge."""
    fourteen = builders.overdue_dues(unit_number=14, principal=Decimal("1400.00"), days_overdue=14)
    eight = builders.overdue_dues(unit_number=3, principal=Decimal("1400.00"), days_overdue=8)
    rows = stack.sql(
        "SELECT u.id || '|' || b.block_name || '|' || u.unit_number FROM units u "
        "JOIN blocks b ON b.id = u.block_id "
        f"WHERE u.id IN ({int(fourteen['unit_id'])}, {int(eight['unit_id'])}) ORDER BY u.unit_number;"
    ).splitlines()
    assert rows == [
        f"{int(eight['unit_id'])}|B Blok|3",
        f"{int(fourteen['unit_id'])}|A Blok|14",
    ], rows

    login_as("manager")
    ManagerCockpit(page).wait()
    DuesManagement(page).open()
    by_id(page, "dues_filter_OVERDUE").click()
    for badge in (fourteen, eight):
        by_id(page, f"dues_status_badge_{badge['unit_id']}").wait_for(timeout=10_000)

    assert text_of(by_id(page, f"dues_status_badge_{fourteen['unit_id']}")) == "14 Gün Gecikti"
    assert text_of(by_id(page, f"dues_status_badge_{eight['unit_id']}")) == "8 Gün Gecikti"


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-02-05")
@pytest.mark.covers("SC-02-03-03")
def test_resident_without_history_can_be_deleted(login_as, page, stack):
    login_as("manager")
    ManagerCockpit(page).wait()
    residents = ResidentsTab(page).open()
    before = set(residents.unit_card_ids())
    residents.start_add().fill(unit_no="25", full_name="Fatma Şahin", email="fatma.sahin@e2e.test",
                               phone="05321234567").save()
    page.wait_for_function("n => document.querySelectorAll('[flt-semantics-identifier^=\"module_unit_actions_\"]').length > n",
                           arg=len(before), timeout=15_000)
    (card_id,) = set(residents.unit_card_ids()) - before
    unit_id = stack.sql("SELECT id FROM units WHERE unit_number = 25;")

    UnitWorkspace(page).open(card_id).action(card_id, "delete")
    with page.expect_response(
        lambda r: "/api/v1/" in r.url and r.request.method in ("DELETE", "POST"), timeout=15_000
    ):
        by_id(page, "btn_confirmation_confirm").click()
    by_id(page, "btn_confirmation_confirm").wait_for(state="detached", timeout=15_000)
    assert stack.sql(f"SELECT count(*) FROM units WHERE id = {int(unit_id)} AND deleted_at IS NULL;") == "0"

    UnitWorkspace(page).close()
    before = set(ResidentsTab(page).open().unit_card_ids())
    # Registering her again reuses her card when the duplicate check still offers it.
    ResidentsTab(page).start_add().fill(
        unit_no="26", full_name="Fatma Şahin", email="fatma.sahin@e2e.test", phone="05321234567",
        reuse_existing=True).save()
    page.wait_for_function(
        "n => document.querySelectorAll('[flt-semantics-identifier^=\"module_unit_actions_\"]').length > n",
        arg=len(before), timeout=15_000)
    assert stack.sql(
        "SELECT count(*) FROM persons WHERE site_id = 1 AND lower(email) = 'fatma.sahin@e2e.test' AND deleted_at IS NULL;"
    ) == "1"
    assert stack.sql(
        "SELECT count(*) FROM users WHERE lower(email) = 'fatma.sahin@e2e.test' AND is_active;"
    ) == "1"


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-02-05")
@pytest.mark.covers("SC-02-03-04")
# Zero data loss: a unit with ledger history is refused (409) and its card stays.
def test_refused_delete_keeps_the_resident_card(login_as, page, october_dues_b3_paid, stack):
    login_as("manager")
    ManagerCockpit(page).wait()
    ResidentsTab(page).open()

    UnitWorkspace(page).open("1").action("1", "delete")
    with page.expect_response(
        lambda r: "/api/v1/" in r.url and r.request.method in ("DELETE", "POST"), timeout=15_000
    ):
        by_id(page, "btn_confirmation_confirm").click()
    page.wait_for_load_state("networkidle")

    assert stack.sql("SELECT deleted_at IS NULL FROM units WHERE id = 1;") == "t"
    UnitWorkspace(page).back()
    assert by_id(page, "module_unit_actions_1").count() >= 1


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-02-06")
@pytest.mark.covers("SC-02-04-01")
def test_manager_can_send_a_payment_reminder(builders, login_as, page):
    builders.overdue_dues(unit_number=14, principal=Decimal("1400.00"), days_overdue=10)
    login_as("manager")
    ManagerCockpit(page).wait()
    DuesManagement(page).open().segment(2)  # aging
    by_id_prefix(page, "btn_remind_").first.wait_for(timeout=10_000)
    assert by_id_prefix(page, "btn_remind_").count() > 0


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-02-07")
@pytest.mark.covers("SC-02-05-01")
def test_manager_can_create_an_announcement(login_as, page, stack):
    login_as("manager")
    ManagerCockpit(page).wait()
    by_id(page, "btn_create_announcement").click()
    by_id(page, "announcement_title_field").wait_for(timeout=10_000)
    fill(page, "announcement_title_field", "Planlı Su Kesintisi")
    fill(page, "announcement_body_field", "Salı 10:00-14:00")
    by_id(page, "btn_save_announcement").click()
    by_id(page, "btn_create_announcement").wait_for(timeout=10_000)
    assert stack.sql("SELECT count(*) FROM notifications WHERE category = 'ANNOUNCEMENT' "
                     "AND subject = 'Planlı Su Kesintisi';") == "1"


def _open_house_types(page):
    by_id(page, "btn_cockpit_house_types").click()
    by_id(page, "btn_edit_house_type_2+1").wait_for(timeout=10_000)
    by_id(page, "btn_edit_house_type_2+1").click()
    by_id(page, "house_type_amount_field").wait_for(timeout=10_000)


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-02-08")
@pytest.mark.covers("SC-02-01-04")
def test_house_type_tariff_is_saved_and_negative_amount_rejected(login_as, page, stack):
    login_as("manager")
    ManagerCockpit(page).wait()
    _open_house_types(page)

    fill(page, "house_type_amount_field", "-5")
    by_id(page, "btn_save_house_type").click()
    by_id(page, "house_type_error").wait_for(timeout=5_000)
    assert stack.sql("SELECT dues_amount FROM house_types WHERE site_id = 1 AND type_name = '2+1';") == "1400.00"

    fill(page, "house_type_amount_field", "1450.50")
    with page.expect_response(
        lambda r: "/api/v1/" in r.url and r.request.method in ("POST", "PUT", "PATCH"), timeout=15_000
    ):
        by_id(page, "btn_save_house_type").click()
    by_id(page, "btn_save_house_type").wait_for(state="detached", timeout=10_000)
    assert stack.sql("SELECT dues_amount FROM house_types WHERE site_id = 1 AND type_name = '2+1';") == "1450.50"


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-02-08")
@pytest.mark.covers("SC-02-01-05")
def test_house_type_tariff_rejects_more_than_two_decimals(login_as, page, stack):
    login_as("manager")
    ManagerCockpit(page).wait()
    _open_house_types(page)

    fill(page, "house_type_amount_field", "1400.555")
    by_id(page, "btn_save_house_type").click()
    by_id(page, "house_type_error").wait_for(timeout=10_000)

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
@pytest.mark.covers("SC-02-01-01")
def test_cockpit_shows_the_accrued_total_before_any_payment(login_as, page, api, actors, stack):
    _accrue_october(api, actors, Decimal("1400.00"))
    expected = Decimal(stack.sql("SELECT sum(principal_amount) FROM dues_liabilities WHERE period = 'Ekim 2026';"))

    collected, shown_expected, badge = _cockpit_figures(login_as, page)

    assert (collected, shown_expected) == (Decimal("0"), expected)
    assert badge.startswith("%0 ")


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-02-01")
@pytest.mark.covers("SC-02-01-02")
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
@pytest.mark.covers("SC-02-01-03")
def test_cockpit_amounts_keep_kurus(login_as, page, api, actors):
    _accrue_october(api, actors, Decimal("1400.55"))
    _, shown_expected, _ = _cockpit_figures(login_as, page)
    assert shown_expected == Decimal("2801.10")


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-02-01")
@pytest.mark.covers("SC-02-01-06")
def test_cockpit_shows_collection_progress_and_unit_breakdown(login_as, page, stack):
    # Add 22 units to the two seeded units at the manager's site.
    stack.sql("""
        INSERT INTO units (block_id, site_id, unit_number, floor, occupancy_status)
        SELECT b.id, s.id, unit_number, 1, 'VACANT'
        FROM sites s JOIN blocks b ON b.site_id = s.id
        CROSS JOIN generate_series(101, 122) AS new_units(unit_number)
        WHERE s.slug = 'begonya-sitesi' AND b.block_name = 'A Blok';
    """)
    # Twelve units paid 5,000 each and six paid 6,000 each. The other six owe
    # 4,000 each; the penalty snapshot keeps the overdue balance fixed today.
    stack.sql("""
        WITH ranked_units AS (
            SELECT u.id, row_number() OVER (ORDER BY u.id) AS unit_rank
            FROM units u JOIN sites s ON s.id = u.site_id
            WHERE s.slug = 'begonya-sitesi'
        ), charges AS (
            SELECT id, unit_rank <= 18 AS paid,
                   CASE WHEN unit_rank <= 12 THEN 5000.00
                        WHEN unit_rank <= 18 THEN 6000.00
                        ELSE 4000.00 END AS principal,
                   (CURRENT_TIMESTAMP AT TIME ZONE 'UTC')::date AS today
            FROM ranked_units
        )
        INSERT INTO dues_liabilities (
            unit_id, period, principal_amount, due_date, status,
            paid_amount, paid_principal, penalty_accrued_through
        )
        SELECT id, 'Ekim 2026', principal, today - 1,
               CASE WHEN paid THEN 'PAID' ELSE 'OVERDUE' END,
               CASE WHEN paid THEN principal ELSE 0 END,
               CASE WHEN paid THEN principal ELSE 0 END,
               CASE WHEN NOT paid THEN today END
        FROM charges;
    """)
    stack.restart_backend()

    assert _cockpit_figures(login_as, page) == (
        Decimal("96000.00"), Decimal("120000.00"), "%80 Tahsil Edildi",
    )
    for test_id, label, value in (
        ("cockpit_total_units", "Toplam Daire", "24"),
        ("cockpit_paid_units", "Ödeyen", "18"),
        ("cockpit_overdue_units", "Geciken", "6"),
        ("cockpit_remaining_debt", "Kalan Borç", "₺24.000,00"),
    ):
        metric = by_id(page, test_id)
        expect(metric.get_by_text(label, exact=True)).to_be_visible()
        expect(metric.get_by_text(value, exact=True)).to_be_visible()
