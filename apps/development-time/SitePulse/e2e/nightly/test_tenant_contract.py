"""Run a fixed authorization contract against two synthetic SitePulse sites."""
from __future__ import annotations

import json
from datetime import date, timedelta
from decimal import Decimal
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

import pytest

# Static, reviewed cases with a known resource type and a positive same-site
# control. Validate each route against the server's generated OpenAPI contract.
READ_CASES = (
    ("/api/v1/home-residents/invite-link/{unit_id}", "unit_id", "unit", False),
    ("/api/v1/home-residents/members/{unit_id}", "unit_id", "unit", False),
    ("/api/v1/residents/{unit_id}/autopay", "unit_id", "unit", False),
    ("/api/v1/residents/{unit_id}/dashboard", "unit_id", "unit", False),
    ("/api/v1/residents/{unit_id}/disputes", "unit_id", "unit", False),
    ("/api/v1/residents/{unit_id}/matching-criteria", "unit_id", "unit", False),
    ("/api/v1/residents/{unit_id}/operating-budget", "unit_id", "unit", False),
    ("/api/v1/residents/{unit_id}/payment-plans", "unit_id", "unit", False),
    ("/api/v1/residents/{unit_id}/statement", "unit_id", "unit", False),
    ("/api/v1/residents/{unit_id}/virman-requests", "unit_id", "unit", False),
    ("/api/v1/site-admin/units/{id}/occupancy-history", "id", "unit", True),
    ("/api/v1/site-admin/units/{id}/occupancy-state", "id", "unit", True),
    ("/api/v1/site-admin/units/{unit_id}/sale-clearance", "unit_id", "unit", False),
    ("/api/v1/site-admin/bank-account/{site_id}", "site_id", "site", False),
    ("/api/v1/units/{id}/virtual-iban", "id", "unit", False),
    ("/api/v1/site-admin/persons/{person_id}", "person_id", "person", True),
    ("/api/v1/site-admin/persons/{person_id}/card", "person_id", "person", True),
    ("/api/v1/dues/periods/{period_id}/summary", "period_id", "period", False),
    ("/api/v1/payments/receipts/{id}", "id", "receipt", False),
    ("/api/v1/payments/receipts/{id}/pdf", "id", "receipt", False),
    ("/api/v1/operating-budgets/{id}", "id", "budget", False),
    ("/api/v1/capital-projects/{id}", "id", "project", False),
    ("/api/v1/capital-projects/{id}/installments", "id", "project", False),
    ("/api/v1/capital-projects/{id}/disbursements", "id", "project", False),
    ("/api/v1/capital-projects/{id}/unit-shares", "id", "project", False),
)

# These routes select the site entirely through the query. Replacing it with
# the caller's site would select different resources and is an authorized read.
SITE_QUERY_READ_CASES = (
    "/api/v1/bank/statements/reconciliation-queue",
    "/api/v1/capital-projects",
    "/api/v1/dues/accrual-runs",
    "/api/v1/dues/periods",
    "/api/v1/operating-budgets",
    "/api/v1/operating-budgets/compliance",
    "/api/v1/payments/debt-aging",
    "/api/v1/payments/homeowner-records",
    "/api/v1/payments/stream",
    "/api/v1/registration/invite-link",
    "/api/v1/registration/pending",
    "/api/v1/site-admin/blocks",
    "/api/v1/site-admin/home-owners",
    "/api/v1/site-admin/house-types",
    "/api/v1/site-admin/overview",
    "/api/v1/site-admin/persons",
    "/api/v1/site-admin/persons/search",
    "/api/v1/site-admin/proration-policy",
    "/api/v1/site-admin/units",
)

PDF_ROUTE = "/api/v1/payments/receipts/{id}/pdf"
SECOND_SITE_MARKER = "Nightly second-site scope marker"
TEST_BANK_IBAN = "TR190020500009863791600001"

