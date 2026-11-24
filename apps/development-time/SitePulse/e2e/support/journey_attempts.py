"""Site-scoped manifests and SQL-only teardown for admin journey attempts.

Journey attempts can share an E2E database. The manifest is written as resources
are created, so teardown can be retried after a process or evidence-capture
failure without truncating another attempt's data.
Attempt locks use POSIX ``flock``; the E2E runner targets Linux and macOS.
"""
from __future__ import annotations

import fcntl
import json
import re
import uuid
import warnings
from dataclasses import dataclass, field
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Callable, TextIO

from decimal import Decimal

from .api import Api, Session
from .stack import E2EStack


_SITE_SCOPED_DELETES = (
    "payment_allocations WHERE payment_entry_id IN (SELECT id FROM payment_entries WHERE site_id = {site})",
    "payment_allocations WHERE dues_liability_id IN (SELECT d.id FROM dues_liabilities d JOIN units u ON u.id = d.unit_id WHERE u.site_id = {site})",
    "processed_bank_webhooks WHERE site_id = {site} OR receipt_id IN (SELECT id FROM payment_receipts WHERE site_id = {site}) OR site_bank_account_id IN (SELECT id FROM site_bank_accounts WHERE site_id = {site})",
    "payment_entries WHERE site_id = {site} AND reverses_entry_id IS NOT NULL",
    "payment_entries WHERE site_id = {site}",
    "payment_idempotency_keys WHERE site_id = {site}",
    "payment_intents WHERE site_id = {site}",
    "payment_receipts WHERE site_id = {site} AND reverses_receipt_id IS NOT NULL",
    "payment_receipts WHERE site_id = {site}",
    "receipt_counters WHERE site_id = {site}",
    "advance_ledger_entries WHERE unit_id IN (SELECT id FROM units WHERE site_id = {site})",
    "advance_balances WHERE unit_id IN (SELECT id FROM units WHERE site_id = {site})",
    "debt_aging_snapshots WHERE site_id = {site}",
    "reconciliation_queue WHERE site_id = {site}",
    "unit_sender_ibans WHERE unit_id IN (SELECT id FROM units WHERE site_id = {site})",
    "unit_payer_names WHERE unit_id IN (SELECT id FROM units WHERE site_id = {site})",
    "late_fee_accruals WHERE site_id = {site}",
    "ledger_adjustments WHERE site_id = {site}",
    "accrual_corrections WHERE site_id = {site}",
    "dues_liabilities WHERE unit_id IN (SELECT id FROM units WHERE site_id = {site})",
    "operating_budgets WHERE site_id = {site}",
    "occupancy_transitions WHERE site_id = {site}",
    "occupancy_members WHERE occupancy_id IN (SELECT o.id FROM unit_occupancies o JOIN units u ON u.id = o.unit_id WHERE u.site_id = {site})",
    "unit_occupancies WHERE unit_id IN (SELECT id FROM units WHERE site_id = {site})",
    "unit_ownerships WHERE unit_id IN (SELECT id FROM units WHERE site_id = {site})",
    "invitation_tokens WHERE site_id = {site}",
    "pending_registrations WHERE site_id = {site}",
    "capital_contractor_disbursements WHERE project_id IN (SELECT id FROM capital_projects WHERE site_id = {site})",
    "capital_project_installments WHERE project_id IN (SELECT id FROM capital_projects WHERE site_id = {site})",
    "capital_projects WHERE site_id = {site}",
    "dues_period_reopen_requests WHERE site_id = {site}",
    "dues_period_snapshots WHERE site_id = {site}",
    "dues_periods WHERE site_id = {site}",
    "user_site_roles WHERE site_id = {site}",
    "account_activations WHERE site_id = {site}",
    "users WHERE site_id = {site}",
    "units WHERE site_id = {site}",
    "persons WHERE site_id = {site}",
    "blocks WHERE site_id = {site}",
    "house_types WHERE site_id = {site}",
    "site_bank_accounts WHERE site_id = {site}",
    "sites WHERE id = {site}",
)


@dataclass
class JourneyManifest:
    """Non-PII ownership record for all resources created by one scenario attempt."""

    run_id: str
    shard_id: str
    attempt_id: str
    path: Path
    site_ids: list[str] = field(default_factory=list)
    unit_ids: list[str] = field(default_factory=list)
    person_ids: list[str] = field(default_factory=list)
    user_ids: list[str] = field(default_factory=list)
    steps: list[dict] = field(default_factory=list)
    teardown_completed: bool = False
    created_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())
    database_name: str | None = None
    _lock_file: TextIO | None = field(default=None, repr=False, compare=False)

    @classmethod
    def create(cls, directory: Path, run_id: str, shard_id: str, attempt_id: str | None = None) -> "JourneyManifest":
        attempt = attempt_id or uuid.uuid4().hex
        manifest = cls(run_id, shard_id, attempt, directory / f"{_slug(run_id)}-{_slug(shard_id)}-{_slug(attempt)}.json")
        manifest.path.parent.mkdir(parents=True, exist_ok=True)
        lock_file = manifest.lock_path.open("a+", encoding="utf-8")
        try:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            lock_file.close()
            raise RuntimeError(f"Journey attempt is already active: {attempt}")
        manifest._lock_file = lock_file
        manifest.save()
        return manifest

    @property
    def lock_path(self) -> Path:
        return self.path.with_suffix(self.path.suffix + ".lock")

    def bind_database(self, database_name: str) -> None:
        if self.database_name and self.database_name != database_name:
            raise ValueError("Journey manifest cannot move between databases")
        self.database_name = database_name
        self.save()

    def release_lock(self) -> None:
        if self._lock_file is not None:
            fcntl.flock(self._lock_file.fileno(), fcntl.LOCK_UN)
            self._lock_file.close()
            self._lock_file = None
        # Keep the lock path: unlinking can split flock ownership across old and new inodes.

    def record(self, resource: str, resource_id: str | int) -> None:
        if resource not in {"site_ids", "unit_ids", "person_ids", "user_ids"}:
            raise ValueError(f"Unsupported journey manifest resource: {resource}")
        value = str(resource_id)
        bucket: list[str] = getattr(self, resource)
        if value not in bucket:
            bucket.append(value)
            self.save()

    def record_step(self, name: str, details: dict | None = None) -> None:
        self.steps.append({
            "step": name,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "details": details or {},
        })
        self.save()

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        data = {
            "run_id": self.run_id,
            "shard_id": self.shard_id,
            "attempt_id": self.attempt_id,
            "created_at": self.created_at,
            "database_name": self.database_name,
            "site_ids": self.site_ids,
            "unit_ids": self.unit_ids,
            "person_ids": self.person_ids,
            "user_ids": self.user_ids,
            "steps": self.steps,
            "teardown_completed": self.teardown_completed,
        }
        temporary = self.path.with_suffix(self.path.suffix + ".tmp")
        temporary.write_text(json.dumps(data, sort_keys=True, indent=2) + "\n", encoding="utf-8")
        temporary.replace(self.path)

    @classmethod
    def load(cls, path: Path) -> "JourneyManifest":
        data = json.loads(path.read_text(encoding="utf-8"))
        manifest = cls(
            run_id=data["run_id"], shard_id=data["shard_id"], attempt_id=data["attempt_id"], path=path,
            site_ids=list(data["site_ids"]), unit_ids=list(data["unit_ids"]),
            person_ids=list(data["person_ids"]), user_ids=list(data["user_ids"]),
            steps=list(data.get("steps", [])),
            teardown_completed=bool(data["teardown_completed"]), created_at=data["created_at"],
            database_name=data.get("database_name"),
        )
        return manifest


