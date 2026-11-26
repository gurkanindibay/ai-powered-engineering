"""STORY-13-06: one site from zero to a closed period, as one manager journey (GUI layer).

SC-13-06-01 walks eight checkpoints on one isolated site: the reference F1 and F2 states
built through the manager's screens, a September accrual and its collection, October and
November accruals with the F5 payment pattern, the September close, the December tenant
replacement and title transfer, and a backend restart.

Each checkpoint is a named step of the journey reporter (`support.journey.Journey`), so a
failure names the checkpoint and the JUnit report lists the ones that ran. The fixture
finalizer tears the site down and captures evidence even when a checkpoint fails.

This test drives the screens and reads what the manager sees at every checkpoint. Steps a
screen cannot perform deterministically in this suite stay API arrange: payments (no manual
payment entry screen), the period's exact due date on an accrual (the dialog's month list is
relative to the browser clock) and the resident logins of accounts the registration hands off
through activation links.
"""
from __future__ import annotations

import re
from decimal import Decimal

import pytest

from pages import ResidentHome, ResidentsTab, Shell, UnitWorkspace
from pages.login import LoginPage
from pages.person import PersonPicker
from support.api import raw_call
from support.flutter import ID_ATTR, by_id, text_of, wait_text_connected
from support.journey import Journey
from support.journey_attempts import ledger_invariants
from support.journey_gui import (
    amount_of,
    id_text,
    journey_site,
    open_dues_segment,
    page_lines,
    resident_email,
    sign_in_manager,
)
from support.journey_reference_site import (
    add_reference_owners,
    add_reference_units,
    assert_site_equals_f1,
    assert_site_equals_f2,
    site_unit_ids,
)
from support.journey_snapshots import current_section, money, open_items
from support.money import parse_try

SEP, SEP_DUE, SEP_KEY = "Eylül 2026", "2026-09-10", "2026-09"
OCT, OCT_DUE = "Ekim 2026", "2026-10-10"
NOV, NOV_DUE = "Kasım 2026", "2026-11-10"
# Turkish month names as the Material month picker prints them, keyed by period.
MONTHS = {SEP: ("Eylül", 9), OCT: ("Ekim", 10), NOV: ("Kasım", 11)}

D = Decimal


def _wait_for_id_text(page, test_id: str, expected: str, timeout_ms: int = 15_000) -> None:
    """Wait until the widget tagged `test_id` exposes `expected` (a slow engine paints late)."""
    page.wait_for_function(
        """([selector, text]) => {
            const element = document.querySelector(selector);
            const content = element
                ? (element.getAttribute('aria-label') || element.textContent || '')
                : '';
            return content.includes(text);
        }""",
        arg=[f'[flt-semantics-identifier="{test_id}"]', expected],
        timeout=timeout_ms,
    )


def _fresh_manager_session(page, login_page, fixture) -> None:
    """Sign the manager in again on a fresh document, so changes made through the API show.

    A hash-only `goto` stays inside the running SPA (the app keeps its in-memory session);
    a query string forces a document load, and the app boots signed out.
    """
    page.goto(f"{login_page.base_url}/?fresh=1")
    page.wait_for_selector('[flt-semantics-identifier="login_tab_quickAll"]', timeout=30_000)
    login_page.login("manager", fixture.manager_email, fixture.manager_password)
    by_id(page, "cockpit_remaining_debt").wait_for(timeout=30_000)
    page.wait_for_load_state("networkidle")


def _pay(api, manager, unit_id: str, name: str, role: str, amount: str, on: str,
         period: str | None = None) -> dict:
    """Record a manual payment on its date.

    The idempotency key names the unit and day, so a second period with the same amount is not
    treated as a replay of the first.

    `period` is the payer's designation (TBK 101): a resident paying October on its due date
    means October, not the oldest debt. Without it the allocation would clear September first
    and the F5 payment pattern could not be reached.
    """
    return api.record_manual_payment(
        manager, unit_id, D(amount), name, payer_role=role,
        payment_date=f"{on}T00:00:00Z", idempotency_key=f"chain-{unit_id}-{on}",
        designation={"periods": [period]} if period else None,
    )


