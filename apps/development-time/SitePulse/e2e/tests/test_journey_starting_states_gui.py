"""STORY-13-01 and STORY-13-02: what the screens show for the reference starting states (GUI layer).

The backend side of these states is covered by test_journey_starting_states.py and
test_journey_accruals_payments.py; here a real browser signs in to an isolated journey site
and reads the pages the manager and the residents actually see.
"""
from __future__ import annotations

import re
from decimal import Decimal

import pytest

from pages import DuesManagement, Occupancy, ResidentHome, ResidentsTab, Shell, UnitWorkspace
from pages.login import LoginPage
from support.flutter import by_id
from support.journey_gui import (
    amount_of,
    id_text,
    journey_site,
    open_dues_segment,
    open_people_directory,
    page_lines,
    page_text,
    resident_email,
    sign_in_manager,
)

EMPTY_STATE = re.compile(r"Henüz|bulunamadı|bulunmuyor", re.IGNORECASE)

BUG_EMPTY_STATES = (
    "BUG: on a site with no data the units list and the people directory show no empty-state message "
    "and no next action (the dues pages say 'Henüz Aidat Dönemi Yok'); see #283"
)


def _units_page_lines(page) -> list[str]:
    Shell(page).nav("residents")
    by_id(page, "add_resident_btn").wait_for(timeout=15_000)
    page.wait_for_timeout(1_500)
    return page_lines(page)


def _count(lines: list[str], wanted: str) -> int:
    return sum(1 for line in lines if line == wanted)


def _aging_rows(page) -> dict[str, tuple[str, Decimal]]:
    """Aging report rows by unit: (debtor line, total shown)."""
    lines = page_lines(page)
    rows: dict[str, tuple[str, Decimal]] = {}
    for index, line in enumerate(lines):
        match = re.fullmatch(r"A Blok D:(\d+)", line)
        if match:
            from support.money import parse_try

            rows[f"A-{match.group(1)}"] = (lines[index + 1], parse_try(lines[index + 2]))
    return rows


@pytest.mark.smoke
@pytest.mark.role_manager
@pytest.mark.covers("SC-13-01-01")
@pytest.mark.gui_id("GUI-13-05")
@pytest.mark.xfail(strict=True, raises=AssertionError, reason=BUG_EMPTY_STATES)
def test_f0_every_page_shows_an_empty_state(request, api, actors, stack, page, login_page):
    with journey_site(request, api, actors, stack, "F0") as fixture:
        sign_in_manager(page, login_page, fixture)
        # Dashboard: all zero.
        assert amount_of(page, "cockpit_collected_amount") == Decimal("0.00")
        assert amount_of(page, "cockpit_remaining_debt") == Decimal("0.00")
        assert id_text(page, "cockpit_total_units").endswith("0")

        shown: dict[str, list[str]] = {}
        for index, name in enumerate(("collection", "live cash", "aging", "unmatched")):
            open_dues_segment(page, index)
            shown[name] = page_lines(page)
        shown["units"] = _units_page_lines(page)
        open_people_directory(page)
        shown["people"] = page_lines(page)

        missing = [name for name, lines in shown.items() if not any(EMPTY_STATE.search(line) for line in lines)]
        assert not missing, f"pages without an empty-state message: {missing}"


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.covers("SC-13-01-04")
@pytest.mark.gui_id("GUI-13-06")
def test_f1_units_without_people_show_as_unassigned(request, api, actors, stack, page, login_page):
    with journey_site(request, api, actors, stack, "F1") as fixture:
        sign_in_manager(page, login_page, fixture)
        assert amount_of(page, "cockpit_remaining_debt") == Decimal("0.00")

        lines = _units_page_lines(page)
        assert "Boş Daire (7)" in lines and "Tümü (7)" in lines
        assert [f"A Blok {n}" for n in range(1, 8)] == [line for line in lines if re.fullmatch(r"A Blok \d+", line)]
        assert _count(lines, "Sakin kaydı yok") == 7
        assert _count(lines, "Sorumlu: Boş Daire") == 7

        open_people_directory(page)
        people = page_text(page)
        # The only person on a fresh site is its manager account; nobody is an owner or a resident.
        assert "Journey Manager" in people
        for name in ("Ayşe Kaya", "Ahmet Yılmaz", "Selin Demir"):
            assert name not in people
        assert stack.sql(
            "SELECT COUNT(*) FROM persons WHERE person_type IN ('HOME_OWNER', 'HOME_RESIDENT') "
            f"AND site_id = {int(fixture.site_id)};"
        ) == "0"


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.covers("SC-13-01-05")
@pytest.mark.gui_id("GUI-13-07")
@pytest.mark.xfail(strict=True, raises=AssertionError, reason=(
    "BUG: registering the first owner of an empty unit creates a 1500.00 liability although no period "
    "was accrued; see #286"))