class JourneyClock:
    """Date-only facade for the feature-gated deterministic E2E clock."""

    def __init__(self, api: Api, start_date: str) -> None:
        self.api = api
        self.current_date = _parse_date(start_date)
        self.api.e2e_clock("set_date", self.current_date.isoformat())

    def set_date(self, value: str) -> dict:
        target = _parse_date(value)
        result = self.api.e2e_clock("set_date", target.isoformat())
        self.current_date = target
        return result

    def advance_to(self, value: str) -> dict:
        target = _parse_date(value)
        if target < self.current_date:
            raise ValueError("Journey clock cannot advance to an earlier date")
        result = self.api.e2e_clock("advance_to", target.isoformat())
        self.current_date = target
        return result

    def set_instant(self, value: str) -> dict:
        """Set an exact RFC 3339 instant (for boundaries inside a UTC day); keeps the date in sync."""
        result = self.api.clock.set_instant(value)
        self.current_date = _parse_date(value[:10])
        return result

    def tick(self) -> dict:
        return self.api.e2e_clock("tick")


@dataclass(frozen=True)
class JourneyFixture:
    state: str
    site_id: str
    manager: Session
    manager_email: str
    manager_password: str
    unit_ids: tuple[str, ...]
    person_ids: tuple[str, ...]


class JourneyFixturePending(RuntimeError):
    """The requested reference state is waiting on a prerequisite in the plan."""


def site_in_state(
    state: str,
    *,
    api: Api,
    stack: E2EStack,
    saas: Session,
    manifest: JourneyManifest,
    name_suffix: str = "",
) -> JourneyFixture:
    """Build an isolated F0-F7 site and record its resources before setup work."""
    if state not in {f"F{number}" for number in range(8)}:
        raise ValueError(f"Unknown Site Admin reference state: {state!r}")
    manifest.bind_database(stack.db_name)
    if state == "F6":
        from .journey_occupancy import build_f6
        j = build_f6(api=api, stack=stack, saas=saas, manifest=manifest, name_suffix=name_suffix)
        api.clock.set_date("2026-11-19")
        all_persons = tuple(
            stack.sql(f"SELECT id FROM persons WHERE site_id = {int(j.site_id)} ORDER BY id;").splitlines()
        )
        return JourneyFixture("F6", j.site_id, j.manager, j.fixture.manager_email, j.fixture.manager_password, j.fixture.unit_ids, all_persons)

    attempt = _slug(f"{manifest.attempt_id}{name_suffix}")
    site_name = f"Journey {manifest.run_id[:30]} {attempt[:12]}"
    manager_email = f"journey.manager.{attempt}@e2e.test"
    credentials = api.create_site(saas, site_name, manager_email, admin_name="Journey Manager", blocks=())
    site_id = str(credentials["site_id"])
    manifest.record("site_ids", site_id)
    temporary_password = str(credentials["temporary_password"])
    manager_password = f"E2E-Journey-{attempt[:10]}-Permanent-1!"
    api.change_password(manager_email, temporary_password, manager_password)
    manager_user_id = api.login(manager_email, manager_password).user["id"]
    manifest.record("user_ids", manager_user_id)

    unit_ids: tuple[str, ...] = ()
    person_ids: tuple[str, ...] = ()
    site = _safe_id(site_id)
    requires_restart = False
    if state == "F0":
        # SaaS onboarding supplies a default block when the request has none.
        # F0 deliberately removes that empty structure to match the catalogue.
        stack.sql(f"DELETE FROM blocks WHERE site_id = {site};")
        requires_restart = True
    if state in {"F1", "F2", "F3", "F4", "F5", "F7"}:
        unit_ids = _create_structure(stack, site_id, manifest)
        requires_restart = True
    if state in {"F2", "F4", "F5", "F7"}:
        person_ids = _create_residents(stack, site_id, manager_user_id, manifest, attempt_slug=attempt)
    if state == "F3":
        _create_period_no_residents(stack, site_id)
        requires_restart = True
    elif state == "F4":
        _build_f4(stack, site_id, unit_ids)
        requires_restart = True
    elif state in {"F5", "F7"}:
        _build_f5(stack, site_id, unit_ids)
        if state == "F7":
            _close_september(stack, site_id)
        requires_restart = True
    if requires_restart:
        stack.restart_backend()
    if state in {"F4", "F5", "F7"}:
        api.clock.set_date("2026-11-19")

    manager = api.login(manager_email, manager_password)
    return JourneyFixture(state, site_id, manager, manager_email, manager_password, unit_ids, person_ids)


