"""Journey tests for tenant and site data isolation across sites and resident accounts (EPIC-13 STORY-13-10)."""
from __future__ import annotations

import json
import os
import urllib.error
import urllib.parse
import urllib.request
from decimal import Decimal
from pathlib import Path

import pytest

from support.api import Api
from support.journey_attempts import (
    JourneyManifest,
    _slug,
    site_in_state,
    teardown_with_evidence,
)

E2E = Path(__file__).resolve().parents[1]


def http_call(
    api: Api,
    method: str,
    path: str,
    token: str | None = None,
    body: object | None = None,
) -> tuple[int, bytes, dict | list | None]:
    data = json.dumps(body).encode() if body is not None else (b"{}" if method in ("POST", "PUT") else None)
    req = urllib.request.Request(api.base + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            status = resp.status
            raw = resp.read()
    except urllib.error.HTTPError as exc:
        status = exc.code
        raw = exc.read()
    parsed = None
    if raw:
        try:
            parsed = json.loads(raw.decode())
        except Exception:
            parsed = None
    return status, raw, parsed


def create_manifest(request) -> JourneyManifest:
    return JourneyManifest.create(
        E2E / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )


@pytest.mark.covers("SC-13-10-01")
@pytest.mark.core
@pytest.mark.role_manager
def test_manager_lists_and_searches_are_site_scoped(request, api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = create_manifest(request)
    try:
        site_a = site_in_state("F2", api=api, stack=stack, saas=saas, manifest=manifest, name_suffix="a")
        site_b = site_in_state("F2", api=api, stack=stack, saas=saas, manifest=manifest, name_suffix="b")
        attempt_b = _slug(f"{manifest.attempt_id}b")

        # Record distinctive payments
        api.record_manual_payment(site_a.manager, site_a.unit_ids[0], Decimal("510.00"), "Ayşe Kaya", payer_role="OWNER")
        api.record_manual_payment(site_b.manager, site_b.unit_ids[0], Decimal("520.00"), "Ayşe Kaya", payer_role="OWNER")

        # 1. Unit directory (overview)
        ov_a = api.site_overview(site_a.manager, site_a.site_id)
        unit_ids_a = {str(f["id"]) for f in ov_a["flats"]}
        assert unit_ids_a == set(site_a.unit_ids)
        assert not (unit_ids_a & set(site_b.unit_ids))

        ov_b = api.site_overview(site_b.manager, site_b.site_id)
        unit_ids_b = {str(f["id"]) for f in ov_b["flats"]}
        assert unit_ids_b == set(site_b.unit_ids)
        assert not (unit_ids_b & set(site_a.unit_ids))

        # 2. Person search
        status, _, res_filter = http_call(
            api, "GET", f"/api/v1/site-admin/persons/search?site_id={site_a.site_id}&q={attempt_b}", site_a.manager.token
        )
        assert status == 200
        assert len(res_filter.get("items", [])) == 0

        status, _, res_all = http_call(
            api, "GET", f"/api/v1/site-admin/persons?site_id={site_a.site_id}", site_a.manager.token
        )
        assert status == 200
        assert len(res_all.get("items", [])) == 7
        assert all(str(p["id"]) in site_a.person_ids for p in res_all.get("items", []))

        # 3. Payment stream
        stream_a = api.payment_stream(site_a.manager)
        amounts_a = {Decimal(str(e.get("amount", "0"))) for e in stream_a.get("entries", [])}
        assert Decimal("510.00") in amounts_a
        assert Decimal("520.00") not in amounts_a

        stream_b = api.payment_stream(site_b.manager)
        amounts_b = {Decimal(str(e.get("amount", "0"))) for e in stream_b.get("entries", [])}
        assert Decimal("520.00") in amounts_b
        assert Decimal("510.00") not in amounts_b

        # 4. Collection report (debt aging)
        status_rep_a, _, report_a = http_call(
            api, "GET", f"/api/v1/payments/debt-aging?site_id={site_a.site_id}", site_a.manager.token
        )
        assert status_rep_a == 200
        assert str(report_a.get("site_id")) == str(site_a.site_id)

        status_rep_b, _, report_b = http_call(
            api, "GET", f"/api/v1/payments/debt-aging?site_id={site_b.site_id}", site_b.manager.token
        )
        assert status_rep_b == 200
        assert str(report_b.get("site_id")) == str(site_b.site_id)
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)


@pytest.mark.covers("SC-13-10-02")
@pytest.mark.core
@pytest.mark.role_manager
def test_direct_reads_and_downloads_require_site_access(request, api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = create_manifest(request)
    try:
        site_a = site_in_state("F2", api=api, stack=stack, saas=saas, manifest=manifest, name_suffix="a")
        site_b = site_in_state("F2", api=api, stack=stack, saas=saas, manifest=manifest, name_suffix="b")

        # Setup site B resources
        person_b_id = site_b.person_ids[0]
        period_b = api.create_period(site_b.manager, "Ekim 2026", "2026-10-15")
        period_b_id = str(period_b["id"])
        rcpt_b = api.record_manual_payment(site_b.manager, site_b.unit_ids[0], Decimal("400.00"), "Ayşe Kaya", payer_role="OWNER")
        rcpt_b_id = str(rcpt_b["id"])
        budget_b = api.call(
            "POST", "/api/v1/operating-budgets", site_b.manager.token,
            body={"fiscal_year": 2026, "total_budget": "100000.00", "lines": []}
        )
        budget_b_id = str(budget_b["id"])

        # 1. Person card
        status, raw, _ = http_call(api, "GET", f"/api/v1/site-admin/persons/{person_b_id}/card?site_id={site_a.site_id}", site_a.manager.token)
        assert status in (403, 404)
        assert str(person_b_id).encode() not in raw

        status_b, _, _ = http_call(api, "GET", f"/api/v1/site-admin/persons/{person_b_id}/card?site_id={site_b.site_id}", site_b.manager.token)
        assert status_b == 200

        # 2. Billing period summary
        status, _, _ = http_call(api, "GET", f"/api/v1/dues/periods/{period_b_id}/summary", site_a.manager.token)
        assert status in (403, 404)

        status_b, _, _ = http_call(api, "GET", f"/api/v1/dues/periods/{period_b_id}/summary", site_b.manager.token)
        assert status_b == 200

        # 3. Receipt JSON
        status, raw, _ = http_call(api, "GET", f"/api/v1/payments/receipts/{rcpt_b_id}", site_a.manager.token)
        assert status in (403, 404)
        assert b"400.00" not in raw

        status_b, _, json_b = http_call(api, "GET", f"/api/v1/payments/receipts/{rcpt_b_id}", site_b.manager.token)
        assert status_b == 200
        assert json_b.get("receipt_number") == rcpt_b.get("receipt_number")

        # 4. Receipt PDF
        status, raw, _ = http_call(api, "GET", f"/api/v1/payments/receipts/{rcpt_b_id}/pdf", site_a.manager.token)
        assert status in (403, 404)
        assert not raw.startswith(b"%PDF")

        status_b, raw_b, _ = http_call(api, "GET", f"/api/v1/payments/receipts/{rcpt_b_id}/pdf", site_b.manager.token)
        assert status_b == 200
        assert raw_b.startswith(b"%PDF")

        # 5. Operating budget
        status, _, _ = http_call(api, "GET", f"/api/v1/operating-budgets/{budget_b_id}", site_a.manager.token)
        assert status in (403, 404)

        status_b, _, _ = http_call(api, "GET", f"/api/v1/operating-budgets/{budget_b_id}", site_b.manager.token)
        assert status_b == 200
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)


@pytest.mark.covers("SC-13-10-03")
@pytest.mark.core
@pytest.mark.role_manager
def test_site_parameter_cannot_widen_manager_permissions(request, api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = create_manifest(request)
    try:
        site_a = site_in_state("F2", api=api, stack=stack, saas=saas, manifest=manifest, name_suffix="a")
        site_b = site_in_state("F2", api=api, stack=stack, saas=saas, manifest=manifest, name_suffix="b")
        attempt_b = _slug(f"{manifest.attempt_id}b")

        api.record_manual_payment(site_b.manager, site_b.unit_ids[0], Decimal("350.00"), "Ayşe Kaya", payer_role="OWNER")

        # Manager A requests payment stream with site B selector
        status_s, raw_s, stream_resp = http_call(
            api, "GET", f"/api/v1/payments/stream?site_id={site_b.site_id}", site_a.manager.token
        )
        assert status_s in (200, 400, 403)
        assert b"350.00" not in raw_s
        if status_s == 200 and isinstance(stream_resp, dict):
            for entry in stream_resp.get("entries", []):
                assert str(entry.get("site_id")) != str(site_b.site_id)

        # Manager A requests people export with site B selector
        status_e, raw_e, _ = http_call(
            api, "GET", f"/api/v1/site-admin/persons/export?site_id={site_b.site_id}", site_a.manager.token
        )
        assert status_e in (200, 400, 403)
        assert attempt_b.encode() not in raw_e

        # Positive controls: Manager B reads site B stream and export
        b_stream = api.payment_stream(site_b.manager)
        assert any(Decimal(str(e.get("amount", "0"))) == Decimal("350.00") for e in b_stream.get("entries", []))

        status_be, raw_be, _ = http_call(
            api, "GET", f"/api/v1/site-admin/persons/export?site_id={site_b.site_id}", site_b.manager.token
        )
        assert status_be == 200
        assert attempt_b.encode() in raw_be
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)


@pytest.mark.covers("SC-13-10-04")
@pytest.mark.core
@pytest.mark.role_manager
def test_manager_cannot_mutate_another_site_records(request, api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = create_manifest(request)
    try:
        site_a = site_in_state("F2", api=api, stack=stack, saas=saas, manifest=manifest, name_suffix="a")
        site_b = site_in_state("F2", api=api, stack=stack, saas=saas, manifest=manifest, name_suffix="b")

        # 1. Record a payment
        status_pay, _, _ = http_call(
            api, "POST", "/api/v1/payments/record-manual", site_a.manager.token,
            body={
                "site_id": site_a.site_id,
                "unit_id": str(site_b.unit_ids[0]),
                "amount": "250.00",
                "payer_name": "Ayşe Kaya",
                "payer_role": "OWNER",
                "payment_channel": "MANUAL_CASH",
                "idempotency_key": f"deny-pay-{site_a.site_id}",
            }
        )
        assert status_pay in (400, 403, 404)
        assert stack.sql(f"SELECT COUNT(*) FROM payment_receipts WHERE site_id = {site_b.site_id};") == "0"

        rcpt_b = api.record_manual_payment(site_b.manager, site_b.unit_ids[0], Decimal("250.00"), "Ayşe Kaya", payer_role="OWNER")
        assert rcpt_b.get("receipt_number")
        assert stack.sql(f"SELECT COUNT(*) FROM payment_receipts WHERE site_id = {site_b.site_id};") == "1"

        # 2. Move out a tenant (unit 2 is tenant-occupied in F2)
        unit_b2 = site_b.unit_ids[1]
        status_move, _, _ = http_call(
            api, "POST", f"/api/v1/site-admin/units/{unit_b2}/move-out?site_id={site_a.site_id}", site_a.manager.token,
            body={"notes": "Illegal move out"}
        )
        assert status_move in (400, 403, 404)
        assert stack.sql(f"SELECT occupancy_status FROM units WHERE id = {unit_b2};") == "TENANT_OCCUPIED"

        api.move_out(site_b.manager, unit_b2)
        assert stack.sql(f"SELECT occupancy_status FROM units WHERE id = {unit_b2};") == "VACANT"

        # 3. Close a billing period
        period_b = api.create_period(site_b.manager, "Kasım 2026", "2026-11-15")
        period_b_id = str(period_b["id"])
        status_close, _, _ = http_call(
            api, "POST", f"/api/v1/dues/periods/{period_b_id}/close", site_a.manager.token, body={}
        )
        assert status_close in (400, 403, 404)
        assert stack.sql(f"SELECT status FROM dues_periods WHERE id = {period_b_id};") != "CLOSED"

        status_close_b, _, _ = http_call(
            api, "POST", f"/api/v1/dues/periods/{period_b_id}/close", site_b.manager.token, body={}
        )
        assert status_close_b == 200
        assert stack.sql(f"SELECT status FROM dues_periods WHERE id = {period_b_id};") == "CLOSED"
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)


@pytest.mark.covers("SC-13-10-05")
@pytest.mark.core
@pytest.mark.role_resident
def test_resident_cannot_read_another_unit_financial_records(request, api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = create_manifest(request)
    try:
        site_a = site_in_state("F2", api=api, stack=stack, saas=saas, manifest=manifest, name_suffix="a")
        site_b = site_in_state("F2", api=api, stack=stack, saas=saas, manifest=manifest, name_suffix="b")
        attempt_a = _slug(f"{manifest.attempt_id}a")

        # Selin Demir is tenant of A-2 at Site A
        unit_a2 = site_a.unit_ids[1]
        unit_a5 = site_a.unit_ids[4]
        unit_b2 = site_b.unit_ids[1]

        rcpt_a2 = api.record_manual_payment(site_a.manager, unit_a2, Decimal("450.00"), "Selin Demir", payer_role="TENANT")
        rcpt_a5 = api.record_manual_payment(site_a.manager, unit_a5, Decimal("460.00"), "Deniz Arslan", payer_role="TENANT")
        rcpt_b2 = api.record_manual_payment(site_b.manager, unit_b2, Decimal("470.00"), "Selin Demir", payer_role="TENANT")

        selin_email = f"{attempt_a}.selin@journey.e2e.test"
        selin = api.login(selin_email, site_a.manager_password)

        # Target 1: A-5 at Selin's site
        s1, r1, _ = http_call(api, "GET", f"/api/v1/residents/{unit_a5}/statement", selin.token)
        assert s1 in (403, 404)
        assert b"460.00" not in r1

        s2, r2, _ = http_call(api, "GET", f"/api/v1/payments/receipts/{rcpt_a5['id']}", selin.token)
        assert s2 in (403, 404)
        assert b"460.00" not in r2

        s3, r3, _ = http_call(api, "GET", f"/api/v1/payments/receipts/{rcpt_a5['id']}/pdf", selin.token)
        assert s3 in (403, 404)
        assert not r3.startswith(b"%PDF")

        # Target 2: A-2 at a different site
        s4, r4, _ = http_call(api, "GET", f"/api/v1/residents/{unit_b2}/statement", selin.token)
        assert s4 in (403, 404)
        assert b"470.00" not in r4

        s5, r5, _ = http_call(api, "GET", f"/api/v1/payments/receipts/{rcpt_b2['id']}", selin.token)
        assert s5 in (403, 404)
        assert b"470.00" not in r5

        s6, r6, _ = http_call(api, "GET", f"/api/v1/payments/receipts/{rcpt_b2['id']}/pdf", selin.token)
        assert s6 in (403, 404)
        assert not r6.startswith(b"%PDF")

        # Positive controls: Selin reads her own unit records
        s_own, _, stmt_own = http_call(api, "GET", f"/api/v1/residents/{unit_a2}/statement", selin.token)
        assert s_own == 200
        rcpt_nums = [r.get("receipt_number") for r in stmt_own.get("receipts", [])]
        assert rcpt_a2.get("receipt_number") in rcpt_nums

        s_rcpt, _, _ = http_call(api, "GET", f"/api/v1/payments/receipts/{rcpt_a2['id']}", selin.token)
        assert s_rcpt == 200

        s_pdf, r_pdf, _ = http_call(api, "GET", f"/api/v1/payments/receipts/{rcpt_a2['id']}/pdf", selin.token)
        assert s_pdf == 200
        assert r_pdf.startswith(b"%PDF")
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)


@pytest.mark.covers("SC-13-10-06")
@pytest.mark.core
@pytest.mark.role_resident
def test_tenant_statement_excludes_owner_private_transactions(request, api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = create_manifest(request)
    try:
        site_a = site_in_state("F2", api=api, stack=stack, saas=saas, manifest=manifest, name_suffix="a")
        attempt_a = _slug(f"{manifest.attempt_id}a")
        unit_2 = site_a.unit_ids[1]

        # Ahmet Yılmaz (owner) and Selin Demir (tenant)
        selin_email = f"{attempt_a}.selin@journey.e2e.test"
        ahmet_email = f"{attempt_a}.ahmet@journey.e2e.test"

        selin_person_id = stack.sql(f"SELECT id FROM persons WHERE site_id = {site_a.site_id} AND email = '{selin_email}';")
        ahmet_person_id = stack.sql(f"SELECT id FROM persons WHERE site_id = {site_a.site_id} AND email = '{ahmet_email}';")

        # Tenant owes 1500 operational principal; owner has 1000 capital liability
        stack.sql(
            "BEGIN; "
            f"INSERT INTO dues_liabilities (unit_id, period, debtor_type, expense_type, liable_person_id, "
            f"principal_amount, due_date, status) VALUES "
            f"({unit_2}, 'Ekim 2026', 'TENANT', 'OPERATIONAL_DUES', {selin_person_id}, 1500.00, DATE '2026-10-15', 'PENDING'); "
            f"INSERT INTO dues_liabilities (unit_id, period, debtor_type, expense_type, liable_person_id, "
            f"principal_amount, due_date, status) VALUES "
            f"({unit_2}, 'Ekim 2026', 'OWNER', 'CAPITAL_DUES', {ahmet_person_id}, 1000.00, DATE '2026-10-15', 'PENDING'); "
            "COMMIT;"
        )

        tenant_rcpt = api.record_manual_payment(site_a.manager, unit_2, Decimal("500.00"), "Selin Demir", payer_role="TENANT")
        owner_rcpt = api.record_manual_payment(site_a.manager, unit_2, Decimal("1000.00"), "Ahmet Yılmaz", payer_role="OWNER")
        stack.restart_backend()

        selin = api.login(selin_email, site_a.manager_password)
        stmt = api.call("GET", f"/api/v1/residents/{unit_2}/statement", selin.token)

        # Tenant's operational debt and own receipt are visible
        open_items = [item for d in stmt.get("debtors", []) for item in d.get("open_items", [])]
        assert any(Decimal(str(item.get("principal_outstanding", "0"))) == Decimal("1000.00") for item in open_items)
        rcpt_numbers = [r.get("receipt_number") for r in stmt.get("receipts", [])]
        assert tenant_rcpt.get("receipt_number") in rcpt_numbers

        # Owner's balance and private receipt are absent from statement
        debtor_types = [d.get("debtor_type") for d in stmt.get("debtors", [])]
        assert "OWNER" not in debtor_types
        assert owner_rcpt.get("receipt_number") not in rcpt_numbers
        assert not any(item.get("expense_type") == "CAPITAL_DUES" for item in open_items)

        # Tenant requests owner's private receipt JSON and PDF
        status_j, raw_j, _ = http_call(api, "GET", f"/api/v1/payments/receipts/{owner_rcpt['id']}", selin.token)
        assert status_j in (403, 404)

        status_p, raw_p, _ = http_call(api, "GET", f"/api/v1/payments/receipts/{owner_rcpt['id']}/pdf", selin.token)
        assert status_p in (403, 404)
        assert not raw_p.startswith(b"%PDF")

        # Owner can retrieve their own receipt
        ahmet = api.login(ahmet_email, site_a.manager_password)
        status_oj, _, oj = http_call(api, "GET", f"/api/v1/payments/receipts/{owner_rcpt['id']}", ahmet.token)
        assert status_oj == 200
        assert oj.get("receipt_number") == owner_rcpt.get("receipt_number")

        status_op, op, _ = http_call(api, "GET", f"/api/v1/payments/receipts/{owner_rcpt['id']}/pdf", ahmet.token)
        assert status_op == 200
        assert op.startswith(b"%PDF")
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)


@pytest.mark.covers("SC-13-10-07")
@pytest.mark.core
@pytest.mark.role_resident
def test_replacing_tenant_keeps_history_and_receipts_private(request, api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = create_manifest(request)
    try:
        site_a = site_in_state("F2", api=api, stack=stack, saas=saas, manifest=manifest, name_suffix="a")
        attempt_a = _slug(f"{manifest.attempt_id}a")
        unit_2 = site_a.unit_ids[1]

        # Initial tenant Selin Demir signs in and makes payment
        selin_email = f"{attempt_a}.selin@journey.e2e.test"
        selin = api.login(selin_email, site_a.manager_password)
        rcpt_selin = api.record_manual_payment(site_a.manager, unit_2, Decimal("600.00"), "Selin Demir", payer_role="TENANT")

        # Manager replaces tenant with Mert Kılıç
        mert_email = f"{attempt_a}.mert@journey.e2e.test"
        api.move_in(site_a.manager, unit_2, "Mert Kılıç", mert_email, role="TENANT")

        mert_person_id = stack.sql(f"SELECT id FROM persons WHERE site_id = {site_a.site_id} AND email = '{mert_email}';")
        manifest.record("person_ids", mert_person_id)
        pwd_hash = stack.sql(f"SELECT password_hash FROM users WHERE email = '{site_a.manager_email}';")
        mert_user_id = stack.sql(
            f"INSERT INTO users (site_id, person_id, email, password_hash, role, must_change_password) "
            f"VALUES ({site_a.site_id}, {mert_person_id}, '{mert_email}', '{pwd_hash}', 'HOME_RESIDENT', FALSE) "
            f"ON CONFLICT (email) DO UPDATE SET password_hash = '{pwd_hash}', must_change_password = FALSE RETURNING id;"
        ).splitlines()[0]
        manifest.record("user_ids", mert_user_id)
        stack.sql(
            f"INSERT INTO user_site_roles (user_id, site_id, role) VALUES ({mert_user_id}, {site_a.site_id}, 'HOME_RESIDENT') "
            f"ON CONFLICT DO NOTHING;"
        )
        stack.sql(f"UPDATE units SET tenant_user_id = '{mert_user_id}' WHERE id = {unit_2};")
        stack.restart_backend()

        mert = api.login(mert_email, site_a.manager_password)
        rcpt_mert = api.record_manual_payment(site_a.manager, unit_2, Decimal("700.00"), "Mert Kılıç", payer_role="TENANT")

        # Mert reads current statement
        stmt_mert = api.call("GET", f"/api/v1/residents/{unit_2}/statement", mert.token)
        mert_rcpt_nums = [r.get("receipt_number") for r in stmt_mert.get("receipts", [])]
        assert rcpt_mert.get("receipt_number") in mert_rcpt_nums
        assert rcpt_selin.get("receipt_number") not in mert_rcpt_nums

        # Selin's prior session reading statement
        status_s, _, stmt_selin = http_call(api, "GET", f"/api/v1/residents/{unit_2}/statement", selin.token)
        if status_s == 200 and isinstance(stmt_selin, dict):
            selin_rcpt_nums = [r.get("receipt_number") for r in stmt_selin.get("receipts", [])]
            assert rcpt_mert.get("receipt_number") not in selin_rcpt_nums

        # Neither can download the other's private receipt
        s1, _, _ = http_call(api, "GET", f"/api/v1/payments/receipts/{rcpt_mert['id']}", selin.token)
        assert s1 in (403, 404)
        s2, _, _ = http_call(api, "GET", f"/api/v1/payments/receipts/{rcpt_mert['id']}/pdf", selin.token)
        assert s2 in (403, 404)

        s3, _, _ = http_call(api, "GET", f"/api/v1/payments/receipts/{rcpt_selin['id']}", mert.token)
        assert s3 in (403, 404)
        s4, _, _ = http_call(api, "GET", f"/api/v1/payments/receipts/{rcpt_selin['id']}/pdf", mert.token)
        assert s4 in (403, 404)

        # Selin's prior session cannot make current-occupant change
        s5, _, _ = http_call(
            api, "POST", f"/api/v1/residents/{unit_2}/matching-criteria/ibans", selin.token,
            body={"sender_iban": "TR110006200000000123456789"}
        )
        assert s5 in (400, 403, 404)

        # Mert cannot access Selin's household contact details
        s6, r6, _ = http_call(api, "GET", f"/api/v1/home-residents/members/{unit_2}", mert.token)
        assert s6 == 200
        assert b"selin" not in r6.lower()
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)
