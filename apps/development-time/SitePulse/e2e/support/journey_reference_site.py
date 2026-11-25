"""The F1 and F2 reference site as the manager builds it through the screens.

GUI-13-10 (SC-13-01-12) grows an empty site to the F1 and F2 reference plans, and the
STORY-13-06 lifecycle chain (SC-13-06-01) starts from the same two states. Both tests use
the helpers here so the screen flow and the expected SQL shape stay in one place.
"""
from __future__ import annotations

from decimal import Decimal

from playwright.sync_api import Page

from pages import Occupancy, ResidentsTab

F1_UNIT_PLAN = (
    (1, "A-01", "VACANT", "Flat", Decimal("1500.00")),
    (2, "A-02", "VACANT", "Flat", Decimal("1500.00")),
    (3, "A-03", "VACANT", "Flat", Decimal("1500.00")),
    (4, "A-04", "VACANT", "Flat", Decimal("1500.00")),
    (5, "A-05", "VACANT", "Flat", Decimal("1500.00")),
    (6, "A-06", "VACANT", "Large flat", Decimal("2250.00")),
    (7, "A-07", "VACANT", "Flat", Decimal("1500.00")),
)

F1_TARIFFS = {"Flat": Decimal("1500.00"), "Large flat": Decimal("2250.00")}

# F2 reference plan: owner and tenant per unit, and the unit's occupancy state.
F2_UNIT_PLAN = (
    (1, "Ayşe Kaya", "", "OWNER_OCCUPIED"),
    (2, "Ahmet Yılmaz", "Selin Demir", "TENANT_OCCUPIED"),
    (3, "Burak Şahin", "", "VACANT"),
    (4, "Ahmet Yılmaz", "", "OWNER_OCCUPIED"),
    (5, "Can Öztürk", "Deniz Arslan", "TENANT_OCCUPIED"),
    (6, "Elif Aydın", "", "OWNER_OCCUPIED"),
    (7, "", "", "VACANT"),
)

F2_NAMES = ("Ayşe Kaya", "Ahmet Yılmaz", "Selin Demir", "Burak Şahin", "Can Öztürk", "Deniz Arslan", "Elif Aydın")


def site_unit_ids(stack, site: int) -> list[str]:
    """The site's unit ids in unit-number order."""
    ids = stack.sql(f"SELECT id FROM units WHERE site_id = {site} ORDER BY unit_number;").splitlines()
    assert len(ids) == 7, ids
    return ids


def add_reference_units(page: Page) -> None:
    """F0 -> F1 through the screens: block "A Blok" with seven units and the reference tariffs.

    The block/units screen assigns one house type per batch, so the seventh unit (the
    reference plan's single "Large flat") is created in its own batch; the last batch
    reuses "Flat" at the same amount instead of repricing it.
    """
    residents = ResidentsTab(page).open()
    residents.start_add_block().fill(
        "A Blok", start_unit=1, unit_count=5, total_floors=7, house_type="Flat", monthly_dues="1.500,00",
    ).save()
    residents.start_add_block().fill(
        "A Blok", start_unit=6, unit_count=1, total_floors=7,
        house_type="Large flat", monthly_dues="2.250,00",
    ).save()
    residents.start_add_block().fill(
        "A Blok", start_unit=7, unit_count=1, total_floors=7, house_type="Flat", monthly_dues="1.500,00",
    ).save()


def add_reference_owners(page: Page, *, vacant_units: tuple[int, ...] = (3,)) -> None:
    """F1 -> F2 through the screens: the reference owners on units 1 to 6 (REQ-042 person cards).

    A unit in `vacant_units` is registered with no occupancy session, so a tenant can be moved
    in afterwards. That matters with occupancy-aware proration: an owner session for the same
    day would split the month between both sessions.
    """
    residents = ResidentsTab(page).open()
    owners = {
        1: ("Ayşe Kaya", "ayse@a13.e2e.test", "05321110001"),
        2: ("Ahmet Yılmaz", "ahmet@a13.e2e.test", "05321110002"),
        3: ("Burak Şahin", "burak@a13.e2e.test", "05321110004"),
        5: ("Can Öztürk", "can@a13.e2e.test", "05321110006"),
    }
    for unit_no, (name, email, phone) in owners.items():
        occupancy = "Boş Daire" if unit_no in vacant_units else None
        residents.start_add().fill(str(unit_no), name, email, phone, occupancy=occupancy).save()
    residents.start_add().fill(
        "4", "Ahmet Yılmaz", "ahmet@a13.e2e.test", "05321110002", reuse_existing=True,
    ).save()
    residents.start_add().fill(
        "6", "Elif Aydın", "elif@a13.e2e.test", "05321110007", house_type="Large flat",
    ).save()


