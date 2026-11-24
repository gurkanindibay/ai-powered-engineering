"""Reference fixture coverage for the Site Admin journey suite."""
from __future__ import annotations

import os
import re
from decimal import Decimal
from pathlib import Path

import pytest

from support.journey_attempts import (
    JourneyManifest,
    capture_failure_evidence,
    ledger_invariants,
    reclaim_stale_attempts,
    site_in_state,
    site_scoped_row_counts,
    teardown_sites,
    teardown_with_evidence,
)

E2E = Path(__file__).resolve().parents[1]
EXPECTED = {
    "F0": {"blocks": 0, "units": 0, "people": 0, "accounts": 0, "periods": 0, "liabilities": 0, "receipts": 0, "overdue": Decimal("0.00"), "advance": Decimal("0.00")},
    "F1": {"blocks": 1, "units": 7, "people": 0, "accounts": 0, "periods": 0, "liabilities": 0, "receipts": 0, "overdue": Decimal("0.00"), "advance": Decimal("0.00")},
    "F2": {"blocks": 1, "units": 7, "people": 7, "accounts": 7, "periods": 0, "liabilities": 0, "receipts": 0, "overdue": Decimal("0.00"), "advance": Decimal("0.00")},
    "F3": {"blocks": 1, "units": 7, "people": 0, "accounts": 0, "periods": 1, "liabilities": 0, "receipts": 0, "overdue": Decimal("0.00"), "advance": Decimal("0.00")},
    "F4": {"blocks": 1, "units": 7, "people": 7, "accounts": 7, "periods": 1, "liabilities": 6, "receipts": 1, "overdue": Decimal("8800.00"), "advance": Decimal("0.00")},
    "F5": {"blocks": 1, "units": 7, "people": 7, "accounts": 7, "periods": 3, "liabilities": 18, "receipts": 9, "overdue": Decimal("4567.50"), "advance": Decimal("1250.00")},
    "F6": {"blocks": 1, "units": 7, "people": 10, "accounts": 7, "periods": 3, "liabilities": 21, "receipts": 0, "overdue": Decimal("9750.00"), "advance": Decimal("0.00")},
    "F7": {"blocks": 1, "units": 7, "people": 7, "accounts": 7, "periods": 3, "liabilities": 18, "receipts": 9, "overdue": Decimal("4567.50"), "advance": Decimal("1250.00")},
}

_APPEND_ONLY_TABLES = {"audit_events", "financial_access_log"}
_MIGRATION_TABLES = {"schema_migrations", "refinery_schema_history", "_sqlx_migrations"}


def _database_row_counts(stack) -> dict[str, int]:
    tables = stack.sql("SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename;").splitlines()
    counts = {}
    for table in tables:
        if not re.fullmatch(r"[a-z_][a-z0-9_]*", table) or table in _APPEND_ONLY_TABLES | _MIGRATION_TABLES:
            continue
        counts[table] = int(stack.sql(f"SELECT COUNT(*) FROM {table};"))
    return counts


def _shared_seed_checksum(stack) -> dict[str, str]:
    queries = {
        "banks": "SELECT to_jsonb(seed_row)::text FROM system_supported_banks seed_row ORDER BY bank_code;",
        "configuration": (
            "SELECT jsonb_build_object('config_key', config_key, 'config_value', config_value, "
            "'description', description)::text FROM system_configurations ORDER BY config_key;"
        ),
        "saas_admin": "SELECT to_jsonb(seed_row)::text FROM users seed_row WHERE role = 'SAAS_ADMIN' ORDER BY id;",
    }
    return {
        name: stack.sql(
            "SELECT md5(COALESCE(string_agg(seed_row, E'\\n' ORDER BY seed_row), '')) "
            f"FROM ({query.rstrip(';')}) AS seed_rows(seed_row);"
        )
        for name, query in queries.items()
    }