def ledger_invariants(api: Api, manager: Session, site_id: str, *, stage: str) -> dict:
    """Check the reusable API-level ledger totals at a named journey stage."""
    overview = api.site_overview(manager, site_id)
    summary = overview["summary"]
    flats = overview["flats"]
    if str(overview["site_id"]) != str(site_id):
        raise AssertionError(f"[{stage}] I10: overview returned another site")
    if int(summary["total_units_count"]) != len(flats):
        raise AssertionError(f"[{stage}] I2: site unit count differs from the unit balances")

    decimal = lambda value: Decimal(str(value))
    outstanding_from_units = sum(
        (decimal(flat["amount_due"]) for flat in flats if not bool(flat["is_paid"])), Decimal("0.00")
    )
    dashboard_outstanding = decimal(summary["total_overdue_with_interest"])
    if outstanding_from_units != dashboard_outstanding:
        raise AssertionError(f"[{stage}] I2: unit outstanding sum {outstanding_from_units} != dashboard {dashboard_outstanding}")

    unit_advances = sum((decimal(flat["advance_balance"]) for flat in flats), Decimal("0.00"))
    dashboard_advances = decimal(summary["total_advance_balance"])
    if unit_advances != dashboard_advances:
        raise AssertionError(f"[{stage}] I4: unit advance sum {unit_advances} != dashboard {dashboard_advances}")
    for flat in flats:
        if decimal(flat["amount_due"]) < Decimal("0.00"):
            raise AssertionError(f"[{stage}] I1: unit {flat['id']} has a negative displayed debt")
    return overview


def make_viban(bank_code: str | int, site_id: str | int, block_name: str, unit_number: int) -> str:
    """Generate deterministic flat virtual IBAN matching VirtualIbanService."""
    bank_code_str = str(bank_code).strip().zfill(5)
    site_id_str = str(site_id)
    site_hash = 9863791
    for b in site_id_str.encode("ascii"):
        site_hash = ((site_hash * 31) + b) & 0xFFFFFFFFFFFFFFFF
    block_hash = sum(block_name.encode("ascii")) & 0xFFFFFFFFFFFFFFFF
    site_prefix = f"{(site_hash + block_hash) % 10_000_000_000:010d}"
    bban = f"{bank_code_str}0{site_prefix}{unit_number:06d}"
    rem = int(f"{bban}292700") % 97
    check = f"{98 - rem:02d}"
    return f"TR{check}{bban}"


def _create_structure(stack: E2EStack, site_id: str, manifest: JourneyManifest) -> tuple[str, ...]:
    site = _safe_id(site_id)
    viban_updates = " ".join(
        f"UPDATE units SET virtual_iban = '{make_viban('00205', site, 'A', unit_no)}' WHERE site_id = {site} AND unit_number = {unit_no};"
        for unit_no in range(1, 8)
    )
    stack.sql(
        "BEGIN; "
        f"DELETE FROM blocks WHERE site_id = {site}; "
        f"UPDATE sites SET proration_enabled = TRUE WHERE id = {site}; "
        f"INSERT INTO blocks (site_id, block_name, total_floors) VALUES ({site}, 'A Blok', 7); "
        f"INSERT INTO house_types (site_id, type_name, dues_amount, description) VALUES "
        f"({site}, 'Flat', 1500.00, 'Journey reference tariff'), "
        f"({site}, 'Large flat', 2250.00, 'Journey reference tariff'); "
        "INSERT INTO units (block_id, site_id, unit_number, floor, land_share, occupancy_status, house_type, house_type_id, created_at) "
        f"SELECT b.id, {site}, n.unit_number, 1, 1, 'VACANT', h.type_name, h.id, TIMESTAMPTZ '2026-09-01 00:00:00+00' "
        "FROM blocks b CROSS JOIN (VALUES (1), (2), (3), (4), (5), (6), (7)) AS n(unit_number) "
        "JOIN house_types h ON h.site_id = b.site_id AND h.type_name = CASE WHEN n.unit_number = 6 THEN 'Large flat' ELSE 'Flat' END "
        f"WHERE b.site_id = {site} AND b.block_name = 'A Blok' ORDER BY n.unit_number; "
        f"{viban_updates} "
        "COMMIT;"
    )
    unit_ids = tuple(stack.sql(f"SELECT id FROM units WHERE site_id = {site} ORDER BY unit_number;").splitlines())
    if len(unit_ids) != 7:
        raise AssertionError(f"F1: expected seven units, created {len(unit_ids)}")
    for unit_id in unit_ids:
        manifest.record("unit_ids", unit_id)
    return unit_ids


