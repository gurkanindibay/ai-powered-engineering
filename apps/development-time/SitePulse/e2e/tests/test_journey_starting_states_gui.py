"""STORY-13-01 and STORY-13-02: what the screens show for the reference starting states (GUI layer).

The backend side of these states is covered by test_journey_starting_states.py and
test_journey_accruals_payments.py; here a real browser signs in to an isolated journey site
and reads the pages the manager and the residents actually see.
"""
from __future__ import annotations

import re
from decimal import Decimal

import pytest

from pages import (
    DuesManagement, ManagerCockpit, Occupancy, ResidentHome, ResidentsTab, SaasAdmin, Shell, UnitWorkspace,
)
from pages.login import LoginPage
from support.flutter import by_id, fill
from support.journey_gui import (
    amount_of,
    id_text,
    journey_site,
    open_dues_segment,
    open_people_directory,
    page_lines,
    page_lines_until,
    page_text,
    resident_email,
    sign_in_manager,
)

EMPTY_STATE = re.compile(r"Henüz|bulunamadı|bulunmuyor", re.IGNORECASE)


def _units_page_lines(page) -> list[str]:
    Shell(page).nav("residents")
    by_id(page, "add_resident_btn").wait_for(timeout=15_000)
    page.wait_for_load_state("networkidle")
    return page_lines(page)


def _count(lines: list[str], wanted: str) -> int:
    return sum(1 for line in lines if line == wanted)


F1_UNIT_PLAN = (
    (1, "A-01", "VACANT", "Flat", Decimal("1500.00")),
    (2, "A-02", "VACANT", "Flat", Decimal("1500.00")),
    (3, "A-03", "VACANT", "Flat", Decimal("1500.00")),
    (4, "A-04", "VACANT", "Flat", Decimal("1500.00")),
    (5, "A-05", "VACANT", "Flat", Decimal("1500.00")),
    (6, "A-06", "VACANT", "Large flat", Decimal("2250.00")),
    (7, "A-07", "VACANT", "Flat", Decimal("1500.00")),
)

F1_TARIFFS = {"Flat": Decimal("1500.00"), "Large flat": Decimal("2250.00")}

# F2 reference plan: owner and tenant per unit, and the unit's occupancy state.
F2_UNIT_PLAN = (
    (1, "Ayşe Kaya", "", "OWNER_OCCUPIED"),
    (2, "Ahmet Yılmaz", "Selin Demir", "TENANT_OCCUPIED"),
    (3, "Burak Şahin", "", "VACANT"),
    (4, "Ahmet Yılmaz", "", "OWNER_OCCUPIED"),
    (5, "Can Öztürk", "Deniz Arslan", "TENANT_OCCUPIED"),
    (6, "Elif Aydın", "", "OWNER_OCCUPIED"),
    (7, "", "", "VACANT"),
)

F2_NAMES = ("Ayşe Kaya", "Ahmet Yılmaz", "Selin Demir", "Burak Şahin", "Can Öztürk", "Deniz Arslan", "Elif Aydın")


def _site_unit_ids(stack, site: int) -> list[str]:
    ids = stack.sql(f"SELECT id FROM units WHERE site_id = {site} ORDER BY unit_number;").splitlines()
    assert len(ids) == 7, ids
    return ids


