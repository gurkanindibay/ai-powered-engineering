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
import sys
import uuid
import warnings
from dataclasses import dataclass, field
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Callable, TextIO

from decimal import Decimal

_SCRIPTS_DIR = Path(__file__).resolve().parents[2] / "scripts"
if str(_SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS_DIR))

from pm_scenarios.seeder import (
    JourneyFixture,
    make_viban,
    delete_blocks_sql,
    create_structure as _seeder_create_structure,
    create_residents as _seeder_create_residents,
    create_period_no_residents_sql,
    build_f4_sql,
    build_f5_sql,
    close_september_sql,
    seed_preset,
    safe_id,
    sql_text,
)

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
    "person_advance_holds WHERE site_id = {site}",
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
    res = seed_preset(
        preset=state,
        api=api,
        stack=stack,
        saas=saas,
        manifest=manifest,
        name_suffix=name_suffix,
        reload_fn=stack.restart_backend,
    )
    return res.fixture


def ledger_invariants(
    api: Api,
    manager: Session,
    site_id: str,
    *,
    stage: str,
    held_advances: Decimal = Decimal("0.00"),
) -> dict:
    """Check the reusable API-level ledger totals at a named journey stage.

    `held_advances` is advance the site holds for a person who no longer holds the
    unit's role; the dashboard total carries it while the unit's own balance does not.
    """
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

    unit_advances = (
        sum((decimal(flat["advance_balance"]) for flat in flats), Decimal("0.00"))
        + held_advances
    )
    dashboard_advances = decimal(summary["total_advance_balance"])
    if unit_advances != dashboard_advances:
        raise AssertionError(f"[{stage}] I4: unit advance sum {unit_advances} != dashboard {dashboard_advances}")
    for flat in flats:
        if decimal(flat["amount_due"]) < Decimal("0.00"):
            raise AssertionError(f"[{stage}] I1: unit {flat['id']} has a negative displayed debt")
    return overview


def _create_structure(stack: E2EStack, site_id: str, manifest: JourneyManifest) -> tuple[str, ...]:
    return _seeder_create_structure(stack.sql, site_id, manifest)


def _build_f4(stack: E2EStack, site_id: str | int, unit_ids: tuple[str, ...]) -> None:
    stack.sql(build_f4_sql(site_id, unit_ids))


def _build_f5(stack: E2EStack, site_id: str | int, unit_ids: tuple[str, ...]) -> None:
    stack.sql(build_f5_sql(site_id, unit_ids))


def _close_september(stack: E2EStack, site_id: str | int) -> None:
    stack.sql(close_september_sql(site_id))


def _create_period_no_residents(stack: E2EStack, site_id: str) -> None:
    stack.sql(create_period_no_residents_sql(site_id))

def _create_residents(
    stack: E2EStack,
    site_id: str,
    manager_user_id: str | int,
    manifest: JourneyManifest,
    attempt_slug: str | None = None,
) -> tuple[str, ...]:
    return _seeder_create_residents(stack.sql, site_id, manager_user_id, manifest, attempt_slug=attempt_slug)


def _safe_id(value: str | int) -> int:
    return safe_id(value)


def _sql_text(value: str) -> str:
    return sql_text(value)


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
        stack.restart_backend(preserve_e2e_clock=False)
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