def _build_f4(stack: E2EStack, site_id: str | int, unit_ids: tuple[str, ...]) -> None:
    site = _safe_id(site_id)
    u1, u2, u3, u4, u5, u6, u7 = [_safe_id(uid) for uid in unit_ids]
    sql = (
        "BEGIN; "
        f"INSERT INTO dues_periods (site_id, period_name, due_date, status) VALUES ({site}, 'Ekim 2026', DATE '2026-10-10', 'ACTIVE'); "
        "INSERT INTO dues_liabilities (unit_id, period, debtor_type, expense_type, liable_person_id, occupancy_id, principal_amount, due_date, effective_due_date, status, delay_penalty, paid_principal, paid_penalty, paid_amount, payment_date, created_at) "
        f"SELECT {u1}, 'Ekim 2026', 'OWNER', 'OPERATIONAL_DUES', u.owner_person_id, o.id, 1500.00, DATE '2026-10-10', DATE '2026-10-10', 'PAID', 0.00, 1500.00, 0.00, 1500.00, TIMESTAMPTZ '2026-10-10 10:00:00+03', TIMESTAMPTZ '2026-10-01 08:00:00+03' "
        f"FROM units u LEFT JOIN unit_occupancies o ON o.unit_id = u.id AND o.is_active WHERE u.id = {u1}; "
        "INSERT INTO dues_liabilities (unit_id, period, debtor_type, expense_type, liable_person_id, occupancy_id, principal_amount, due_date, effective_due_date, status, delay_penalty, paid_principal, paid_penalty, paid_amount, penalty_accrued_through, created_at) "
        f"SELECT {u2}, 'Ekim 2026', 'TENANT', 'OPERATIONAL_DUES', u.tenant_person_id, o.id, 1500.00, DATE '2026-10-10', DATE '2026-10-10', 'OVERDUE', 100.00, 0.00, 0.00, 0.00, DATE '2026-11-19', TIMESTAMPTZ '2026-10-01 08:00:00+03' "
        f"FROM units u LEFT JOIN unit_occupancies o ON o.unit_id = u.id AND o.is_active WHERE u.id = {u2}; "
        "INSERT INTO dues_liabilities (unit_id, period, debtor_type, expense_type, liable_person_id, occupancy_id, principal_amount, due_date, effective_due_date, status, delay_penalty, paid_principal, paid_penalty, paid_amount, penalty_accrued_through, created_at) "
        f"SELECT {u3}, 'Ekim 2026', 'OWNER', 'OPERATIONAL_DUES', u.owner_person_id, NULL, 1500.00, DATE '2026-10-10', DATE '2026-10-10', 'OVERDUE', 100.00, 0.00, 0.00, 0.00, DATE '2026-11-19', TIMESTAMPTZ '2026-10-01 08:00:00+03' "
        f"FROM units u WHERE u.id = {u3}; "
        "INSERT INTO dues_liabilities (unit_id, period, debtor_type, expense_type, liable_person_id, occupancy_id, principal_amount, due_date, effective_due_date, status, delay_penalty, paid_principal, paid_penalty, paid_amount, penalty_accrued_through, created_at) "
        f"SELECT {u4}, 'Ekim 2026', 'OWNER', 'OPERATIONAL_DUES', u.owner_person_id, o.id, 1500.00, DATE '2026-10-10', DATE '2026-10-10', 'OVERDUE', 100.00, 0.00, 0.00, 0.00, DATE '2026-11-19', TIMESTAMPTZ '2026-10-01 08:00:00+03' "
        f"FROM units u LEFT JOIN unit_occupancies o ON o.unit_id = u.id AND o.is_active WHERE u.id = {u4}; "
        "INSERT INTO dues_liabilities (unit_id, period, debtor_type, expense_type, liable_person_id, occupancy_id, principal_amount, due_date, effective_due_date, status, delay_penalty, paid_principal, paid_penalty, paid_amount, penalty_accrued_through, created_at) "
        f"SELECT {u5}, 'Ekim 2026', 'TENANT', 'OPERATIONAL_DUES', u.tenant_person_id, o.id, 1500.00, DATE '2026-10-10', DATE '2026-10-10', 'OVERDUE', 100.00, 0.00, 0.00, 0.00, DATE '2026-11-19', TIMESTAMPTZ '2026-10-01 08:00:00+03' "
        f"FROM units u LEFT JOIN unit_occupancies o ON o.unit_id = u.id AND o.is_active WHERE u.id = {u5}; "
        "INSERT INTO dues_liabilities (unit_id, period, debtor_type, expense_type, liable_person_id, occupancy_id, principal_amount, due_date, effective_due_date, status, delay_penalty, paid_principal, paid_penalty, paid_amount, penalty_accrued_through, created_at) "
        f"SELECT {u6}, 'Ekim 2026', 'OWNER', 'OPERATIONAL_DUES', u.owner_person_id, o.id, 2250.00, DATE '2026-10-10', DATE '2026-10-10', 'OVERDUE', 150.00, 0.00, 0.00, 0.00, DATE '2026-11-19', TIMESTAMPTZ '2026-10-01 08:00:00+03' "
        f"FROM units u LEFT JOIN unit_occupancies o ON o.unit_id = u.id AND o.is_active WHERE u.id = {u6}; "
        f"INSERT INTO late_fee_accruals (site_id, due_id, accrual_date, outstanding_principal, segment_start, segment_base, cumulative_fee, daily_amount) "
        f"SELECT {site}, d.id, DATE '2026-11-19', 1500.00, DATE '2026-10-10', 0.00, 100.00, 2.50 "
        f"FROM dues_liabilities d WHERE d.unit_id IN ({u2}, {u3}, {u4}, {u5}) AND d.period = 'Ekim 2026'; "
        f"INSERT INTO late_fee_accruals (site_id, due_id, accrual_date, outstanding_principal, segment_start, segment_base, cumulative_fee, daily_amount) "
        f"SELECT {site}, d.id, DATE '2026-11-19', 2250.00, DATE '2026-10-10', 0.00, 150.00, 3.75 "
        f"FROM dues_liabilities d WHERE d.unit_id = {u6} AND d.period = 'Ekim 2026'; "
        f"INSERT INTO payment_receipts (site_id, unit_id, receipt_number, sequence_number, payer_name, payer_role, total_amount, payment_channel, allocated_principal, allocated_penalty, allocated_advance, verification_hash, issued_at) "
        f"VALUES ({site}, {u1}, 'TAH-2026-000001', 1, 'Ayşe Kaya', 'OWNER', 1500.00, 'BANK_STATEMENT', 1500.00, 0.00, 0.00, encode(sha256(('receipt-' || {site} || '-1')::bytea), 'hex'), TIMESTAMPTZ '2026-10-10 10:00:00+03'); "
        f"INSERT INTO receipt_counters (site_id, receipt_type, last_sequence) VALUES ({site}, 'COLLECTION', 1) ON CONFLICT (site_id, receipt_type) DO UPDATE SET last_sequence = EXCLUDED.last_sequence; "
        f"INSERT INTO payment_entries (site_id, unit_id, payer_name, payer_role, receipt_id, amount, payment_channel, settlement_status, description, payment_date, created_at) "
        f"SELECT {site}, {u1}, 'Ayşe Kaya', 'OWNER', r.id, 1500.00, 'BANK_STATEMENT', 'SETTLED', 'Ekim 2026 aidat ödemesi', TIMESTAMPTZ '2026-10-10 10:00:00+03', TIMESTAMPTZ '2026-10-10 10:00:00+03' "
        f"FROM payment_receipts r WHERE r.site_id = {site} AND r.sequence_number = 1; "
        f"INSERT INTO payment_allocations (payment_entry_id, dues_liability_id, principal_amount, penalty_amount, created_at) "
        f"SELECT pe.id, dl.id, 1500.00, 0.00, TIMESTAMPTZ '2026-10-10 10:00:00+03' "
        f"FROM payment_entries pe JOIN dues_liabilities dl ON dl.unit_id = pe.unit_id AND dl.period = 'Ekim 2026' "
        f"WHERE pe.site_id = {site} AND pe.unit_id = {u1}; "
        "COMMIT;"
    )
    stack.sql(sql)