@pytest.mark.covers("SC-13-07-01", "SC-13-07-02", "SC-13-07-03")
@pytest.mark.core
@pytest.mark.parametrize("state", ["F0", "F1", "F2", "F3", "F4", "F5"])
def test_site_admin_reference_fixtures(state, request, api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    seed_checksum = _shared_seed_checksum(stack)
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    fixture = None
    try:
        fixture = site_in_state(state, api=api, stack=stack, saas=saas, manifest=manifest)
        overview = ledger_invariants(api, fixture.manager, fixture.site_id, stage=state)
        expected = EXPECTED[state]

        assert len(overview["flats"]) == expected["units"]
        assert len(fixture.unit_ids) == expected["units"]
        assert stack.sql(f"SELECT COUNT(*) FROM blocks WHERE site_id = {int(fixture.site_id)};") == str(expected["blocks"])
        assert Decimal(str(overview["summary"]["total_overdue_with_interest"])) == expected["overdue"]
        assert Decimal(str(overview["summary"]["total_advance_balance"])) == expected["advance"]
        assert len(overview["available_periods"]) == expected["periods"]
        assert stack.sql(
            f"SELECT COUNT(*) FROM persons WHERE site_id = {int(fixture.site_id)} "
            "AND person_type IN ('HOME_OWNER', 'HOME_RESIDENT');"
        ) == str(expected["people"])
        assert stack.sql(
            f"SELECT COUNT(*) FROM users WHERE site_id = {int(fixture.site_id)} "
            "AND role IN ('HOME_OWNER', 'HOME_RESIDENT') AND is_active AND NOT must_change_password;"
        ) == str(expected["accounts"])
        assert stack.sql(f"SELECT COUNT(*) FROM dues_periods WHERE site_id = {int(fixture.site_id)};") == str(expected["periods"])
        assert stack.sql(
            "SELECT COUNT(*) FROM dues_liabilities d JOIN units u ON u.id = d.unit_id "
            f"WHERE u.site_id = {int(fixture.site_id)};"
        ) == str(expected["liabilities"])
        assert stack.sql(f"SELECT COUNT(*) FROM payment_receipts WHERE site_id = {int(fixture.site_id)};") == str(expected["receipts"])
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
    else:
        site_ids = list(manifest.site_ids)
        user_ids = list(manifest.user_ids)
        person_ids = list(manifest.person_ids)
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)
        assert all(stack.sql(f"SELECT COUNT(*) FROM sites WHERE id = {int(site_id)};") == "0" for site_id in site_ids)
        for site_id in site_ids:
            assert not any(site_scoped_row_counts(stack, site_id).values())
        if user_ids:
            assert stack.sql(f"SELECT COUNT(*) FROM users WHERE id IN ({', '.join(user_ids)});") == "0"
        if person_ids:
            assert stack.sql(f"SELECT COUNT(*) FROM persons WHERE id IN ({', '.join(person_ids)});") == "0"
        assert _shared_seed_checksum(stack) == seed_checksum