# A named arrangement gives a list or personal status a visible marker. The
# remaining reports carry the selected site ID in the response object.
IMPLICIT_READ_CASES = {
    "/api/v1/accounting/account-report": None,
    "/api/v1/accounting/approval-policy": "approval-policy",
    "/api/v1/accounting/budget-vs-actual": None,
    "/api/v1/accounting/expenses": "expense",
    "/api/v1/accounting/journal": "journal",
    "/api/v1/accounting/reserve-fund": None,
    "/api/v1/accounting/trial-balance": None,
    "/api/v1/accounting/vendors": "vendor",
    "/api/v1/accrual-corrections": "correction",
    "/api/v1/accrual-schedule": "schedule",
    "/api/v1/adjustments": "adjustment",
    "/api/v1/analytics/collections": None,
    "/api/v1/assembly/decisions": "decision",
    "/api/v1/assembly/meetings": "meeting",
    "/api/v1/audit/events": "audit",
    "/api/v1/audit/export": "audit",
    "/api/v1/bank-matching/daily-reconciliation": "reconciliation",
    "/api/v1/bank-matching/feeds": "feed",
    "/api/v1/collections/cases": "collection",
    "/api/v1/dunning/actions": "dunning",
    "/api/v1/dunning/policy": None,
    "/api/v1/heat-share/periods": "heat",
    "/api/v1/kvkk/access-log": "access-log",
    "/api/v1/kvkk/debtor-export": "debtor-export",
    "/api/v1/kvkk/me": "privacy",
    "/api/v1/kvkk/retention": None,
    "/api/v1/late-fees/reconciliation": None,
    "/api/v1/leases": "lease",
    "/api/v1/leases/joint-exposure": None,
    "/api/v1/notifications": "notification",
    "/api/v1/operating-budgets/legal-basis": None,
    "/api/v1/payment-plans": "payment-plan",
    "/api/v1/resident-requests/disputes": "dispute",
    "/api/v1/resident-requests/virman": "virman",
    "/api/v1/site-admin/advance-exit-settlements": "exit-settlement",
    "/api/v1/site-admin/seller-pays-overrides": "seller-override",
}
# The accounting chart is a shared constant in the handler, so it has no
# second-site data to distinguish. All tenant-specific rows accept managers.


def get_response(api, path: str, token: str, *, method: str = "GET", body=None) -> tuple[int, bytes]:
    """Return raw responses for JSON and binary API routes with any HTTP method."""
    headers = {"Authorization": f"Bearer {token}"}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    request = Request(api.base + path, data=data, headers=headers, method=method)
    try:
        with urlopen(request, timeout=30) as response:
            return response.status, response.read()
    except HTTPError as error:
        with error:
            return error.code, error.read()


def assert_read_is_site_scoped(api, paths, template, path, owner, foreign):
    assert "get" in paths.get(template, {}), f"GET {template} is missing from generated OpenAPI"
    owner_status, owner_body = get_response(api, path, owner.token)
    assert owner_status == 200, f"Same-site GET {template} returned {owner_status}"
    foreign_status, foreign_body = get_response(api, path, foreign.token)
    assert foreign_status in {403, 404}, f"Foreign GET {template} returned {foreign_status}"
    if template == PDF_ROUTE:
        assert owner_body.startswith(b"%PDF"), "Same-site receipt response is not a PDF"
        assert not foreign_body.startswith(b"%PDF"), "Foreign receipt response contains a PDF"


@pytest.fixture
def two_sites(api, actors):
    platform = api.login(**actors["saas"])
    manager = api.login(**actors["manager"])

    email = "nightly-second-manager@example.test"
    site = api.create_site(platform, "Nightly authorization site", email, blocks=("A",))
    password = "Nightly-Manager-2026!"
    api.change_password(email, site["temporary_password"], password)
    second = api.login(email, password)
    site_id = str(site["site_id"])
    api.call("POST", "/api/v1/auth/step-up", second.token, body={"password": password})
    api.call(
        "POST", f"/api/v1/site-admin/bank-account/{site_id}", second.token,
        body={
            "bank_code": "KUVEYT_TURK",
            "iban": TEST_BANK_IBAN,
            "account_holder": "Nightly authorization site",
        },
    )
    api.create_units(second, "A", unit_number=1)
    api.register_home_owner(second, "A", 1, "Nightly Owner", "second-owner@example.test")
    created = api.get_units(second)[0]
    unit = created["id"]
    assert created["virtual_iban"], "The virtual IBAN read requires an already allocated value"
    receipt = api.record_manual_payment(second, unit, Decimal("25.00"), "Nightly Owner")
    period = api.create_period(second, "Ekim 2026", "2026-10-15")
    budget = api.call(
        "POST", "/api/v1/operating-budgets", second.token,
        body={"fiscal_year": 2026, "lines": [
            {"category": "CLEANING", "annual_amount": "10000.00", "allocation_key": "EQUAL"}
        ]},
    )
    project = api.create_capital_project(
        second, "Nightly authorization project", Decimal("60.00"), basis="EQUAL_PER_UNIT",
    )
    people = api.call("GET", f"/api/v1/site-admin/persons?site_id={site_id}", second.token)
    person = next(item["person_id"] for item in people["items"] if item["full_name"] == "Nightly Owner")
    return manager, second, {
        "site": site_id,
        "unit": unit,
        "person": person,
        "period": period["id"],
        "receipt": receipt["id"],
        "receipt_number": receipt["receipt_number"],
        "budget": budget["id"],
        "project": project["id"],
    }