def _build_f5(stack: E2EStack, site_id: str | int, unit_ids: tuple[str, ...]) -> None:
    site = _safe_id(site_id)
    u1, u2, u3, u4, u5, u6, u7 = [_safe_id(uid) for uid in unit_ids]

    statements = [
        "BEGIN;",
        f"INSERT INTO dues_periods (site_id, period_name, due_date, status) VALUES "
        f"({site}, 'Eylül 2026', DATE '2026-09-10', 'ACTIVE'), "
        f"({site}, 'Ekim 2026', DATE '2026-10-10', 'ACTIVE'), "
        f"({site}, 'Kasım 2026', DATE '2026-11-10', 'ACTIVE');",
    ]

    liabilities = [
        # Eylül 2026
        (u1, "Eylül 2026", "OWNER", "1500.00", "2026-09-10", "PAID", "0.00", "1500.00", None, "TIMESTAMPTZ '2026-09-10 10:00:00+03'"),
        (u2, "Eylül 2026", "TENANT", "1500.00", "2026-09-10", "PAID", "0.00", "1500.00", None, "TIMESTAMPTZ '2026-09-10 10:00:00+03'"),
        (u3, "Eylül 2026", "OWNER", "1500.00", "2026-09-10", "OVERDUE", "175.00", "0.00", "DATE '2026-11-19'", "NULL"),
        (u4, "Eylül 2026", "OWNER", "1500.00", "2026-09-10", "PAID", "0.00", "1500.00", None, "TIMESTAMPTZ '2026-09-10 10:00:00+03'"),
        (u5, "Eylül 2026", "TENANT", "1500.00", "2026-09-10", "OVERDUE", "175.00", "0.00", "DATE '2026-11-19'", "NULL"),
        (u6, "Eylül 2026", "OWNER", "2250.00", "2026-09-10", "PAID", "0.00", "2250.00", None, "TIMESTAMPTZ '2026-09-01 10:00:00+03'"),
        # Ekim 2026
        (u1, "Ekim 2026", "OWNER", "1500.00", "2026-10-10", "PAID", "0.00", "1500.00", None, "TIMESTAMPTZ '2026-10-10 10:00:00+03'"),
        (u2, "Ekim 2026", "TENANT", "1500.00", "2026-10-10", "OVERDUE", "100.00", "0.00", "DATE '2026-11-19'", "NULL"),
        (u3, "Ekim 2026", "OWNER", "1500.00", "2026-10-10", "PAID", "0.00", "1500.00", None, "TIMESTAMPTZ '2026-10-10 10:00:00+03'"),
        (u4, "Ekim 2026", "OWNER", "1500.00", "2026-10-10", "PAID", "0.00", "1500.00", None, "TIMESTAMPTZ '2026-10-10 10:00:00+03'"),
        (u5, "Ekim 2026", "TENANT", "1500.00", "2026-10-10", "OVERDUE", "100.00", "0.00", "DATE '2026-11-19'", "NULL"),
        (u6, "Ekim 2026", "OWNER", "2250.00", "2026-10-10", "PAID", "0.00", "2250.00", None, "TIMESTAMPTZ '2026-09-01 10:00:00+03'"),
        # Kasım 2026
        (u1, "Kasım 2026", "OWNER", "1500.00", "2026-11-10", "PAID", "0.00", "1500.00", None, "TIMESTAMPTZ '2026-11-10 10:00:00+03'"),
        (u2, "Kasım 2026", "TENANT", "1500.00", "2026-11-10", "OVERDUE", "22.50", "0.00", "DATE '2026-11-19'", "NULL"),
        (u3, "Kasım 2026", "OWNER", "1500.00", "2026-11-10", "PAID", "0.00", "1500.00", None, "TIMESTAMPTZ '2026-11-10 10:00:00+03'"),
        (u4, "Kasım 2026", "OWNER", "1500.00", "2026-11-10", "OVERDUE", "22.50", "0.00", "DATE '2026-11-19'", "NULL"),
        (u5, "Kasım 2026", "TENANT", "1500.00", "2026-11-10", "OVERDUE", "22.50", "0.00", "DATE '2026-11-19'", "NULL"),
        (u6, "Kasım 2026", "OWNER", "2250.00", "2026-11-10", "PAID", "0.00", "2250.00", None, "TIMESTAMPTZ '2026-09-01 10:00:00+03'"),
    ]

    for uid, period, debtor, principal, due_date, status, penalty, paid_p, pen_through, p_date in liabilities:
        pen_through_sql = pen_through if pen_through is not None else "NULL"
        created_at_month = "09" if "Eylül" in period else ("10" if "Ekim" in period else "11")
        statements.append(
            f"INSERT INTO dues_liabilities (unit_id, period, debtor_type, expense_type, liable_person_id, occupancy_id, principal_amount, due_date, effective_due_date, status, delay_penalty, paid_principal, paid_penalty, paid_amount, payment_date, penalty_accrued_through, created_at) "
            f"SELECT {uid}, '{period}', '{debtor}', 'OPERATIONAL_DUES', "
            f"{'u.tenant_person_id' if debtor == 'TENANT' else 'u.owner_person_id'}, "
            f"{'NULL' if uid == u3 else 'o.id'}, {principal}, DATE '{due_date}', DATE '{due_date}', '{status}', {penalty}, {paid_p}, 0.00, {paid_p}, {p_date}, {pen_through_sql}, TIMESTAMPTZ '2026-{created_at_month}-01 08:00:00+03' "
            f"FROM units u LEFT JOIN unit_occupancies o ON o.unit_id = u.id AND o.is_active WHERE u.id = {uid};"
        )

    overdue_accruals = [
        (u2, "Ekim 2026", "1500.00", "2026-10-10", "100.00", "2.50"),
        (u2, "Kasım 2026", "1500.00", "2026-11-10", "22.50", "2.50"),
        (u3, "Eylül 2026", "1500.00", "2026-09-10", "175.00", "2.50"),
        (u4, "Kasım 2026", "1500.00", "2026-11-10", "22.50", "2.50"),
        (u5, "Eylül 2026", "1500.00", "2026-09-10", "175.00", "2.50"),
        (u5, "Ekim 2026", "1500.00", "2026-10-10", "100.00", "2.50"),
        (u5, "Kasım 2026", "1500.00", "2026-11-10", "22.50", "2.50"),
    ]
    for uid, period, princ, seg_start, cum_fee, daily in overdue_accruals:
        statements.append(
            f"INSERT INTO late_fee_accruals (site_id, due_id, accrual_date, outstanding_principal, segment_start, segment_base, cumulative_fee, daily_amount) "
            f"SELECT {site}, d.id, DATE '2026-11-19', {princ}, DATE '{seg_start}', 0.00, {cum_fee}, {daily} "
            f"FROM dues_liabilities d WHERE d.unit_id = {uid} AND d.period = '{period}';"
        )

    receipt_data = [
        (1, u1, "Eylül 2026", "Ayşe Kaya", "OWNER", "1500.00", "2026-09-10"),
        (2, u1, "Ekim 2026", "Ayşe Kaya", "OWNER", "1500.00", "2026-10-10"),
        (3, u1, "Kasım 2026", "Ayşe Kaya", "OWNER", "1500.00", "2026-11-10"),
        (4, u2, "Eylül 2026", "Selin Demir", "TENANT", "1500.00", "2026-09-10"),
        (5, u3, "Ekim 2026", "Burak Şahin", "OWNER", "1500.00", "2026-10-10"),
        (6, u3, "Kasım 2026", "Burak Şahin", "OWNER", "1500.00", "2026-11-10"),
        (7, u4, "Eylül 2026", "Ahmet Yılmaz", "OWNER", "1500.00", "2026-09-10"),
        (8, u4, "Ekim 2026", "Ahmet Yılmaz", "OWNER", "1500.00", "2026-10-10"),
    ]
    for seq, uid, period, payer, role, amount, pdate in receipt_data:
        statements.append(
            f"INSERT INTO payment_receipts (site_id, unit_id, receipt_number, sequence_number, payer_name, payer_role, total_amount, payment_channel, allocated_principal, allocated_penalty, allocated_advance, verification_hash, issued_at) "
            f"VALUES ({site}, {uid}, 'TAH-2026-00000{seq}', {seq}, '{payer}', '{role}', {amount}, 'BANK_STATEMENT', {amount}, 0.00, 0.00, encode(sha256(('receipt-' || {site} || '-{seq}')::bytea), 'hex'), TIMESTAMPTZ '{pdate} 10:00:00+03'); "
            f"INSERT INTO payment_entries (site_id, unit_id, payer_name, payer_role, receipt_id, amount, payment_channel, settlement_status, description, payment_date, created_at) "
            f"SELECT {site}, {uid}, '{payer}', '{role}', r.id, {amount}, 'BANK_STATEMENT', 'SETTLED', '{period} aidat ödemesi', TIMESTAMPTZ '{pdate} 10:00:00+03', TIMESTAMPTZ '{pdate} 10:00:00+03' "
            f"FROM payment_receipts r WHERE r.site_id = {site} AND r.sequence_number = {seq}; "
            f"INSERT INTO payment_allocations (payment_entry_id, dues_liability_id, principal_amount, penalty_amount, created_at) "
            f"SELECT pe.id, dl.id, {amount}, 0.00, TIMESTAMPTZ '{pdate} 10:00:00+03' "
            f"FROM payment_entries pe JOIN dues_liabilities dl ON dl.unit_id = pe.unit_id AND dl.period = '{period}' "
            f"WHERE pe.site_id = {site} AND pe.unit_id = {uid} AND pe.receipt_id = (SELECT id FROM payment_receipts WHERE site_id = {site} AND sequence_number = {seq});"
        )

    statements.append(
        f"INSERT INTO payment_receipts (site_id, unit_id, receipt_number, sequence_number, payer_name, payer_role, advance_debtor_type, total_amount, payment_channel, allocated_principal, allocated_penalty, allocated_advance, verification_hash, issued_at) "
        f"VALUES ({site}, {u6}, 'TAH-2026-000009', 9, 'Elif Aydın', 'OWNER', 'OWNER', 8000.00, 'BANK_STATEMENT', 6750.00, 0.00, 1250.00, encode(sha256(('receipt-' || {site} || '-9')::bytea), 'hex'), TIMESTAMPTZ '2026-09-01 10:00:00+03'); "
        f"INSERT INTO payment_entries (site_id, unit_id, payer_name, payer_role, receipt_id, amount, payment_channel, settlement_status, description, payment_date, created_at) "
        f"SELECT {site}, {u6}, 'Elif Aydın', 'OWNER', r.id, 8000.00, 'BANK_STATEMENT', 'SETTLED', 'Eylül, Ekim, Kasım aidatı ve avans', TIMESTAMPTZ '2026-09-01 10:00:00+03', TIMESTAMPTZ '2026-09-01 10:00:00+03' "
        f"FROM payment_receipts r WHERE r.site_id = {site} AND r.sequence_number = 9; "
        f"INSERT INTO payment_allocations (payment_entry_id, dues_liability_id, principal_amount, penalty_amount, created_at) "
        f"SELECT pe.id, dl.id, 2250.00, 0.00, TIMESTAMPTZ '2026-09-01 10:00:00+03' "
        f"FROM payment_entries pe JOIN dues_liabilities dl ON dl.unit_id = pe.unit_id "
        f"WHERE pe.site_id = {site} AND pe.unit_id = {u6} AND pe.receipt_id = (SELECT id FROM payment_receipts WHERE site_id = {site} AND sequence_number = 9); "
        f"INSERT INTO advance_balances (unit_id, debtor_type, balance) VALUES ({u6}, 'OWNER', 1250.00); "
        f"INSERT INTO advance_ledger_entries (unit_id, debtor_type, entry_type, amount, reference_id, description, created_at) "
        f"VALUES ({u6}, 'OWNER', 'PAYMENT_SURPLUS', 1250.00, 'TAH-2026-000009', 'Advance from overpayment', TIMESTAMPTZ '2026-09-01 10:00:00+03'); "
        f"INSERT INTO receipt_counters (site_id, receipt_type, last_sequence) VALUES ({site}, 'COLLECTION', 9) ON CONFLICT (site_id, receipt_type) DO UPDATE SET last_sequence = EXCLUDED.last_sequence;"
    )

    # A product accrual records the titled owner as jointly liable for every tenant charge (KMK m.22); the
    # direct inserts above bypass it, so state the same fact for the seeded tenant charges.
    statements.append(
        "INSERT INTO dues_liability_joint_owners (site_id, due_id, owner_person_id, tenant_person_id, liable_from, liable_through) "
        f"SELECT {site}, d.id, u.owner_person_id, d.liable_person_id, date_trunc('month', d.due_date)::date, "
        "(date_trunc('month', d.due_date) + interval '1 month - 1 day')::date "
        f"FROM dues_liabilities d JOIN units u ON u.id = d.unit_id WHERE u.site_id = {site} AND d.debtor_type = 'TENANT';"
    )
    statements.append("COMMIT;")
    stack.sql(" ".join(statements))


