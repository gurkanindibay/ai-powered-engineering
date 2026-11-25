"""Run a fixed authorization contract against two synthetic SitePulse sites."""
from __future__ import annotations

import json
from datetime import date, timedelta
from decimal import Decimal
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

import pytest

# Static, reviewed cases with a known resource type and a positive same-site
# control. Validate each route against the server's generated OpenAPI contract.
READ_CASES = (
    ("/api/v1/home-residents/members/{unit_id}", "unit_id", "unit", False),
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
IMPLICIT_WRITE_CASES = (
    ("POST", "/api/v1/autopay/run", lambda: {"as_of": date.today().isoformat()}),
    ("PUT", "/api/v1/operating-budgets/transition", lambda: {"transition_days": 30}),
    ("POST", "/api/v1/kvkk/retention/purge", lambda: {}),
)
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
    "/api/v1/kvkk/retention": "retention",
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


def assert_write_is_site_scoped(
    api, path: str, owner, foreign, body, *, success: set[int], method: str = "POST",
) -> None:
    owner_status, owner_body = get_response(api, path, owner.token, method=method, body=body)
    assert owner_status in success, f"Same-site {method} {path} returned {owner_status}: {owner_body[:300]}"
    foreign_status, _ = get_response(api, path, foreign.token, method=method, body=body)
    assert foreign_status in {403, 404}, f"Foreign {method} {path} returned {foreign_status}"


def test_tenant_inventory_matches_live_openapi(api, record_property):
    """Keep the reviewed tenant operation inventory aligned with the running API."""
    inventory = json.loads(Path(__file__).with_name("tenant_operation_inventory.json").read_text())
    operations = api.call("GET", "/api/v1/openapi.json")["paths"]
    for row in inventory["operations"]:
        methods = operations.get(row["path"], {})
        assert row["method"].lower() in methods, (
            f"{row['method']} {row['path']} is missing from generated OpenAPI"
        )
    scoped = [row for row in inventory["operations"]
              if row["applicability"] in {"tenant_reference", "implicit_tenant_scope"}]
    covered = sum(bool(row["runtime_tests"]) for row in scoped)
    record_property("tenant_applicable_operations", len(scoped))
    record_property("tenant_operations_with_runtime_evidence", covered)


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
    period = api.create_period(second, "Ekim 2025", "2025-10-15")
    budget = api.call(
        "POST", "/api/v1/operating-budgets", second.token,
        body={"fiscal_year": 2026, "lines": [
            {"category": "CLEANING", "annual_amount": "10000.00", "allocation_key": "EQUAL"}
        ]},
    )
    project = api.create_capital_project(
        second, "Nightly authorization project", Decimal("60.00"), basis="EQUAL_PER_UNIT",
        first_due="2026-09-15",
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


def test_tenant_resources_require_membership(api, stack, two_sites, record_property):
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
        if template == "/api/v1/home-residents/members/{unit_id}":
            members_path = f"/api/v1/home-residents/members/{ids['unit']}?site_id={ids['site']}"
            member_body = {
                "person": {"kind": "new", "card": {
                    "full_name": "Nightly Additional Resident",
                    "phone": "+90 533 123 45 67",
                    "email": "nightly-additional-resident@example.test",
                }},
                "relationship": "OTHER",
            }
            owner_member_status, owner_member_raw = get_response(
                api, members_path, second.token, method="POST", body=member_body,
            )
            assert owner_member_status == 201, (
                f"Same-site POST /api/v1/home-residents/members/{{unit_id}} returned "
                f"{owner_member_status}: {owner_member_raw[:300]}"
            )
            foreign_member_status, _ = get_response(
                api, members_path, first.token, method="POST", body=member_body,
            )
            assert foreign_member_status in {403, 404}, (
                f"Foreign POST /api/v1/home-residents/members/{{unit_id}} returned {foreign_member_status}"
            )
            resident_id = json.loads(owner_member_raw)["resident_id"]
            member_path = (
                f"/api/v1/home-residents/members/{ids['unit']}/{resident_id}?site_id={ids['site']}"
            )
            update_body = {
                "full_name": "Nightly Updated Resident",
                "phone": "+90 533 123 45 68",
                "email": "nightly-additional-resident@example.test",
                "relationship": "OTHER",
            }
            owner_update_status, _ = get_response(
                api, member_path, second.token, method="PUT", body=update_body,
            )
            assert owner_update_status == 200, (
                f"Same-site PUT /api/v1/home-residents/members/{{unit_id}}/{{resident_id}} returned {owner_update_status}"
            )
            foreign_update_status, _ = get_response(
                api, member_path, first.token, method="PUT", body=update_body,
            )
            assert foreign_update_status in {403, 404}, (
                f"Foreign PUT /api/v1/home-residents/members/{{unit_id}}/{{resident_id}} returned {foreign_update_status}"
            )
            foreign_delete_status, _ = get_response(
                api, member_path, first.token, method="DELETE",
            )
            assert foreign_delete_status in {403, 404}, (
                f"Foreign DELETE /api/v1/home-residents/members/{{unit_id}}/{{resident_id}} returned {foreign_delete_status}"
            )
            owner_delete_status, _ = get_response(
                api, member_path, second.token, method="DELETE",
            )
            assert owner_delete_status == 204, (
                f"Same-site DELETE /api/v1/home-residents/members/{{unit_id}}/{{resident_id}} returned {owner_delete_status}"
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
    query_site = f"site_id={ids['site']}"
    assert_write_is_site_scoped(
        api, f"/api/v1/site-admin/units?{query_site}", second, first,
        {"block_name": "A", "unit_number": 2}, success={201},
    )
    assert_write_is_site_scoped(
        api, f"/api/v1/site-admin/blocks?{query_site}", second, first,
        {"block_name": "Z", "total_floors": 1}, success={201},
    )
    assert_write_is_site_scoped(
        api, f"/api/v1/site-admin/house-types?{query_site}", second, first,
        {"type_name": "Nightly Scoped Type", "dues_amount": "100.00"}, success={201},
    )
    api.register_home_owner(
        second, "A", 2, "Nightly Move In Owner", "nightly-move-in-owner@example.test",
        is_resident=False,
    )
    move_in_unit = next(
        item for item in api.get_units(second) if int(item["unit_number"]) == 2
    )
    assert_write_is_site_scoped(
        api, f"/api/v1/site-admin/units/{move_in_unit['id']}/move-in?{query_site}", second, first,
        {
            "role": "TENANT", "full_name": "Nightly Scoped Tenant",
            "phone": "+90 532 111 22 44", "email": "nightly-scoped-tenant@example.test",
            "start_date": date.today().isoformat(),
        }, success={200},
    )
    assert_write_is_site_scoped(
        api, f"/api/v1/site-admin/proration-policy?{query_site}", second, first,
        {"proration_enabled": True}, success={200}, method="PUT",
    )
    assert_write_is_site_scoped(
        api, f"/api/v1/site-admin/persons?{query_site}", second, first,
        {"card": {"full_name": "Nightly Tenant Scope Person"}}, success={201},
    )
    assert_write_is_site_scoped(
        api, f"/api/v1/site-admin/persons/duplicate-check?{query_site}", second, first,
        {"full_name": "Nightly Duplicate Scope Probe"}, success={200},
    )
    role_user_id = stack.sql(
        "SELECT id FROM users WHERE email='second-owner@example.test' "
        f"AND site_id={int(ids['site'])};"
    ).strip()
    assert role_user_id, "The second site's owner login must exist"
    assert_write_is_site_scoped(
        api, "/api/v1/site-admin/roles", second, first,
        {"user_id": role_user_id, "role": "HOME_OWNER"}, success={200},
    )
    assert_write_is_site_scoped(
        api, f"/api/v1/site-admin/persons/import?{query_site}", second, first,
        {
            "dry_run": True,
            "csv": "block,unit_no,owner_full_name,owner_email,owner_phone\n"
                   "A,99,Nightly Import Owner,nightly-import@example.test,+90 532 111 22 33\n",
        }, success={200},
    )
    bank_account = {
        "bank_code": "KUVEYT_TURK", "iban": TEST_BANK_IBAN,
        "account_holder": "Nightly authorization site",
    }
    assert_write_is_site_scoped(
        api, f"/api/v1/site-admin/bank-account/{ids['site']}", second, first,
        bank_account, success={200},
    )
    assert_write_is_site_scoped(
        api, "/api/v1/bank/statements/parse", second, first,
        {
            "site_id": ids["site"],
            "content": "2026-11-01;Nightly tenant-scope transfer;1,00;TXN-SCOPE-001",
        }, success={200},
    )
    assert_write_is_site_scoped(
        api, "/api/v1/bank/statements/confirm-reconciliation", second, first,
        {"site_id": ids["site"], "match_ids": [], "matches": []}, success={200},
    )
    assert_write_is_site_scoped(
        api, "/api/v1/bank/remembered-ibans", second, first,
        {
            "site_id": ids["site"], "unit_id": str(ids["unit"]),
            "sender_iban": "TR110006200000000123456789", "sender_name": "Nightly scoped payer",
        }, success={200},
    )
    decision_path = "/api/v1/assembly/decisions"
    decision_body = {
        "decided_on": date.today().isoformat(), "title": "Nightly linked budget decision",
        "text": "Tenant scope check", "linked_budget_id": str(ids["budget"]),
    }
    decision_status, decision_response = get_response(
        api, decision_path, second.token, method="POST", body=decision_body,
    )
    assert decision_status == 201, f"Same-site POST {decision_path} returned {decision_status}"
    # This route creates a decision in the caller's current site, so use a
    # distinct request for each caller and verify their stored site scopes.
    foreign_decision_body = {
        "decided_on": date.today().isoformat(), "title": "Nightly foreign-site decision",
        "text": "Caller-site scope check",
    }
    foreign_decision_status, foreign_decision_response = get_response(
        api, decision_path, first.token, method="POST", body=foreign_decision_body,
    )
    assert foreign_decision_status == 201, (
        f"Caller-site POST {decision_path} returned {foreign_decision_status}"
    )
    owner_decision = json.loads(decision_response)
    foreign_decision = json.loads(foreign_decision_response)
    assert foreign_decision["site_id"] != owner_decision["site_id"], (
        "Foreign caller's assembly decision was stored in the other site's scope"
    )
    virman_path = "/api/v1/residents/" + str(ids["unit"]) + "/virman-requests"
    virman_body = {"source_debtor": "OWNER", "amount": "1.00", "note": "Nightly scope virman"}
    virman_status, virman_response = get_response(
        api, virman_path, second.token, method="POST", body=virman_body,
    )
    assert virman_status == 201, f"Same-site POST {virman_path} returned {virman_status}"
    foreign_virman_status, _ = get_response(
        api, virman_path, first.token, method="POST", body=virman_body,
    )
    assert foreign_virman_status in {403, 404}, (
        f"Foreign POST {virman_path} returned {foreign_virman_status}"
    )
    virman_id = json.loads(virman_response)["id"]
    assert_write_is_site_scoped(
        api, f"/api/v1/resident-requests/virman/{virman_id}/decide", second, first,
        {"approve": False, "note": "Nightly scope rejection"}, success={200},
    )
    exit_path = "/api/v1/site-admin/units/" + str(ids["unit"]) + "/advance-exit-settlements"
    exit_body = {
        "request_key": "nightly-cross-site-exit", "kind": "PAYOUT",
        "source_debtor": "OWNER", "beneficiary_name": "Nightly Beneficiary",
        "beneficiary_person_id": str(ids["person"]), "amount": "1.00",
    }
    exit_status, exit_response = get_response(
        api, exit_path, second.token, method="POST", body=exit_body,
    )
    assert exit_status == 201, f"Same-site POST {exit_path} returned {exit_status}"
    foreign_exit_status, _ = get_response(
        api, exit_path, first.token, method="POST", body=exit_body,
    )
    assert foreign_exit_status in {403, 404}, (
        f"Foreign POST {exit_path} returned {foreign_exit_status}"
    )
    exit_id = json.loads(exit_response)["id"]
    exit_decision_path = f"/api/v1/site-admin/advance-exit-settlements/{exit_id}/decide"
    exit_decision_body = {"approve": False, "note": "Nightly scope rejection"}
    same_site_decision_status, same_site_decision_body = get_response(
        api, exit_decision_path, second.token, method="POST", body=exit_decision_body,
    )
    assert same_site_decision_status == 403, (
        f"Same-site decision should enforce four-eyes approval, got "
        f"{same_site_decision_status}: {same_site_decision_body[:300]}"
    )
    assert b"different person" in same_site_decision_body.lower(), (
        "Same-site decision was rejected for a reason other than the four-eyes control"
    )
    foreign_decision_status, _ = get_response(
        api, exit_decision_path, first.token, method="POST", body=exit_decision_body,
    )
    assert foreign_decision_status in {403, 404}, (
        f"Foreign POST {exit_decision_path} returned {foreign_decision_status}"
    )
    assert_write_is_site_scoped(
        api, "/api/v1/payments/record", second, first,
        {
            "unit_id": str(ids["unit"]), "amount": "1.00",
            "payment_method": "MANUAL_CASH", "homeowner_name": "Nightly Owner",
        }, success={200},
    )
    assert_write_is_site_scoped(
        api, "/api/v1/payments/reverse", second, first,
        {"receipt": str(ids["receipt"]), "reason": "Nightly cross-site rejection control"},
        success={201},
    )
    assert_write_is_site_scoped(
        api, "/api/v1/dues/periods", second, first,
        {"site_id": ids["site"], "period_name": "2026-11", "due_date": "2026-11-30"},
        success={201},
    )
    assert_write_is_site_scoped(
        api, "/api/v1/dues/accrue-period", second, first,
        {"site_id": ids["site"], "period": "2025-10", "amount": "1.00", "due_date": "2025-10-15"},
        success={200},
    )
    assert_write_is_site_scoped(
        api, f"/api/v1/operating-budgets?{query_site}", second, first,
        {"fiscal_year": 2027, "lines": [
            {"category": "CLEANING", "annual_amount": "1200.00", "allocation_key": "EQUAL"},
        ]},
        success={201},
    )
    assert_write_is_site_scoped(
        api, f"/api/v1/operating-budgets/policy?{query_site}", second, first,
        {"site_id": ids["site"], "require_operating_budget": True},
        success={200}, method="PUT",
    )
    assert_write_is_site_scoped(
        api, f"/api/v1/payments/debt-aging/snapshot?{query_site}", second, first,
        {}, success={200},
    )
    assert_write_is_site_scoped(
        api, "/api/v1/payments/match-all", second, first,
        {"site_id": ids["site"]}, success={200},
    )
    assert_write_is_site_scoped(
        api, "/api/v1/capital-projects", second, first,
        {
            "site_id": ids["site"], "title": "Nightly Tenant Scope Project",
            "category": "OTHER", "total_budget": "12.00", "allocation_basis": "EQUAL_PER_UNIT",
            "contract_amount": "12.00", "installments": [{
                "installment_number": 1, "total_installments": 1,
                "due_date": "2026-11-30", "installment_budget": "12.00",
            }],
        },
        success={201},
    )
    assert_write_is_site_scoped(
        api, "/api/v1/leases", second, first,
        {
            "unit_id": str(ids["unit"]), "tenant_name": "Nightly Lease Tenant",
            "monthly_rent": "100.00", "lease_start": "2026-11-01",
        },
        success={201},
    )
    assert_write_is_site_scoped(
        api, "/api/v1/announcements", second, first,
        {"site_id": ids["site"], "title": "Nightly Tenant Scope Announcement", "body": "Site scoped."},
        success={201},
    )
    sender_iban = "TR110006200000000123456789"
    matching_path = "/api/v1/residents/" + str(ids["unit"]) + "/matching-criteria/ibans"
    assert_write_is_site_scoped(
        api, matching_path, second, first,
        {"sender_iban": sender_iban, "label": "Nightly scoped payer"}, success={200},
    )
    assert_write_is_site_scoped(
        api, "/api/v1/residents/" + str(ids["unit"]) + "/matching-criteria/payer-names",
        second, first, {"payer_names": ["Nightly scoped payer"]}, success={200}, method="PUT",
    )
    assert_write_is_site_scoped(
        api, matching_path + "/" + sender_iban, second, first, None,
        success={200}, method="DELETE",
    )
    api.create_units(second, "B", unit_number=1)
    api.create_units(second, "B", unit_number=2)
    api.register_home_owner(second, "B", 1, "Nightly Scoped Owner", "nightly-scoped-owner@example.test")
    assert_write_is_site_scoped(
        api, f"/api/v1/site-admin/home-owners?{query_site}", second, first,
        {
            "block": "B", "unit_no": 2, "floor": 1,
            "owner_full_name": "Nightly Foreign Owner",
            "email": "nightly-foreign-owner@example.test",
            "phone": "+90 532 000 00 00", "is_resident": True, "monthly_dues": "0.00",
        }, success={201},
    )
    scoped_owner = next(
        owner for owner in api.call(
            "GET", f"/api/v1/site-admin/home-owners?{query_site}", second.token,
        ) if owner["owner_full_name"] == "Nightly Scoped Owner"
    )
    assert_write_is_site_scoped(
        api, f"/api/v1/site-admin/home-owners/{scoped_owner['unit_id']}?{query_site}",
        second, first, None, success={204}, method="DELETE",
    )
    scoped_type = next(
        item for item in api.call(
            "GET", f"/api/v1/site-admin/house-types?{query_site}", second.token,
        ) if item["type_name"] == "Nightly Scoped Type"
    )
    assert_write_is_site_scoped(
        api, f"/api/v1/site-admin/house-types/{scoped_type['id']}?{query_site}",
        second, first, None, success={204}, method="DELETE",
    )
    owner_query = urlencode({"site_id": ids["site"]})
    owner_path = "/api/v1/site-admin/home-owners/" + str(ids["unit"])
    assert_write_is_site_scoped(
        api, owner_path + "?" + owner_query, second, first,
        {"owner_full_name": "Nightly Owner"}, success={200}, method="PUT",
    )
    assert_write_is_site_scoped(
        api, owner_path + "/resend-activation?" + owner_query, second, first,
        {"role": "OWNER"}, success={200},
    )
    person_query = urlencode({"site_id": ids["site"]})
    person_path = "/api/v1/site-admin/persons/" + str(ids["person"])
    preferences_path = person_path + "/preferences?" + person_query
    assert_write_is_site_scoped(
        api, preferences_path, second, first,
        {"preferred_channel": "EMAIL", "preferred_language": "tr"}, success={200}, method="PUT",
    )
    card = api.call("GET", person_path + "/card?" + person_query, second.token)
    assert_write_is_site_scoped(
        api, person_path + "?" + person_query, second, first,
        {"full_name": "Nightly Owner", "version": card["card"]["version"]},
        success={200}, method="PATCH",
    )
    assert_write_is_site_scoped(
        api, person_path + "/national-id?" + person_query, second, first,
        {"national_id": None}, success={200}, method="PUT",
    )
    site_query = urlencode({"site_id": ids["site"]})
    for template in SITE_QUERY_READ_CASES:
        assert_read_is_site_scoped(api, paths, template, f"{template}?{site_query}", second, first)
        denies.append(template)
    assert_write_is_site_scoped(
        api, f"/api/v1/site-admin/units/{ids['unit']}/transfer-ownership",
        second, first,
        {
            "site_id": ids["site"], "unit_id": str(ids["unit"]),
            "new_owner": {"kind": "new", "card": {
                "full_name": "Nightly Scoped Buyer",
                "phone": "+90 532 111 22 55",
                "email": "nightly-scoped-buyer@example.test",
            }},
            "new_owner_name": "Nightly Scoped Buyer",
            "transfer_date": date.today().isoformat(),
        }, success={200},
    )
    record_property("authorization_contract", ", ".join(denies))


def test_registration_decisions_are_site_scoped(api, stack, two_sites):
    first, second, ids = two_sites
    reject_id = "nightly-registration-reject-scope"
    approve_id = "nightly-registration-approve-scope"
    site = int(ids["site"])
    stack.sql(
        "INSERT INTO pending_registrations "
        "(request_id, site_id, block, unit_no, floor, full_name, email, phone, is_resident) "
        f"VALUES ('{reject_id}', {site}, 'A Blok', 1, 1, 'Nightly Reject', "
        "'nightly-reject@example.test', '', TRUE), "
        f"('{approve_id}', {site}, 'A Blok', 1, 1, 'Nightly Approve', "
        "'nightly-approve@example.test', '', TRUE);"
    )

    reject_path = f"/api/v1/registration/reject/{reject_id}"
    foreign_reject, _ = get_response(api, reject_path, first.token, method="POST")
    assert foreign_reject in {403, 404}, f"Foreign POST {reject_path} returned {foreign_reject}"
    owner_reject, _ = get_response(api, reject_path, second.token, method="POST")
    assert owner_reject == 200, f"Same-site POST {reject_path} returned {owner_reject}"

    approve_path = f"/api/v1/registration/approve/{approve_id}"
    foreign_approve, _ = get_response(api, approve_path, first.token, method="POST")
    assert foreign_approve in {403, 404}, f"Foreign POST {approve_path} returned {foreign_approve}"
    owner_approve, _ = get_response(api, approve_path, second.token, method="POST")
    # The fixture already occupies unit A-1, so the domain rejects approval
    # after authorization and tenant ownership have both been verified.
    assert owner_approve == 409, f"Same-site POST {approve_path} returned {owner_approve}"


def test_reconciliation_queue_decisions_are_site_scoped(api, stack, two_sites):
    first, second, ids = two_sites
    arrange_open_due(api, stack, ids)
    marker = "NIGHTLY-RECON-SCOPE"
    api.call(
        "POST", "/api/v1/bank/statements/parse", second.token,
        body={
            "site_id": ids["site"],
            "content": "\n".join((
                f"2026-11-19;TR330006100519786457841326;REF-{marker}-ASSIGN;5.00",
                f"2026-11-19;TR330006100519786457841326;REF-{marker}-REJECT;6.00",
            )),
            "format": "EXCEL",
        },
    )
    queue = api.call(
        "GET", f"/api/v1/bank/statements/reconciliation-queue?site_id={ids['site']}", second.token,
    )
    assignment = next(item for item in queue if marker + "-ASSIGN" in str(item.get("transaction", {})))
    rejection = next(item for item in queue if marker + "-REJECT" in str(item.get("transaction", {})))

    assign_path = f"/api/v1/bank/statements/reconciliation-queue/{assignment['match_id']}/assign"
    assign_body = {"site_id": ids["site"], "unit_id": ids["unit"], "debtor_role": "OWNER"}
    foreign_assign_body = {**assign_body, "site_id": str(first.user["site_id"])}
    foreign_assign, _ = get_response(api, assign_path, first.token, method="POST", body=foreign_assign_body)
    assert foreign_assign in {403, 404}, f"Foreign POST {assign_path} returned {foreign_assign}"
    owner_assign, _ = get_response(api, assign_path, second.token, method="POST", body=assign_body)
    assert owner_assign == 200, f"Same-site POST {assign_path} returned {owner_assign}"

    reject_path = f"/api/v1/bank/statements/reconciliation-queue/{rejection['match_id']}/reject"
    reject_body = {"site_id": ids["site"], "reason": marker}
    foreign_reject_body = {**reject_body, "site_id": str(first.user["site_id"])}
    foreign_reject, _ = get_response(api, reject_path, first.token, method="POST", body=foreign_reject_body)
    assert foreign_reject in {403, 404}, f"Foreign POST {reject_path} returned {foreign_reject}"
    owner_reject, _ = get_response(api, reject_path, second.token, method="POST", body=reject_body)
    assert owner_reject == 200, f"Same-site POST {reject_path} returned {owner_reject}"


def test_person_login_lifecycle_is_site_scoped(api, two_sites):
    first, second, ids = two_sites
    person = api.call(
        "POST", f"/api/v1/site-admin/persons?site_id={ids['site']}", second.token,
        body={"card": {
            "full_name": "Nightly Login Lifecycle", "phone": "+90 532 123 00 00",
            "email": "nightly-login-lifecycle@example.test",
        }, "confirm_distinct": True},
    )
    path = f"/api/v1/site-admin/persons/{person['card']['person_id']}/login?site_id={ids['site']}"
    foreign_open, _ = get_response(api, path, first.token, method="POST")
    assert foreign_open in {403, 404}, f"Foreign POST {path} returned {foreign_open}"
    owner_open, _ = get_response(api, path, second.token, method="POST")
    assert owner_open == 200, f"Same-site POST {path} returned {owner_open}"

    foreign_remove, _ = get_response(api, path, first.token, method="DELETE")
    assert foreign_remove in {403, 404}, f"Foreign DELETE {path} returned {foreign_remove}"
    owner_remove, _ = get_response(api, path, second.token, method="DELETE")
    assert owner_remove == 204, f"Same-site DELETE {path} returned {owner_remove}"


def test_person_merge_is_site_scoped(api, two_sites):
    first, second, ids = two_sites
    query = f"?site_id={ids['site']}"
    source = api.call(
        "POST", "/api/v1/site-admin/persons" + query, second.token,
        body={"card": {"full_name": "Nightly Merge Source", "phone": "+90 532 123 45 67"},
              "confirm_distinct": True},
    )
    target = api.call(
        "POST", "/api/v1/site-admin/persons" + query, second.token,
        body={"card": {"full_name": "Nightly Merge Target", "phone": "+90 532 765 43 21"},
              "confirm_distinct": True},
    )
    path = f"/api/v1/site-admin/persons/{source['card']['person_id']}/merge{query}"
    body = {"target_person_id": str(target["card"]["person_id"])}
    foreign_status, _ = get_response(api, path, first.token, method="POST", body=body)
    assert foreign_status in {403, 404}, f"Foreign POST {path} returned {foreign_status}"
    api.call("POST", "/api/v1/auth/step-up", second.token, body={"password": "Nightly-Manager-2026!"})
    owner_status, _ = get_response(api, path, second.token, method="POST", body=body)
    assert owner_status == 200, f"Same-site POST {path} returned {owner_status}"


def test_occupancy_transition_is_site_scoped(api, two_sites):
    first, second, ids = two_sites
    api.create_units(second, "A", unit_number=2)
    api.register_home_owner(
        second, "A", 2, "Nightly Transition Owner", "nightly-transition-owner@example.test",
        is_resident=False,
    )
    unit = next(item for item in api.get_units(second) if int(item["unit_number"]) == 2)
    unit_id = str(unit["id"])
    path = f"/api/v1/site-admin/units/{unit_id}/occupancy-transitions?site_id={ids['site']}"
    state = api.get_unit_occupancy_state(second, unit_id, ids["site"])
    assert "TENANT_MOVE_IN" in state["allowed_commands"], f"Unexpected owned vacant unit state: {state}"
    body = {
        "command": "TENANT_MOVE_IN", "effective_date": date.today().isoformat(),
        "full_name": "Nightly Scoped Tenant", "email": "nightly-scoped-tenant@example.test",
        "phone": "+90 532 111 22 33",
    }
    foreign_status, _ = get_response(api, path, first.token, method="POST", body=body)
    assert foreign_status in {403, 404}, f"Foreign POST {path} returned {foreign_status}"
    owner_status, owner_body = get_response(api, path, second.token, method="POST", body=body)
    assert owner_status == 200, f"Same-site POST {path} returned {owner_status}: {owner_body[:300]}"


def test_autopay_mandate_lifecycle_is_site_scoped(api, stack, actors, two_sites):
    first, second, ids = two_sites
    stack.sql(
        "UPDATE users SET password_hash = (SELECT password_hash FROM users WHERE id = "
        f"{int(second.user['id'])}), must_change_password = FALSE "
        "WHERE email = 'second-owner@example.test' "
        f"AND site_id = {int(ids['site'])};"
    )
    method_id = stack.sql(
        "INSERT INTO saved_payment_methods "
        "(site_id, unit_id, debtor_type, owner_ref, provider, token_ref, brand, last4, "
        "exp_month, exp_year, status, created_at) "
        f"VALUES ({int(ids['site'])}, {int(ids['unit'])}, 'OWNER', 'person-{ids['person']}', "
        f"'SANDBOX', 'nightly-autopay-scope-{ids['site']}', 'VISA', '4242', 12, 2032, 'ACTIVE', NOW()) "
        "RETURNING id;"
    ).splitlines()[0]
    stack.restart_backend()
    owner = api.login("second-owner@example.test", "Nightly-Manager-2026!")
    first_owner = api.login(**actors["homeowner"])
    unit_path = f"/api/v1/residents/{owner.user['unit_id']}/autopay/mandates"
    body = {"payment_method_id": int(method_id), "debtor_type": "OWNER", "max_amount": "100.00"}
    foreign_create, _ = get_response(api, unit_path, first_owner.token, method="POST", body=body)
    assert foreign_create in {403, 404}, f"Foreign POST {unit_path} returned {foreign_create}"
    owner_create, owner_response = get_response(api, unit_path, owner.token, method="POST", body=body)
    assert owner_create == 201, f"Same-site POST {unit_path} returned {owner_create}"
    mandate_id = json.loads(owner_response)["id"]

    cancel_path = f"{unit_path}/{mandate_id}/cancel"
    foreign_cancel, _ = get_response(api, cancel_path, first_owner.token, method="POST")
    assert foreign_cancel in {403, 404}, f"Foreign POST {cancel_path} returned {foreign_cancel}"
    owner_cancel, _ = get_response(api, cancel_path, owner.token, method="POST")
    assert owner_cancel == 200, f"Same-site POST {cancel_path} returned {owner_cancel}"


def test_support_grant_lifecycle_requires_platform_scope(api, stack, actors, two_sites):
    first, second, ids = two_sites
    admin = api.login(**actors["saas"])
    approver_email = "nightly-support-approver@example.test"
    stack.sql(
        "INSERT INTO users (email, password_hash, role, is_active, must_change_password) "
        "SELECT 'nightly-support-approver@example.test', password_hash, 'SAAS_ADMIN', TRUE, FALSE "
        "FROM users WHERE email = 'admin@sitepulse.io';"
    )
    stack.restart_backend()
    approver = api.login(approver_email, actors["saas"]["password"])
    for session, password in ((admin, actors["saas"]["password"]), (approver, actors["saas"]["password"])):
        api.call("POST", "/api/v1/auth/step-up", session.token, body={"password": password})

    grant_body = {
        "site_id": ids["site"], "operator_user_id": str(admin.user["id"]),
        "permissions": ["SITE_MANAGE", "PERSON_READ", "AUDIT_LOG_READ", "UNIT_READ"],
        "reason": "Nightly tenant scope grant", "minutes": 5,
    }
    create_path = "/api/v1/support/grants"
    foreign_create, _ = get_response(api, create_path, second.token, method="POST", body=grant_body)
    assert foreign_create == 403, f"Site manager POST {create_path} returned {foreign_create}"
    owner_create, response = get_response(api, create_path, admin.token, method="POST", body=grant_body)
    assert owner_create == 200, f"Platform admin POST {create_path} returned {owner_create}"
    grant_id = json.loads(response)["id"]

    action_body = {"id": grant_id}
    for action in ("approve", "revoke"):
        path = f"/api/v1/support/grants/{action}"
        foreign_status, _ = get_response(api, path, second.token, method="POST", body=action_body)
        assert foreign_status == 403, f"Site manager POST {path} returned {foreign_status}"
        owner_status, _ = get_response(api, path, approver.token, method="POST", body=action_body)
        assert owner_status == 200, f"Platform approver POST {path} returned {owner_status}"


def test_inter_ledger_transfer_is_site_scoped(api, stack, two_sites):
    first, second, ids = two_sites
    stack.sql(
        "INSERT INTO dues_liabilities "
        "(unit_id, period, debtor_type, expense_type, principal_amount, due_date, status) "
        f"VALUES ({int(ids['unit'])}, 'Nightly interledger scope', 'TENANT', 'OPERATIONAL_DUES', "
        "5.00, CURRENT_DATE - 1, 'PENDING');"
    )
    stack.restart_backend()
    api.clock.set_date(date.today())
    path = "/api/v1/payments/inter-ledger-transfer"
    body = {
        "site_id": ids["site"], "unit_id": ids["unit"], "amount": "1.00",
        "source_debtor": "OWNER", "target_debtor": "TENANT",
    }
    foreign_status, _ = get_response(api, path, first.token, method="POST", body=body)
    assert foreign_status in {403, 404}, f"Foreign POST {path} returned {foreign_status}"
    owner_status, owner_body = get_response(api, path, second.token, method="POST", body=body)
    assert owner_status == 200, f"Same-site POST {path} returned {owner_status}: {owner_body[:300]}"


@pytest.mark.covers("SC-10-01-03")
def test_additional_tenant_resource_reads_require_membership(api, stack, actors, two_sites):
    """Exercise resource reads that need domain-specific nightly arrangements."""
    first, second, ids = two_sites
    paths = api.call("GET", "/api/v1/openapi.json")["paths"]

    meeting = api.call("POST", "/api/v1/assembly/meetings", second.token, body={
        "call_number": 2,
        "scheduled_at": "2026-11-20T10:00:00Z",
        "location": "Nightly tenant authorization meeting",
        "agenda": [{"title": "Authorization contract"}],
    })
    heat_period = api.call("POST", "/api/v1/heat-share/periods", second.token, body={
        "label": "Nightly tenant authorization heat period",
        "period_start": "2026-10-01", "period_end": "2026-10-31",
        "total_cost": "104.29", "due_date": "2026-11-15",
    })
    project_path = "/api/v1/capital-projects/" + str(ids["project"])
    assert_write_is_site_scoped(
        api, project_path + "/accrue-installment?site_id=" + str(ids["site"]),
        second, first, {"installment_number": 1}, success={200},
    )
    assert_write_is_site_scoped(
        api, project_path + "/disbursements", second, first,
        {
            "milestone_name": "Nightly tenant-scope milestone",
            "amount": "1.00", "recipient_name": "Nightly Contractor",
            "recipient_iban": "TR330006100519786457841326",
            "disbursement_date": date.today().isoformat(),
        }, success={201},
    )
    heat_path = "/api/v1/heat-share/periods/" + str(heat_period["id"])
    heat_readings = {
        "readings": [
            {
                "unit_id": str(unit["id"]),
                "previous_reading": "0.00",
                "current_reading": "5.00",
            }
            for unit in api.get_units(second, site_id=ids["site"])
        ],
    }
    assert heat_readings["readings"], "Heat-share approval fixture needs at least one site unit"
    assert_write_is_site_scoped(
        api, heat_path + "/readings", second, first, heat_readings,
        success={200}, method="PUT",
    )
    assert_write_is_site_scoped(
        api, heat_path + "/approve", second, first, {}, success={200},
    )
    agenda_item_id = str(meeting["agenda"][0]["id"])
    assert_write_is_site_scoped(
        api, "/api/v1/assembly/meetings/" + str(meeting["id"]) + "/attendance",
        second, first,
        {"attendance": [
            {
                "unit_id": str(unit["id"]),
                "attendee_name": "Nightly Owner",
            }
            for unit in api.get_units(second, site_id=ids["site"])
        ], "held_on": date.today().isoformat()},
        success={200},
    )
    assert_write_is_site_scoped(
        api, "/api/v1/assembly/agenda-items/" + agenda_item_id + "/votes",
        second, first,
        {"votes": [{"unit_id": str(ids["unit"]), "vote": "YES"}]}, success={200},
    )
    assert_write_is_site_scoped(
        api, "/api/v1/assembly/agenda-items/" + agenda_item_id + "/close",
        second, first, {"decision_text": "Nightly tenant-scope decision"}, success={200},
    )
    feed = api.call("POST", "/api/v1/bank-matching/feeds", second.token, body={
        "provider": "SANDBOX", "account_iban": "TR330006100519786457841326",
    })
    assert_write_is_site_scoped(
        api, f"/api/v1/bank-matching/feeds/{feed['id']}/sync", second, first,
        None, success={200},
    )
    arrangements = [
        ("/api/v1/assembly/meetings/{id}", str(meeting["id"])),
        ("/api/v1/heat-share/periods/{id}", str(heat_period["id"])),
        ("/api/v1/payments/receipts/{id}/rent-deduction-certificate", str(ids["receipt"])),
    ]

    api.close_period(second, ids["period"])
    reopen_body = {"reason": "Nightly tenant-scope reopen"}
    reopen_path = f"/api/v1/dues/periods/{ids['period']}/reopen"
    reopen_status, reopen_response = get_response(
        api, reopen_path, second.token, method="POST", body=reopen_body,
    )
    assert reopen_status == 201, f"Same-site POST {reopen_path} returned {reopen_status}"
    foreign_reopen_status, _ = get_response(
        api, reopen_path, first.token, method="POST", body=reopen_body,
    )
    assert foreign_reopen_status in {403, 404}, (
        f"Foreign POST {reopen_path} returned {foreign_reopen_status}"
    )
    reopen_id = json.loads(reopen_response)["id"]
    assert_write_is_site_scoped(
        api, f"/api/v1/dues/period-reopen-requests/{reopen_id}/decide",
        second, first, {"approve": False, "decision_note": "Nightly rejection"},
        success={200},
    )
    due_id, _ = arrange_open_due(api, stack, ids)
    vendor = api.call(
        "POST", "/api/v1/accounting/vendors", second.token,
        body={"name": "Nightly Expense Vendor", "tax_id": "0010180009"},
    )
    expense_base = {
        "vendor_id": vendor["id"], "invoice_date": date.today().isoformat(),
        "category": "CLEANING", "net_amount": "31.27",
    }
    payable_expense = api.call(
        "POST", "/api/v1/accounting/expenses", second.token,
        body={**expense_base, "invoice_number": "NIGHTLY-EXPENSE-PAYABLE"},
    )
    assert_write_is_site_scoped(
        api, f"/api/v1/accounting/expenses/{payable_expense['id']}/approve",
        second, first, None, success={200},
    )
    assert_write_is_site_scoped(
        api, f"/api/v1/accounting/expenses/{payable_expense['id']}/payments",
        second, first,
        {"amount": "31.27", "paid_on": date.today().isoformat(),
         "method": "BANK_TRANSFER", "reference": "NIGHTLY-PAYMENT"},
        success={200},
    )
    rejected_expense = api.call(
        "POST", "/api/v1/accounting/expenses", second.token,
        body={**expense_base, "invoice_number": "NIGHTLY-EXPENSE-REJECT"},
    )
    assert_write_is_site_scoped(
        api, f"/api/v1/accounting/expenses/{rejected_expense['id']}/reject",
        second, first, {"reason": "Nightly scope rejection"}, success={200},
    )
    budget_query = "?site_id=" + str(ids["site"])
    budget_path = "/api/v1/operating-budgets/" + str(ids["budget"])
    assert_write_is_site_scoped(
        api, budget_path + "/issue-interim" + budget_query, second, first,
        {"issued_on": (date.today() - timedelta(days=25)).isoformat()}, success={200},
    )
    assert_write_is_site_scoped(
        api, budget_path + "/approve" + budget_query, second, first,
        {
            "assembly_decision_ref": "NIGHTLY-APPROVAL-01",
            "assembly_decision_date": (date.today() - timedelta(days=20)).isoformat(),
        }, success={200},
    )
    service_date = date.today() - timedelta(days=10)
    assert_write_is_site_scoped(
        api, budget_path + "/service" + budget_query, second, first,
        {
            "unit_id": str(ids["unit"]), "recipient_name": "Nightly Owner",
            "method": "E_NOTIFICATION", "served_on": service_date.isoformat(),
        }, success={200},
    )
    assert_write_is_site_scoped(
        api, budget_path + "/objections" + budget_query, second, first,
        {
            "unit_id": str(ids["unit"]), "objector_name": "Nightly Owner",
            "filed_on": (date.today() - timedelta(days=5)).isoformat(),
            "reason": "Nightly scoped budget objection",
        }, success={201},
    )
    budget = api.call("GET", budget_path + budget_query, second.token)
    objection_id = budget["objections"][-1]["id"]
    assert_write_is_site_scoped(
        api, budget_path + "/objections/" + str(objection_id) + "/resolve" + budget_query,
        second, first, {"status": "DISMISSED", "resolution_note": "Nightly resolution"},
        success={200},
    )
    assert_write_is_site_scoped(
        api, budget_path + "/finalize" + budget_query, second, first, None,
        success={200},
    )
    rejected_budget = api.call("POST", "/api/v1/operating-budgets", second.token, body={
        "fiscal_year": 2027, "lines": [
            {"category": "CLEANING", "annual_amount": "1200.00", "allocation_key": "EQUAL"},
        ],
    })
    assert_write_is_site_scoped(
        api, f"/api/v1/operating-budgets/{rejected_budget['id']}/reject{budget_query}",
        second, first, {"reason": "Nightly scoped rejection"}, success={200},
    )
    deleted_budget = api.call("POST", "/api/v1/operating-budgets", second.token, body={
        "fiscal_year": 2028, "lines": [
            {"category": "CLEANING", "annual_amount": "1200.00", "allocation_key": "EQUAL"},
        ],
    })
    assert_write_is_site_scoped(
        api, f"/api/v1/operating-budgets/{deleted_budget['id']}{budget_query}",
        second, first, None, success={204}, method="DELETE",
    )
    arrangements.append(("/api/v1/dunning/notice-letter/{due_id}", due_id))
    dispute_path = "/api/v1/residents/" + str(ids["unit"]) + "/disputes"
    dispute_body = {"due_id": due_id, "reason": "Nightly tenant-scope dispute"}
    dispute_status, dispute_response = get_response(
        api, dispute_path, second.token, method="POST", body=dispute_body,
    )
    assert dispute_status == 201, f"Same-site POST {dispute_path} returned {dispute_status}"
    foreign_dispute_status, _ = get_response(
        api, dispute_path, first.token, method="POST", body=dispute_body,
    )
    assert foreign_dispute_status in {403, 404}, (
        f"Foreign POST {dispute_path} returned {foreign_dispute_status}"
    )
    dispute_id = json.loads(dispute_response)["id"]
    assert_write_is_site_scoped(
        api, f"/api/v1/resident-requests/disputes/{dispute_id}/resolve", second, first,
        {"accept": False, "note": "Nightly scope rejection"}, success={200},
    )
    case_body = {
        "unit_id": str(ids["unit"]), "debtor_type": "OWNER", "due_ids": [due_id],
        "note": "Nightly tenant authorization collection case",
    }
    case_status, case_response = get_response(
        api, "/api/v1/collections/cases", second.token, method="POST", body=case_body,
    )
    assert case_status == 201, f"Same-site POST /api/v1/collections/cases returned {case_status}"
    foreign_case_status, _ = get_response(
        api, "/api/v1/collections/cases", first.token, method="POST", body=case_body,
    )
    assert foreign_case_status in {403, 404}, (
        f"Foreign POST /api/v1/collections/cases returned {foreign_case_status}"
    )
    case = json.loads(case_response)
    assert_write_is_site_scoped(
        api, f"/api/v1/collections/cases/{case['id']}/advance", second, first,
        {
            "to_status": "LAWYER_ASSIGNED", "lawyer_name": "Nightly Scope Counsel",
            "lawyer_contact": "nightly-lawyer@example.test",
        }, success={200},
    )
    assert_write_is_site_scoped(
        api, f"/api/v1/collections/cases/{case['id']}/lawyer-access",
        second, first, None, success={200},
    )
    adjustment_body = {
        "due_id": due_id, "kind": "PRINCIPAL_WRITE_OFF",
        "amount": "1.00", "reason": "Nightly adjustment scope",
    }
    adjustment_status, adjustment_response = get_response(
        api, "/api/v1/adjustments", second.token, method="POST", body=adjustment_body,
    )
    assert adjustment_status == 201, f"Same-site POST /api/v1/adjustments returned {adjustment_status}"
    foreign_adjustment_status, _ = get_response(
        api, "/api/v1/adjustments", first.token, method="POST", body=adjustment_body,
    )
    assert foreign_adjustment_status in {403, 404}, (
        f"Foreign POST /api/v1/adjustments returned {foreign_adjustment_status}"
    )
    adjustment_id = json.loads(adjustment_response)["id"]
    assert_write_is_site_scoped(
        api, f"/api/v1/adjustments/{adjustment_id}/decide", second, first,
        {"approve": False, "note": "Nightly scope rejection"}, success={200},
    )
    correction_body = {
        "due_id": due_id, "kind": "CREDIT_NOTE", "amount": "1.00",
        "reason": "Nightly scope correction",
    }
    correction_status, correction_response = get_response(
        api, "/api/v1/accrual-corrections", second.token, method="POST", body=correction_body,
    )
    assert correction_status == 201, (
        f"Same-site POST /api/v1/accrual-corrections returned {correction_status}"
    )
    foreign_correction_status, _ = get_response(
        api, "/api/v1/accrual-corrections", first.token, method="POST", body=correction_body,
    )
    assert foreign_correction_status in {403, 404}, (
        f"Foreign POST /api/v1/accrual-corrections returned {foreign_correction_status}"
    )
    correction_id = json.loads(correction_response)["id"]
    assert_write_is_site_scoped(
        api, f"/api/v1/accrual-corrections/{correction_id}/decide", second, first,
        {"approve": False, "note": "Nightly scope rejection"}, success={200},
    )
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
    invite_template = "/api/v1/home-residents/invite-link/{unit_id}"
    assert "get" in paths.get(invite_template, {}), f"GET {invite_template} is missing from generated OpenAPI"
    assert_read_is_site_scoped(
        api, paths, invite_template,
        invite_template.format(unit_id=second_owner_unit), second_owner, first_owner,
    )
    autopay_template = "/api/v1/residents/{unit_id}/autopay"
    assert_read_is_site_scoped(
        api, paths, autopay_template,
        autopay_template.format(unit_id=second_owner_unit), second_owner, first_owner,
    )
    second_intent = api.call(
        "POST", f"/api/v1/residents/{second_owner_unit}/payment-intents", second_owner.token,
        body={"amount": "1.00"},
    )
    first_intent = api.call(
        "POST", f"/api/v1/residents/{first_owner_unit}/payment-intents", first_owner.token,
        body={"amount": "1.00"},
    )
    foreign_intent_status, _ = get_response(
        api, f"/api/v1/residents/{second_owner_unit}/payment-intents", first_owner.token,
        method="POST", body={"amount": "1.00"},
    )
    assert foreign_intent_status in {403, 404}, (
        f"Foreign POST /api/v1/residents/{{unit_id}}/payment-intents returned {foreign_intent_status}"
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
    if arrangement == "journal":
        post("/accounting/journal", {
            "kind": "RESERVE_ALLOCATION", "description": marker,
            "lines": [
                {"account_code": "690", "debit": "1.00", "credit": "0.00"},
                {"account_code": "549", "debit": "0.00", "credit": "1.00"},
            ],
        })
        return "description", marker
    if arrangement == "approval-policy":
        api.call("PUT", "/api/v1/accounting/approval-policy", manager.token, body={
            "manager_limit": "4321.00",
        })
        return "site_id", site
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
    if arrangement == "retention":
        api.call("PUT", "/api/v1/kvkk/retention", manager.token, body={
            "category": "ACCESS_LOG", "retention_months": 137,
        })
        return "retention_months", "137"
    if arrangement == "privacy":
        post("/kvkk/privacy-notices", {"title": marker, "body": marker})
        api.call("PUT", "/api/v1/kvkk/me/consents", manager.token, body={
            "consents": [{"channel": "EMAIL", "granted": False}],
        })
        api.call("POST", "/api/v1/kvkk/me/acknowledge", manager.token)
        return "title", marker
    if arrangement == "lease":
        post("/leases", {
            "unit_id": unit, "tenant_name": marker, "monthly_rent": "750.00", "lease_start": "2026-10-01",
        })
        return "tenant_name", marker
    if arrangement == "notification":
        post("/announcements", {"site_id": site, "title": marker, "body": marker})
        post("/notifications/broadcast", {
            "channel": "NOTICE_BOARD", "category": "ANNOUNCEMENT",
            "subject": marker, "body": marker,
        })
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
        cancel_due = stack.sql(f"""
            INSERT INTO dues_liabilities (
                unit_id, period, period_key, dues_period_id, debtor_type, expense_type,
                liable_person_id, principal_amount, due_date, effective_due_date, status, created_at
            )
            SELECT u.id, p.period_name, p.period_key, p.id, 'OWNER', 'CAPITAL_DUES',
                   u.owner_person_id, 50.00, p.due_date, p.due_date, 'PENDING', p.due_date
              FROM units u JOIN dues_periods p ON p.site_id = u.site_id
             WHERE u.site_id = {int(ids["site"])}
               AND u.id = {int(ids["unit"])}
               AND p.id = {int(ids["period"])}
            RETURNING id;
        """).splitlines()[0]
        stack.restart_backend()
        api.clock.set_date(as_of)
        post("/payment-plans", {
            "unit_id": unit, "debtor_type": "OWNER", "due_ids": [due], "installment_count": 2,
            "first_due_date": (as_of + timedelta(days=14)).isoformat(), "approved_by": reviewer, "note": marker,
        })
        post("/payment-plans", {
            "unit_id": unit, "debtor_type": "OWNER", "due_ids": [cancel_due], "installment_count": 2,
            "first_due_date": (as_of + timedelta(days=14)).isoformat(), "approved_by": reviewer,
            "note": marker + " cancellation",
        })
        return "note", marker
    raise AssertionError(f"Unknown implicit-read arrangement: {arrangement}")


@pytest.mark.parametrize("path,arrangement", IMPLICIT_READ_CASES.items(), ids=IMPLICIT_READ_CASES)
def test_implicit_reads_follow_manager_site(api, stack, two_sites, path, arrangement):
    first, second, ids = two_sites
    paths = api.call("GET", "/api/v1/openapi.json")["paths"]
    assert "get" in paths.get(path, {}), f"GET {path} is missing from generated OpenAPI"
    field, marker = arrange_implicit_read(api, stack, second, ids, arrangement)
    if arrangement == "seller-override":
        overrides = api.call("GET", "/api/v1/site-admin/seller-pays-overrides", second.token)
        override = next(row for row in overrides if row["reason"] == marker)
        override_path = f"/api/v1/site-admin/seller-pays-overrides/{override['id']}/decide"
        reviewer_email = f"nightly-seller-reviewer-{ids['site']}@example.test"
        stack.sql(
            "INSERT INTO users (site_id, email, password_hash, role, is_active, must_change_password) "
            f"SELECT site_id, '{reviewer_email}', password_hash, 'SITE_MANAGER', TRUE, FALSE "
            f"FROM users WHERE id = {int(second.user['id'])};"
        )
        stack.restart_backend()
        reviewer = api.login(reviewer_email, "Nightly-Manager-2026!")
        assert_write_is_site_scoped(
            api, override_path, reviewer, first,
            {"approve": False, "note": "Nightly scoped rejection"}, success={200},
        )
        create_path = f"/api/v1/site-admin/units/{ids['unit']}/seller-pays-overrides"
        foreign_status, _ = get_response(
            api, create_path, first.token, method="POST",
            body={
                "buyer_person_id": override["buyer_person_id"],
                "transfer_date": "2026-11-20", "reason": marker,
            },
        )
        assert foreign_status in {403, 404}, (
            f"Foreign POST {create_path} returned {foreign_status}"
        )

    owner_status, owner_body = get_response(api, path, second.token)
    assert owner_status == 200, f"Second-site GET {path} returned {owner_status}"
    assert marker in field_values(json.loads(owner_body), field), f"GET {path} did not return the seeded {field}"
    if arrangement == "payment-plan":
        plans = json.loads(owner_body)
        plan = next(item for item in plans if item.get("note") == marker)
        plan_id = plan["id"]
        cancel_plan = next(item for item in plans if item.get("note") == marker + " cancellation")
        assert_write_is_site_scoped(
            api, f"/api/v1/payment-plans/{cancel_plan['id']}/cancel", second, first,
            None, success={200},
        )
        as_of = (date.fromisoformat(plan["first_due_date"]) + timedelta(days=90)).isoformat()
        run_path = "/api/v1/payment-plans/run"
        assert "post" in paths.get(run_path, {}), f"POST {run_path} is missing from generated OpenAPI"
        owner_run_status, owner_run_body = get_response(
            api, run_path, second.token, method="POST", body={"as_of": as_of},
        )
        assert owner_run_status == 200, f"Second-site POST {run_path} returned {owner_run_status}"
        owner_run = json.loads(owner_run_body)
        assert plan_id in owner_run["completed"] + owner_run["broken"]
        foreign_run_status, foreign_run_body = get_response(
            api, run_path, first.token, method="POST", body={"as_of": as_of},
        )
        assert foreign_run_status == 200, f"First-site POST {run_path} returned {foreign_run_status}"
        foreign_run = json.loads(foreign_run_body)
        assert plan_id not in foreign_run["completed"] + foreign_run["broken"]
    if arrangement == "approval-policy":
        assert Decimal(json.loads(owner_body)["manager_limit"]) == Decimal("4321.00")
    if arrangement == "privacy":
        own_privacy = json.loads(owner_body)
        assert own_privacy["acknowledged"] is True
        assert next(c for c in own_privacy["consents"] if c["channel"] == "EMAIL")["granted"] is False

    foreign_status, foreign_body = get_response(api, path, first.token)
    assert foreign_status == 200, f"First-site GET {path} returned {foreign_status}"
    first_values = field_values(json.loads(foreign_body), field)
    if arrangement is None:
        assert str(first.user["site_id"]) in first_values, f"GET {path} did not identify the first site"
    assert marker not in first_values, f"GET {path} returned the other site's {field}"
    if arrangement == "approval-policy":
        assert Decimal(json.loads(foreign_body)["manager_limit"]) != Decimal("4321.00")
    if arrangement == "privacy":
        foreign_privacy = json.loads(foreign_body)
        assert foreign_privacy["acknowledged"] is False
        assert next(c for c in foreign_privacy["consents"] if c["channel"] == "EMAIL")["granted"] is True


@pytest.mark.parametrize("method,path,body_factory", IMPLICIT_WRITE_CASES, ids=[c[1] for c in IMPLICIT_WRITE_CASES])
def test_implicit_writes_follow_manager_site(api, two_sites, method, path, body_factory):
    first, second, _ = two_sites
    paths = api.call("GET", "/api/v1/openapi.json")["paths"]
    assert method.lower() in paths.get(path, {}), f"{method} {path} is missing from generated OpenAPI"
    body = body_factory()

    owner_status, owner_body = get_response(api, path, second.token, method=method, body=body)
    assert owner_status == 200, f"Second-site {method} {path} returned {owner_status}"
    owner_result = json.loads(owner_body)
    if path == "/api/v1/autopay/run":
        assert owner_result["as_of"] == body["as_of"]
    else:
        assert owner_result["site_id"] == str(second.user["site_id"])

    foreign_status, foreign_body = get_response(api, path, first.token, method=method, body=body)
    assert foreign_status == 200, f"First-site {method} {path} returned {foreign_status}"
    foreign_result = json.loads(foreign_body)
    if path == "/api/v1/autopay/run":
        assert foreign_result["as_of"] == body["as_of"]
    else:
        assert foreign_result["site_id"] == str(first.user["site_id"])


def test_bank_matching_suggestions_follow_manager_site(api, two_sites):
    first, second, ids = two_sites
    paths = api.call("GET", "/api/v1/openapi.json")["paths"]
    path = "/api/v1/bank-matching/suggest"
    assert "post" in paths.get(path, {}), f"POST {path} is missing from generated OpenAPI"
    body = {"transfers": [{
        "reference": "nightly-owner-transfer", "amount": "1.00",
        "description": "Nightly Owner", "sender_name": "Nightly Owner",
    }]}

    owner_status, owner_body = get_response(api, path, second.token, method="POST", body=body)
    assert owner_status == 200, f"Second-site POST {path} returned {owner_status}"
    owner_units = {
        candidate["unit_id"]
        for suggestion in json.loads(owner_body)
        for candidate in suggestion["candidates"]
    }
    assert ids["unit"] in owner_units, "Second-site suggestions omitted its matching unit"

    foreign_status, foreign_body = get_response(api, path, first.token, method="POST", body=body)
    assert foreign_status == 200, f"First-site POST {path} returned {foreign_status}"
    foreign_units = {
        candidate["unit_id"]
        for suggestion in json.loads(foreign_body)
        for candidate in suggestion["candidates"]
    }
    assert ids["unit"] not in foreign_units, "First-site suggestions exposed a second-site unit"
