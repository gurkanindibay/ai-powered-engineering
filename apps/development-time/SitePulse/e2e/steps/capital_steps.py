"""Steps for EPIC-10 (capital expenditure and fixture dues), .specify/features/EPIC-10."""
from __future__ import annotations

import time
import uuid
from decimal import ROUND_HALF_UP, Decimal

from pytest_bdd import given, parsers, then, when

from pages import CapitalProjects, DuesManagement, ManagerCockpit, ResidentHome
from support.flutter import by_id, fill, text_of
from support.money import last_amount

MONEY = {"Money": Decimal}
VIRTUAL_IBANS = {"A14": "TR620020500009863791600001"}  # seed: A Blok D:14
CONTRACTOR_IBAN = "TR330006100519786457841326"
CENT = Decimal("0.01")
ACTIVE_UNITS = "FROM units WHERE site_id = 1 AND deleted_at IS NULL"


def _parse(text: str):
    return parsers.parse(text, extra_types=MONEY)


def _shown_shares(capital: CapitalProjects) -> dict[str, Decimal]:
    """{'<unit number>': share} from 'Arsa Payı: 24/1000 • Toplam Pay: ₺285.714,29' rows."""
    texts = capital.show_unit_shares().unit_share_texts()
    return {key.rsplit("_", 1)[1]: last_amount(text) for key, text in texts.items()}


def _metric(page, metric_id: str) -> Decimal:
    """Capital tile value, e.g. 'Tahsil Edilen₺4.000,00' -> Decimal('4000.00')."""
    return last_amount(text_of(by_id(page, f"capital_metric_{metric_id}")))


# ---------------------------------------------------------------- arrange (API)

@given(_parse('capital project "{title}" with budget {budget:Money} has installment {number:d} accrued'))
def accrued_project(api, actors, title: str, budget: Decimal, number: int) -> None:
    manager = api.login(**actors["manager"])
    project = api.create_capital_project(manager, title, budget)
    api.accrue_installment(manager, str(project.get("id") or project.get("project_id")), number)


@given(_parse('the owner of unit {unit} has paid {amount:Money} by FAST with description "{description}"'))
def owner_fast_payment(api, unit: str, amount: Decimal, description: str) -> None:
    api.webhook_transfer(VIRTUAL_IBANS[unit], amount, f"E2E-FAST-{uuid.uuid4().hex[:10]}", description)


# ---------------------------------------------------------------- manager: projects

@given("the site manager opens the capital projects segment", target_fixture="capital")
@when("the site manager opens the capital projects segment", target_fixture="capital")
def open_capital_segment(login_as, page) -> CapitalProjects:
    login_as("manager")
    ManagerCockpit(page).wait()
    return CapitalProjects(page).open()


@given(_parse('the manager creates capital project "{title}" with budget {budget:Money} '
              'allocated {basis} in {installments:d} installments'))
@when(_parse('the manager creates capital project "{title}" with budget {budget:Money} '
             'allocated {basis} in {installments:d} installments'))
def create_project(capital: CapitalProjects, title: str, budget: Decimal, basis: str, installments: int) -> None:
    assert basis in ("by land share", "equally"), basis
    capital.create(title, str(budget), by_land_share=basis == "by land share", installments=installments)


@then(_parse('the project is stored as "{status}" with budget {budget:Money} and allocation "{basis}"'))
def project_stored(stack, status: str, budget: Decimal, basis: str) -> None:
    row = stack.sql("SELECT status || '|' || total_budget || '|' || allocation_basis FROM capital_projects;")
    assert row == f"{status}|{budget}|{basis}", row


@then(_parse("the unit shares shown add up to exactly {budget:Money}"))
def shares_sum_to_budget(capital: CapitalProjects, budget: Decimal) -> None:
    assert sum(_shown_shares(capital).values()) == budget  # exact: no kuruş lost or invented


@then(_parse('unit "{unit}" is shown its land share proportion of {budget:Money}'))
def unit_share_is_proportional(capital: CapitalProjects, stack, unit: str, budget: Decimal) -> None:
    rows = stack.sql(f"SELECT unit_number, land_share {ACTIVE_UNITS};").splitlines()
    land = {number: int(share) for number, share in (row.split("|") for row in rows)}
    expected = (budget * land[unit] / sum(land.values())).quantize(CENT, rounding=ROUND_HALF_UP)
    assert _shown_shares(capital)[unit] == expected


@then(_parse("every unit is shown an equal share of {budget:Money}"))
def shares_are_equal(capital: CapitalProjects, stack, budget: Decimal) -> None:
    units = int(stack.sql(f"SELECT count(*) {ACTIVE_UNITS};"))
    assert list(_shown_shares(capital).values()) == [(budget / units).quantize(CENT)] * units


# ---------------------------------------------------------------- manager: installments

@when(parsers.parse("the manager accrues installment {number:d}"))
def accrue_installment(capital: CapitalProjects, number: int) -> None:
    capital.accrue_installment(number)