def test_tenant_resources_require_membership(api, two_sites, record_property):
    first, second, ids = two_sites
    paths = api.call("GET", "/api/v1/openapi.json")["paths"]
    denies = []
    for template, parameter, resource, include_site in READ_CASES:
        path = template.format(**{parameter: ids[resource]})
        owner_path = path + ("?" + urlencode({"site_id": ids["site"]}) if include_site else "")
        assert_read_is_site_scoped(api, paths, template, owner_path, second, first)
        if template == "/api/v1/units/{id}/virtual-iban":
            owner_post_status, _ = get_response(api, path, second.token, method="POST")
            assert owner_post_status == 200, f"Same-site POST {template} returned {owner_post_status}"
            foreign_post_status, _ = get_response(api, path, first.token, method="POST")
            assert foreign_post_status in {403, 404}, (
                f"Foreign POST {template} returned {foreign_post_status}"
            )
        if template == "/api/v1/site-admin/units/{id}/occupancy-state":
            contact_path = f"/api/v1/site-admin/units/{ids['unit']}/responsible-contact"
            body = {"person_id": int(ids["person"])}
            owner_put_status, _ = get_response(
                api, contact_path, second.token, method="PUT", body=body,
            )
            assert owner_put_status == 200, (
                f"Same-site PUT /api/v1/site-admin/units/{{id}}/responsible-contact returned {owner_put_status}"
            )
            foreign_put_status, _ = get_response(
                api, contact_path, first.token, method="PUT", body=body,
            )
            assert foreign_put_status in {403, 404}, (
                f"Foreign PUT /api/v1/site-admin/units/{{id}}/responsible-contact returned {foreign_put_status}"
            )
        if include_site:
            caller_path = path + "?" + urlencode({"site_id": first.user["site_id"]})
            caller_status, _ = get_response(api, caller_path, first.token)
            assert caller_status in {403, 404}, f"Foreign GET {template} with caller site returned {caller_status}"
        denies.append(template)
    site_query = urlencode({"site_id": ids["site"]})
    for template in SITE_QUERY_READ_CASES:
        assert_read_is_site_scoped(api, paths, template, f"{template}?{site_query}", second, first)
        denies.append(template)
    record_property("authorization_contract", ", ".join(denies))