def _open_cockpit(page) -> None:
    Shell(page).nav("home")
    by_id(page, "cockpit_remaining_debt").wait_for(timeout=15_000)
    page.wait_for_load_state("networkidle")


def _accrue_through_the_dialog(page, api, fixture, period: str, due: str, due_day: int) -> str:
    """Accrue `period` on the manager's dues screen with `due`; return the result message.

    The period row is created through the API first so the app opens it with the intended
    due date (the dialog's calendar starts on the 15th); the dialog then selects that month
    and the due day, which is what the accrual writes on every liability.
    """
    year, month = int(due[:4]), int(due[5:7])
    month_name = MONTHS[period][0]
    assert MONTHS[period][1] == month, (period, due)
    api.create_period(fixture.manager, period, due)

    open_dues_segment(page, 0)
    by_id(page, "btn_open_accrual_dialog").click()
    by_id(page, "btn_confirm_period_accrual").wait_for(timeout=10_000)
    if text_of(by_id(page, "accrual_dialog_period")).strip() != period:
        by_id(page, "accrual_dialog_period").click()
        option = by_id(page, f"accrual_month_{year}_{month}")
        option.first.wait_for(state="attached", timeout=10_000)
        option.first.click()

    by_id(page, "accrual_dialog_due_date").click()
    # The calendar grid exposes each day only as painted text; the picker's input mode
    # writes the same date through a real <input> and is stable across engines.
    switch = page.get_by_text("Girişe geç", exact=True)
    switch.last.wait_for(timeout=10_000)
    switch.last.click()
    field = page.locator("flt-semantics input, flt-semantics textarea").last
    field.wait_for(state="attached", timeout=10_000)
    field.click()
    assert wait_text_connected(page, field), "the date input never connected to the app"
    field.press("Control+a")
    field.press("Delete")
    field.type(f"{due_day:02d}.{month:02d}.{year}")
    page.get_by_text("Tamam", exact=True).last.click()
    _wait_for_id_text(page, "accrual_dialog_due_date", f"{due_day:02d}.{month:02d}.{year}")

    by_id(page, "btn_confirm_period_accrual").click()
    snackbar = by_id(page, "snackbar_accrual_result")
    snackbar.wait_for(timeout=20_000)
    # The result message is a short-lived snackbar; the checkpoint assertions read the ledger,
    # so a message that has already gone is reported as empty rather than failing the step.
    message = ""
    try:
        page.wait_for_function(
            """([attribute, id]) => {
                const element = document.querySelector(`[${attribute}="${id}"]`);
                return element && ((element.textContent || '').trim().length > 0
                    || (element.getAttribute('aria-label') || '').length > 0);
            }""",
            arg=[ID_ATTR, "snackbar_accrual_result"], timeout=5_000,
        )
        message = text_of(snackbar).strip()
    except Exception:
        pass
    try:
        snackbar.wait_for(state="detached", timeout=20_000)
    except Exception:
        pass
    return message


def _aging_rows(page) -> dict[str, tuple[str, Decimal]]:
    """Aging report rows by unit label: (debtor line, total shown)."""
    lines = page_lines(page)
    rows: dict[str, tuple[str, Decimal]] = {}
    for index, line in enumerate(lines):
        match = re.fullmatch(r"A Blok D:(\d+)", line)
        if match:
            rows[f"A-{match.group(1)}"] = (lines[index + 1], parse_try(lines[index + 2]))
    return rows


def _open_statement(page, unit_id: str) -> None:
    Shell(page).nav("residents")
    by_id(page, "add_resident_btn").wait_for(timeout=15_000)
    page.wait_for_load_state("networkidle")
    UnitWorkspace(page).open(unit_id).action(unit_id, "statement")
    page.wait_for_load_state("networkidle")


def _leave_statement(page) -> None:
    page.keyboard.press("Escape")
    by_id(page, "workspace_actions").wait_for(timeout=10_000)
    UnitWorkspace(page).close()