def _assert_site_equals_f1(stack, site: int) -> None:
    """Compare the site with the F1 reference plan built by `_create_structure`."""
    assert stack.sql(
        f"SELECT block_name || '|' || total_floors FROM blocks WHERE site_id = {site};"
    ) == "A Blok|7"

    rows = stack.sql(
        "SELECT u.unit_number || '|' || b.block_name || '|' || u.occupancy_status || '|' || "
        "COALESCE(h.type_name, '') || '|' || COALESCE(h.dues_amount::text, '0') "
        "FROM units u JOIN blocks b ON b.id = u.block_id "
        "LEFT JOIN house_types h ON h.id = u.house_type_id "
        f"WHERE u.site_id = {site} ORDER BY u.unit_number;"
    ).splitlines()
    parsed = []
    for line in rows:
        unit_no, block_name, status, type_name, amount = line.split("|")
        # The unit label is derived (the units table stores no label column).
        label = f"{block_name.replace(' Blok', '').strip()}-{int(unit_no):02d}"
        parsed.append((int(unit_no), label, status, type_name, Decimal(amount)))
    assert tuple(parsed) == F1_UNIT_PLAN, rows

    tariffs = {
        name: Decimal(amount)
        for name, amount in (
            line.split("|")
            for line in stack.sql(
                f"SELECT type_name || '|' || dues_amount::text FROM house_types WHERE site_id = {site};"
            ).splitlines()
        )
    }
    assert tariffs == F1_TARIFFS, tariffs

    assert stack.sql(f"SELECT COUNT(*) FROM persons WHERE site_id = {site};") == "1", (
        "F1 has no people beyond the manager"
    )
    assert stack.sql(
        "SELECT COUNT(*) FROM units WHERE "
        f"site_id = {site} AND (owner_person_id IS NOT NULL OR tenant_person_id IS NOT NULL);"
    ) == "0", "F1 units are unassigned"
    assert stack.sql(
        "SELECT COUNT(*) FROM dues_liabilities d JOIN units u ON u.id = d.unit_id "
        f"WHERE u.site_id = {site};"
    ) == "0"
    assert stack.sql(f"SELECT COUNT(*) FROM dues_periods WHERE site_id = {site};") == "0"


