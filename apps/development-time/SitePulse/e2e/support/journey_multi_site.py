"""Multi-site financial journey builder for Epic 13 (zero to multi-site journey).

Sets up Site A (24 units @ TRY 1,000.00) and Site B (64 units across B1 and B2 @ TRY 750.00)
with zero grace days and the complete initial resident roster specified in
docs/testing/journey-plan/zero-to-multi-site-financial-journey.md.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from decimal import Decimal

from support.api import Api, Session
from support.journey_attempts import (
    JourneyClock,
    JourneyManifest,
    ledger_invariants,
    make_viban,
    _safe_id,
    _slug,
    _sql_text,
)
from support.stack import E2EStack


@dataclass
class MultiSiteJourney:
    """Handles and references for the two onboarded sites across 4 billing periods."""

    manifest: JourneyManifest
    clock: JourneyClock
    api: Api
    stack: E2EStack
    site_a_id: str
    site_b_id: str
    manager_a: Session
    manager_b: Session
    manager_a_password: str
    manager_b_password: str
    units_a: dict[str, str] = field(default_factory=dict)  # "A-01" -> unit_id
    units_b: dict[str, str] = field(default_factory=dict)  # "B1-01" -> unit_id, "B2-01" -> unit_id
    people: dict[str, str] = field(default_factory=dict)   # "Ada Kaya" -> person_id
    routine_a: list[tuple[str, str]] = field(default_factory=list)  # (unit_id, "Owner A-04")
    routine_b: list[tuple[str, str]] = field(default_factory=list)  # (unit_id, "Owner B1-02")

    def unit_a(self, label: str) -> str:
        return self.units_a[label]

    def unit_b(self, label: str) -> str:
        return self.units_b[label]

    def accrue_a(self, period: str, due_date: str) -> dict:
        return self.api.accrue_period(self.manager_a, period, Decimal("1000.00"), due_date)

    def accrue_b(self, period: str, due_date: str) -> dict:
        return self.api.accrue_period(self.manager_b, period, Decimal("750.00"), due_date)

    def invariants_a(self, stage: str) -> dict:
        return ledger_invariants(self.api, self.manager_a, self.site_a_id, stage=f"[Site A] {stage}")

    def invariants_b(self, stage: str) -> dict:
        return ledger_invariants(self.api, self.manager_b, self.site_b_id, stage=f"[Site B] {stage}")

    def post_routine_payments(self, period_label: str) -> None:
        """Record on-time full payments for all 83 routine owner-occupants."""
        # 21 in Site A @ 1,000.00
        for unit_id, name in self.routine_a:
            self.api.record_manual_payment(
                self.manager_a,
                unit_id,
                Decimal("1000.00"),
                payer_name=name,
                payer_role="OWNER",
                channel="MANUAL_CASH",
                description=f"{period_label} aidat ödemesi",
                idempotency_key=f"pay-a-{unit_id}-{period_label}",
            )
        # 62 in Site B @ 750.00
        for unit_id, name in self.routine_b:
            self.api.record_manual_payment(
                self.manager_b,
                unit_id,
                Decimal("750.00"),
                payer_name=name,
                payer_role="OWNER",
                channel="MANUAL_CASH",
                description=f"{period_label} aidat ödemesi",
                idempotency_key=f"pay-b-{unit_id}-{period_label}",
            )


def build_multi_site_journey(
    api: Api,
    stack: E2EStack,
    saas: Session,
    manifest: JourneyManifest,
    start_date: str = "2027-01-01",
) -> MultiSiteJourney:
    """Onboard Site A and Site B, create 88 units and registers all residents."""
    clock = JourneyClock(api, start_date)
    attempt = _slug(manifest.attempt_id)

    # 1. SaaS onboarding of Site A and Site B
    site_a_name = f"Site A {attempt[:8]}"
    manager_a_email = f"manager.a.{attempt[:8]}@journey.e2e.test"
    creds_a = api.create_site(saas, site_a_name, manager_a_email, admin_name="Site A Manager", blocks=())
    site_a_id = str(creds_a["site_id"])
    manifest.record("site_ids", site_a_id)
    manager_a_pass = f"E2E-Pass-SiteA-{attempt[:6]}-1!"
    api.change_password(manager_a_email, str(creds_a["temporary_password"]), manager_a_pass)
    manager_a = api.login(manager_a_email, manager_a_pass)
    manifest.record("user_ids", manager_a.user["id"])

    site_b_name = f"Site B {attempt[:8]}"
    manager_b_email = f"manager.b.{attempt[:8]}@journey.e2e.test"
    creds_b = api.create_site(saas, site_b_name, manager_b_email, admin_name="Site B Manager", blocks=())
    site_b_id = str(creds_b["site_id"])
    manifest.record("site_ids", site_b_id)
    manager_b_pass = f"E2E-Pass-SiteB-{attempt[:6]}-1!"
    api.change_password(manager_b_email, str(creds_b["temporary_password"]), manager_b_pass)
    manager_b = api.login(manager_b_email, manager_b_pass)
    manifest.record("user_ids", manager_b.user["id"])

    # Grab a valid bcrypt password hash to seed resident user rows
    password_hash = stack.sql(f"SELECT password_hash FROM users WHERE id = {int(manager_a.user['id'])};")

    sa_id = _safe_id(site_a_id)
    sb_id = _safe_id(site_b_id)

    # 2. Build Site A structure: Block A, 24 units, house type @ 1000.00
    stack.sql(
        "BEGIN; "
        f"DELETE FROM blocks WHERE site_id = {sa_id}; "
        f"UPDATE sites SET proration_enabled = FALSE, due_day = 10, accrual_day = 1, grace_days = 0 WHERE id = {sa_id}; "
        f"INSERT INTO blocks (site_id, block_name, total_floors) VALUES ({sa_id}, 'A', 24); "
        f"INSERT INTO house_types (site_id, type_name, dues_amount, description) "
        f"VALUES ({sa_id}, 'Standard', 1000.00, 'Site A Tariff'); "
        "INSERT INTO units (block_id, site_id, unit_number, floor, land_share, occupancy_status, house_type, house_type_id, created_at) "
        f"SELECT b.id, {sa_id}, n.unit_number, 1, 1, 'VACANT', h.type_name, h.id, TIMESTAMPTZ '2026-12-01 00:00:00+00' "
        f"FROM blocks b CROSS JOIN generate_series(1, 24) AS n(unit_number) "
        f"JOIN house_types h ON h.site_id = b.site_id AND h.type_name = 'Standard' "
        f"WHERE b.site_id = {sa_id} AND b.block_name = 'A'; "
        "COMMIT;"
    )

    # Deterministic virtual IBANs for Site A
    vibans_a = " ".join(
        f"UPDATE units SET virtual_iban = '{make_viban('00205', sa_id, 'A', u)}' "
        f"WHERE site_id = {sa_id} AND unit_number = {u};"
        for u in range(1, 25)
    )
    stack.sql(f"BEGIN; {vibans_a} COMMIT;")

    # 3. Build Site B structure: Blocks B1 (32 units) and B2 (32 units), house type @ 750.00
    stack.sql(
        "BEGIN; "
        f"DELETE FROM blocks WHERE site_id = {sb_id}; "
        f"UPDATE sites SET proration_enabled = FALSE, due_day = 10, accrual_day = 1, grace_days = 0 WHERE id = {sb_id}; "
        f"INSERT INTO blocks (site_id, block_name, total_floors) VALUES "
        f"({sb_id}, 'B1', 32), ({sb_id}, 'B2', 32); "
        f"INSERT INTO house_types (site_id, type_name, dues_amount, description) "
        f"VALUES ({sb_id}, 'Standard', 750.00, 'Site B Tariff'); "
        "INSERT INTO units (block_id, site_id, unit_number, floor, land_share, occupancy_status, house_type, house_type_id, created_at) "
        f"SELECT b.id, {sb_id}, n.unit_number, 1, 1, 'VACANT', h.type_name, h.id, TIMESTAMPTZ '2026-12-01 00:00:00+00' "
        f"FROM blocks b CROSS JOIN generate_series(1, 32) AS n(unit_number) "
        f"JOIN house_types h ON h.site_id = b.site_id AND h.type_name = 'Standard' "
        f"WHERE b.site_id = {sb_id} AND b.block_name IN ('B1', 'B2'); "
        "COMMIT;"
    )

    vibans_b = " ".join(
        f"UPDATE units SET virtual_iban = '{make_viban('00205', sb_id, blk, u)}' "
        f"WHERE site_id = {sb_id} AND block_id = (SELECT id FROM blocks WHERE site_id = {sb_id} AND block_name = '{blk}') AND unit_number = {u};"
        for blk in ("B1", "B2")
        for u in range(1, 33)
    )
    stack.sql(f"BEGIN; {vibans_b} COMMIT;")

    # Record all unit IDs in manifest and dictionaries
    unit_rows_a = stack.sql(
        f"SELECT u.unit_number || '|' || u.id FROM units u WHERE u.site_id = {sa_id} ORDER BY u.unit_number;"
    ).splitlines()
    units_a = {f"A-{int(line.split('|')[0]):02d}": line.split("|")[1] for line in unit_rows_a}
    for uid in units_a.values():
        manifest.record("unit_ids", uid)

    unit_rows_b = stack.sql(
        f"SELECT b.block_name || '-' || lpad(u.unit_number::text, 2, '0') || '|' || u.id "
        f"FROM units u JOIN blocks b ON b.id = u.block_id WHERE u.site_id = {sb_id} ORDER BY b.block_name, u.unit_number;"
    ).splitlines()
    units_b = {line.split("|")[0]: line.split("|")[1] for line in unit_rows_b}
    for uid in units_b.values():
        manifest.record("unit_ids", uid)

    # 4. Create Persons for Site A
    # Detailed persons in Site A:
    # A-01: Ada Kaya (owner-occupant), Ali Kaya (household member)
    # A-02: Cara Demir (owner), Dan Arslan (tenant), Derya Arslan (household member)
    # A-03: Fay Çelik (owner-occupant)
    # Transition actors: Ben Kaya (buyer for A-01), Eli Koç (tenant for A-02)
    # Routine owners: Owner A-04 .. Owner A-24
    site_a_people: dict[str, tuple[str, str]] = {
        "ada": ("Ada Kaya", "HOME_OWNER"),
        "ali": ("Ali Kaya", "HOME_RESIDENT"),
        "cara": ("Cara Demir", "HOME_OWNER"),
        "dan": ("Dan Arslan", "HOME_RESIDENT"),
        "derya": ("Derya Arslan", "HOME_RESIDENT"),
        "fay": ("Fay Çelik", "HOME_OWNER"),
        "ben": ("Ben Kaya", "HOME_OWNER"),
        "eli": ("Eli Koç", "HOME_RESIDENT"),
    }
    for num in range(4, 25):
        site_a_people[f"owner_a_{num:02d}"] = (f"Owner A-{num:02d}", "HOME_OWNER")

    emails_a = {k: f"{attempt[:6]}.a.{k}@journey.e2e.test".lower() for k in site_a_people}
    person_values_a = ", ".join(
        f"({sa_id}, {_sql_text(name)}, {_sql_text(emails_a[k])}, {_sql_text(ptype)})"
        for k, (name, ptype) in site_a_people.items()
    )
    stack.sql(f"INSERT INTO persons (site_id, full_name, email, person_type) VALUES {person_values_a};")

    prows_a = stack.sql(
        f"SELECT id || '|' || full_name FROM persons WHERE site_id = {sa_id};"
    ).splitlines()
    people_map = {line.split("|")[1]: line.split("|")[0] for line in prows_a}
    for pid in people_map.values():
        manifest.record("person_ids", pid)

    # 5. Create Persons for Site B
    # Detailed persons in Site B:
    # B1-01: Gus Şahin (owner-occupant)
    # B2-01: Ivan Öztürk (owner), Juno Yıldız (tenant)
    # Transition actors: Hana Aydın (buyer for B1-01)
    # Routine owners: Owner B1-02 .. Owner B1-32, Owner B2-02 .. Owner B2-32
    site_b_people: dict[str, tuple[str, str]] = {
        "gus": ("Gus Şahin", "HOME_OWNER"),
        "ivan": ("Ivan Öztürk", "HOME_OWNER"),
        "juno": ("Juno Yıldız", "HOME_RESIDENT"),
        "hana": ("Hana Aydın", "HOME_OWNER"),
    }
    for num in range(2, 33):
        site_b_people[f"owner_b1_{num:02d}"] = (f"Owner B1-{num:02d}", "HOME_OWNER")
        site_b_people[f"owner_b2_{num:02d}"] = (f"Owner B2-{num:02d}", "HOME_OWNER")

    emails_b = {k: f"{attempt[:6]}.b.{k}@journey.e2e.test".lower() for k in site_b_people}
    person_values_b = ", ".join(
        f"({sb_id}, {_sql_text(name)}, {_sql_text(emails_b[k])}, {_sql_text(ptype)})"
        for k, (name, ptype) in site_b_people.items()
    )
    stack.sql(f"INSERT INTO persons (site_id, full_name, email, person_type) VALUES {person_values_b};")

    prows_b = stack.sql(
        f"SELECT id || '|' || full_name FROM persons WHERE site_id = {sb_id};"
    ).splitlines()
    for line in prows_b:
        pid, name = line.split("|")
        people_map[name] = pid
        manifest.record("person_ids", pid)

    # 6. Assign Initial Ownerships and Occupancies for Site A
    # A-01: Ada Kaya (owner & occupant), Ali Kaya (household member)
    u_a01 = units_a["A-01"]
    p_ada = people_map["Ada Kaya"]
    p_ali = people_map["Ali Kaya"]

    # A-02: Cara Demir (owner), Dan Arslan (tenant & occupant), Derya Arslan (household member)
    u_a02 = units_a["A-02"]
    p_cara = people_map["Cara Demir"]
    p_dan = people_map["Dan Arslan"]
    p_derya = people_map["Derya Arslan"]

    # A-03: Fay Çelik (owner & occupant)
    u_a03 = units_a["A-03"]
    p_fay = people_map["Fay Çelik"]

    statements_a = [
        "BEGIN;",
        # A-01
        f"UPDATE units SET owner_person_id = {p_ada}, occupancy_status = 'OWNER_OCCUPIED' WHERE id = {u_a01};",
        f"INSERT INTO unit_ownerships (unit_id, person_id, share_percentage, start_date, is_active) "
        f"VALUES ({u_a01}, {p_ada}, 100.00, DATE '2026-12-01', TRUE);",
        f"INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type, start_date, is_active) "
        f"VALUES ({u_a01}, {p_ada}, 'OWNER', DATE '2026-12-01', TRUE);",
        f"INSERT INTO occupancy_members (occupancy_id, person_id, full_name, relationship, is_emergency_contact) "
        f"SELECT id, {p_ali}, 'Ali Kaya', 'CHILD', FALSE FROM unit_occupancies WHERE unit_id = {u_a01} AND is_active;",

        # A-02
        f"UPDATE units SET owner_person_id = {p_cara}, tenant_person_id = {p_dan}, occupancy_status = 'TENANT_OCCUPIED' WHERE id = {u_a02};",
        f"INSERT INTO unit_ownerships (unit_id, person_id, share_percentage, start_date, is_active) "
        f"VALUES ({u_a02}, {p_cara}, 100.00, DATE '2026-12-01', TRUE);",
        f"INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type, start_date, is_active) "
        f"VALUES ({u_a02}, {p_dan}, 'TENANT', DATE '2026-12-01', TRUE);",
        f"INSERT INTO occupancy_members (occupancy_id, person_id, full_name, relationship, is_emergency_contact) "
        f"SELECT id, {p_derya}, 'Derya Arslan', 'SPOUSE', FALSE FROM unit_occupancies WHERE unit_id = {u_a02} AND is_active;",

        # A-03
        f"UPDATE units SET owner_person_id = {p_fay}, occupancy_status = 'OWNER_OCCUPIED' WHERE id = {u_a03};",
        f"INSERT INTO unit_ownerships (unit_id, person_id, share_percentage, start_date, is_active) "
        f"VALUES ({u_a03}, {p_fay}, 100.00, DATE '2026-12-01', TRUE);",
        f"INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type, start_date, is_active) "
        f"VALUES ({u_a03}, {p_fay}, 'OWNER', DATE '2026-12-01', TRUE);",
    ]

    routine_a: list[tuple[str, str]] = []
    for num in range(4, 25):
        lbl = f"A-{num:02d}"
        uid = units_a[lbl]
        name = f"Owner A-{num:02d}"
        pid = people_map[name]
        routine_a.append((uid, name))
        statements_a.extend([
            f"UPDATE units SET owner_person_id = {pid}, occupancy_status = 'OWNER_OCCUPIED' WHERE id = {uid};",
            f"INSERT INTO unit_ownerships (unit_id, person_id, share_percentage, start_date, is_active) "
            f"VALUES ({uid}, {pid}, 100.00, DATE '2026-12-01', TRUE);",
            f"INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type, start_date, is_active) "
            f"VALUES ({uid}, {pid}, 'OWNER', DATE '2026-12-01', TRUE);",
        ])

    statements_a.append("COMMIT;")
    stack.sql(" ".join(statements_a))

    # 7. Assign Initial Ownerships and Occupancies for Site B
    # B1-01: Gus Şahin (owner & occupant)
    u_b101 = units_b["B1-01"]
    p_gus = people_map["Gus Şahin"]

    # B2-01: Ivan Öztürk (owner), Juno Yıldız (tenant & occupant)
    u_b201 = units_b["B2-01"]
    p_ivan = people_map["Ivan Öztürk"]
    p_juno = people_map["Juno Yıldız"]

    statements_b = [
        "BEGIN;",
        # B1-01
        f"UPDATE units SET owner_person_id = {p_gus}, occupancy_status = 'OWNER_OCCUPIED' WHERE id = {u_b101};",
        f"INSERT INTO unit_ownerships (unit_id, person_id, share_percentage, start_date, is_active) "
        f"VALUES ({u_b101}, {p_gus}, 100.00, DATE '2026-12-01', TRUE);",
        f"INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type, start_date, is_active) "
        f"VALUES ({u_b101}, {p_gus}, 'OWNER', DATE '2026-12-01', TRUE);",

        # B2-01
        f"UPDATE units SET owner_person_id = {p_ivan}, tenant_person_id = {p_juno}, occupancy_status = 'TENANT_OCCUPIED' WHERE id = {u_b201};",
        f"INSERT INTO unit_ownerships (unit_id, person_id, share_percentage, start_date, is_active) "
        f"VALUES ({u_b201}, {p_ivan}, 100.00, DATE '2026-12-01', TRUE);",
        f"INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type, start_date, is_active) "
        f"VALUES ({u_b201}, {p_juno}, 'TENANT', DATE '2026-12-01', TRUE);",
    ]

    routine_b: list[tuple[str, str]] = []
    for num in range(2, 33):
        # B1 routine
        lbl_b1 = f"B1-{num:02d}"
        uid_b1 = units_b[lbl_b1]
        name_b1 = f"Owner B1-{num:02d}"
        pid_b1 = people_map[name_b1]
        routine_b.append((uid_b1, name_b1))
        statements_b.extend([
            f"UPDATE units SET owner_person_id = {pid_b1}, occupancy_status = 'OWNER_OCCUPIED' WHERE id = {uid_b1};",
            f"INSERT INTO unit_ownerships (unit_id, person_id, share_percentage, start_date, is_active) "
            f"VALUES ({uid_b1}, {pid_b1}, 100.00, DATE '2026-12-01', TRUE);",
            f"INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type, start_date, is_active) "
            f"VALUES ({uid_b1}, {pid_b1}, 'OWNER', DATE '2026-12-01', TRUE);",
        ])

        # B2 routine
        lbl_b2 = f"B2-{num:02d}"
        uid_b2 = units_b[lbl_b2]
        name_b2 = f"Owner B2-{num:02d}"
        pid_b2 = people_map[name_b2]
        routine_b.append((uid_b2, name_b2))
        statements_b.extend([
            f"UPDATE units SET owner_person_id = {pid_b2}, occupancy_status = 'OWNER_OCCUPIED' WHERE id = {uid_b2};",
            f"INSERT INTO unit_ownerships (unit_id, person_id, share_percentage, start_date, is_active) "
            f"VALUES ({uid_b2}, {pid_b2}, 100.00, DATE '2026-12-01', TRUE);",
            f"INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type, start_date, is_active) "
            f"VALUES ({uid_b2}, {pid_b2}, 'OWNER', DATE '2026-12-01', TRUE);",
        ])

    statements_b.append("COMMIT;")
    stack.sql(" ".join(statements_b))

    # 8. Create User Accounts for all persons so resident auth and lookups work
    all_site_ids = f"({sa_id}, {sb_id})"
    stack.sql(
        "BEGIN; "
        "INSERT INTO users (site_id, person_id, email, password_hash, role, must_change_password) "
        f"SELECT p.site_id, p.id, p.email, {_sql_text(password_hash)}, "
        "CASE WHEN p.person_type = 'HOME_OWNER' THEN 'HOME_OWNER' ELSE 'HOME_RESIDENT' END, FALSE "
        f"FROM persons p WHERE p.site_id IN {all_site_ids} "
        "AND p.person_type IN ('HOME_OWNER', 'HOME_RESIDENT') "
        "ON CONFLICT DO NOTHING; "
        "INSERT INTO user_site_roles (user_id, site_id, role) "
        f"SELECT id, site_id, role FROM users WHERE site_id IN {all_site_ids} "
        "ON CONFLICT (user_id, site_id, role) DO NOTHING; "
        "COMMIT;"
    )
    user_rows = stack.sql(f"SELECT id FROM users WHERE site_id IN {all_site_ids};").splitlines()
    for uid in user_rows:
        manifest.record("user_ids", uid)

    # Restart backend to load synchronized in-memory state
    stack.restart_backend()

    return MultiSiteJourney(
        manifest=manifest,
        clock=clock,
        api=api,
        stack=stack,
        site_a_id=site_a_id,
        site_b_id=site_b_id,
        manager_a=manager_a,
        manager_b=manager_b,
        manager_a_password=manager_a_pass,
        manager_b_password=manager_b_pass,
        units_a=units_a,
        units_b=units_b,
        people=people_map,
        routine_a=routine_a,
        routine_b=routine_b,
    )