@pytest.mark.covers("SC-13-07-10", "SC-13-07-02", "SC-13-07-03")
@pytest.mark.core
@pytest.mark.parametrize("state", ["F6", "F7"])
def test_site_admin_historical_reference_fixtures(state, request, api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    seed_checksum = _shared_seed_checksum(stack)
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    fixture = None
    try:
        fixture = site_in_state(state, api=api, stack=stack, saas=saas, manifest=manifest)
        overview = ledger_invariants(api, fixture.manager, fixture.site_id, stage=state)
        expected = EXPECTED[state]

        assert len(overview["flats"]) == expected["units"]
        assert len(fixture.unit_ids) == expected["units"]
        assert stack.sql(f"SELECT COUNT(*) FROM blocks WHERE site_id = {int(fixture.site_id)};") == str(expected["blocks"])
        assert Decimal(str(overview["summary"]["total_overdue_with_interest"])) == expected["overdue"]
        assert Decimal(str(overview["summary"]["total_advance_balance"])) == expected["advance"]
        assert len(overview["available_periods"]) == expected["periods"]
        assert stack.sql(
            f"SELECT COUNT(*) FROM persons WHERE site_id = {int(fixture.site_id)} "
            "AND person_type IN ('HOME_OWNER', 'HOME_RESIDENT');"
        ) == str(expected["people"])
        assert stack.sql(
            f"SELECT COUNT(*) FROM users WHERE site_id = {int(fixture.site_id)} "
            "AND role IN ('HOME_OWNER', 'HOME_RESIDENT') AND is_active AND NOT must_change_password;"
        ) == str(expected["accounts"])
        assert stack.sql(f"SELECT COUNT(*) FROM dues_periods WHERE site_id = {int(fixture.site_id)};") == str(expected["periods"])
        assert stack.sql(
            "SELECT COUNT(*) FROM dues_liabilities d JOIN units u ON u.id = d.unit_id "
            f"WHERE u.site_id = {int(fixture.site_id)};"
        ) == str(expected["liabilities"])
        assert stack.sql(f"SELECT COUNT(*) FROM payment_receipts WHERE site_id = {int(fixture.site_id)};") == str(expected["receipts"])
        if state == "F7":
            assert stack.sql(
                f"SELECT status FROM dues_periods WHERE site_id = {int(fixture.site_id)} AND period_name = 'Eylül 2026';"
            ) == "CLOSED"
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
    else:
        site_ids = list(manifest.site_ids)
        user_ids = list(manifest.user_ids)
        person_ids = list(manifest.person_ids)
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)
        assert all(stack.sql(f"SELECT COUNT(*) FROM sites WHERE id = {int(site_id)};") == "0" for site_id in site_ids)
        for site_id in site_ids:
            assert not any(site_scoped_row_counts(stack, site_id).values())
        if user_ids:
            assert stack.sql(f"SELECT COUNT(*) FROM users WHERE id IN ({', '.join(user_ids)});") == "0"
        if person_ids:
            assert stack.sql(f"SELECT COUNT(*) FROM persons WHERE id IN ({', '.join(person_ids)});") == "0"
        assert _shared_seed_checksum(stack) == seed_checksum


@pytest.mark.covers("SC-13-07-05")
@pytest.mark.core
def test_teardown_works_after_half_built_state(request, api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    seed_checksum = _shared_seed_checksum(stack)
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    failure = RuntimeError("synthetic builder failure after second period accrued")
    site_id = None
    try:
        from support.journey_occupancy import build_base, tenant_move_in
        j = build_base(api=api, stack=stack, saas=saas, manifest=manifest)
        site_id = int(j.site_id)
        j.accrue("Eylül 2026")  # first period
        j.clock.advance_to("2026-10-11")
        tenant_move_in(j, 2, "Selin Demir", "selin")
        j.accrue("Ekim 2026")  # second period accrued
        raise failure
    except BaseException as err:
        try:
            teardown_with_evidence(stack, manifest, failed=err, capture_evidence=manifest.save)
        except BaseException:
            pass
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)

    assert site_id is not None
    assert stack.sql(f"SELECT COUNT(*) FROM sites WHERE id = {site_id};") == "0"
    assert not any(site_scoped_row_counts(stack, site_id).values())
    assert _shared_seed_checksum(stack) == seed_checksum


