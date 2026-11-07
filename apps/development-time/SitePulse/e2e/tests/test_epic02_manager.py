"""EPIC-02 Site manager operations & EPIC-10 capital segment entry point."""
import pytest

from pages import DuesManagement, ManagerCockpit, ResidentsTab
from support.flutter import by_id


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
