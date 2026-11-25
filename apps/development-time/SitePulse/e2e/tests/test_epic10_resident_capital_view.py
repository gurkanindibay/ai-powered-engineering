"""Resident-facing capital project details and statutory guidance (STORY-10-06)."""

import pytest

from pages import ResidentHome
from support.flutter import by_id, text_of


def _capital_project(api, manager, title: str) -> dict:
    return api.call(
        "POST",
        "/api/v1/capital-projects",
        manager.token,
        body={
            "site_id": manager.user["site_id"],
            "title": title,
            "category": "OTHER",
            "description": "A Blok çatı yalıtım yenilemesi",
            "total_budget": "42000.00",
            "allocation_basis": "BY_LAND_SHARE",
            "contract_amount": "42000.00",
            "contractor_name": "Atlas Çatı Sistemleri",
            "installments": [
                {
                    "installment_number": 1,
                    "total_installments": 2,
                    "due_date": "2026-11-30",
                    "installment_budget": "21000.00",
                },
                {
                    "installment_number": 2,
                    "total_installments": 2,
                    "due_date": "2026-12-30",
                    "installment_budget": "21000.00",
                },
            ],
        },
    )


@pytest.mark.core
@pytest.mark.role_homeowner
@pytest.mark.gui_id("GUI-10-12")
@pytest.mark.covers("SC-10-06-03")
def test_owner_opens_capital_project_details(login_as, page, api, actors, stack):
    manager = api.login(**actors["manager"])
    project = _capital_project(api, manager, "A Blok Çatı Yalıtımı")
    project_id = str(project.get("id") or project.get("project_id"))
    api.accrue_installment(manager, project_id, 1)

    login_as("homeowner")
    ResidentHome(page).wait()
    by_id(page, f"capital_project_detail_{project_id}").click()

    breakdown = by_id(page, "resident_capital_project_breakdown")
    breakdown.wait_for(timeout=15_000)
    assert "Proje Detayları" in text_of(breakdown)
    assert "Atlas Çatı Sistemleri" in text_of(by_id(page, "resident_capital_project_contractor"))
    schedule = text_of(by_id(page, "resident_capital_project_installments"))
    assert "1. Taksit" in schedule and "2. Taksit" in schedule
    assert "2026-11-30" in schedule and "2026-12-30" in schedule
    assert "21.000" in schedule


@pytest.mark.core
@pytest.mark.role_resident
@pytest.mark.gui_id("GUI-10-13")
@pytest.mark.covers("SC-10-06-04")
def test_tenant_sees_capital_project_responsibility_guidance(
    login_as, page, api, actors, stack
):
    manager = api.login(**actors["manager"])
    b3 = stack.sql(
        "SELECT u.id FROM units u JOIN blocks b ON b.id = u.block_id "
        "WHERE b.block_name = 'B Blok' AND u.unit_number = 3;"
    )
    api.move_in(manager, b3, "Canan Can", "canan.can@e2e.test")
    project = _capital_project(api, manager, "B Blok Asansör Yenilemesi")
    api.accrue_installment(manager, str(project.get("id") or project.get("project_id")), 1)

    original_identity = stack.sql(
        "SELECT COALESCE(person_id::text, '') || '|' || role FROM users "
        "WHERE lower(email) = lower('ahmet.yilmaz@begonya.com');"
    )
    original_person, original_role = original_identity.split("|", 1)
    tenant_person = stack.sql(
        "SELECT id FROM persons WHERE lower(email) = lower('canan.can@e2e.test');"
    )
    stack.sql(
        "UPDATE users SET person_id = "
        f"{int(tenant_person)}, role = 'HOME_RESIDENT' "
        "WHERE lower(email) = lower('ahmet.yilmaz@begonya.com');"
    )
    try:
        stack.restart_backend()
        login_as("homeowner")
        ResidentHome(page).wait()
        project_row = by_id(page, f"tenant_capital_project_{project.get('id') or project.get('project_id')}")
        project_row.wait_for(timeout=15_000)
        assert "B Blok Asansör Yenilemesi" in text_of(project_row)
        assert "Kat Maliki Sorumluluğunda" in text_of(project_row)
        guidance = by_id(page, "tenant_capital_guidance")
        guidance.wait_for(timeout=10_000)
        assert (
            "Demirbaş giderleri yasal olarak ev sahibinize aittir. "
            "Ödemeniz halinde kiradan düşebilirsiniz."
        ) in text_of(guidance)
    finally:
        person_sql = "NULL" if not original_person else str(int(original_person))
        stack.sql(
            f"UPDATE users SET person_id = {person_sql}, role = '{original_role}' "
            "WHERE lower(email) = lower('ahmet.yilmaz@begonya.com');"
        )
        stack.restart_backend()

