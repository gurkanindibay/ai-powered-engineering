"""EPIC-10 Capital expenditure & fixture dues."""
from decimal import ROUND_HALF_UP, Decimal

import pytest

from pages import CapitalProjects, ManagerCockpit

BUDGET = Decimal("500000.00")


def _share_from(text: str) -> Decimal:
    # "Arsa Payı: 24/1000 • Toplam Pay: ₺285714.29" (printed with Decimal.toString, not the Turkish format)
    return Decimal(text.rsplit("₺", 1)[1].strip())


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
