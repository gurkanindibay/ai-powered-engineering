"""F6 CHANGING_OCCUPANCY builder and read helpers for the occupancy journey tests.

Follows docs/testing/journey-plan/README.md section 3.1: proration is on, no payments, and every
accrual runs on the date of its step. All writes go through the public API with the shared journey
clock; the only direct SQL is the F2 base adjustment (A-2 starts vacant) and the second-manager
promotion that the split-correction four-eyes rule needs.
"""
from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal

from support.api import Api, Session
from support.journey_attempts import (
    JourneyClock,
    JourneyFixture,
    JourneyManifest,
    ledger_invariants,
    site_in_state,
)
from support.stack import E2EStack

CENT = Decimal("0.01")
DUE_DATES = {"Eylül 2026": "2026-09-10", "Ekim 2026": "2026-10-10", "Kasım 2026": "2026-11-10"}


@dataclass
class OccupancyJourney:
    """A built site plus the handles the scenarios assert through."""

    fixture: JourneyFixture
    clock: JourneyClock
    api: Api
    stack: E2EStack
    manifest: JourneyManifest
    people: dict[str, str]

    @property
    def manager(self) -> Session:
        return self.fixture.manager

    @manager.setter
    def manager(self, session: Session) -> None:
        self.fixture = JourneyFixture(self.fixture.state, self.fixture.site_id, session, self.fixture.manager_email,
                                      self.fixture.manager_password, self.fixture.unit_ids, self.fixture.person_ids)

    def roles(self, unit_number: int, period: str) -> dict[str, Decimal]:
        """Operational principal per debtor role (OWNER, TENANT) of a unit and period."""
        return role_shares(self.stack, self.unit_id(unit_number), period)

    @property
    def site_id(self) -> str:
        return self.fixture.site_id

    def unit_id(self, number: int) -> str:
        return self.fixture.unit_ids[number - 1]

    def invariants(self, stage: str) -> dict:
        held = Decimal(self.stack.sql(
            f"SELECT COALESCE(SUM(balance), 0)::text FROM person_advance_holds WHERE site_id = {int(self.site_id)};"
        ) or "0.00")
        return ledger_invariants(
            self.api, self.manager, self.site_id, stage=stage, held_advances=held
        )

    def accrue(self, period: str, due: str | None = None, amount: Decimal | None = None) -> dict:
        return self.api.accrue_period(self.manager, period, amount, due or DUE_DATES[period])

    def shares(self, unit_number: int, period: str, expense_type: str = "OPERATIONAL_DUES") -> dict[str, Decimal]:
        return liability_shares(self.stack, self.unit_id(unit_number), period, expense_type)

    def share_rows(self, unit_number: int, period: str) -> list[dict]:
        return liability_rows(self.stack, self.unit_id(unit_number), period)


def liability_rows(stack: E2EStack, unit_id: str, period: str) -> list[dict]:
    """Operational liabilities of a unit and period as dicts (cancelled rows are excluded)."""
    raw = stack.sql(
        "SELECT COALESCE(p.full_name, '') || '|' || d.debtor_type || '|' || d.principal_amount || '|' || d.due_date "
        "|| '|' || COALESCE(d.effective_due_date::text, '') || '|' || d.status "
        "FROM dues_liabilities d LEFT JOIN persons p ON p.id = d.liable_person_id "
        f"WHERE d.unit_id = {int(unit_id)} AND d.expense_type = 'OPERATIONAL_DUES' "
        f"AND d.period = '{period.replace(chr(39), '')}' AND d.status <> 'CANCELLED' ORDER BY d.id;"
    )
    rows = []
    for line in raw.splitlines():
        name, debtor, principal, due, effective, status = line.split("|")
        rows.append({"name": name, "debtor": debtor, "principal": Decimal(principal), "due": due,
                     "effective_due": effective, "status": status})
    return rows


def liability_shares(stack: E2EStack, unit_id: str, period: str, expense_type: str = "OPERATIONAL_DUES") -> dict[str, Decimal]:
    """Principal per named debtor; resolve role-based owner rows to the unit's active owner."""
    raw = stack.sql(
        "SELECT COALESCE(p.full_name, owner_person_data.full_name) || '|' || sum(d.principal_amount) "
        "FROM dues_liabilities d LEFT JOIN persons p ON p.id = d.liable_person_id "
        "LEFT JOIN LATERAL (SELECT owner_person.full_name FROM unit_ownerships o "
        "JOIN persons owner_person ON owner_person.id = o.person_id "
        "WHERE o.unit_id = d.unit_id AND o.is_active ORDER BY o.id LIMIT 1) owner_person_data "
        "ON d.debtor_type = 'OWNER' AND d.liable_person_id IS NULL "
        f"WHERE d.unit_id = {int(unit_id)} AND d.expense_type = '{expense_type}' "
        f"AND d.period = '{period}' AND d.status <> 'CANCELLED' "
        "GROUP BY COALESCE(p.full_name, owner_person_data.full_name) ORDER BY 1;"
    )
    return {line.split("|")[0]: Decimal(line.split("|")[1]) for line in raw.splitlines() if line}