def add_reference_people(page: Page, stack, site: int) -> None:
    """F1 -> F2 through the screens: the reference owners and the two tenants moving in."""
    add_reference_owners(page)
    unit_ids = site_unit_ids(stack, site)
    Occupancy(page).move_in(unit_ids[1], "Selin Demir", "selin@a13.e2e.test", "05321110003")
    Occupancy(page).move_in(unit_ids[4], "Deniz Arslan", "deniz@a13.e2e.test", "05321110005")


def assert_site_equals_f1(stack, site: int) -> None:
    """Compare the site with the F1 reference plan built by `add_reference_units`."""
    assert stack.sql(
        f"SELECT block_name || '|' || total_floors FROM blocks WHERE site_id = {site};"
    ) == "A Blok|7"

    rows = stack.sql(
        "SELECT u.unit_number || '|' || b.block_name || '|' || u.occupancy_status || '|' || "
        "COALESCE(h.type_name, '') || '|' || COALESCE(h.dues_amount::text, '0') "
        "FROM units u JOIN blocks b ON b.id = u.block_id "
        "LEFT JOIN house_types h ON h.id = u.house_type_id "
        f"WHERE u.site_id = {site} ORDER BY u.unit_number;"
    ).splitlines()
    parsed = []
    for line in rows:
        unit_no, block_name, status, type_name, amount = line.split("|")
        # The unit label is derived (the units table stores no label column).
        label = f"{block_name.replace(' Blok', '').strip()}-{int(unit_no):02d}"
        parsed.append((int(unit_no), label, status, type_name, Decimal(amount)))
    assert tuple(parsed) == F1_UNIT_PLAN, rows

    tariffs = {
        name: Decimal(amount)
        for name, amount in (
            line.split("|")
            for line in stack.sql(
                f"SELECT type_name || '|' || dues_amount::text FROM house_types WHERE site_id = {site};"
            ).splitlines()
        )
    }
    assert tariffs == F1_TARIFFS, tariffs

    assert stack.sql(f"SELECT COUNT(*) FROM persons WHERE site_id = {site};") == "1", (
        "F1 has no people beyond the manager"
    )
    assert stack.sql(
        "SELECT COUNT(*) FROM units WHERE "
        f"site_id = {site} AND (owner_person_id IS NOT NULL OR tenant_person_id IS NOT NULL);"
    ) == "0", "F1 units are unassigned"
    assert stack.sql(
        "SELECT COUNT(*) FROM dues_liabilities d JOIN units u ON u.id = d.unit_id "
        f"WHERE u.site_id = {site};"
    ) == "0"
    assert stack.sql(f"SELECT COUNT(*) FROM dues_periods WHERE site_id = {site};") == "0"


def assert_site_equals_f2(stack, site: int) -> None:
    """Compare owners, tenants and occupancy with the F2 reference plan."""
    rows = stack.sql(
        "SELECT u.unit_number || '|' || COALESCE(o.full_name, '') || '|' || "
        "COALESCE(t.full_name, '') || '|' || u.occupancy_status "
        "FROM units u LEFT JOIN persons o ON o.id = u.owner_person_id "
        "LEFT JOIN persons t ON t.id = u.tenant_person_id "
        f"WHERE u.site_id = {site} ORDER BY u.unit_number;"
    ).splitlines()
    assert rows == ["|".join(str(part) for part in row) for row in F2_UNIT_PLAN], rows

    people = stack.sql(
        f"SELECT full_name FROM persons WHERE site_id = {site} ORDER BY full_name;"
    ).splitlines()
    for name in F2_NAMES:
        assert name in people, f"{name} is missing from the site's people"
    assert len(people) == 8, f"expected the manager and seven people: {people}"
    assert stack.sql(
        "SELECT COUNT(*) FROM dues_liabilities d JOIN units u ON u.id = d.unit_id "
        f"WHERE u.site_id = {site};"
    ) == "0"
    assert stack.sql(f"SELECT COUNT(*) FROM dues_periods WHERE site_id = {site};") == "0"
