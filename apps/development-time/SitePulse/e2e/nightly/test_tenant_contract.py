"""Run a fixed authorization contract against two synthetic SitePulse sites."""
from __future__ import annotations

from decimal import Decimal
from urllib.parse import urlencode

import pytest

from support.api import raw_call

# Static, reviewed cases with a known resource type and a positive same-site
# control. Validate each route against the server's generated OpenAPI contract.
READ_CASES = (
    ("/api/v1/residents/{unit_id}/statement", "unit_id", "unit", False),
    ("/api/v1/site-admin/units/{id}/occupancy-state", "id", "unit", True),
    ("/api/v1/site-admin/persons/{person_id}/card", "person_id", "person", True),
    ("/api/v1/dues/periods/{period_id}/summary", "period_id", "period", False),
    ("/api/v1/payments/receipts/{id}", "id", "receipt", False),
    ("/api/v1/operating-budgets/{id}", "id", "budget", False),
)


@pytest.fixture
def two_sites(api, actors):
    platform = api.login(**actors["saas"])
    manager = api.login(**actors["manager"])

    email = "nightly-second-manager@example.test"
    site = api.create_site(platform, "Nightly authorization site", email, blocks=("A",))
    password = "Nightly-Manager-2026!"
    api.change_password(email, site["temporary_password"], password)
    second = api.login(email, password)
    api.create_units(second, "A", unit_number=1)
    api.register_home_owner(second, "A", 1, "Nightly Owner", "second-owner@example.test")
    unit = api.get_units(second)[0]["id"]
    receipt = api.record_manual_payment(second, unit, Decimal("25.00"), "Nightly Owner")
    period = api.create_period(second, "Ekim 2026", "2026-10-15")
    budget = api.call(
        "POST", "/api/v1/operating-budgets", second.token,
        body={"fiscal_year": 2026, "lines": [
            {"category": "CLEANING", "annual_amount": "10000.00", "allocation_key": "EQUAL"}
        ]},
    )
    people = api.call("GET", f"/api/v1/site-admin/persons?site_id={site['site_id']}", second.token)
    person = next(item["person_id"] for item in people["items"] if item["full_name"] == "Nightly Owner")
    return manager, second, {
        "unit": unit,
        "person": person,
        "period": period["id"],
        "receipt": receipt["id"],
        "budget": budget["id"],
    }


def test_tenant_resources_require_membership(api, two_sites, record_property):
    first, second, ids = two_sites
    paths = api.call("GET", "/api/v1/openapi.json")["paths"]
    denies = []
    for template, parameter, resource, include_site in READ_CASES:
        assert "get" in paths[template], f"Update the authorization contract for {template}"
        path = template.format(**{parameter: ids[resource]})
        owner_path = path + ("?" + urlencode({"site_id": second.user["site_id"]}) if include_site else "")
        assert raw_call(api, "GET", owner_path, second.token)[0] == 200, f"Control failed for {template}"

        assert raw_call(api, "GET", owner_path, first.token)[0] in {403, 404}, template
        denies.append(template)
        if include_site:
            caller_path = path + "?" + urlencode({"site_id": first.user["site_id"]})
            assert raw_call(api, "GET", caller_path, first.token)[0] in {403, 404}, template
    record_property("authorization_contract", ", ".join(denies))