def test_additional_tenant_resource_reads_require_membership(api, stack, actors, two_sites):
    """Exercise resource reads that need domain-specific nightly arrangements."""
    first, second, ids = two_sites
    paths = api.call("GET", "/api/v1/openapi.json")["paths"]

    meeting = api.call("POST", "/api/v1/assembly/meetings", second.token, body={
        "scheduled_at": "2026-11-20T10:00:00Z",
        "location": "Nightly tenant authorization meeting",
        "agenda": [{"title": "Authorization contract"}],
    })
    heat_period = api.call("POST", "/api/v1/heat-share/periods", second.token, body={
        "label": "Nightly tenant authorization heat period",
        "period_start": "2026-10-01", "period_end": "2026-10-31",
        "total_cost": "104.29", "due_date": "2026-11-15",
    })
    arrangements = [
        ("/api/v1/assembly/meetings/{id}", str(meeting["id"])),
        ("/api/v1/heat-share/periods/{id}", str(heat_period["id"])),
        ("/api/v1/payments/receipts/{id}/rent-deduction-certificate", str(ids["receipt"])),
    ]

    due_id, _ = arrange_open_due(api, stack, ids)
    arrangements.append(("/api/v1/dunning/notice-letter/{due_id}", due_id))
    case = api.call("POST", "/api/v1/collections/cases", second.token, body={
        "unit_id": str(ids["unit"]), "debtor_type": "OWNER", "due_ids": [due_id],
        "note": "Nightly tenant authorization collection case",
    })
    arrangements.extend((
        ("/api/v1/collections/cases/{id}", str(case["id"])),
        ("/api/v1/collections/cases/{id}/evidence-pack", str(case["id"])),
    ))

    platform = api.login(**actors["saas"])
    company = api.call("POST", "/api/v1/saas/companies", platform.token, body={
        "name": "Nightly tenant authorization company",
        "tax_id": "9912384721", "tax_office": "Nightly",
    })
    api.call("POST", f"/api/v1/saas/companies/{company['id']}/sites", platform.token, body={
        "site_id": ids["site"], "monthly_fee": "100.00",
    })
    api.call("POST", f"/api/v1/saas/companies/{company['id']}/members", platform.token, body={
        "user_ref": str(second.user["id"]),
    })
    arrangements.append(("/api/v1/portfolio/companies/{id}/summary", str(company["id"])))

    api.create_units(second, "A", unit_number=2)
    api.register_home_owner(second, "A", 2, "Nightly Payment Owner", "nightly-payment-owner@example.test")
    stack.sql(
        "UPDATE users SET password_hash = (SELECT password_hash FROM users WHERE id = "
        f"{int(second.user['id'])}), must_change_password = FALSE "
        "WHERE email = 'nightly-payment-owner@example.test' "
        f"AND site_id = {int(ids['site'])};"
    )
    stack.restart_backend()
    second_owner = api.login("nightly-payment-owner@example.test", actors["manager"]["password"])
    first_owner = api.login(**actors["homeowner"])
    second_owner_unit = str(second_owner.user["unit_id"])
    first_owner_unit = str(first_owner.user["unit_id"])
    second_intent = api.call(
        "POST", f"/api/v1/residents/{second_owner_unit}/payment-intents", second_owner.token,
        body={"amount": "1.00"},
    )
    first_intent = api.call(
        "POST", f"/api/v1/residents/{first_owner_unit}/payment-intents", first_owner.token,
        body={"amount": "1.00"},
    )
    template = "/api/v1/residents/{unit_id}/payment-intents/{intent_id}"
    assert "get" in paths.get(template, {}), f"GET {template} is missing from generated OpenAPI"
    path = template.format(unit_id=second_owner_unit, intent_id=second_intent["id"])
    assert_read_is_site_scoped(api, paths, template, path, second_owner, first_owner)
    first_status, _ = get_response(
        api,
        template.format(unit_id=first_owner_unit, intent_id=first_intent["id"]),
        first_owner.token,
    )
    assert first_status == 200, f"Same-site GET {template} returned {first_status}"

    for template, resource_id in arrangements:
        assert "get" in paths.get(template, {}), f"GET {template} is missing from generated OpenAPI"
        path = template.format(id=resource_id, due_id=resource_id)
        assert_read_is_site_scoped(api, paths, template, path, second, first)


def field_values(document, field: str) -> set[str]:
    """Compare a field's scalar values exactly, including IDs serialized as strings."""
    if isinstance(document, list):
        return {value for child in document for value in field_values(child, field)}
    if isinstance(document, dict):
        values = {value for child in document.values() for value in field_values(child, field)}
        if isinstance(document.get(field), (str, int)):
            values.add(str(document[field]))
        return values
    return set()