def _assert_site_equals_f2(stack, site: int) -> None:
    """Compare owners, tenants and occupancy with the F2 reference plan."""
    rows = stack.sql(
        "SELECT u.unit_number || '|' || COALESCE(o.full_name, '') || '|' || "
        "COALESCE(t.full_name, '') || '|' || u.occupancy_status "
        "FROM units u LEFT JOIN persons o ON o.id = u.owner_person_id "
        "LEFT JOIN persons t ON t.id = u.tenant_person_id "
        f"WHERE u.site_id = {site} ORDER BY u.unit_number;"
    ).splitlines()
    assert rows == ["|".join(str(part) for part in row) for row in F2_UNIT_PLAN], rows

    people = stack.sql(
        f"SELECT full_name FROM persons WHERE site_id = {site} ORDER BY full_name;"
    ).splitlines()
    for name in F2_NAMES:
        assert name in people, f"{name} is missing from the site's people"
    assert len(people) == 8, f"expected the manager and seven people: {people}"
    assert stack.sql(
        "SELECT COUNT(*) FROM dues_liabilities d JOIN units u ON u.id = d.unit_id "
        f"WHERE u.site_id = {site};"
    ) == "0"
    assert stack.sql(f"SELECT COUNT(*) FROM dues_periods WHERE site_id = {site};") == "0"


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
            shown[name] = page_lines_until(page, EMPTY_STATE)
        _units_page_lines(page)  # opens the Residents tab; lines are read again once the empty state paints
        shown["units"] = page_lines_until(page, EMPTY_STATE)
        open_people_directory(page)
        shown["people"] = page_lines_until(page, EMPTY_STATE)

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
def test_f0_site_grows_to_f2_through_the_screens(request, api, actors, stack, page, login_page):
    """Grow an empty site to the F1 and F2 reference states through the manager's screens.

    The block/units screen assigns one house type per batch, so the seventh unit
    (the reference plan's single "Large flat") is created in its own batch; the
    last batch reuses "Flat" at the same amount instead of repricing it.
    """
    with journey_site(request, api, actors, stack, "F0") as fixture:
        sign_in_manager(page, login_page, fixture)
        site = int(fixture.site_id)
        residents = ResidentsTab(page).open()
        assert residents.unit_card_ids() == []

        # F0 -> F1: block "A Blok" with seven units and the reference tariffs.
        residents.start_add_block().fill(
            "A Blok", start_unit=1, unit_count=5, total_floors=7, house_type="Flat", monthly_dues="1.500,00",
        ).save()
        residents.start_add_block().fill(
            "A Blok", start_unit=6, unit_count=1, total_floors=7,
            house_type="Large flat", monthly_dues="2.250,00",
        ).save()
        residents.start_add_block().fill(
            "A Blok", start_unit=7, unit_count=1, total_floors=7, house_type="Flat", monthly_dues="1.500,00",
        ).save()

        _assert_site_equals_f1(stack, site)
        lines = _units_page_lines(page)
        assert "Boş Daire (7)" in lines and "Tümü (7)" in lines
        assert [f"A Blok {n}" for n in range(1, 8)] == [line for line in lines if re.fullmatch(r"A Blok \d+", line)]
        assert _count(lines, "Sakin kaydı yok") == 7
        assert _count(lines, "Sorumlu: Boş Daire") == 7

        # F1 -> F2: the reference owners and tenants, through the same screens.
        residents = ResidentsTab(page).open()
        residents.start_add().fill("1", "Ayşe Kaya", "ayse@a13.e2e.test", "05321110001").save()
        residents.start_add().fill("2", "Ahmet Yılmaz", "ahmet@a13.e2e.test", "05321110002").save()
        residents.start_add().fill(
            "3", "Burak Şahin", "burak@a13.e2e.test", "05321110004", occupancy="Boş Daire",
        ).save()
        residents.start_add().fill(
            "4", "Ahmet Yılmaz", "ahmet@a13.e2e.test", "05321110002", reuse_existing=True,
        ).save()
        residents.start_add().fill("5", "Can Öztürk", "can@a13.e2e.test", "05321110006").save()
        residents.start_add().fill(
            "6", "Elif Aydın", "elif@a13.e2e.test", "05321110007", house_type="Large flat",
        ).save()

        unit_ids = _site_unit_ids(stack, site)
        Occupancy(page).move_in(unit_ids[1], "Selin Demir", "selin@a13.e2e.test", "05321110003")
        Occupancy(page).move_in(unit_ids[4], "Deniz Arslan", "deniz@a13.e2e.test", "05321110005")

        _assert_site_equals_f2(stack, site)
        lines = _units_page_lines(page)
        assert "Kiracılı (2)" in lines, lines
        assert "Malik Mukim (3)" in lines, lines
        assert "Boş Daire (2)" in lines, lines
        # The directory names the occupant; a tenant-occupied unit shows the tenant
        # rather than the owner, and a vacant unit keeps its owner on the workspace
        # card, so unit 3 (owner only) reads "Sakin kaydı yok".
        for name in ("Ayşe Kaya", "Ahmet Yılmaz", "Selin Demir", "Deniz Arslan", "Elif Aydın"):
            assert name in lines, f"{name} missing from the units page"
        assert _count(lines, "Sakin kaydı yok") == 2

        # Every unit workspace agrees with the directory on its owner and occupant.
        for unit_no, unit_id in enumerate(unit_ids, start=1):
            _, owner, tenant, _ = F2_UNIT_PLAN[unit_no - 1]
            UnitWorkspace(page).open(unit_id)
            identity = id_text(page, "workspace_identity")
            UnitWorkspace(page).close()
            for name in (owner, tenant):
                if name:
                    assert name in identity, f"unit {unit_no} workspace misses {name}: {identity}"
            for other in F2_NAMES:
                if other not in (owner, tenant):
                    assert other not in identity, f"unit {unit_no} workspace shows {other}: {identity}"

        open_people_directory(page)
        people = page_text(page)
        for name in F2_NAMES:
            assert name in people, f"{name} missing from the people directory"


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
        page.wait_for_function(
            "() => [...document.querySelectorAll('flt-semantics')].some("
            "e => /A Blok D:\\d+/.test((e.getAttribute('aria-label') || e.textContent || '').trim()))",
            timeout=15_000,
        )
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
        page.wait_for_load_state("networkidle")
        page.evaluate("() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))")
        # The statement body can paint a frame or a fetch after the page settles, which WebKit
        # exposes: wait for the amount instead of reading one snapshot.
        lines = page_lines_until(page, re.compile(r"1\.250,00"))
        assert any("1.250,00" in line for line in lines), "A-6 advance balance 1250.00 not shown"


