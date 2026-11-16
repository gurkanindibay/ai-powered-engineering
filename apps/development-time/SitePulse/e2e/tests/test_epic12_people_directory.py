"""EPIC-12 people directory paging and filter acceptance coverage."""
from __future__ import annotations

import json
from urllib.parse import parse_qs, urlsplit

import pytest

from pages import ManagerCockpit
from support.flutter import by_id


def _person(person_id: int, login: str = "ACTIVE") -> dict:
    return {
        "person_id": person_id,
        "full_name": f"Synthetic Person {person_id}",
        "email": f"person{person_id}@e2e.test",
        "phone": f"0532000{person_id:04d}",
        "role": "HOME_OWNER",
        "owned_units": 1,
        "occupied_units": 0,
        "login": login,
    }


@pytest.mark.role_manager
@pytest.mark.gui_id("GUI-12-01")
@pytest.mark.covers("SC-12-04-01")
@pytest.mark.covers("SC-12-04-02")
def test_people_directory_pages_and_filters_server_results(login_as, page):
    login_as("manager")
    ManagerCockpit(page).wait()

    calls: list[dict[str, list[str]]] = []

    def directory(route) -> None:
        request = route.request
        parsed = urlsplit(request.url)
        if parsed.path != "/api/v1/site-admin/persons":
            route.continue_()
            return

        query = parse_qs(parsed.query)
        calls.append(query)
        current_page = int(query.get("page", ["1"])[0])
        login = query.get("login", [""])[0]
        if login == "PENDING":
            ids = [2, 4, 6]
            items = [_person(person_id, "PENDING") for person_id in ids]
            total = len(items)
        else:
            first = (current_page - 1) * 25 + 1
            last = min(first + 24, 30)
            items = [_person(person_id) for person_id in range(first, last + 1)]
            total = 30

        route.fulfill(json={
            "items": items,
            "total": total,
            "page": current_page,
            "page_size": int(query.get("page_size", ["25"])[0]),
        })

    page.route("**/api/v1/site-admin/persons*", directory)
    by_id(page, "btn_cockpit_manage_residents").click()
    by_id(page, "open_owners_residents_module").click()
    by_id(page, "module_people_directory_btn").click()

    by_id(page, "people_row_1").wait_for(timeout=10_000)
    with page.expect_response(lambda response: "page=2" in response.url):
        by_id(page, "directory_next_page_btn").click()
    by_id(page, "people_row_26").wait_for(timeout=10_000)

    with page.expect_response(lambda response: "login=PENDING" in response.url):
        by_id(page, "people_filter_pending").click()
    by_id(page, "people_row_2").wait_for(timeout=10_000)

    assert any(call.get("page") == ["2"] for call in calls)
    pending_call = next(call for call in reversed(calls) if call.get("login") == ["PENDING"])
    assert pending_call["page"] == ["1"]
    assert pending_call["page_size"] == ["25"]
    assert by_id(page, "people_row_26").count() == 0