def arrange_open_due(api, stack, ids) -> tuple[str, date]:
    # Seed the overdue liability in the throwaway E2E database, as the shared
    # journey builders do. The read contract only needs the resulting row.
    row = stack.sql(f"""
        INSERT INTO dues_liabilities (
            unit_id, period, period_key, dues_period_id, debtor_type, expense_type,
            liable_person_id, principal_amount, due_date, effective_due_date, status, created_at
        )
        SELECT u.id, p.period_name, p.period_key, p.id, 'OWNER', 'OPERATIONAL_DUES',
               u.owner_person_id, 327.41, p.due_date, p.due_date, 'PENDING', p.due_date
          FROM units u
          JOIN dues_periods p ON p.site_id = u.site_id
         WHERE u.site_id = {int(ids["site"])}
           AND u.id = {int(ids["unit"])}
           AND u.owner_person_id = {int(ids["person"])}
           AND p.id = {int(ids["period"])}
        RETURNING id, due_date;
    """)
    assert row, "The second site's unit, owner and period must all match the liability"
    due_id, due_date = row.split("|")
    as_of = date.fromisoformat(due_date) + timedelta(days=60)
    stack.restart_backend()
    api.clock.set_date(as_of)
    return due_id, as_of


def arrange_implicit_read(api, stack, manager, ids, arrangement: str | None) -> tuple[str, str]:
    marker = SECOND_SITE_MARKER
    site, unit = ids["site"], str(ids["unit"])

    def post(path, body):
        return api.call("POST", f"/api/v1{path}", manager.token, body=body)

    if arrangement is None:
        return "site_id", site
    if arrangement == "approval-policy":
        api.call("PUT", "/api/v1/accounting/approval-policy", manager.token, body={
            "manager_limit": "4321.00",
        })
        return "site_id", site
    if arrangement == "journal":
        return "reference", str(ids["receipt_number"])
    if arrangement in {"audit", "access-log"}:
        api.resident_statement(manager, unit)
        return "site_id", site
    if arrangement == "schedule":
        api.call("PUT", "/api/v1/accrual-schedule", manager.token, body={
            "accrual_day": 27, "due_day": 29, "grace_days": 13, "catch_up_limit_months": 5,
            "go_live_date": "2051-01-01",
        })
        return "go_live_date", "2051-01-01"
    if arrangement in {"vendor", "expense"}:
        vendor = post("/accounting/vendors", {"name": marker, "tax_id": "0010180009"})
        if arrangement == "vendor":
            return "name", marker
        post("/accounting/expenses", {
            "vendor_id": vendor["id"], "invoice_number": marker, "invoice_date": "2026-10-01",
            "category": "CLEANING", "net_amount": "31.27",
        })
        return "invoice_number", marker
    if arrangement == "decision":
        post("/assembly/decisions", {"decided_on": date.today().isoformat(), "title": marker, "text": marker})
        return "title", marker
    if arrangement == "meeting":
        post("/assembly/meetings", {
            "scheduled_at": "2026-11-20T10:00:00Z", "location": marker, "agenda": [{"title": marker}],
        })
        return "location", marker
    if arrangement == "reconciliation":
        post("/bank-matching/daily-reconciliation", {"business_date": "2026-10-15", "lines": []})
        return "site_id", site
    if arrangement == "feed":
        # The sandbox provider stays local. Creating the fixture does not sync the feed.
        post("/bank-matching/feeds", {"provider": "SANDBOX", "account_iban": TEST_BANK_IBAN})
        return "site_id", site
    if arrangement == "heat":
        post("/heat-share/periods", {
            "label": marker, "period_start": "2026-10-01", "period_end": "2026-10-31",
            "total_cost": "104.29", "due_date": "2026-11-15",
        })
        return "label", marker
    if arrangement == "privacy":
        post("/kvkk/privacy-notices", {"title": marker, "body": marker})
        return "title", marker
    if arrangement == "lease":
        post("/leases", {
            "unit_id": unit, "tenant_name": marker, "monthly_rent": "750.00", "lease_start": "2026-10-01",
        })
        return "tenant_name", marker
    if arrangement == "notification":
        post("/announcements", {"site_id": site, "title": marker, "body": marker})
        return "subject", marker
    if arrangement == "virman":
        post(f"/residents/{unit}/virman-requests", {"source_debtor": "OWNER", "amount": "1.00", "note": marker})
        return "note", marker
    if arrangement == "exit-settlement":
        post(f"/site-admin/units/{unit}/advance-exit-settlements", {
            "request_key": "nightly-site-scope-exit", "kind": "PAYOUT", "source_debtor": "OWNER",
            "beneficiary_name": marker, "beneficiary_person_id": str(ids["person"]), "amount": "1.00",
        })
        return "beneficiary_name", marker
    if arrangement == "seller-override":
        buyer = post("/site-admin/persons", {"card": {"full_name": "Nightly Scope Buyer"}})
        post(f"/site-admin/units/{unit}/seller-pays-overrides", {
            "buyer_person_id": buyer["card"]["person_id"], "transfer_date": "2026-11-20", "reason": marker,
        })
        return "reason", marker

    if arrangement == "payment-plan":
        # Copy the fixture password entirely inside PostgreSQL. The domain
        # requires a second same-site manager or auditor to approve the plan.
        reviewer = stack.sql(
            "INSERT INTO users (site_id, email, password_hash, role, is_active, must_change_password) "
            f"SELECT site_id, 'nightly-plan-reviewer@example.test', password_hash, 'AUDITOR', TRUE, FALSE "
            f"FROM users WHERE id = {int(manager.user['id'])} RETURNING id;"
        ).strip()
        assert reviewer, "Could not create the payment-plan approver"
    due, as_of = arrange_open_due(api, stack, ids)
    if arrangement == "correction":
        post("/accrual-corrections", {"due_id": due, "kind": "CANCEL", "reason": marker})
        return "reason", marker
    if arrangement == "adjustment":
        post("/adjustments", {"due_id": due, "kind": "PRINCIPAL_WRITE_OFF", "amount": "1.00", "reason": marker})
        return "reason", marker
    if arrangement == "collection":
        post("/collections/cases", {"unit_id": unit, "debtor_type": "OWNER", "due_ids": [due], "note": marker})
        return "note", marker
    if arrangement == "dunning":
        api.call("PUT", "/api/v1/dunning/policy", manager.token, body={
            "enabled": True, "steps": [{"day_offset": 45, "channel": "LETTER", "kind": "IHTARNAME"}],
        })
        post("/dunning/run", {"as_of": as_of.isoformat()})
        return "due_id", due
    if arrangement == "debtor-export":
        return "debtor_name", "Nightly Owner"
    if arrangement == "dispute":
        post(f"/residents/{unit}/disputes", {"due_id": due, "reason": marker})
        return "reason", marker
    if arrangement == "payment-plan":
        post("/payment-plans", {
            "unit_id": unit, "debtor_type": "OWNER", "due_ids": [due], "installment_count": 2,
            "first_due_date": (as_of + timedelta(days=14)).isoformat(), "approved_by": reviewer, "note": marker,
        })
        return "note", marker
    raise AssertionError(f"Unknown implicit-read arrangement: {arrangement}")


