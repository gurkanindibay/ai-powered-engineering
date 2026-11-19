"""Site-scoped manifests and SQL-only teardown for admin journey attempts.

Journey attempts can share an E2E database. The manifest is written as resources
are created, so teardown can be retried after a process or evidence-capture
failure without truncating another attempt's data.
"""
from __future__ import annotations

import json
import re
import uuid
from dataclasses import dataclass, field
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Callable

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
    teardown_completed: bool = False
    created_at: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())

    @classmethod
    def create(cls, directory: Path, run_id: str, shard_id: str, attempt_id: str | None = None) -> "JourneyManifest":
        attempt = attempt_id or uuid.uuid4().hex
        manifest = cls(run_id, shard_id, attempt, directory / f"{_slug(run_id)}-{_slug(shard_id)}-{_slug(attempt)}.json")
        manifest.save()
        return manifest

    def record(self, resource: str, resource_id: str | int) -> None:
        if resource not in {"site_ids", "unit_ids", "person_ids", "user_ids"}:
            raise ValueError(f"Unsupported journey manifest resource: {resource}")
        value = str(resource_id)
        bucket: list[str] = getattr(self, resource)
        if value not in bucket:
            bucket.append(value)
            self.save()

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        data = {
            "run_id": self.run_id,
            "shard_id": self.shard_id,
            "attempt_id": self.attempt_id,
            "created_at": self.created_at,
            "site_ids": self.site_ids,
            "unit_ids": self.unit_ids,
            "person_ids": self.person_ids,
            "user_ids": self.user_ids,
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
            teardown_completed=bool(data["teardown_completed"]), created_at=data["created_at"],
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
    """Build an isolated F0-F2 site and record its resources before later setup work.

    F3-F7 need the shared deterministic clock and the later occupancy, payment,
    close and correction builders. Those states fail explicitly until their
    acceptance scenarios are enabled rather than silently returning partial data.
    """
    if state not in {f"F{number}" for number in range(8)}:
        raise ValueError(f"Unknown Site Admin reference state: {state!r}")
    if state not in {"F0", "F1", "F2"}:
        raise JourneyFixturePending(f"{state} is pending the later journey fixture builders and #211 clock integration")

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
    if state in {"F1", "F2"}:
        unit_ids = _create_structure(stack, site_id, manifest)
        requires_restart = True
    if state == "F2":
        person_ids = _create_residents(stack, site_id, manager_user_id, manifest, attempt_slug=attempt)
    if requires_restart:
        stack.restart_backend()

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


def _create_structure(stack: E2EStack, site_id: str, manifest: JourneyManifest) -> tuple[str, ...]:
    site = _safe_id(site_id)
    stack.sql(
        "BEGIN; "
        f"DELETE FROM blocks WHERE site_id = {site}; "
        f"INSERT INTO blocks (site_id, block_name, total_floors) VALUES ({site}, 'A Blok', 7); "
        f"INSERT INTO house_types (site_id, type_name, dues_amount, description) VALUES "
        f"({site}, 'Flat', 1500.00, 'Journey reference tariff'), "
        f"({site}, 'Large flat', 2250.00, 'Journey reference tariff'); "
        "INSERT INTO units (block_id, site_id, unit_number, floor, land_share, occupancy_status, house_type, house_type_id) "
        f"SELECT b.id, {site}, n.unit_number, 1, 1, 'VACANT', h.type_name, h.id "
        "FROM blocks b CROSS JOIN (VALUES (1), (2), (3), (4), (5), (6), (7)) AS n(unit_number) "
        "JOIN house_types h ON h.site_id = b.site_id AND h.type_name = CASE WHEN n.unit_number = 6 THEN 'Large flat' ELSE 'Flat' END "
        f"WHERE b.site_id = {site} AND b.block_name = 'A Blok' ORDER BY n.unit_number; COMMIT;"
    )
    unit_ids = tuple(stack.sql(f"SELECT id FROM units WHERE site_id = {site} ORDER BY unit_number;").splitlines())
    if len(unit_ids) != 7:
        raise AssertionError(f"F1: expected seven units, created {len(unit_ids)}")
    for unit_id in unit_ids:
        manifest.record("unit_ids", unit_id)
    return unit_ids


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
    manifest.teardown_completed = True
    manifest.save()


def teardown_with_evidence(
    stack: E2EStack,
    manifest: JourneyManifest,
    *,
    failed: BaseException | None,
    capture_evidence: Callable[[], None],
) -> None:
    """Capture failure evidence before cleanup and preserve both failures if capture also fails."""
    errors: list[BaseException] = []
    try:
        if failed is not None:
            capture_evidence()
    except BaseException as error:  # evidence failure must never skip cleanup
        errors.append(error)
    try:
        teardown_sites(stack, manifest)
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