def role_shares(stack: E2EStack, unit_id: str, period: str) -> dict[str, Decimal]:
    raw = stack.sql(
        "SELECT debtor_type || '|' || sum(principal_amount) FROM dues_liabilities "
        f"WHERE unit_id = {int(unit_id)} AND expense_type = 'OPERATIONAL_DUES' AND period = '{period}' "
        "AND status <> 'CANCELLED' GROUP BY debtor_type ORDER BY 1;"
    )
    return {line.split("|")[0]: Decimal(line.split("|")[1]) for line in raw.splitlines() if line}


def seed_tenant_occupancy(j: "OccupancyJourney", unit_number: int, person_name: str, start_date: str) -> None:
    """Arrange step for start dates the live API refuses (after today): writes the tenancy, then reloads."""
    unit = int(j.unit_id(unit_number))
    person = int(j.people[person_name])
    j.stack.sql(
        "BEGIN; "
        f"INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type, start_date, is_active) "
        f"VALUES ({unit}, {person}, 'TENANT', DATE '{start_date}', TRUE); "
        f"UPDATE units SET tenant_person_id = {person}, occupancy_status = 'TENANT_OCCUPIED' WHERE id = {unit}; COMMIT;"
    )
    j.stack.restart_backend()
    j.clock.set_date(j.clock.current_date.isoformat())
    j.manager = j.api.login(j.fixture.manager_email, j.fixture.manager_password)


def person_id(stack: E2EStack, site_id: str, full_name: str) -> str:
    return stack.sql(f"SELECT id FROM persons WHERE site_id = {int(site_id)} AND full_name = '{full_name}' ORDER BY id LIMIT 1;")


def build_base(
    *, api: Api, stack: E2EStack, saas: Session, manifest: JourneyManifest, start: str = "2026-09-01",
    proration: bool = True, vacate_a2: bool = True, name_suffix: str = "",
) -> OccupancyJourney:
    """F2 plus a clock and the proration switch; A-2 is vacant when `vacate_a2` (F6 start)."""
    manifest.bind_database(stack.db_name)
    fixture = site_in_state("F2", api=api, stack=stack, saas=saas, manifest=manifest, name_suffix=name_suffix)
    if vacate_a2:
        unit = int(fixture.unit_ids[1])
        stack.sql(
            "BEGIN; "
            f"DELETE FROM unit_occupancies WHERE unit_id = {unit}; "
            f"UPDATE units SET tenant_person_id = NULL, occupancy_status = 'VACANT' WHERE id = {unit}; COMMIT;"
        )
        stack.restart_backend()
        fixture = JourneyFixture(fixture.state, fixture.site_id, api.login(fixture.manager_email, fixture.manager_password),
                                 fixture.manager_email, fixture.manager_password, fixture.unit_ids, fixture.person_ids)
    clock = JourneyClock(api, start)
    api.call("PUT", f"/api/v1/site-admin/proration-policy?site_id={fixture.site_id}", fixture.manager.token,
             body={"proration_enabled": proration})
    people = {name: pid for name, pid in zip(
        ("Ayşe Kaya", "Ahmet Yılmaz", "Selin Demir", "Burak Şahin", "Can Öztürk", "Deniz Arslan", "Elif Aydın"),
        fixture.person_ids)}
    return OccupancyJourney(fixture, clock, api, stack, manifest, people)


def transition(j: OccupancyJourney, unit_number: int, command: str, **body: object) -> dict:
    """Runs one occupancy command effective on the journey clock's current date."""
    return j.api.call(
        "POST",
        f"/api/v1/site-admin/units/{j.unit_id(unit_number)}/occupancy-transitions?site_id={j.site_id}",
        j.manager.token,
        body={"command": command, "effective_date": j.clock.current_date.isoformat(), **body},
    )