@pytest.mark.parametrize("path,arrangement", IMPLICIT_READ_CASES.items(), ids=IMPLICIT_READ_CASES)
def test_implicit_reads_follow_manager_site(api, stack, two_sites, path, arrangement):
    first, second, ids = two_sites
    paths = api.call("GET", "/api/v1/openapi.json")["paths"]
    assert "get" in paths.get(path, {}), f"GET {path} is missing from generated OpenAPI"
    field, marker = arrange_implicit_read(api, stack, second, ids, arrangement)

    owner_status, owner_body = get_response(api, path, second.token)
    assert owner_status == 200, f"Second-site GET {path} returned {owner_status}"
    assert marker in field_values(json.loads(owner_body), field), f"GET {path} did not return the seeded {field}"
    if arrangement == "approval-policy":
        assert Decimal(json.loads(owner_body)["manager_limit"]) == Decimal("4321.00")

    foreign_status, foreign_body = get_response(api, path, first.token)
    assert foreign_status == 200, f"First-site GET {path} returned {foreign_status}"
    first_values = field_values(json.loads(foreign_body), field)
    if arrangement is None:
        assert str(first.user["site_id"]) in first_values, f"GET {path} did not identify the first site"
    assert marker not in first_values, f"GET {path} returned the other site's {field}"
    if arrangement == "approval-policy":
        assert Decimal(json.loads(foreign_body)["manager_limit"]) != Decimal("4321.00")