def _close_september(stack: E2EStack, site_id: str | int) -> None:
    site = _safe_id(site_id)
    stack.sql(
        "BEGIN; "
        f"UPDATE dues_periods SET status = 'CLOSED' WHERE site_id = {site} AND period_name = 'Eylül 2026'; "
        f"INSERT INTO dues_period_snapshots (site_id, period_id, period_key, snapshot_version, accrued, collected, outstanding, corrections, per_unit, trial_balance, account_report, journal_entries, closed_by, closed_at) "
        f"SELECT {site}, p.id, '2026-09', 1, 9750.00, 6750.00, 3000.00, 0.00, '[]'::jsonb, "
        f"jsonb_build_object('site_id', '{site}', 'from', '2026-09-01', 'to', '2026-09-30', 'rows', '[]'::jsonb, 'total_debit', '0.00', 'total_credit', '0.00', 'balanced', true), "
        "jsonb_build_object('period_id', p.id::text, 'period_key', '2026-09', 'status', 'CLOSED', 'accrued', '9750.00', 'collected', '6750.00', 'outstanding', '3000.00', 'corrections', '0.00', 'per_unit', '[]'::jsonb), "
        "'[]'::jsonb, 'manager', TIMESTAMPTZ '2026-11-19 12:00:00+03' "
        f"FROM dues_periods p WHERE p.site_id = {site} AND p.period_name = 'Eylül 2026'; "
        "COMMIT;"
    )