def test_f1_manager_adds_first_owners_and_tenant(request, api, actors, stack, page, login_page):
    with journey_site(request, api, actors, stack, "F1") as fixture:
        sign_in_manager(page, login_page, fixture)
        ResidentsTab(page).open().start_add().fill("1", "Ayşe Kaya", "ayse@a13.e2e.test", "05321110001").save()
        ResidentsTab(page).open().start_add().fill("2", "Ahmet Yılmaz", "ahmet@a13.e2e.test", "05321110002").save()
        unit_a2 = fixture.unit_ids[1]
        Occupancy(page).move_in(unit_a2, "Selin Demir", "selin@a13.e2e.test", "05321110003")

        site = int(fixture.site_id)
        rows = dict(
            line.split("|")
            for line in stack.sql(
                "SELECT u.unit_number || '|' || COALESCE(o.full_name, '') || '/' || COALESCE(t.full_name, '') "
                f"FROM units u LEFT JOIN persons o ON o.id = u.owner_person_id "
                f"LEFT JOIN persons t ON t.id = u.tenant_person_id WHERE u.site_id = {site} "
                "AND u.unit_number IN (1, 2) ORDER BY u.unit_number;"
            ).splitlines()
        )
        assert rows["1"] == "Ayşe Kaya/"
        assert rows["2"] == "Ahmet Yılmaz/Selin Demir"

        lines = _units_page_lines(page)
        assert any("Ayşe Kaya" in line for line in lines)
        assert any("Selin Demir" in line for line in lines)

        # Three people were added; the fourth card is the site manager's own.
        assert stack.sql(f"SELECT COUNT(*) FROM persons WHERE site_id = {site};") == "4"
        liabilities = stack.sql(
            "SELECT u.unit_number || ' ' || d.principal_amount || ' ' || d.created_at FROM dues_liabilities d "
            f"JOIN units u ON u.id = d.unit_id WHERE u.site_id = {site};"
        )
        periods = stack.sql(f"SELECT period_name FROM dues_periods WHERE site_id = {site};")
        assert liabilities == "", f"liabilities without any accrued period (periods: {periods!r}): {liabilities!r}"
        open_people_directory(page)
        people = page_text(page)
        for name in ("Ayşe Kaya", "Ahmet Yılmaz", "Selin Demir"):
            assert name in people


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.covers("SC-13-01-06")
@pytest.mark.gui_id("GUI-13-08")
def test_f2_people_without_a_period_have_no_debt(request, api, actors, stack, page, login_page):
    with journey_site(request, api, actors, stack, "F2") as fixture:
        sign_in_manager(page, login_page, fixture)
        open_dues_segment(page, 0)
        lines = page_lines(page)
        assert "Henüz Aidat Dönemi Yok" in lines
        assert "Geciken (0)" in lines and "Ödeyen (0)" in lines
        assert by_id(page, "btn_open_accrual_dialog").count() == 1  # the offered first action
        assert amount_of(page, "cockpit_remaining_debt") == Decimal("0.00") if by_id(
            page, "cockpit_remaining_debt").count() else True

        owner_page = page.context.new_page()
        LoginPage(owner_page, login_page.base_url).open().login(
            "homeowner", resident_email(stack, fixture, "Ayşe Kaya"), fixture.manager_password)
        home = ResidentHome(owner_page).wait()
        assert home.balance() == Decimal("0.00")
        assert by_id(owner_page, "ledger_row_0").count() == 0
        assert by_id(owner_page, "statement_error").count() == 0


