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
    _safe_id,
    _slug,
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
    expected_posted_cash_a: Decimal = Decimal("90658.50")
    expected_posted_cash_b: Decimal = Decimal("189538.75")
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
    manifest.bind_database(stack.db_name)
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

    sa_id = _safe_id(site_a_id)
    sb_id = _safe_id(site_b_id)

    # Site timing is deterministic fixture configuration. Structure and resident data below
    # are created through the same manager APIs used by the product UI.
    stack.sql(
        "BEGIN; "
        f"UPDATE sites SET proration_enabled = FALSE, due_day = 10, accrual_day = 1, grace_days = 0 "
        f"WHERE id IN ({sa_id}, {sb_id}); "
        "COMMIT;"
    )
    api.create_block(manager_a, "A", total_floors=6, site_id=site_a_id)
    api.create_block(manager_b, "B1", total_floors=8, site_id=site_b_id)
    api.create_block(manager_b, "B2", total_floors=8, site_id=site_b_id)
    created_a = api.create_units(manager_a, "A", start_unit=1, end_unit=24, site_id=site_a_id)
    created_b1 = api.create_units(manager_b, "B1", start_unit=1, end_unit=32, site_id=site_b_id)
    created_b2 = api.create_units(manager_b, "B2", start_unit=1, end_unit=32, site_id=site_b_id)
    units_a = {unit["label"]: str(unit["id"]) for unit in created_a}
    units_b = {unit["label"]: str(unit["id"]) for unit in (*created_b1, *created_b2)}
    assert len(units_a) == 24 and len(units_b) == 64
    for unit_id in (*units_a.values(), *units_b.values()):
        manifest.record("unit_ids", unit_id)

    contact_sequence = 0

    def next_phone() -> str:
        nonlocal contact_sequence
        contact_sequence += 1
        return f"+90 532 {100 + contact_sequence:03d} 01 01"

    def register(manager: Session, site_id: str, block: str, number: int, name: str, key: str,
                 *, resident: bool = True, tenant: str | None = None,
                 household: tuple[str, str] | None = None) -> None:
        email = f"{attempt[:8]}.{key}@journey.e2e.test".lower()
        owner_phone = next_phone()
        tenant_data = None if tenant is None else {
            "full_name": tenant,
            "email": f"{attempt[:8]}.{key}.tenant@journey.e2e.test".lower(),
            "phone": next_phone(),
        }
        members = [] if household is None else [{
            "full_name": household[0],
            "relationship": household[1],
            "email": f"{attempt[:8]}.{key}.household@journey.e2e.test".lower(),
            "phone": next_phone(),
        }]
        api.register_home_owner(
            manager, block, number, name, email, phone=owner_phone,
            is_resident=resident,
            tenant=tenant_data,
            household_members=members,
            monthly_dues=Decimal("0.00"),
            house_type="JourneyNoTariff",
            site_id=site_id,
        )

    # Site A's five detailed residents and its 21 routine owner-occupants.
    register(manager_a, site_a_id, "A", 1, "Ada Kaya", "ada", household=("Ali Kaya", "CHILD"))
    register(manager_a, site_a_id, "A", 2, "Cara Demir", "cara", resident=False,
             tenant="Dan Arslan", household=("Derya Arslan", "SPOUSE"))
    register(manager_a, site_a_id, "A", 3, "Fay Çelik", "fay")
    routine_a: list[tuple[str, str]] = []
    for number in range(4, 25):
        name = f"Owner A-{number:02d}"
        register(manager_a, site_a_id, "A", number, name, f"owner-a-{number:02d}")
        routine_a.append((units_a[f"A-{number:02d}"], name))

    # Site B's two detailed residents and its 62 routine owner-occupants.
    register(manager_b, site_b_id, "B1", 1, "Gus Şahin", "gus")
    register(manager_b, site_b_id, "B2", 1, "Ivan Öztürk", "ivan", resident=False, tenant="Juno Yıldız")
    routine_b: list[tuple[str, str]] = []
    for block in ("B1", "B2"):
        for number in range(2, 33):
            name = f"Owner {block}-{number:02d}"
            register(manager_b, site_b_id, block, number, name, f"owner-{block.lower()}-{number:02d}")
            routine_b.append((units_b[f"{block}-{number:02d}"], name))

    # The manifest captures all resources created by these API calls. SQL is used here only
    # to read the IDs back for cleanup; no unit, person, user or occupancy is seeded directly.
    initial_liabilities = stack.sql(
        "SELECT COUNT(*) FROM dues_liabilities d JOIN units u ON u.id = d.unit_id "
        f"WHERE u.site_id IN ({sa_id}, {sb_id}) AND d.status <> 'CANCELLED';"
    )
    assert initial_liabilities == "0", (
        "manager registration must leave liabilities empty before the first planned accrual; "
        f"found {initial_liabilities} rows"
    )
    people_rows = stack.sql(
        f"SELECT id || '|' || full_name FROM persons WHERE site_id IN ({sa_id}, {sb_id}) ORDER BY id;"
    ).splitlines()
    people_map: dict[str, str] = {}
    for row in people_rows:
        person_id, full_name = row.split("|", 1)
        people_map[full_name] = person_id
        manifest.record("person_ids", person_id)
    user_rows = stack.sql(f"SELECT id FROM users WHERE site_id IN ({sa_id}, {sb_id});").splitlines()
    for user_id in user_rows:
        manifest.record("user_ids", user_id)

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