def _create_period_no_residents(stack: E2EStack, site_id: str) -> None:
    site = _safe_id(site_id)
    stack.sql(
        f"INSERT INTO dues_periods (site_id, period_name, period_key, due_date, status) "
        f"VALUES ({site}, 'Ekim 2026', '2026-10', DATE '2026-10-10', 'OPEN') "
        f"ON CONFLICT (site_id, period_name) DO UPDATE SET period_key = EXCLUDED.period_key, status = 'OPEN';"
    )

def _create_residents(stack: E2EStack, site_id: str, manager_user_id: str | int,
                      manifest: JourneyManifest, attempt_slug: str | None = None) -> tuple[str, ...]:
    site = _safe_id(site_id)
    manager_id = _safe_id(manager_user_id)
    password_hash = stack.sql(f"SELECT password_hash FROM users WHERE id = {manager_id};")
    if not password_hash:
        raise AssertionError("F2: permanent manager password hash is unavailable")
    attempt = attempt_slug or _slug(manifest.attempt_id)
    people = {
        "ayse": ("Ayşe Kaya", "HOME_OWNER"),
        "ahmet": ("Ahmet Yılmaz", "HOME_OWNER"),
        "selin": ("Selin Demir", "HOME_RESIDENT"),
        "burak": ("Burak Şahin", "HOME_OWNER"),
        "can": ("Can Öztürk", "HOME_OWNER"),
        "deniz": ("Deniz Arslan", "HOME_RESIDENT"),
        "elif": ("Elif Aydın", "HOME_OWNER"),
    }
    emails = {key: f"{attempt}.{key}@journey.e2e.test" for key in people}
    person_values = ", ".join(
        f"({site}, {_sql_text(name)}, {_sql_text(emails[key])}, {_sql_text(person_type)})"
        for key, (name, person_type) in people.items()
    )
    stack.sql(
        f"INSERT INTO persons (site_id, full_name, email, person_type) VALUES {person_values};"
    )
    person_rows = stack.sql(
        f"SELECT id || '|' || email FROM persons WHERE site_id = {site} "
        f"AND email IN ({', '.join(_sql_text(email) for email in emails.values())}) ORDER BY email;"
    ).splitlines()
    person_ids_by_email = {line.split("|", 1)[1]: line.split("|", 1)[0] for line in person_rows}
    if len(person_ids_by_email) != len(people):
        raise AssertionError(f"F2: expected {len(people)} reference people, created {len(person_ids_by_email)}")
    person_ids = tuple(person_ids_by_email[email] for email in emails.values())
    for person_id in person_ids:
        manifest.record("person_ids", person_id)

    owner_by_unit = {1: "ayse", 2: "ahmet", 3: "burak", 4: "ahmet", 5: "can", 6: "elif"}
    occupants = {1: ("ayse", "OWNER"), 2: ("selin", "TENANT"),
                 4: ("ahmet", "OWNER"), 5: ("deniz", "TENANT"), 6: ("elif", "OWNER")}
    statements = ["BEGIN;"]
    for unit_number, key in owner_by_unit.items():
        email = _sql_text(emails[key])
        statements.extend([
            f"UPDATE units SET owner_person_id = (SELECT id FROM persons WHERE site_id = {site} AND email = {email}) "
            f"WHERE site_id = {site} AND unit_number = {unit_number};",
            f"INSERT INTO unit_ownerships (unit_id, person_id, share_percentage, start_date, is_active) "
            f"SELECT u.id, p.id, 100.00, DATE '2026-09-01', TRUE FROM units u JOIN persons p "
            f"ON p.site_id = u.site_id AND p.email = {email} WHERE u.site_id = {site} AND u.unit_number = {unit_number};",
        ])
    for unit_number, (key, occupancy_type) in occupants.items():
        email = _sql_text(emails[key])
        tenant_person = f"(SELECT id FROM persons WHERE site_id = {site} AND email = {email})" \
            if occupancy_type == "TENANT" else "NULL"
        statements.extend([
            f"UPDATE units SET tenant_person_id = {tenant_person}, "
            f"occupancy_status = '{'TENANT_OCCUPIED' if occupancy_type == 'TENANT' else 'OWNER_OCCUPIED'}' "
            f"WHERE site_id = {site} AND unit_number = {unit_number};",
            f"INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type, start_date, is_active) "
            f"SELECT u.id, p.id, '{occupancy_type}', DATE '2026-09-01', TRUE FROM units u JOIN persons p "
            f"ON p.site_id = u.site_id AND p.email = {email} WHERE u.site_id = {site} AND u.unit_number = {unit_number};",
        ])
    statements.append(
        f"INSERT INTO users (site_id, person_id, email, password_hash, role, must_change_password) "
        f"SELECT p.site_id, p.id, p.email, {_sql_text(password_hash)}, "
        f"CASE WHEN p.person_type = 'HOME_OWNER' THEN 'HOME_OWNER' ELSE 'HOME_RESIDENT' END, FALSE "
        f"FROM persons p WHERE p.site_id = {site} AND p.email IN ({', '.join(_sql_text(email) for email in emails.values())});"
    )
    statements.append(
        f"INSERT INTO user_site_roles (user_id, site_id, role) SELECT id, site_id, role FROM users "
        f"WHERE site_id = {site} AND email IN ({', '.join(_sql_text(email) for email in emails.values())}) "
        "ON CONFLICT (user_id, site_id, role) DO NOTHING;"
    )
    statements.append("COMMIT;")
    stack.sql(" ".join(statements))
    user_rows = stack.sql(
        f"SELECT id FROM users WHERE site_id = {site} AND email IN ({', '.join(_sql_text(email) for email in emails.values())}) ORDER BY id;"
    ).splitlines()
    for user_id in user_rows:
        manifest.record("user_ids", user_id)
    return person_ids