@pytest.mark.smoke
@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.covers("SC-13-08-01")
def test_first_manager_sign_in_unlocks_the_site_after_password_change(
        request, api, actors, stack, page, login_page):
    """SC-13-08-01: the provisioning password opens only the change screen, then the F5 site."""
    with journey_site(request, api, actors, stack, "F5") as fixture:
        # The seed already completed the onboarding password change; return the manager to the
        # provisioning state that a fresh onboarding leaves behind.
        stack.sql(
            "UPDATE users SET must_change_password = TRUE "
            f"WHERE lower(email) = lower('{fixture.manager_email}');")
        stack.restart_backend()

        login_page.open().login("manager", fixture.manager_email, fixture.manager_password)
        by_id(page, "screen_force_password_change").wait_for(timeout=15_000)

        requests: list[str] = []
        page.on("request", lambda r: requests.append(r.url) if "/api/v1/" in r.url else None)
        page.goto(f"{login_page.base_url.rstrip('/')}/#/manager/dues")
        # Let the router and its fetches settle before judging the request list; a route handler
        # can fire a request a few frames after the change screen is already visible.
        page.wait_for_load_state("networkidle")
        page.evaluate("() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))")
        by_id(page, "screen_force_password_change").wait_for(timeout=15_000)
        business = [url for url in requests
                    if any(marker in url for marker in ("/dues", "/payments", "/residents", "/site-admin"))]
        assert business == [], f"a protected deep link must not send a business request: {business}"

        new_password = "E2E-F5-Manager-Permanent-1!"
        SaasAdmin(page).change_password(fixture.manager_password, new_password)
        by_id(page, "screen_force_password_change").wait_for(state="detached", timeout=20_000)
        # The deep link that was refused is not resumed automatically; open the manager home.
        page.goto(f"{login_page.base_url.rstrip('/')}/#/manager/home")
        ManagerCockpit(page).wait()

        open_dues_segment(page, 2)
        page.wait_for_function(
            "() => [...document.querySelectorAll('flt-semantics')].some("
            "e => /A Blok D:\\d+/.test((e.getAttribute('aria-label') || e.textContent || '').trim()))",
            timeout=15_000,
        )
        rows = _aging_rows(page)
        assert rows["A-5"][1] == Decimal("4797.50"), "the F5 A-5 debt must be recognizable on the dashboard"
        assert sum(total for _, total in rows.values()) == Decimal("11117.50")
        assert api.login(fixture.manager_email, new_password).user["must_change_password"] is False