@pytest.mark.edge
@pytest.mark.role_manager
@pytest.mark.covers("SC-13-01-11")
@pytest.mark.gui_id("GUI-13-09")
def test_f3_accruing_the_same_period_again_is_blocked(request, api, actors, stack, page, login_page):
    with journey_site(request, api, actors, stack, "F3") as fixture:
        site = int(fixture.site_id)
        before = stack.sql(f"SELECT COUNT(*) FROM dues_liabilities d JOIN units u ON u.id = d.unit_id WHERE u.site_id = {site};")
        assert before == "0"
        sign_in_manager(page, login_page, fixture)
        open_dues_segment(page, 0)
        period, message = DuesManagement(page).accrue_selected_period()
        assert period.strip().startswith("Ekim 2026")
        assert re.search(r"zaten|daha önce|tekrar|mükerrer", message, re.IGNORECASE), message
        assert stack.sql(
            f"SELECT COUNT(*) FROM dues_liabilities d JOIN units u ON u.id = d.unit_id WHERE u.site_id = {site};"
        ) == "0"
        assert stack.sql(
            f"SELECT COUNT(*) FROM dues_periods WHERE site_id = {site} AND period_name = 'Ekim 2026';"
        ) == "1"


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.covers("SC-13-01-12")
@pytest.mark.gui_id("GUI-13-10")
@pytest.mark.xfail(strict=True, raises=AssertionError, reason="BUG: the manager screens cannot add a block or units; see #285")
def test_f0_site_grows_to_f2_through_the_screens(request, api, actors, stack, page, login_page):
    with journey_site(request, api, actors, stack, "F0") as fixture:
        sign_in_manager(page, login_page, fixture)
        Shell(page).nav("residents")
        by_id(page, "add_resident_btn").wait_for(timeout=15_000)
        assert by_id(page, "btn_add_block").count() == 1, "no screen adds a block with its units"


@pytest.mark.smoke
@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.covers("SC-13-02-01")
@pytest.mark.gui_id("GUI-13-11")
def test_f4_single_period_shows_one_debt_each(request, api, actors, stack, page, login_page):
    with journey_site(request, api, actors, stack, "F4") as fixture:
        sign_in_manager(page, login_page, fixture)
        assert amount_of(page, "cockpit_remaining_debt") == Decimal("8800.00")
        assert id_text(page, "cockpit_overdue_units").endswith("5")
        assert id_text(page, "cockpit_paid_units").endswith("1")

        open_dues_segment(page, 2)
        rows = _aging_rows(page)
        # A-1 paid in full: it is not a debtor; A-2 to A-6 are.
        assert sorted(rows) == ["A-2", "A-3", "A-4", "A-5", "A-6"]
        assert rows["A-2"] == ("Selin Demir • Kiracı", Decimal("1600.00"))
        assert rows["A-3"] == ("Burak Şahin • Kat Maliki", Decimal("1600.00"))
        assert rows["A-4"] == ("Ahmet Yılmaz • Kat Maliki", Decimal("1600.00"))
        assert rows["A-5"] == ("Deniz Arslan • Kiracı", Decimal("1600.00"))
        assert rows["A-6"] == ("Elif Aydın • Kat Maliki", Decimal("2400.00"))
        assert amount_of(page, "aging_grand_total") + amount_of(page, "aging_total_penalty") >= Decimal("8800.00")


@pytest.mark.core
@pytest.mark.role_resident
@pytest.mark.covers("SC-13-02-02")
@pytest.mark.gui_id("GUI-13-12")
def test_f4_resident_sees_what_the_admin_sees(request, api, actors, stack, page, login_page):
    with journey_site(request, api, actors, stack, "F4") as fixture:
        tenant_page = page.context.new_page()
        LoginPage(tenant_page, login_page.base_url).open().login(
            "resident", resident_email(stack, fixture, "Selin Demir"), fixture.manager_password)
        home = ResidentHome(tenant_page).wait()
        assert home.balance() == Decimal("1600.00")
        assert "40 Gün Gecikme" in id_text(tenant_page, "hero_overdue_badge")

        sign_in_manager(page, login_page, fixture)
        Shell(page).nav("residents")
        unit = fixture.unit_ids[1]
        UnitWorkspace(page).open(unit).action(unit, "statement")
        by_id(page, "statement_total_tenant").wait_for(timeout=15_000)
        assert amount_of(page, "statement_total_tenant") == Decimal("1600.00")


@pytest.mark.smoke
@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.covers("SC-13-02-04")
@pytest.mark.gui_id("GUI-13-13")
def test_f5_multiple_periods_add_up_per_unit_and_per_site(request, api, actors, stack, page, login_page):
    with journey_site(request, api, actors, stack, "F5") as fixture:
        sign_in_manager(page, login_page, fixture)
        open_dues_segment(page, 2)
        rows = _aging_rows(page)
        expected = {
            "A-2": Decimal("3122.50"), "A-3": Decimal("1675.00"),
            "A-4": Decimal("1522.50"), "A-5": Decimal("4797.50"),
        }
        assert {unit: total for unit, (_, total) in rows.items()} == expected
        assert sum(expected.values()) == Decimal("11117.50")
        assert "A-1" not in rows and "A-6" not in rows

        Shell(page).nav("residents")
        unit = fixture.unit_ids[5]
        UnitWorkspace(page).open(unit).action(unit, "statement")
        page.wait_for_timeout(1_500)
        assert any("1.250,00" in line for line in page_lines(page)), "A-6 advance balance 1250.00 not shown"