@then(parsers.parse("installment {number:d} is shown as accrued"))
def installment_shown_accrued(capital: CapitalProjects, number: int) -> None:
    capital.installment_accrued(number).wait_for(timeout=15_000)


def _capital_liability_groups(stack) -> dict[str, tuple[str, str]]:
    rows = stack.sql("SELECT debtor_type || '/' || expense_type, count(*), sum(principal_amount) "
                     "FROM dues_liabilities WHERE capital_project_id IS NOT NULL GROUP BY 1;").splitlines()
    return {key: (count, total) for key, count, total in (row.split("|") for row in rows)}


@then(_parse('one "{expense_type}" liability per unit is charged to "{debtor}" totalling {total:Money}'))
def liabilities_per_unit(stack, expense_type: str, debtor: str, total: Decimal) -> None:
    units = stack.sql(f"SELECT count(*) {ACTIVE_UNITS};")
    assert _capital_liability_groups(stack).get(f"{debtor}/{expense_type}") == (units, str(total))


@then("no capital liability is charged to any other debtor")
def only_one_debtor_group(stack) -> None:
    groups = _capital_liability_groups(stack)
    assert len(groups) == 1, groups


@then(parsers.parse("installment {number:d} is stored as accrued"))
def installment_stored_accrued(stack, number: int) -> None:
    assert stack.sql("SELECT is_accrued FROM capital_project_installments "
                     f"WHERE installment_number = {number};") == "t"


# ---------------------------------------------------------------- manager: treasury

@then(_parse('the "{metric}" capital metric shows {amount:Money}'))
def capital_metric_shows(page, metric: str, amount: Decimal) -> None:
    by_id(page, f"capital_metric_{metric}").wait_for(timeout=10_000)
    deadline = time.monotonic() + 10
    while _metric(page, metric) != amount and time.monotonic() < deadline:
        page.wait_for_timeout(250)  # the tile refreshes after the list reloads
    assert _metric(page, metric) == amount


@then(_parse("capital dues paid in the ledger total {amount:Money}"))
def capital_dues_paid(stack, amount: Decimal) -> None:
    paid = stack.sql("SELECT sum(paid_amount) FROM dues_liabilities WHERE expense_type = 'CAPITAL_DUES';")
    assert paid == str(amount)


@when(_parse('the manager records disbursement "{milestone}" of {amount:Money} to "{recipient}"'))
def record_disbursement(page, milestone: str, amount: Decimal, recipient: str) -> None:
    by_id(page, "subtab_button_2").click()
    by_id(page, "btn_record_disbursement").click()
    by_id(page, "input_disbursement_amount").wait_for(timeout=10_000)
    fill(page, "input_disbursement_milestone", milestone)
    fill(page, "input_disbursement_amount", str(amount))
    fill(page, "input_disbursement_recipient", recipient)
    fill(page, "input_disbursement_iban", CONTRACTOR_IBAN)
    by_id(page, "btn_submit_disbursement").click()


@then("the disbursement dialog closes")
def disbursement_dialog_closes(page) -> None:
    by_id(page, "btn_submit_disbursement").wait_for(state="detached", timeout=10_000)


@then(_parse("a single contractor disbursement of {amount:Money} is stored"))
def one_disbursement_stored(stack, amount: Decimal) -> None:
    assert stack.sql("SELECT amount FROM capital_contractor_disbursements;") == str(amount)


@then("no contractor disbursement is stored")
def no_disbursement_stored(page, stack) -> None:
    page.wait_for_timeout(2_000)  # give a wrongly accepted request time to land
    assert stack.sql("SELECT count(*) FROM capital_contractor_disbursements;") == "0"


@when("the site manager opens the virman dialog in dues management")
def open_virman_dialog(login_as, page) -> None:
    login_as("manager")
    ManagerCockpit(page).wait()
    DuesManagement(page).open()
    by_id(page, "btn_dues_more_actions").click()
    by_id(page, "menu_item_virman").click()


@then(parsers.parse('the virman unit list shows an advance of "{formatted}"'))
def virman_shows_advance(page, formatted: str) -> None:
    dropdown = by_id(page, "virman_unit_dropdown")
    dropdown.wait_for(timeout=10_000)
    assert formatted in text_of(dropdown)


# ---------------------------------------------------------------- resident

@when("the home owner opens the resident dashboard", target_fixture="resident_home")
def owner_opens_dashboard(login_as, page) -> ResidentHome:
    login_as("homeowner")
    return ResidentHome(page).wait()


@then(_parse("the dashboard balance is above {amount:Money}"))
def dashboard_balance_above(resident_home: ResidentHome, amount: Decimal) -> None:
    assert resident_home.balance() > amount


@then("the capital balance card is shown")
def capital_card_shown(page) -> None:
    assert by_id(page, "hero_capital_balance").count() == 1


@when("the home owner signs in")
def owner_signs_in(login_as, page) -> None:
    login_as("homeowner")
    page.wait_for_timeout(2_000)


@then("the owner responsibility capital badge is shown")
def owner_badge_shown(page) -> None:
    assert by_id(page, "capital_owner_badge").count() == 1