def _safe_id(value: str | int) -> int:
    raw = str(value)
    if not re.fullmatch(r"[1-9][0-9]*", raw):
        raise ValueError(f"Expected a positive database id, got {raw!r}")
    return int(raw)


def _sql_text(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def teardown_sites(stack: E2EStack, manifest: JourneyManifest, *, restart: bool = True) -> None:
    """Delete only the manifest's sites in one SQL transaction; safe to retry."""
    for raw_site_id in manifest.site_ids:
        if not re.fullmatch(r"[1-9][0-9]*", raw_site_id):
            raise ValueError(f"Invalid site id in journey manifest: {raw_site_id!r}")
        site_id = int(raw_site_id)
        statements = []
        for target in _SITE_SCOPED_DELETES:
            table = target.split(maxsplit=1)[0]
            statements.append(
                f"IF to_regclass('public.{table}') IS NOT NULL THEN "
                f"EXECUTE 'DELETE FROM {target.format(site=site_id)}'; END IF;"
            )
        sql = "BEGIN; SET LOCAL sitepulse.allow_ledger_purge = 'on'; DO $$ BEGIN " + " ".join(statements) + " END $$; COMMIT;"
        stack.sql(sql)
    if restart and manifest.site_ids:
        stack.restart_backend()
    elif manifest.site_ids:
        # Without a restart the backend process survives, so release its frozen fixture date.
        Api(stack=stack).clock.clear()
    manifest.teardown_completed = True
    manifest.save()
    manifest.release_lock()


def site_scoped_row_counts(stack: E2EStack, site_id: str | int) -> dict[str, int]:
    """Return row counts for every table covered by the site teardown manifest."""
    site = _safe_id(site_id)
    predicates_by_table: dict[str, list[str]] = {}
    for target in _SITE_SCOPED_DELETES:
        table, predicate = target.split(" WHERE ", maxsplit=1)
        predicates_by_table.setdefault(table, []).append(predicate.format(site=site))
    counts: dict[str, int] = {}
    for table, predicates in predicates_by_table.items():
        exists = stack.sql(f"SELECT to_regclass('public.{table}') IS NOT NULL;") == "t"
        if exists:
            counts[table] = int(stack.sql(
                f"SELECT COUNT(*) FROM {table} WHERE {' OR '.join(f'({p})' for p in predicates)};"
            ))
        else:
            counts[table] = 0
    return counts


def capture_failure_evidence(stack: E2EStack, api: Api, manifest: JourneyManifest) -> None:
    """Persist a redacted site snapshot and route/status-only API evidence before cleanup."""
    site_counts = {
        site_id: site_scoped_row_counts(stack, site_id)
        for site_id in manifest.site_ids
    }
    manifest.record_step("failure_evidence", {
        "site_row_counts": site_counts,
        "network": api.network_events[-100:],
    })


def reclaim_stale_attempts(stack: E2EStack, directory: Path) -> list[str]:
    """Clean incomplete manifests for this database when their process lock is gone."""
    reclaimed: list[str] = []
    for path in sorted(directory.glob("*.json")):
        try:
            manifest = JourneyManifest.load(path)
        except (OSError, ValueError, KeyError) as error:
            warnings.warn(
                f"Skipped unreadable journey manifest {path.name}: {type(error).__name__}",
                RuntimeWarning,
                stacklevel=2,
            )
            continue
        if manifest.teardown_completed or manifest.database_name != stack.db_name:
            continue
        with manifest.lock_path.open("a+", encoding="utf-8") as lock_file:
            try:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                continue
            try:
                teardown_sites(stack, manifest)
                reclaimed.append(manifest.attempt_id)
            except Exception as error:
                warnings.warn(
                    f"Could not reclaim journey manifest {path.name}: {type(error).__name__}",
                    RuntimeWarning,
                    stacklevel=2,
                )
            finally:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
    return reclaimed


def teardown_with_evidence(
    stack: E2EStack,
    manifest: JourneyManifest,
    *,
    failed: BaseException | None,
    capture_evidence: Callable[[], None],
    restart: bool = True,
) -> None:
    """Capture failure evidence before cleanup and preserve both failures if capture also fails."""
    errors: list[BaseException] = []
    try:
        if failed is not None:
            capture_evidence()
    except BaseException as error:  # evidence failure must never skip cleanup
        errors.append(error)
    try:
        teardown_sites(stack, manifest, restart=restart)
    except BaseException as error:
        errors.append(error)
    if errors:
        causes = ([failed] if failed is not None else []) + errors
        raise BaseExceptionGroup("journey teardown reported multiple failures", causes)
    if failed is not None:
        raise failed


def _slug(value: str) -> str:
    safe = re.sub(r"[^a-zA-Z0-9-]+", "-", value).strip("-").lower()
    return safe[:80] or "run"


def _parse_date(value: str) -> date:
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
        raise ValueError(f"Invalid journey date: {value!r}; expected YYYY-MM-DD")
    try:
        return date.fromisoformat(value)
    except ValueError as error:
        raise ValueError(f"Invalid journey date: {value!r}; expected YYYY-MM-DD") from error