def tenant_move_in(j: OccupancyJourney, unit_number: int, full_name: str, email_key: str, command: str | None = None) -> dict:
    existing = j.people.get(full_name)
    body: dict[str, object] = {"person_id": int(existing)} if existing else {
        "full_name": full_name, "email": f"{j.manifest.attempt_id[:8]}.{email_key}@journey.e2e.test".lower(),
        "phone": "+90 533 000 00 00"}
    state = j.api.call("GET", f"/api/v1/site-admin/units/{j.unit_id(unit_number)}/occupancy-state?site_id={j.site_id}",
                       j.manager.token)
    chosen = command or {"OWNER_OCCUPIED": "OWNER_RENTS_OUT", "TENANT_OCCUPIED": "REPLACE_TENANT"}.get(
        state.get("occupancy"), "TENANT_MOVE_IN")
    result = transition(j, unit_number, chosen, **body)
    opened = result.get("opened") or {}
    if not existing and opened.get("person_id"):
        j.people[full_name] = str(opened["person_id"])
        j.manifest.record("person_ids", opened["person_id"])
    return result


def sell_unit(j: OccupancyJourney, unit_number: int, buyer: str, email_key: str, *, moves_in: bool = True) -> dict:
    """Title-deed transfer effective on the clock date; the buyer takes the unit over as owner-occupant."""
    j.api.call("POST", "/api/v1/auth/step-up", j.manager.token, body={"password": j.fixture.manager_password})
    result = j.api.call(
        "POST", f"/api/v1/site-admin/units/{j.unit_id(unit_number)}/transfer-ownership", j.manager.token,
        body={"unit_id": j.unit_id(unit_number), "new_owner_name": buyer,
              "new_owner_email": f"{j.manifest.attempt_id[:8]}.{email_key}@journey.e2e.test".lower(),
              "transfer_date": j.clock.current_date.isoformat(), "new_owner_moves_in": moves_in})
    owner_id = j.stack.sql(f"SELECT owner_person_id FROM units WHERE id = {int(j.unit_id(unit_number))};")
    if owner_id:
        j.people[buyer] = owner_id
        j.manifest.record("person_ids", owner_id)
    return result


def second_manager(j: OccupancyJourney, person_name: str | None = None) -> Session:
    """Creates a second site manager for the isolated site (four-eyes reviewer)."""
    reviewer_email = f"journey.reviewer.{j.manifest.attempt_id[:8]}@e2e.test"
    existing = j.stack.sql(f"SELECT id FROM users WHERE email = '{reviewer_email}';")
    if existing:
        return j.api.login(reviewer_email, j.fixture.manager_password)
    existing_user_id = j.manifest.user_ids[0]
    password_hash = j.stack.sql(f"SELECT password_hash FROM users WHERE id = {int(existing_user_id)};")
    user_id = j.stack.sql(
        f"INSERT INTO users (site_id, email, password_hash, role, is_active, must_change_password) "
        f"VALUES ({int(j.site_id)}, '{reviewer_email}', '{password_hash}', 'SITE_MANAGER', TRUE, FALSE) "
        "RETURNING id;"
    )
    j.manifest.record("user_ids", user_id)
    j.stack.restart_backend()
    j.clock.set_date(j.clock.current_date.isoformat())
    return j.api.login(reviewer_email, j.fixture.manager_password)


def build_f6(**kwargs: object) -> OccupancyJourney:
    """Section 3.1 of the journey plan, step by step."""
    j = build_base(**kwargs)  # type: ignore[arg-type]
    j.invariants("F6 step 0: base")
    j.accrue("Eylül 2026")                                   # 1. 2026-09-01
    j.invariants("F6 step 1: Eylül accrued")

    j.clock.advance_to("2026-10-11")                         # 2. Selin moves into A-2
    tenant_move_in(j, 2, "Selin Demir", "selin")
    j.accrue("Ekim 2026")
    j.invariants("F6 step 2: Ekim accrued")

    j.clock.advance_to("2026-11-05")                         # 3. A-4 sold to Gül
    sell_unit(j, 4, "Gül Tanrıverdi", "gul")
    j.invariants("F6 step 3: A-4 sold")

    j.clock.advance_to("2026-11-15")                         # 4. tenant replaced, Kasım accrued
    tenant_move_in(j, 2, "Mert Kılıç", "mert")
    j.accrue("Kasım 2026")
    j.invariants("F6 step 4: Kasım accrued")

    j.clock.advance_to("2026-11-18")                         # 5. Oya moves into A-3, split approved
    tenant_move_in(j, 3, "Oya Çelik", "oya")
    reviewer = second_manager(j)
    pending = j.api.call("GET", "/api/v1/accrual-corrections", reviewer.token)
    for correction in pending:
        if correction.get("status") == "PENDING":
            j.api.call("POST", f"/api/v1/accrual-corrections/{correction['id']}/decide", reviewer.token,
                       body={"approve": True, "note": "F6 split approved"})
    j.invariants("F6 step 5: Oya's split approved")
    j.clock.advance_to("2026-11-19")
    return j