@pytest.mark.covers("SC-13-05-16")
@pytest.mark.core
@pytest.mark.role_manager
@pytest.mark.parametrize("state", ["F4", "F5", "F6", "F7"])
def test_balances_identical_after_backend_restart(state, request, api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    seed_checksum = _shared_seed_checksum(stack)
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    fixture = None
    try:
        fixture = site_in_state(state, api=api, stack=stack, saas=saas, manifest=manifest)
        overview_before = api.site_overview(fixture.manager, fixture.site_id)
        statements_before = [api.resident_statement(fixture.manager, uid) for uid in fixture.unit_ids]

        stack.restart_backend()
        api.clock.set_date("2026-11-19")
        manager = api.login(fixture.manager_email, fixture.manager_password)

        overview_after = api.site_overview(manager, fixture.site_id)
        statements_after = [api.resident_statement(manager, uid) for uid in fixture.unit_ids]

        def normalize_summary(s: dict) -> dict:
            return {
                k: Decimal(str(v))
                if k in ("total_expected", "total_collected", "total_overdue_with_interest", "total_advance_balance")
                else v
                for k, v in s.items()
            }

        assert normalize_summary(overview_before["summary"]) == normalize_summary(overview_after["summary"])
        for b, a in zip(overview_before["flats"], overview_after["flats"]):
            assert Decimal(str(b["amount_due"])) == Decimal(str(a["amount_due"]))
            assert Decimal(str(b["advance_balance"])) == Decimal(str(a["advance_balance"]))
            assert b["is_paid"] == a["is_paid"]
        for sb, sa in zip(statements_before, statements_after):
            assert sb["debtors"] == sa["debtors"]

        ledger_invariants(api, manager, fixture.site_id, stage=f"{state}-restart")
    finally:
        user_ids = list(manifest.user_ids)
        person_ids = list(manifest.person_ids)
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)
        if user_ids:
            assert stack.sql(f"SELECT COUNT(*) FROM users WHERE id IN ({', '.join(user_ids)});") == "0"
        if person_ids:
            assert stack.sql(f"SELECT COUNT(*) FROM persons WHERE id IN ({', '.join(person_ids)});") == "0"
        assert _shared_seed_checksum(stack) == seed_checksum


@pytest.mark.covers("SC-13-07-04", "SC-13-07-07", "SC-13-07-09")
@pytest.mark.core
def test_failed_attempt_evidence_and_retry_cleanup_are_isolated(request, api, actors, stack, monkeypatch):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    baseline_rows = _database_row_counts(stack)
    seed_checksum = _shared_seed_checksum(stack)
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys", request.node.nodeid,
        os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    other_manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys", request.node.nodeid + "-other",
        os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    restart_count = 0
    original_restart = stack.restart_backend

    def count_restart(*, preserve_e2e_clock=True):
        nonlocal restart_count
        restart_count += 1
        original_restart(preserve_e2e_clock=preserve_e2e_clock)

    monkeypatch.setattr(stack, "restart_backend", count_restart)
    try:
        first = site_in_state("F5", api=api, stack=stack, saas=saas, manifest=manifest)
        second = site_in_state("F4", api=api, stack=stack, saas=saas, manifest=other_manifest)
        first_user_ids, first_person_ids = list(manifest.user_ids), list(manifest.person_ids)
        second_site_id = second.site_id
        restarts_before_cleanup = restart_count
        failure = AssertionError("synthetic journey failure")

        def capture_then_fail():
            capture_failure_evidence(stack, api, manifest)
            raise OSError("evidence export failed")

        with pytest.raises(BaseExceptionGroup) as raised:
            teardown_with_evidence(
                stack, manifest, failed=failure, capture_evidence=capture_then_fail, restart=False,
            )
        assert failure in raised.value.exceptions
        assert any(isinstance(error, OSError) for error in raised.value.exceptions)
        saved = manifest.path.read_text(encoding="utf-8")
        assert "failure_evidence" in saved
        assert "Authorization" not in saved and "@journey.e2e.test" not in saved

        teardown_sites(stack, manifest, restart=False)
        assert not any(site_scoped_row_counts(stack, first.site_id).values())
        assert stack.sql(f"SELECT COUNT(*) FROM users WHERE id IN ({', '.join(first_user_ids)});") == "0"
        assert stack.sql(f"SELECT COUNT(*) FROM persons WHERE id IN ({', '.join(first_person_ids)});") == "0"
        assert stack.sql(f"SELECT COUNT(*) FROM sites WHERE id = {int(second_site_id)};") == "1"
        assert stack.sql(f"SELECT COUNT(*) FROM units WHERE site_id = {int(second_site_id)};") == "7"
        teardown_sites(stack, other_manifest, restart=True)
        assert restart_count == restarts_before_cleanup + 1
        assert _database_row_counts(stack) == baseline_rows
        assert _shared_seed_checksum(stack) == seed_checksum
    finally:
        if not manifest.teardown_completed:
            teardown_sites(stack, manifest)
        if not other_manifest.teardown_completed:
            teardown_sites(stack, other_manifest)


