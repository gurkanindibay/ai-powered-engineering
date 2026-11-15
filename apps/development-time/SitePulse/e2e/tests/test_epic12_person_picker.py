"""EPIC-12 person picker against the live backend.

The people-directory tests stub `/persons` with `page.route`, so they never exercise the server's
query parsing. This test sends the picker's real search request (with `page` and `limit`) to the
running backend, and picks an existing person instead of typing personal data.
"""
from __future__ import annotations

from urllib.parse import parse_qs, urlsplit

import pytest

from pages import ManagerCockpit
from pages.shell import Shell
from support.flutter import by_id, fill

SEARCH_PATH = "/api/v1/site-admin/persons/search"


def _unit_id(stack, block: str, number: int) -> int:
    return int(stack.sql("SELECT u.id FROM units u JOIN blocks b ON b.id = u.block_id "
                         f"WHERE b.block_name = '{block}' AND u.unit_number = {number};"))


@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-12-03")
@pytest.mark.covers("SC-12-03-04")
def test_picker_chooses_an_existing_person_through_the_live_search_api(login_as, page, stack, actors):
    a14 = _unit_id(stack, "A Blok", 14)
    old_owner = int(stack.sql(f"SELECT owner_person_id FROM units WHERE id = {a14};"))
    # An existing card in the same site that has no relationship with A Blok D:14.
    row = stack.sql(
        "SELECT p.id || '|' || p.full_name FROM units u "
        "JOIN blocks b ON b.id = u.block_id JOIN persons p ON p.id = u.owner_person_id "
        f"WHERE u.id <> {a14} AND u.owner_person_id <> {old_owner} "
        f"AND b.site_id = (SELECT b2.site_id FROM units u2 JOIN blocks b2 ON b2.id = u2.block_id "
        f"WHERE u2.id = {a14}) ORDER BY p.id LIMIT 1;"
    )
    existing_id, existing_name = int(row.split("|", 1)[0]), row.split("|", 1)[1]
    persons_before = stack.sql("SELECT count(*) FROM persons;")

    searches: list[tuple[int, dict[str, list[str]], str]] = []

    def record(response) -> None:
        parsed = urlsplit(response.url)
        if parsed.path == SEARCH_PATH:
            body = "" if response.ok else response.text()
            searches.append((response.status, parse_qs(parsed.query), body))

    page.on("response", record)

    login_as("manager")
    ManagerCockpit(page).wait()
    Shell(page).verify_sensitive(actors["manager"]["password"])
    by_id(page, "btn_cockpit_manage_residents").click()
    by_id(page, "open_owners_residents_module").click()
    by_id(page, "module_search_input").wait_for(timeout=10_000)
    fill(page, "module_search_input", "14")
    by_id(page, f"module_unit_actions_{a14}").click()
    transfer = by_id(page, f"workspace_action_transfer_ownership_{a14}")
    page.mouse.move(640, 500)
    for _ in range(10):  # the action list builds rows lazily; scroll until the action exists
        if transfer.count() > 0:
            break
        page.mouse.wheel(0, 400)
        page.wait_for_timeout(250)
    transfer.click()

    by_id(page, "module_transfer_new_owner_name_input").click()
    by_id(page, "sp_person_search").wait_for(timeout=10_000)
    with page.expect_response(
        lambda r: urlsplit(r.url).path == SEARCH_PATH and "q=" in r.url, timeout=15_000,
    ):
        fill(page, "sp_person_search", existing_name)
    result = by_id(page, f"sp_person_result_{existing_id}")
    result.wait_for(timeout=10_000)
    result.click()
    by_id(page, "module_transfer_new_owner_name_input_card").wait_for(timeout=10_000)

    by_id(page, "module_confirm_transfer_ownership_btn").click()
    by_id(page, "module_confirm_transfer_ownership_btn").wait_for(state="detached", timeout=15_000)

    assert searches, "the picker never called the live search endpoint"
    failed = [(status, body) for status, _, body in searches if status != 200]
    assert not failed, f"search requests failed: {failed}"
    paged = [query for _, query, _ in searches if "page" in query and "limit" in query]
    assert paged, "the picker search sent no page/limit parameters"
    assert all(q["context"] == ["owner"] for q in paged)
    assert stack.sql(f"SELECT owner_person_id FROM units WHERE id = {a14};") == str(existing_id)
    assert stack.sql("SELECT count(*) FROM persons;") == persons_before  # no duplicate card
