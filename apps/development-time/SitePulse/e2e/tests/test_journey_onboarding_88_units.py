"""E2E journey: onboard two sites and create all 88 units from zero (Issue #247, STORY-13-13).

Covers:
- SC-13-13-01: Onboard two sites from zero and create all 88 units with residents
"""
from __future__ import annotations

import os
from pathlib import Path

import pytest

from support.api import Api
from support.journey_attempts import (
    JourneyManifest,
    teardown_with_evidence,
)

E2E = Path(__file__).resolve().parents[1]


@pytest.mark.covers("SC-13-13-01")
@pytest.mark.core
def test_onboard_two_sites_and_create_88_units_from_zero(request, api: Api, actors, stack):
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    attempt = manifest.attempt_id[:8]

    try:
        manifest.record_step("start_onboarding", {"attempt": attempt})

        # 1. Onboard Site A with empty blocks
        site_a_name = f"Site A {attempt}"
        manager_a_email = f"manager.a.{attempt}@e2e.test"
        site_a_creds = api.create_site(
            saas, site_a_name, manager_a_email, admin_name="Site A Manager", blocks=()
        )
        site_a_id = str(site_a_creds["site_id"])
        manifest.record("site_ids", site_a_id)

        api.change_password(
            manager_a_email,
            str(site_a_creds["temporary_password"]),
            f"Pass-A-{attempt}-123!",
        )
        manager_a = api.login(manager_a_email, f"Pass-A-{attempt}-123!")
        manifest.record("user_ids", manager_a.user["id"])

        # 2. Onboard Site B with empty blocks
        site_b_name = f"Site B {attempt}"
        manager_b_email = f"manager.b.{attempt}@e2e.test"
        site_b_creds = api.create_site(
            saas, site_b_name, manager_b_email, admin_name="Site B Manager", blocks=()
        )
        site_b_id = str(site_b_creds["site_id"])
        manifest.record("site_ids", site_b_id)

        api.change_password(
            manager_b_email,
            str(site_b_creds["temporary_password"]),
            f"Pass-B-{attempt}-123!",
        )
        manager_b = api.login(manager_b_email, f"Pass-B-{attempt}-123!")
        manifest.record("user_ids", manager_b.user["id"])

        # Verify block and unit lists start empty
        blocks_a = api.get_blocks(manager_a, site_id=site_a_id)
        assert blocks_a == [], f"Site A blocks should start empty, got {blocks_a}"
        units_a_initial = api.get_units(manager_a, site_id=site_a_id)
        assert units_a_initial == [], f"Site A units should start empty, got {units_a_initial}"

        blocks_b = api.get_blocks(manager_b, site_id=site_b_id)
        assert blocks_b == [], f"Site B blocks should start empty, got {blocks_b}"
        units_b_initial = api.get_units(manager_b, site_id=site_b_id)
        assert units_b_initial == [], f"Site B units should start empty, got {units_b_initial}"

        manifest.record_step(
            "verified_empty_structure",
            {"site_a": site_a_id, "site_b": site_b_id},
        )

        # 3. Create Site A Block A with units A-01..A-24
        api.create_block(manager_a, "A", total_floors=6, site_id=site_a_id)
        created_a_units = api.create_units(
            manager_a, "A", start_unit=1, end_unit=24, site_id=site_a_id
        )
        assert len(created_a_units) == 24
        for u in created_a_units:
            manifest.record("unit_ids", u["id"])

        # 4. Create Site B Blocks B1 and B2 with units 01..32 in each
        api.create_block(manager_b, "B1", total_floors=8, site_id=site_b_id)
        created_b1_units = api.create_units(
            manager_b, "B1", start_unit=1, end_unit=32, site_id=site_b_id
        )
        assert len(created_b1_units) == 32
        for u in created_b1_units:
            manifest.record("unit_ids", u["id"])

        api.create_block(manager_b, "B2", total_floors=8, site_id=site_b_id)
        created_b2_units = api.create_units(
            manager_b, "B2", start_unit=1, end_unit=32, site_id=site_b_id
        )
        assert len(created_b2_units) == 32
        for u in created_b2_units:
            manifest.record("unit_ids", u["id"])

        # Assert exact labels and site unit counts (24 in A, 64 in B) BEFORE registering any people
        site_a_units = api.get_units(manager_a, site_id=site_a_id)
        assert len(site_a_units) == 24
        expected_a_labels = [f"A-{i:02d}" for i in range(1, 25)]
        assert [u["label"] for u in site_a_units] == expected_a_labels
        for u in site_a_units:
            assert u["occupancy_status"] == "VACANT"

        site_b_units = api.get_units(manager_b, site_id=site_b_id)
        assert len(site_b_units) == 64
        expected_b1_labels = {f"B1-{i:02d}" for i in range(1, 33)}
        expected_b2_labels = {f"B2-{i:02d}" for i in range(1, 33)}
        expected_b_labels = expected_b1_labels | expected_b2_labels
        assert set(u["label"] for u in site_b_units) == expected_b_labels
        for u in site_b_units:
            assert u["occupancy_status"] == "VACANT"

        manifest.record_step(
            "created_88_units_vacant",
            {
                "site_a_units": 24,
                "site_b_units": 64,
                "total_units": 88,
            },
        )

        # 5. Register 5 detailed units:
        # A-01: Ada owns and occupies (is_resident=True) + linked household member
        api.register_home_owner(
            manager_a,
            block="A",
            unit_no=1,
            owner_full_name="Ada Lovelace",
            email=f"ada.{attempt}@e2e.test",
            phone="+90 532 101 01 01",
            is_resident=True,
            household_members=[
                {
                    "full_name": "Ada Household Member",
                    "relationship": "CHILD",
                    "phone": "+90 532 101 01 02",
                    "email": f"ada.child.{attempt}@e2e.test",
                }
            ],
            site_id=site_a_id,
        )

        # A-02: Cara owns (is_resident=False), Dan rents (is_resident=True) + linked household member
        api.register_home_owner(
            manager_a,
            block="A",
            unit_no=2,
            owner_full_name="Cara Owner",
            email=f"cara.{attempt}@e2e.test",
            phone="+90 532 102 01 01",
            is_resident=False,
            tenant={
                "full_name": "Dan Tenant",
                "email": f"dan.{attempt}@e2e.test",
                "phone": "+90 532 102 01 02",
            },
            household_members=[
                {
                    "full_name": "Dan Household Member",
                    "relationship": "SPOUSE",
                    "phone": "+90 532 102 01 03",
                    "email": f"dan.spouse.{attempt}@e2e.test",
                }
            ],
            site_id=site_a_id,
        )

        # A-03: Fay owns and occupies (is_resident=True)
        api.register_home_owner(
            manager_a,
            block="A",
            unit_no=3,
            owner_full_name="Fay Owner",
            email=f"fay.{attempt}@e2e.test",
            phone="+90 532 103 01 01",
            is_resident=True,
            site_id=site_a_id,
        )

        # B1-01: Gus owns and occupies (is_resident=True)
        api.register_home_owner(
            manager_b,
            block="B1",
            unit_no=1,
            owner_full_name="Gus Owner",
            email=f"gus.{attempt}@e2e.test",
            phone="+90 532 201 01 01",
            is_resident=True,
            site_id=site_b_id,
        )

        # B2-01: Ivan owns (is_resident=False), Juno rents (is_resident=True)
        api.register_home_owner(
            manager_b,
            block="B2",
            unit_no=1,
            owner_full_name="Ivan Owner",
            email=f"ivan.{attempt}@e2e.test",
            phone="+90 532 301 01 01",
            is_resident=False,
            tenant={
                "full_name": "Juno Tenant",
                "email": f"juno.{attempt}@e2e.test",
                "phone": "+90 532 301 01 02",
            },
            site_id=site_b_id,
        )

        # 6. Register 83 distinct owner-occupants across remaining units:
        # 21 in Site A (units 4..24)
        for i in range(4, 25):
            api.register_home_owner(
                manager_a,
                block="A",
                unit_no=i,
                owner_full_name=f"Site A Owner {i:02d}",
                email=f"owner.a.{i:02d}.{attempt}@e2e.test",
                phone=f"+90 532 100 {i:02d} 00",
                is_resident=True,
                site_id=site_a_id,
            )

        # 31 in Site B Block B1 (units 2..32)
        for i in range(2, 33):
            api.register_home_owner(
                manager_b,
                block="B1",
                unit_no=i,
                owner_full_name=f"Site B1 Owner {i:02d}",
                email=f"owner.b1.{i:02d}.{attempt}@e2e.test",
                phone=f"+90 532 200 {i:02d} 00",
                is_resident=True,
                site_id=site_b_id,
            )

        # 31 in Site B Block B2 (units 2..32)
        for i in range(2, 33):
            api.register_home_owner(
                manager_b,
                block="B2",
                unit_no=i,
                owner_full_name=f"Site B2 Owner {i:02d}",
                email=f"owner.b2.{i:02d}.{attempt}@e2e.test",
                phone=f"+90 532 300 {i:02d} 00",
                is_resident=True,
                site_id=site_b_id,
            )

        # Record created persons and users in manifest
        site_persons = stack.sql(
            f"SELECT id FROM persons WHERE site_id IN ({int(site_a_id)}, {int(site_b_id)});"
        )
        for pid in site_persons.splitlines():
            if pid.strip():
                manifest.record("person_ids", pid.strip())

        site_users = stack.sql(
            f"SELECT id FROM users WHERE site_id IN ({int(site_a_id)}, {int(site_b_id)});"
        )
        for uid in site_users.splitlines():
            if uid.strip():
                manifest.record("user_ids", uid.strip())

        # 7. Verify owner, primary occupant, and household relationships:
        # A-01: Ada owns and occupies
        unit_map_a = {u["label"]: u for u in api.get_units(manager_a, site_id=site_a_id)}
        a01 = unit_map_a["A-01"]
        state_a01 = api.get_unit_occupancy_state(manager_a, a01["id"], site_id=site_a_id)
        assert state_a01["occupancy"] in ("OwnerOccupied", "OWNER_OCCUPIED")
        assert state_a01["occupant"]["full_name"] == "Ada Lovelace"
        assert len(state_a01["owners"]) == 1
        assert state_a01["owners"][0]["full_name"] == "Ada Lovelace"
        members_a01 = api.get_unit_members(manager_a, a01["id"], site_id=site_a_id)
        assert len(members_a01) == 1
        assert members_a01[0]["full_name"] == "Ada Household Member"
        assert members_a01[0]["relationship"] == "CHILD"

        # A-02: Cara owns, Dan rents + linked household member
        a02 = unit_map_a["A-02"]
        state_a02 = api.get_unit_occupancy_state(manager_a, a02["id"], site_id=site_a_id)
        assert state_a02["occupancy"] in ("TenantOccupied", "TENANT_OCCUPIED")
        assert state_a02["occupant"]["full_name"] == "Dan Tenant"
        assert len(state_a02["owners"]) == 1
        assert state_a02["owners"][0]["full_name"] == "Cara Owner"
        members_a02 = api.get_unit_members(manager_a, a02["id"], site_id=site_a_id)
        assert len(members_a02) == 1
        assert members_a02[0]["full_name"] == "Dan Household Member"
        assert members_a02[0]["relationship"] == "SPOUSE"

        # A-03: Fay owns and occupies
        a03 = unit_map_a["A-03"]
        state_a03 = api.get_unit_occupancy_state(manager_a, a03["id"], site_id=site_a_id)
        assert state_a03["occupancy"] in ("OwnerOccupied", "OWNER_OCCUPIED")
        assert state_a03["occupant"]["full_name"] == "Fay Owner"
        assert len(state_a03["owners"]) == 1
        assert state_a03["owners"][0]["full_name"] == "Fay Owner"

        # B1-01: Gus owns and occupies
        unit_map_b = {u["label"]: u for u in api.get_units(manager_b, site_id=site_b_id)}
        b1_01 = unit_map_b["B1-01"]
        state_b1_01 = api.get_unit_occupancy_state(manager_b, b1_01["id"], site_id=site_b_id)
        assert state_b1_01["occupancy"] in ("OwnerOccupied", "OWNER_OCCUPIED")
        assert state_b1_01["occupant"]["full_name"] == "Gus Owner"
        assert len(state_b1_01["owners"]) == 1
        assert state_b1_01["owners"][0]["full_name"] == "Gus Owner"

        # B2-01: Ivan owns, Juno rents
        b2_01 = unit_map_b["B2-01"]
        state_b2_01 = api.get_unit_occupancy_state(manager_b, b2_01["id"], site_id=site_b_id)
        assert state_b2_01["occupancy"] in ("TenantOccupied", "TENANT_OCCUPIED")
        assert state_b2_01["occupant"]["full_name"] == "Juno Tenant"
        assert len(state_b2_01["owners"]) == 1
        assert state_b2_01["owners"][0]["full_name"] == "Ivan Owner"

        # 8. Verify household members (and all registrations) receive NO independent charges merely by registration
        total_charges = stack.sql(
            "SELECT COUNT(*) FROM dues_liabilities dl JOIN units u ON dl.unit_id = u.id "
            f"WHERE u.site_id IN ({int(site_a_id)}, {int(site_b_id)});"
        )
        assert total_charges.strip() == "0", f"Registration should create 0 dues liabilities, got {total_charges}"

        # 9. Verify attempt manifest captured onboarding steps and site IDs
        manifest.record_step(
            "completed_onboarding_and_unit_creation",
            {
                "site_a_id": site_a_id,
                "site_b_id": site_b_id,
                "total_units": 88,
                "detailed_units": 5,
                "owner_occupants": 83,
            },
        )
        assert site_a_id in manifest.site_ids
        assert site_b_id in manifest.site_ids
        assert len(manifest.unit_ids) == 88
        assert len(manifest.steps) >= 4

    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
        raise
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)
