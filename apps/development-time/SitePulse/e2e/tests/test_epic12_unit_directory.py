"""EPIC-12 compact unit directory scenarios."""
import pytest

from pages import ManagerCockpit
from support.flutter import by_id, fill


def _unit_id(stack, block: str, number: int) -> str:
    return stack.sql("SELECT u.id FROM units u JOIN blocks b ON b.id = u.block_id "
                     f"WHERE b.block_name = '{block}' AND u.unit_number = {number};")


@pytest.mark.edge
@pytest.mark.role_manager
@pytest.mark.covers("SC-12-02-03")
@pytest.mark.covers("SC-12-02-05")
@pytest.mark.covers("SC-12-02-06")
@pytest.mark.covers("SC-12-02-07")
@pytest.mark.gui_id("GUI-08-07")
def test_residents_module_search_by_name_and_unit(login_as, page, stack):
    login_as("manager")
    ManagerCockpit(page).wait()
    by_id(page, "btn_cockpit_manage_residents").click()
    by_id(page, "open_owners_residents_module").click()
    by_id(page, "module_search_input").wait_for(timeout=10_000)

    selector = '[flt-semantics-identifier^="module_unit_actions_"]'
    only = (
        "id => { const ids = new Set([...document.querySelectorAll('[flt-semantics-identifier^=\"module_unit_actions_\"]')]"
        ".map(e => e.getAttribute('flt-semantics-identifier'))); return ids.size === 1 && ids.has(id); }"
    )

    def shows_only(unit_id: str) -> None:
        action_id = f"module_unit_actions_{unit_id}"
        try:
            page.wait_for_function(only, arg=action_id, timeout=10_000)
        except Exception:
            ids = sorted(set(page.eval_on_selector_all(
                selector, "els => els.map(e => e.getAttribute('flt-semantics-identifier'))")))
            pytest.fail(f"expected only {action_id}, unit actions shown: {ids}; units: "
                        f"{stack.sql('SELECT id, unit_number FROM units ORDER BY id;')!r}")

    b3 = _unit_id(stack, "B Blok", 3)
    fill(page, "module_search_input", "Mehmet Öz")
    shows_only(b3)

    fill(page, "module_search_input", "14")
    a14 = _unit_id(stack, "A Blok", 14)
    shows_only(a14)

    phone = stack.sql(
        "SELECT regexp_replace(phone, '[^0-9]', '', 'g') FROM persons "
        f"WHERE id = (SELECT COALESCE(tenant_person_id, owner_person_id) FROM units WHERE id = {int(b3)});"
    )
    assert phone
    fill(page, "module_search_input", phone[-6:])
    shows_only(b3)

    fill(page, "module_search_input", "14")
    shows_only(a14)

    action_id = f"module_unit_actions_{a14}"
    details_id = f"module_unit_details_{a14}"
    assert by_id(page, action_id).count() == 1
    assert by_id(page, details_id).count() == 1

    for width in (320, 390, 768, 1024, 1440):
        page.set_viewport_size({"width": width, "height": 900})
        page.wait_for_timeout(250)
        action = by_id(page, action_id)
        details = by_id(page, details_id)
        action.wait_for(state="attached", timeout=3_000)
        details.wait_for(state="attached", timeout=3_000)
        action_box = action.bounding_box()
        details_box = details.bounding_box()
        assert action_box and details_box, f"unit targets are missing at {width}px"
        assert action_box["x"] >= 0 and action_box["x"] + action_box["width"] <= width
        assert details_box["x"] >= 0 and details_box["x"] + details_box["width"] <= width