@pytest.mark.covers("SC-13-07-06")
@pytest.mark.core
def test_parallel_journey_managers_only_see_their_site_data(request, api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys", request.node.nodeid,
        os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    try:
        first = site_in_state("F5", api=api, stack=stack, saas=saas, manifest=manifest, name_suffix="first")
        second = site_in_state("F4", api=api, stack=stack, saas=saas, manifest=manifest, name_suffix="second")
        for own, other, expected_outstanding in (
            (first, second, EXPECTED["F5"]["overdue"]),
            (second, first, EXPECTED["F4"]["overdue"]),
        ):
            overview = api.site_overview(own.manager, own.site_id)
            assert Decimal(str(overview["summary"]["total_overdue_with_interest"])) == expected_outstanding
            own_units = {str(unit["id"]) for unit in overview["flats"]}
            assert own_units == set(own.unit_ids)
            assert not (own_units & set(other.unit_ids))
            listed_people = api.call(
                "GET", f"/api/v1/site-admin/persons?site_id={own.site_id}", own.manager.token,
            ).get("items", [])
            listed_person_ids = {str(person["person_id"]) for person in listed_people}
            assert set(own.person_ids) <= listed_person_ids
            assert not (listed_person_ids & set(other.person_ids))
            stream_ids = {
                str(entry["unit_id"]) for entry in api.payment_stream(own.manager).get("entries", [])
                if entry.get("unit_id") is not None
            }
            assert stream_ids
            assert stream_ids <= own_units
            assert not (stream_ids & set(other.unit_ids))
    finally:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)


@pytest.mark.covers("SC-13-07-08")
@pytest.mark.core
def test_stale_attempt_recovery_preserves_live_attempt(request, api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    stale = JourneyManifest.create(
        E2E / ".artifacts" / "journeys", request.node.nodeid + "-stale",
        os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    active = JourneyManifest.create(
        E2E / ".artifacts" / "journeys", request.node.nodeid + "-active",
        os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    try:
        stale_fixture = site_in_state("F1", api=api, stack=stack, saas=saas, manifest=stale)
        active_fixture = site_in_state("F1", api=api, stack=stack, saas=saas, manifest=active)
        stale_user_id = stale.user_ids[0]
        stale.release_lock()  # Simulate process exit after creating resources.
        reclaimed = reclaim_stale_attempts(stack, E2E / ".artifacts" / "journeys")
        assert stale.attempt_id in reclaimed
        assert stack.sql(f"SELECT COUNT(*) FROM sites WHERE id = {int(stale_fixture.site_id)};") == "0"
        assert stack.sql(f"SELECT COUNT(*) FROM users WHERE id = {int(stale_user_id)};") == "0"
        assert stack.sql(f"SELECT COUNT(*) FROM sites WHERE id = {int(active_fixture.site_id)};") == "1"
        assert stack.sql(f"SELECT COUNT(*) FROM users WHERE id = {int(active.user_ids[0])};") == "1"
        assert stack.sql(f"SELECT COUNT(*) FROM units WHERE site_id = {int(active_fixture.site_id)};") == "7"
        active_summary = api.site_overview(active_fixture.manager, active_fixture.site_id)["summary"]
        assert Decimal(str(active_summary["total_overdue_with_interest"])) == Decimal("0.00")
        assert Decimal(str(active_summary["total_advance_balance"])) == Decimal("0.00")
    finally:
        if not JourneyManifest.load(stale.path).teardown_completed:
            teardown_sites(stack, stale)
        if not active.teardown_completed:
            teardown_sites(stack, active)