@pytest.mark.edge
@pytest.mark.role_manager
@pytest.mark.covers("SC-13-05-06")
def test_f5_vacant_unit_shows_the_former_tenant_section_under_a_suffixed_id(
        request, api, actors, stack, page, login_page):
    with journey_site(request, api, actors, stack, "F5") as fixture:
        unit = fixture.unit_ids[4]  # A-5: Deniz Arslan (tenant) leaves with three unpaid periods
        api.e2e_clock("set_date", "2026-11-30")
        api.e2e_clock("tick")
        api.e2e_clock("set_date", "2026-12-01")
        api.call(
            "POST", f"/api/v1/site-admin/units/{unit}/occupancy-transitions?site_id={fixture.site_id}",
            fixture.manager.token, body={"command": "MOVE_OUT", "effective_date": "2026-12-01"})

        sign_in_manager(page, login_page, fixture)
        Shell(page).nav("residents")
        UnitWorkspace(page).open(unit).action(unit, "statement")
        # #295: the plain id belongs to the current holder only, so a vacant
        # unit's former section is the first suffixed one.
        by_id(page, "statement_total_tenant_1").wait_for(timeout=15_000)
        assert by_id(page, "statement_total_tenant").count() == 0, \
            "a former tenant section never takes the current holder's id"
        # 4500.00 principal plus the penalty through the statement's own date
        # (2026-12-01, one day past the 2026-11-30 exit settlement).
        assert amount_of(page, "statement_total_tenant_1") == Decimal("4887.50")
        assert by_id(page, "statement_debtor_tenant").count() == 0, \
            "the former tenant's card is not the current holder's card"


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.covers("SC-13-08-03")
@pytest.mark.gui_id("GUI-13-14")
def test_f5_unit_search_zero_matches_is_recoverable(request, api, actors, stack, page, login_page):
    with journey_site(request, api, actors, stack, "F5") as fixture:
        sign_in_manager(page, login_page, fixture)
        ResidentsTab(page).open()

        # Search for an absent unit label
        fill(page, "resident_search_field", "Z-999-ABSENT")
        try:
            by_id(page, "units_filtered_empty_state").wait_for(timeout=10_000)
        except Exception:
            page.wait_for_load_state("networkidle")

        # Directory reports zero matches
        lines = page_lines(page)
        assert any("bulunamadı" in line.lower() or "bulunamadi" in line.lower() or "bulunmuyor" in line.lower() for line in lines)
        assert not any("A Blok 1" in line or "Ayşe Kaya" in line or "A-01" in line or "A-1" in line for line in lines)

        # Clear search
        clear_btn = by_id(page, "resident_search_clear_btn")
        reset_btn = by_id(page, "empty_state_reset_filters_btn")
        if clear_btn.count() > 0:
            clear_btn.click()
        elif reset_btn.count() > 0:
            reset_btn.click()
        else:
            fill(page, "resident_search_field", "")
        try:
            by_id(page, "units_filtered_empty_state").wait_for(state="detached", timeout=10_000)
        except Exception:
            page.wait_for_load_state("networkidle")

        # All units reappear and site unit count remains 7
        refreshed_lines = page_lines(page)
        assert any("A Blok 1" in line or "Ayşe Kaya" in line or "A-01" in line or "A-1" in line for line in refreshed_lines)
        assert stack.sql(f"SELECT COUNT(*) FROM units WHERE site_id = {int(fixture.site_id)};") == "7"


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.covers("SC-13-08-05")
@pytest.mark.gui_id("GUI-13-15")
def test_f2_cancelling_accrual_confirmation_makes_no_financial_change(request, api, actors, stack, page, login_page):
    with journey_site(request, api, actors, stack, "F2") as fixture:
        sign_in_manager(page, login_page, fixture)
        dues = DuesManagement(page).open()

        # Open accrual confirmation with valid inputs
        by_id(page, "btn_open_accrual_dialog").click()
        by_id(page, "btn_confirm_period_accrual").wait_for(timeout=10_000)

        # Cancel dialog
        cancel_btn = by_id(page, "btn_cancel_period_accrual")
        if cancel_btn.count() > 0:
            cancel_btn.click()
        else:
            page.get_by_role("button", name=re.compile(r"İptal|Cancel", re.IGNORECASE)).click()
        by_id(page, "btn_confirm_period_accrual").wait_for(state="detached", timeout=10_000)

        # Verify no liabilities exist
        site = int(fixture.site_id)
        assert stack.sql(f"SELECT COUNT(*) FROM dues_liabilities dl JOIN units u ON dl.unit_id = u.id WHERE u.site_id = {site};") == "0"

        # Reopening allows manager to confirm once successfully
        period, text = dues.accrue_selected_period()
        assert len(period) > 0
        assert stack.sql(f"SELECT COUNT(*) FROM dues_liabilities dl JOIN units u ON dl.unit_id = u.id WHERE u.site_id = {site};") != "0"


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.covers("SC-13-05-17")
@pytest.mark.gui_id("GUI-13-16")
def test_f5_checkout_shows_tenant_debt_and_owner_remains_collectible(
        request, api, actors, stack, page, login_page):
    with journey_site(request, api, actors, stack, "F5") as fixture:
        unit = fixture.unit_ids[4]  # A-5: tenant Deniz Arslan, owner Can Öztürk
        sign_in_manager(page, login_page, fixture)
        ResidentsTab(page).open()
        UnitWorkspace(page).open(unit).action(unit, "move_out")

        assert amount_of(page, "checkout_debt_principal") == Decimal("4500.00")
        assert amount_of(page, "checkout_debt_late_fee") == Decimal("297.50")
        assert amount_of(page, "checkout_debt_total") == Decimal("4797.50")
        assert "Deniz Arslan" in page_text(page)
        by_id(page, "module_move_out_effective_date").click()
        page.get_by_role(
            "button",
            name=re.compile(r"(?:November 19, 2026|19 Kasım 2026)", re.IGNORECASE),
        ).click()
        page.get_by_role("button", name="Tamam", exact=True).click()
        by_id(page, "module_confirm_move_out_btn").click()
        by_id(page, "module_confirm_move_out_btn").wait_for(state="detached", timeout=15_000)

        before = api.resident_statement(fixture.manager, unit)
        tenant_receipt_numbers = [
            item["receipt_number"]
            for item in before["receipts"]
            if item["payer_role"] == "TENANT"
        ]
        tenant = next(d for d in before["debtors"] if d["debtor_type"] == "TENANT")
        september = next(i for i in tenant["open_items"] if i["period"] == "Eylül 2026")
        payment = api.call(
            "POST",
            "/api/v1/payments/record-manual",
            fixture.manager.token,
            body={
                "site_id": fixture.site_id,
                "unit_id": unit,
                "amount": "1675.00",
                "payer_name": "Can Öztürk",
                "payer_role": "OWNER",
                "payment_channel": "MANUAL_CASH",
                "designation": {"due_ids": [september["due_id"]]},
                "settles_tenant_joint_liability": True,
                "idempotency_key": f"sc-13-05-17-{fixture.site_id}",
            },
        )
        receipt = payment.get("receipt", payment)
        assert receipt["payer_name"] == "Can Öztürk"
        assert receipt["on_behalf_of_name"] == "Deniz Arslan"

        owner_page = page.context.new_page()
        owner_email = resident_email(stack, fixture, "Can Öztürk")
        LoginPage(owner_page, login_page.base_url).open().login(
            "homeowner", owner_email, fixture.manager_password)
        ResidentHome(owner_page).wait()
        by_id(owner_page, "resident_statement_entry").click()
        by_id(owner_page, "statement_joint_liability_total").wait_for(timeout=15_000)
        assert amount_of(owner_page, "statement_joint_liability_total") == Decimal("3122.50")
        assert by_id(owner_page, f"statement_receipt_{receipt['receipt_number']}").count() == 1
        owner_text = page_text(owner_page)
        tenant_phone = stack.sql(
            "SELECT COALESCE(phone, '') FROM persons "
            f"WHERE site_id = {int(fixture.site_id)} AND full_name = 'Deniz Arslan';"
        )
        assert "Deniz Arslan" not in owner_text
        assert resident_email(stack, fixture, "Deniz Arslan") not in owner_text
        assert not tenant_phone or tenant_phone not in owner_text

        # Add a tenant-origin receipt after proving the owner's exact remaining balance.
        # The owner statement must keep showing the owner's own receipt only.
        tenant_payment = api.call(
            "POST",
            "/api/v1/payments/record-manual",
            fixture.manager.token,
            body={
                "site_id": fixture.site_id,
                "unit_id": unit,
                "amount": "100.00",
                "payer_name": "Deniz Arslan",
                "payer_role": "TENANT",
                "payment_channel": "MANUAL_CASH",
                "designation": {"due_ids": [next(
                    item["due_id"] for item in tenant["open_items"]
                    if item["period"] == "Ekim 2026"
                )]},
                "idempotency_key": f"sc-13-05-17-tenant-{fixture.site_id}",
            },
        )
        tenant_receipt = tenant_payment.get("receipt", tenant_payment)
        assert tenant_receipt["payer_name"] == "Deniz Arslan"
        assert tenant_receipt["payer_role"] == "TENANT"
        owner_page.close()
        owner_page = page.context.new_page()
        LoginPage(owner_page, login_page.base_url).open().login(
            "homeowner", owner_email, fixture.manager_password)
        ResidentHome(owner_page).wait()
        by_id(owner_page, "resident_statement_entry").click()
        by_id(owner_page, "statement_joint_liability_total").wait_for(timeout=15_000)
        assert by_id(owner_page, f"statement_receipt_{tenant_receipt['receipt_number']}").count() == 0
        for receipt_number in tenant_receipt_numbers:
            assert by_id(owner_page, f"statement_receipt_{receipt_number}").count() == 0