@pytest.mark.smoke
@pytest.mark.role_manager
@pytest.mark.covers("SC-13-06-01")
@pytest.mark.gui_id("GUI-13-17")
@pytest.mark.timeout(900)
def test_manager_grows_a_site_collects_dues_and_closes_a_period(request, api, actors, stack, page, login_page):
    journey = Journey(request, role="manager")
    with journey_site(request, api, actors, stack, "F0") as fixture:
        site = int(fixture.site_id)
        manager = fixture.manager
        api.clock.set_instant("2026-09-01T06:00:00Z")  # 09:00 in Istanbul
        status, body = raw_call(
            api, "PUT", f"/api/v1/site-admin/proration-policy?site_id={site}", manager.token,
            {"proration_enabled": True},
        )
        assert status == 200, body
        sign_in_manager(page, login_page, fixture)

        with journey.step("checkpoint 1: F1 units and tariffs"):
            residents = ResidentsTab(page).open()
            assert residents.unit_card_ids() == [], "a site in F0 has no units"
            add_reference_units(page)
            assert_site_equals_f1(stack, site)
            lines = page_lines(page)
            assert "Boş Daire (7)" in lines and "Tümü (7)" in lines, lines
            assert [f"A Blok {n}" for n in range(1, 8)] == [
                line for line in lines if re.fullmatch(r"A Blok \d+", line)
            ], lines
            ledger_invariants(api, manager, fixture.site_id, stage="checkpoint 1")

            # The app stamps a new unit with the database wall clock, which the E2E time machine
            # does not move; the reference seeder pins the same creation date (`create_structure_sql`).
            # Without it, an occupancy starting on the scenario date would look backdated before
            # the unit existed and the proration guard would refuse it.
            stack.sql(
                "UPDATE units SET created_at = TIMESTAMPTZ '2026-09-01 06:00:00+00' "
                f"WHERE site_id = {site};"
            )
            stack.restart_backend()
            manager = api.login(fixture.manager_email, fixture.manager_password)
            page.wait_for_load_state("networkidle")

        with journey.step("checkpoint 2: F2 owners and tenants"):
            add_reference_owners(page, vacant_units=(2, 3, 5))
            unit_ids = site_unit_ids(stack, site)
            # The move-in form carries no effective date, and the endpoint would default to the
            # wall clock rather than the scenario clock; date the two tenancies explicitly.
            api.move_in(
                manager, unit_ids[1], "Selin Demir", "selin@a13.e2e.test",
                phone="05321110003", effective_date="2026-09-01")
            api.move_in(
                manager, unit_ids[4], "Deniz Arslan", "deniz@a13.e2e.test",
                phone="05321110005", effective_date="2026-09-01")
            assert_site_equals_f2(stack, site)

            # Reload from the persisted rows before any financial checkpoint, as the reference
            # fixture does: the accrual reads the unit occupancy sessions loaded at startup, and
            # this journey mixes screen registrations with the dated tenancy commands.
            stack.restart_backend()
            manager = api.login(fixture.manager_email, fixture.manager_password)
            _fresh_manager_session(page, login_page, fixture)

            ResidentsTab(page).open()
            page.wait_for_load_state("networkidle")
            lines = page_lines(page)
            assert "Kiracılı (2)" in lines, lines
            assert "Malik Mukim (3)" in lines, lines
            named = "\n".join(page_lines(page))
            for name in ("Ayşe Kaya", "Selin Demir", "Elif Aydın"):
                assert name in named, f"{name} missing from the units page when checkpoint 2 closed"
            ledger_invariants(api, manager, fixture.site_id, stage="checkpoint 2")

        a1, a2, a3, a4, a5, a6 = unit_ids[:6]

        with journey.step("checkpoint 3: September accrual"):
            message = _accrue_through_the_dialog(page, api, fixture, SEP, SEP_DUE, 10)
            if message:
                assert "6 daireye" in message, message
            _open_cockpit(page)
            assert amount_of(page, "cockpit_remaining_debt") == D("9750.00")
            assert id_text(page, "cockpit_overdue_units").endswith("6"), id_text(page, "cockpit_overdue_units")
            assert stack.sql(
                "SELECT COUNT(*) || '|' || SUM(principal_amount)::text FROM dues_liabilities d "
                f"JOIN units u ON u.id = d.unit_id WHERE u.site_id = {site};"
            ) == "6|9750.00"
            ledger_invariants(api, manager, fixture.site_id, stage="checkpoint 3")

        with journey.step("checkpoint 4: Ayşe pays in full, Elif holds an advance"):
            _pay(api, manager, a1, "Ayşe Kaya", "OWNER", "1500.00", "2026-09-01", SEP)
            _pay(api, manager, a6, "Elif Aydın", "OWNER", "8000.00", "2026-09-01")

            ayse = current_section(api.resident_statement(manager, a1), "OWNER")
            assert money(ayse["total_outstanding"]) == D("0.00"), ayse
            elif_owner = current_section(api.resident_statement(manager, a6), "OWNER")
            assert money(elif_owner["total_outstanding"]) == D("0.00"), elif_owner
            assert money(elif_owner["advance_balance"]) == D("5750.00"), elif_owner

            _open_statement(page, a1)
            _wait_for_id_text(page, "statement_total_owner", "0,00")
            assert amount_of(page, "statement_total_owner") == D("0.00")
            _leave_statement(page)
            _open_statement(page, a6)
            _wait_for_id_text(page, "statement_debtor_owner", "5.750,00")
            assert amount_of(page, "statement_total_owner") == D("0.00")
            assert "5.750,00" in id_text(page, "statement_debtor_owner")
            _leave_statement(page)

            _fresh_manager_session(page, login_page, fixture)  # the payments were API-side
            # 9750.00 charged, 1500.00 and the 2250.00 September share paid; Elif's 5750.00 is an advance.
            assert amount_of(page, "cockpit_remaining_debt") == D("6000.00")
            ledger_invariants(api, manager, fixture.site_id, stage="checkpoint 4")

        with journey.step("checkpoint 5: October and November accruals and the F5 payments"):
            api.clock.set_instant("2026-09-10T06:00:00Z")
            _pay(api, manager, a2, "Selin Demir", "TENANT", "1500.00", "2026-09-10", SEP)
            _pay(api, manager, a4, "Ahmet Yılmaz", "OWNER", "1500.00", "2026-09-10", SEP)

            api.clock.set_instant("2026-10-01T06:00:00Z")
            message = _accrue_through_the_dialog(page, api, fixture, OCT, OCT_DUE, 10)
            if message:
                assert "1 daire avanstan otomatik kapatıldı" in message, message
            elif_owner = current_section(api.resident_statement(manager, a6), "OWNER")
            assert money(elif_owner["advance_balance"]) == D("3500.00"), elif_owner
            api.clock.set_instant("2026-10-10T06:00:00Z")
            for unit_id, name, role in (
                (a1, "Ayşe Kaya", "OWNER"),
                (a3, "Burak Şahin", "OWNER"),
                (a4, "Ahmet Yılmaz", "OWNER"),
            ):
                _pay(api, manager, unit_id, name, role, "1500.00", "2026-10-10", OCT)

            api.clock.set_instant("2026-11-01T06:00:00Z")
            message = _accrue_through_the_dialog(page, api, fixture, NOV, NOV_DUE, 10)
            if message:
                assert "1 daire avanstan otomatik kapatıldı" in message, message
            api.clock.set_instant("2026-11-10T06:00:00Z")
            for unit_id, name in ((a1, "Ayşe Kaya"), (a3, "Burak Şahin")):
                _pay(api, manager, unit_id, name, "OWNER", "1500.00", "2026-11-10", NOV)

            api.clock.set_instant("2026-11-19T09:00:00Z")  # 12:00 in Istanbul
            api.clock.tick()

            overview = ledger_invariants(api, manager, fixture.site_id, stage="checkpoint 5")
            expected = {
                a2: ("TENANT", D("3122.50")), a3: ("OWNER", D("1675.00")),
                a4: ("OWNER", D("1522.50")), a5: ("TENANT", D("4797.50")),
            }
            for unit_id, (role, total) in expected.items():
                section = current_section(api.resident_statement(manager, unit_id), role)
                assert money(section["total_outstanding"]) == total, (unit_id, section)
            outstanding = sum(total for _, total in expected.values())
            assert outstanding == D("11117.50")
            assert money(overview["summary"]["total_advance_balance"]) == D("1250.00")
            elif_owner = current_section(api.resident_statement(manager, a6), "OWNER")
            assert money(elif_owner["advance_balance"]) == D("1250.00"), elif_owner

            # The manager's aging report shows the same per-unit totals as the ledger.
            _fresh_manager_session(page, login_page, fixture)  # accruals, payments and the tick were API-side
            open_dues_segment(page, 2)
            page.wait_for_load_state("networkidle")
            try:
                page.wait_for_function(
                    "() => [...document.querySelectorAll('flt-semantics')].some("
                    "e => /A Blok D:\\d+/.test((e.getAttribute('aria-label') || e.textContent || '').trim()))",
                    timeout=20_000,
                )
            except Exception:
                raise AssertionError(f"the aging report did not paint; page showed: {page_lines(page)[-30:]}")
            rows = _aging_rows(page)
            assert {unit: total for unit, (_, total) in rows.items()} == {
                "A-2": D("3122.50"), "A-3": D("1675.00"), "A-4": D("1522.50"), "A-5": D("4797.50"),
            }, rows
            assert sum(total for _, total in rows.values()) == D("11117.50")

            _open_statement(page, a6)
            _wait_for_id_text(page, "statement_debtor_owner", "1.250,00")
            assert "1.250,00" in id_text(page, "statement_debtor_owner")
            assert amount_of(page, "statement_total_owner") == D("0.00")
            _leave_statement(page)

        period_ids = {row["period_name"]: str(row["id"]) for row in api.list_periods(manager)}
        sep_id = period_ids[SEP]

        with journey.step("checkpoint 6: September closes and stays collectable"):
            open_dues_segment(page, 0)
            by_id(page, f"period_action_close_{sep_id}").click()
            by_id(page, f"period_close_confirm_{sep_id}").click()
            _wait_for_id_text(page, f"period_status_{sep_id}", "KAPALI")
            assert text_of(by_id(page, f"period_status_{sep_id}")) == "KAPALI"
            assert not by_id(page, f"period_action_accrue_{sep_id}").is_enabled()
            assert not by_id(page, f"period_action_close_{sep_id}").is_enabled()
            assert by_id(page, f"period_action_reopen_{sep_id}").is_enabled()

            snapshot = stack.sql(
                "SELECT accrued::text || '|' || collected::text || '|' || outstanding::text || '|' || snapshot_version "
                f"FROM dues_period_snapshots WHERE site_id = {site} AND period_key = '{SEP_KEY}';"
            )
            assert snapshot == "10100.00|6750.00|3350.00|1", snapshot

            # A second accrual of the closed period changes nothing.
            status, body = raw_call(
                api, "POST", "/api/v1/dues/accrue-period", manager.token,
                {"site_id": str(site), "period": SEP, "due_date": SEP_DUE},
            )
            assert status == 409, (status, body)
            assert stack.sql(
                "SELECT accrued::text || '|' || collected::text || '|' || outstanding::text "
                f"FROM dues_period_snapshots WHERE site_id = {site} AND period_key = '{SEP_KEY}';"
            ) == "10100.00|6750.00|3350.00"

            # The unpaid September debt is still on record and shown to the manager.
            september = [item for item in open_items(api, manager, a3, "OWNER") if item["period"] == SEP]
            assert len(september) == 1, september
            assert money(september[0]["principal_outstanding"]) == D("1500.00")
            assert money(september[0]["penalty_outstanding"]) == D("175.00")
            _open_statement(page, a3)
            _wait_for_id_text(page, "statement_debtor_owner", SEP)
            assert amount_of(page, "statement_total_owner") == D("1675.00")
            _leave_statement(page)
            ledger_invariants(api, manager, fixture.site_id, stage="checkpoint 6")

        with journey.step("checkpoint 7: tenant replacement and title transfer on 1 December"):
            api.clock.set_instant("2026-12-01T06:00:00Z")  # 09:00 in Istanbul

            # The debts each outgoing debtor carries into the transition, with the late fee as of
            # the transfer day; the transition must hand them to nobody else.
            selin_before = next(
                d for d in api.resident_statement(manager, a2)["debtors"]
                if d["debtor_type"] == "TENANT" and d["name"].split()[0] == "Selin"
            )
            ahmet_before = next(
                d for d in api.resident_statement(manager, a4)["debtors"]
                if d["debtor_type"] == "OWNER" and d["name"].split()[0] == "Ahmet"
            )

            # A-2: Selin Demir leaves and Mert Kılıç moves in on the same day. The move-in form
            # carries no effective date, so the replacement is dated explicitly through the API.
            api.move_in(
                manager, a2, "Mert Kılıç", "mert.kilic@a13.e2e.test",
                phone="05321110009", effective_date="2026-12-01")
            _fresh_manager_session(page, login_page, fixture)
            Shell(page).nav("residents")
            by_id(page, "add_resident_btn").wait_for(timeout=15_000)
            page.wait_for_load_state("networkidle")

            # A-4: Ahmet Yılmaz transfers title to Gül Tanrıverdi on the same effective date.
            Shell(page).verify_sensitive(fixture.manager_password)  # the transfer asks for step-up
            UnitWorkspace(page).open(a4).action(a4, "transfer_ownership")
            by_id(page, "module_confirm_transfer_ownership_btn").wait_for(timeout=15_000)
            PersonPicker(page, "module_transfer_new_owner_name_input").create(
                "Gül Tanrıverdi", phone="05321110010", email="gul.tanriverdi@a13.e2e.test")
            by_id(page, "module_confirm_transfer_ownership_btn").click()
            by_id(page, "module_confirm_transfer_ownership_btn").wait_for(state="detached", timeout=30_000)
            UnitWorkspace(page).close()

            # The pre-December debts stay with the people who owed them.
            selin = next(
                d for d in api.resident_statement(manager, a2)["debtors"]
                if d["debtor_type"] == "TENANT" and d["name"].split()[0] == "Selin"
            )
            assert selin["is_former"] is True, selin
            assert money(selin["total_outstanding"]) == money(selin_before["total_outstanding"]), selin
            ahmet = next(
                d for d in api.resident_statement(manager, a4)["debtors"]
                if d["debtor_type"] == "OWNER" and d["name"].split()[0] == "Ahmet"
            )
            assert ahmet["is_former"] is True, ahmet
            assert money(ahmet["total_outstanding"]) == money(ahmet_before["total_outstanding"]), ahmet
            # Neither newcomer inherits a balance or an advance.
            for unit_id, role in ((a2, "TENANT"), (a4, "OWNER")):
                newcomer = current_section(api.resident_statement(manager, unit_id), role)
                assert newcomer["name"].split()[0] in ("Mert", "Gül"), newcomer
                assert money(newcomer["total_outstanding"]) == D("0.00"), newcomer
                assert money(newcomer["advance_balance"]) == D("0.00"), newcomer

            # The closed September snapshot is unchanged.
            assert stack.sql(
                "SELECT accrued::text || '|' || collected::text || '|' || outstanding::text || '|' || snapshot_version "
                f"FROM dues_period_snapshots WHERE site_id = {site} AND period_key = '{SEP_KEY}';"
            ) == "10100.00|6750.00|3350.00|1"
            ledger_invariants(api, manager, fixture.site_id, stage="checkpoint 7")

            # The screens show both debtor sections: the current holder and the former one.
            _open_statement(page, a2)
            by_id(page, "statement_total_tenant_1").wait_for(timeout=15_000)
            assert amount_of(page, "statement_total_tenant") == D("0.00")
            assert amount_of(page, "statement_total_tenant_1") == money(selin_before["total_outstanding"])
            assert "Selin" in id_text(page, "statement_debtor_tenant_1")
            assert "Önceki kiracı" in id_text(page, "statement_debtor_tenant_1")
            _leave_statement(page)
            _open_statement(page, a4)
            by_id(page, "statement_total_owner_1").wait_for(timeout=15_000)
            assert amount_of(page, "statement_total_owner") == D("0.00")
            assert amount_of(page, "statement_total_owner_1") == money(ahmet_before["total_outstanding"])
            assert "Ahmet" in id_text(page, "statement_debtor_owner_1")
            assert "Önceki malik" in id_text(page, "statement_debtor_owner_1")
            _leave_statement(page)

        with journey.step("checkpoint 8: restart, same balances, scoped sessions"):
            before = api.site_overview(manager, site)
            scope_before = {
                unit_id: api.resident_statement(manager, unit_id)["debtors"]
                for unit_id in (a1, a2, a3, a4, a5, a6)
            }

            # Manual registrations hand off activation links; give the two current owners the
            # same test password so they can open their own sessions after the restart.
            password_hash = stack.sql(
                f"SELECT password_hash FROM users WHERE lower(email) = lower('{fixture.manager_email}');"
            )
            assert password_hash.startswith("$argon2"), password_hash
            stack.sql(
                "UPDATE users SET password_hash = '" + password_hash + "', must_change_password = FALSE "
                f"WHERE site_id = {site} AND person_id IN (SELECT id FROM persons WHERE site_id = {site} "
                "AND full_name IN ('Ayşe Kaya', 'Elif Aydın'));"
            )

            stack.restart_backend()
            manager = api.login(fixture.manager_email, fixture.manager_password)

            after = api.site_overview(manager, site)
            assert after["summary"] == before["summary"]
            financial = lambda flats: [
                (f["id"], f["amount_due"], f["advance_balance"], f["is_paid"], f["days_overdue"])
                for f in flats
            ]
            assert financial(after["flats"]) == financial(before["flats"])
            for unit_id, debtors in scope_before.items():
                assert api.resident_statement(manager, unit_id)["debtors"] == debtors, unit_id
            assert stack.sql(
                "SELECT accrued::text || '|' || collected::text || '|' || outstanding::text || '|' || snapshot_version "
                f"FROM dues_period_snapshots WHERE site_id = {site} AND period_key = '{SEP_KEY}';"
            ) == "10100.00|6750.00|3350.00|1"
            ledger_invariants(api, manager, fixture.site_id, stage="checkpoint 8")

            # The manager's screens still show the same balances and the closed period.
            _fresh_manager_session(page, login_page, fixture)
            remaining = amount_of(page, "cockpit_remaining_debt")
            assert remaining == money(after["summary"]["total_overdue_with_interest"]), remaining
            open_dues_segment(page, 0)
            assert text_of(by_id(page, f"period_status_{sep_id}")) == "KAPALI"

            # Each resident session sees only its own unit.
            resident_page = page.context.new_page()
            try:
                LoginPage(resident_page, login_page.base_url).open().login(
                    "homeowner", resident_email(stack, fixture, "Ayşe Kaya"), fixture.manager_password)
                assert ResidentHome(resident_page).wait().balance() == D("0.00")
                elif_session = api.login(resident_email(stack, fixture, "Elif Aydın"), fixture.manager_password)
                elif_owner = current_section(
                    api.call(
                        "GET", f"/api/v1/residents/{a6}/statement", elif_session.token,
                    ),
                    "OWNER",
                )
                assert money(elif_owner["advance_balance"]) == D("1250.00"), elif_owner
                status, _ = raw_call(
                    api, "GET", f"/api/v1/residents/{a1}/statement", elif_session.token)
                assert status in (403, 404), status
            finally:
                resident_page.close()

            # Another manager's site sees none of this site's data.
            saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
            email = f"other.manager.{site}@sitepulse.test"
            credentials = api.create_site(saas, f"Other Site {site}", email, blocks=())
            api.change_password(email, credentials["temporary_password"], "Other-Manager-Permanent-1!")
            other = api.login(email, "Other-Manager-Permanent-1!")
            for path in (
                f"/api/v1/site-admin/overview?site_id={site}",
                f"/api/v1/residents/{a1}/statement",
                f"/api/v1/dues/periods/{sep_id}/summary",
            ):
                status, _ = raw_call(api, "GET", path, other.token)
                assert status in (403, 404), (path, status)

            other_page = page.context.new_page()
            try:
                LoginPage(other_page, login_page.base_url).open().login(
                    "manager", email, "Other-Manager-Permanent-1!")
                by_id(other_page, "cockpit_total_units").wait_for(timeout=20_000)
                assert id_text(other_page, "cockpit_total_units").endswith("0"), (
                    "another manager's cockpit must show none of this site's units"
                )
                ResidentsTab(other_page).open()
                assert ResidentsTab(other_page).unit_card_ids() == []
            finally:
                other_page.close()
