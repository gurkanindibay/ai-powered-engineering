"""SitePulse Product Manager Scenario Seeder (F0–F7).

Extracts the named starting states F0–F7 (docs/testing/journey-plan/README.md)
so both e2e tests (journey_attempts.py) and interactive Product Manager testing
share one source of truth.

Can run standalone against a running local backend with --features e2e using
POST /api/e2e/reload-state (no process restart or pytest needed), or within
E2EStack test runs.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass, field
from decimal import Decimal
from pathlib import Path
from typing import Any, Callable

# ---------------------------------------------------------------------------
# Constants and Reference Catalogues (docs/testing/journey-plan/README.md)
# ---------------------------------------------------------------------------

REFERENCE_CLOCKS = {
    "F0": "2026-09-01",
    "F1": "2026-09-01",
    "F2": "2026-09-01",
    "F3": "2026-10-01",
    "F4": "2026-11-19",
    "F5": "2026-11-19",
    "F6": "2026-11-19",
    "F7": "2026-11-19",
    "F8": "2026-11-19",
    "F8_CAPITAL": "2026-11-19",
    "F9": "2026-11-19",
    "F9_RECON": "2026-11-19",
    "F10": "2026-11-19",
    "F10_GOVERNANCE": "2026-11-19",
}

EXPECTED_TOTALS: dict[str, dict[str, Any]] = {
    "F0": {
        "blocks": 0, "units": 0, "people": 0, "accounts": 0,
        "periods": 0, "liabilities": 0, "receipts": 0,
        "overdue": Decimal("0.00"), "advance": Decimal("0.00"),
        "total_overdue": "0.00", "total_advance": "0.00",
    },
    "F1": {
        "blocks": 1, "units": 7, "people": 0, "accounts": 0,
        "periods": 0, "liabilities": 0, "receipts": 0,
        "overdue": Decimal("0.00"), "advance": Decimal("0.00"),
        "total_overdue": "0.00", "total_advance": "0.00",
    },
    "F2": {
        "blocks": 1, "units": 7, "people": 7, "accounts": 7,
        "periods": 0, "liabilities": 0, "receipts": 0,
        "overdue": Decimal("0.00"), "advance": Decimal("0.00"),
        "total_overdue": "0.00", "total_advance": "0.00",
    },
    "F3": {
        "blocks": 1, "units": 7, "people": 0, "accounts": 0,
        "periods": 1, "liabilities": 0, "receipts": 0,
        "overdue": Decimal("0.00"), "advance": Decimal("0.00"),
        "total_overdue": "0.00", "total_advance": "0.00",
    },
    "F4": {
        "blocks": 1, "units": 7, "people": 7, "accounts": 7,
        "periods": 1, "liabilities": 6, "receipts": 1,
        "overdue": Decimal("8800.00"), "advance": Decimal("0.00"),
        "total_overdue": "8800.00", "total_advance": "0.00",
    },
    "F5": {
        "blocks": 1, "units": 7, "people": 7, "accounts": 7,
        "periods": 3, "liabilities": 18, "receipts": 9,
        "overdue": Decimal("4567.50"), "advance": Decimal("1250.00"),
        "total_overdue": "4567.50", "total_advance": "1250.00",
    },
    "F6": {
        "blocks": 1, "units": 7, "people": 10, "accounts": 7,
        "periods": 3, "liabilities": 21, "receipts": 0,
        "overdue": Decimal("9750.00"), "advance": Decimal("0.00"),
        "total_overdue": "9750.00", "total_advance": "0.00",
    },
    "F7": {
        "blocks": 1, "units": 7, "people": 7, "accounts": 7,
        "periods": 3, "liabilities": 18, "receipts": 9,
        "overdue": Decimal("4567.50"), "advance": Decimal("1250.00"),
        "total_overdue": "4567.50", "total_advance": "1250.00",
    },
    "F8": {
        "blocks": 1, "units": 7, "people": 7, "accounts": 7,
        "periods": 3, "liabilities": 25, "receipts": 9,
        "overdue": Decimal("4567.50"), "advance": Decimal("1250.00"),
        "total_overdue": "4567.50", "total_advance": "1250.00",
        "capital_projects": 1,
        "capital_budget": Decimal("105000.00"),
        "capital_installments": 3,
        "capital_accrued": Decimal("35000.00"),
    },
    "F9": {
        "blocks": 1, "units": 7, "people": 11, "accounts": 7,
        "periods": 3, "liabilities": 21, "receipts": 0,
        "overdue": Decimal("9750.00"), "advance": Decimal("0.00"),
        "total_overdue": "9750.00", "total_advance": "0.00",
        "virtual_ibans_assigned": 7,
        "duplicate_candidates": 1,
    },
    "F10": {
        "blocks": 1, "units": 7, "people": 7, "accounts": 7,
        "periods": 4, "liabilities": 8, "receipts": 0,
        "overdue": Decimal("11600.00"), "advance": Decimal("0.00"),
        "total_overdue": "11600.00", "total_advance": "0.00",
        "sites": 2,
        "severe_arrears_units": 1,
        "active_payment_plans": 1,
        "heat_cost_periods": 1,
        "scheduled_meetings": 1,
    },
}
EXPECTED_TOTALS["F8_CAPITAL"] = EXPECTED_TOTALS["F8"]
EXPECTED_TOTALS["F9_RECON"] = EXPECTED_TOTALS["F9"]
EXPECTED_TOTALS["F10_GOVERNANCE"] = EXPECTED_TOTALS["F10"]

EXPECTED_UNIT_BALANCES: dict[str, list[dict[str, Any]]] = {
    "F0": [],
    "F1": [
        {"unit_number": i, "unit": f"A-{i}", "house_type": "Large flat" if i == 6 else "Flat",
         "amount_due": "0.00", "advance_balance": "0.00", "is_paid": True}
        for i in range(1, 8)
    ],
    "F2": [
        {"unit_number": i, "unit": f"A-{i}", "house_type": "Large flat" if i == 6 else "Flat",
         "amount_due": "0.00", "advance_balance": "0.00", "is_paid": True}
        for i in range(1, 8)
    ],
    "F3": [
        {"unit_number": i, "unit": f"A-{i}", "house_type": "Large flat" if i == 6 else "Flat",
         "amount_due": "0.00", "advance_balance": "0.00", "is_paid": True}
        for i in range(1, 8)
    ],
    "F4": [
        {"unit_number": 1, "unit": "A-1", "house_type": "Flat", "amount_due": "0.00", "advance_balance": "0.00", "is_paid": True},
        {"unit_number": 2, "unit": "A-2", "house_type": "Flat", "amount_due": "1600.00", "advance_balance": "0.00", "is_paid": False},
        {"unit_number": 3, "unit": "A-3", "house_type": "Flat", "amount_due": "1600.00", "advance_balance": "0.00", "is_paid": False},
        {"unit_number": 4, "unit": "A-4", "house_type": "Flat", "amount_due": "1600.00", "advance_balance": "0.00", "is_paid": False},
        {"unit_number": 5, "unit": "A-5", "house_type": "Flat", "amount_due": "1600.00", "advance_balance": "0.00", "is_paid": False},
        {"unit_number": 6, "unit": "A-6", "house_type": "Large flat", "amount_due": "2400.00", "advance_balance": "0.00", "is_paid": False},
        {"unit_number": 7, "unit": "A-7", "house_type": "Flat", "amount_due": "0.00", "advance_balance": "0.00", "is_paid": True},
    ],
    "F5": [
        {"unit_number": 1, "unit": "A-1", "house_type": "Flat", "amount_due": "0.00", "advance_balance": "0.00", "is_paid": True},
        {"unit_number": 2, "unit": "A-2", "house_type": "Flat", "amount_due": "1522.50", "advance_balance": "0.00", "is_paid": False},
        {"unit_number": 3, "unit": "A-3", "house_type": "Flat", "amount_due": "0.00", "advance_balance": "0.00", "is_paid": True},
        {"unit_number": 4, "unit": "A-4", "house_type": "Flat", "amount_due": "1522.50", "advance_balance": "0.00", "is_paid": False},
        {"unit_number": 5, "unit": "A-5", "house_type": "Flat", "amount_due": "1522.50", "advance_balance": "0.00", "is_paid": False},
        {"unit_number": 6, "unit": "A-6", "house_type": "Large flat", "amount_due": "0.00", "advance_balance": "1250.00", "is_paid": True},
        {"unit_number": 7, "unit": "A-7", "house_type": "Flat", "amount_due": "0.00", "advance_balance": "0.00", "is_paid": True},
    ],
    "F6": [
        {"unit_number": 1, "unit": "A-1", "house_type": "Flat", "amount_due": "1500.00", "advance_balance": "0.00", "is_paid": False},
        {"unit_number": 2, "unit": "A-2", "house_type": "Flat", "amount_due": "1500.00", "advance_balance": "0.00", "is_paid": False},
        {"unit_number": 3, "unit": "A-3", "house_type": "Flat", "amount_due": "1500.00", "advance_balance": "0.00", "is_paid": False},
        {"unit_number": 4, "unit": "A-4", "house_type": "Flat", "amount_due": "1500.00", "advance_balance": "0.00", "is_paid": False},
        {"unit_number": 5, "unit": "A-5", "house_type": "Flat", "amount_due": "1500.00", "advance_balance": "0.00", "is_paid": False},
        {"unit_number": 6, "unit": "A-6", "house_type": "Large flat", "amount_due": "2250.00", "advance_balance": "0.00", "is_paid": False},
        {"unit_number": 7, "unit": "A-7", "house_type": "Flat", "amount_due": "0.00", "advance_balance": "0.00", "is_paid": True},
    ],
    "F7": [
        {"unit_number": 1, "unit": "A-1", "house_type": "Flat", "amount_due": "0.00", "advance_balance": "0.00", "is_paid": True},
        {"unit_number": 2, "unit": "A-2", "house_type": "Flat", "amount_due": "1522.50", "advance_balance": "0.00", "is_paid": False},
        {"unit_number": 3, "unit": "A-3", "house_type": "Flat", "amount_due": "0.00", "advance_balance": "0.00", "is_paid": True},
        {"unit_number": 4, "unit": "A-4", "house_type": "Flat", "amount_due": "1522.50", "advance_balance": "0.00", "is_paid": False},
        {"unit_number": 5, "unit": "A-5", "house_type": "Flat", "amount_due": "1522.50", "advance_balance": "0.00", "is_paid": False},
        {"unit_number": 6, "unit": "A-6", "house_type": "Large flat", "amount_due": "0.00", "advance_balance": "1250.00", "is_paid": True},
        {"unit_number": 7, "unit": "A-7", "house_type": "Flat", "amount_due": "0.00", "advance_balance": "0.00", "is_paid": True},
    ],
    "F8": [
        {"unit_number": 1, "unit": "A-1", "house_type": "Flat", "amount_due": "0.00", "advance_balance": "0.00", "is_paid": True, "capital_due": "5000.00"},
        {"unit_number": 2, "unit": "A-2", "house_type": "Flat", "amount_due": "1522.50", "advance_balance": "0.00", "is_paid": False, "capital_due": "5000.00"},
        {"unit_number": 3, "unit": "A-3", "house_type": "Flat", "amount_due": "0.00", "advance_balance": "0.00", "is_paid": True, "capital_due": "5000.00"},
        {"unit_number": 4, "unit": "A-4", "house_type": "Flat", "amount_due": "1522.50", "advance_balance": "0.00", "is_paid": False, "capital_due": "5000.00"},
        {"unit_number": 5, "unit": "A-5", "house_type": "Flat", "amount_due": "1522.50", "advance_balance": "0.00", "is_paid": False, "capital_due": "5000.00"},
        {"unit_number": 6, "unit": "A-6", "house_type": "Large flat", "amount_due": "0.00", "advance_balance": "1250.00", "is_paid": True, "capital_due": "5000.00"},
        {"unit_number": 7, "unit": "A-7", "house_type": "Flat", "amount_due": "0.00", "advance_balance": "0.00", "is_paid": True, "capital_due": "5000.00"},
    ],
    "F9": [
        {"unit_number": 1, "unit": "A-1", "house_type": "Flat", "amount_due": "1500.00", "advance_balance": "0.00", "is_paid": False},
        {"unit_number": 2, "unit": "A-2", "house_type": "Flat", "amount_due": "1500.00", "advance_balance": "0.00", "is_paid": False},
        {"unit_number": 3, "unit": "A-3", "house_type": "Flat", "amount_due": "1500.00", "advance_balance": "0.00", "is_paid": False},
        {"unit_number": 4, "unit": "A-4", "house_type": "Flat", "amount_due": "1500.00", "advance_balance": "0.00", "is_paid": False},
        {"unit_number": 5, "unit": "A-5", "house_type": "Flat", "amount_due": "1500.00", "advance_balance": "0.00", "is_paid": False},
        {"unit_number": 6, "unit": "A-6", "house_type": "Large flat", "amount_due": "2250.00", "advance_balance": "0.00", "is_paid": False},
        {"unit_number": 7, "unit": "A-7", "house_type": "Flat", "amount_due": "0.00", "advance_balance": "0.00", "is_paid": True},
    ],
    "F10": [
        {"unit_number": 1, "unit": "A-1", "house_type": "Flat", "amount_due": "1500.00", "advance_balance": "0.00", "is_paid": False},
        {"unit_number": 2, "unit": "A-2", "house_type": "Flat", "amount_due": "3350.00", "advance_balance": "0.00", "is_paid": False},
        {"unit_number": 3, "unit": "A-3", "house_type": "Flat", "amount_due": "1500.00", "advance_balance": "0.00", "is_paid": False},
        {"unit_number": 4, "unit": "A-4", "house_type": "Flat", "amount_due": "1500.00", "advance_balance": "0.00", "is_paid": False},
        {"unit_number": 5, "unit": "A-5", "house_type": "Flat", "amount_due": "1500.00", "advance_balance": "0.00", "is_paid": False},
        {"unit_number": 6, "unit": "A-6", "house_type": "Large flat", "amount_due": "2250.00", "advance_balance": "0.00", "is_paid": False},
        {"unit_number": 7, "unit": "A-7", "house_type": "Flat", "amount_due": "0.00", "advance_balance": "0.00", "is_paid": True},
    ],
}
EXPECTED_UNIT_BALANCES["F8_CAPITAL"] = EXPECTED_UNIT_BALANCES["F8"]
EXPECTED_UNIT_BALANCES["F9_RECON"] = EXPECTED_UNIT_BALANCES["F9"]
EXPECTED_UNIT_BALANCES["F10_GOVERNANCE"] = EXPECTED_UNIT_BALANCES["F10"]

PM_CHECKLISTS: dict[str, list[str]] = {
    "F0": [
        "Verify clean site creation with no initial blocks or units",
        "Test initial site wizard and block creation workflow",
    ],
    "F1": [
        "Verify 7 units created in A Blok with assigned tariffs and land shares",
        "Test resident invitation and vacancy assignment",
    ],
    "F2": [
        "Verify resident accounts and credentials activated for 7 personas",
        "Test resident login and profile navigation",
    ],
    "F3": [
        "Verify period 'Ekim 2026' created in OPEN status without prior residents",
        "Test tariff calculation and accrual preview on unassigned units",
    ],
    "F4": [
        "Verify single period 'Ekim 2026' with ₺8,800.00 total overdue",
        "Verify A-1 paid in full (₺1,500.00) with verified receipt TAH-2026-000001",
        "Test delay penalty calculation across overdue units",
    ],
    "F5": [
        "Verify multi-period accruals (Eylül, Ekim, Kasım 2026) with ₺4,567.50 overdue",
        "Verify unit A-6 holding ₺1,250.00 operational advance balance",
        "Test FIFO allocation and advance balance utilization",
    ],
    "F6": [
        "Verify changing occupancy lifecycle across three periods",
        "Verify multi-debtor status on unit A-2 (Ahmet Yılmaz, Selin Demir, Mert Kılıç)",
        "Test pro-rata dues split approval workflow with four-eyes reviewer",
    ],
    "F7": [
        "Verify historical period 'Eylül 2026' is CLOSED with immutable snapshot",
        "Verify Ekim and Kasım 2026 remain ACTIVE",
        "Test period re-open request and audit trail",
    ],
    "F8": [
        "Verify capital project 'Exterior Facade Insulation' with ₺105,000.00 total budget",
        "Verify 1st installment accrued (₺35,000.00) across 7 units (₺5,000.00 per unit)",
        "Verify unit A-6 holds ₺1,250.00 operational advance ready for inter-ledger virman",
        "Verify contractor 'Özkan Yalıtım İnşaat A.Ş.' record ready for milestone disbursement",
        "Test inter-ledger virman from operational advance to capital debt",
    ],
    "F9": [
        "Verify deterministic Virtual IBANs (TR...) assigned to all 7 units",
        "Verify multi-debtor history on unit A-2 (owner Ahmet, former tenant Selin, tenant Mert)",
        "Test bank statement import and automated reconciliation matching via Virtual IBAN",
        "Identify duplicate candidate person in directory matching phone '+90 532 111 22 33'",
        "Execute person-card merge into canonical record and verify historical ledger preservation",
    ],
    "F10": [
        "Verify multi-site tenant isolation between Begonya Sitesi and Kardelen Rezidans",
        "Verify unit A-2 has severe >90-day arrears from Haziran 2026 (₺1,850.00 overdue)",
        "Test legal dunning notice generation and collection case creation for severe arrears",
        "Verify active 3-installment payment plan on unit A-4 with four-eyes approvals",
        "Inspect heating meter readings and verify 70/30 consumption cost distribution",
        "Review scheduled General Assembly meeting and agenda items for voting",
    ],
}
PM_CHECKLISTS["F8_CAPITAL"] = PM_CHECKLISTS["F8"]
PM_CHECKLISTS["F9_RECON"] = PM_CHECKLISTS["F9"]
PM_CHECKLISTS["F10_GOVERNANCE"] = PM_CHECKLISTS["F10"]

PERSONAS: dict[str, list[dict[str, str | None]]] = {
    "reference_residents": [
        {"role": "HOME_OWNER", "name": "Ayşe Kaya", "unit": "A-1", "key": "ayse"},
        {"role": "HOME_RESIDENT", "name": "Selin Demir", "unit": "A-2", "key": "selin"},
        {"role": "HOME_OWNER", "name": "Burak Şahin", "unit": "A-3", "key": "burak"},
        {"role": "HOME_OWNER", "name": "Ahmet Yılmaz", "unit": "A-4", "key": "ahmet"},
        {"role": "HOME_OWNER", "name": "Can Öztürk", "unit": "A-5", "key": "can"},
        {"role": "HOME_RESIDENT", "name": "Deniz Arslan", "unit": "A-5", "key": "deniz"},
        {"role": "HOME_OWNER", "name": "Elif Aydın", "unit": "A-6", "key": "elif"},
    ]
}

# ---------------------------------------------------------------------------
# Data Models
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class JourneyFixture:
    state: str
    site_id: str
    manager: Any
    manager_email: str
    manager_password: str
    unit_ids: tuple[str, ...]
    person_ids: tuple[str, ...]
    scenario_manifest: dict[str, Any] | None = None


@dataclass
class PersonaAccount:
    role: str
    name: str
    unit: str | None
    email: str
    password: str

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class ScenarioManifest:
    """Structured JSON manifest returned from each seed run."""

    preset: str
    site_id: str
    site_name: str
    reference_clock: str
    expected_site_totals: dict[str, Any]
    unit_by_unit_expected_balances: list[dict[str, Any]]
    personas: list[dict[str, Any]]
    pm_checklist: list[str] = field(default_factory=list)

    @property
    def unit_balances(self) -> list[dict[str, Any]]:
        return self.unit_by_unit_expected_balances

    @property
    def persona_accounts(self) -> list[dict[str, Any]]:
        return self.personas

    @property
    def pm_checklists(self) -> list[str]:
        return self.pm_checklist

    def to_dict(self) -> dict[str, Any]:
        return {
            "preset": self.preset,
            "site_id": self.site_id,
            "site_name": self.site_name,
            "reference_clock": self.reference_clock,
            "expected_site_totals": self.expected_site_totals,
            "unit_by_unit_expected_balances": self.unit_by_unit_expected_balances,
            "unit_balances": self.unit_by_unit_expected_balances,
            "personas": self.personas,
            "persona_accounts": self.personas,
            "pm_checklist": self.pm_checklist,
            "pm_checklists": self.pm_checklist,
        }

    def to_json(self, indent: int = 2) -> str:
        return json.dumps(self.to_dict(), indent=indent, default=str)


# ---------------------------------------------------------------------------
# SQL & Identifier Utilities
# ---------------------------------------------------------------------------

def safe_id(value: str | int) -> int:
    raw = str(value)
    if not re.fullmatch(r"[1-9][0-9]*", raw):
        raise ValueError(f"Expected a positive database id, got {raw!r}")
    return int(raw)


def sql_text(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def slug(value: str) -> str:
    safe = re.sub(r"[^a-zA-Z0-9-]+", "-", value).strip("-").lower()
    return safe[:80] or "run"


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


# ---------------------------------------------------------------------------
# SQL Builder Functions
# ---------------------------------------------------------------------------

def delete_blocks_sql(site_id: str | int) -> str:
    site = safe_id(site_id)
    return f"DELETE FROM blocks WHERE site_id = {site};"


def create_structure_sql(site_id: str | int) -> str:
    site = safe_id(site_id)
    viban_updates = " ".join(
        f"UPDATE units SET virtual_iban = '{make_viban('00205', site, 'A', unit_no)}' WHERE site_id = {site} AND unit_number = {unit_no};"
        for unit_no in range(1, 8)
    )
    return (
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


def create_residents_sql(site_id: str | int, attempt_slug: str, password_hash: str) -> tuple[str, str, dict[str, str]]:
    site = safe_id(site_id)
    people = {
        "ayse": ("Ayşe Kaya", "HOME_OWNER"),
        "ahmet": ("Ahmet Yılmaz", "HOME_OWNER"),
        "selin": ("Selin Demir", "HOME_RESIDENT"),
        "burak": ("Burak Şahin", "HOME_OWNER"),
        "can": ("Can Öztürk", "HOME_OWNER"),
        "deniz": ("Deniz Arslan", "HOME_RESIDENT"),
        "elif": ("Elif Aydın", "HOME_OWNER"),
    }
    emails = {key: f"{attempt_slug}.{key}@journey.e2e.test" for key in people}
    person_values = ", ".join(
        f"({site}, {sql_text(name)}, {sql_text(emails[key])}, {sql_text(person_type)})"
        for key, (name, person_type) in people.items()
    )
    insert_persons = f"INSERT INTO persons (site_id, full_name, email, person_type) VALUES {person_values};"

    owner_by_unit = {1: "ayse", 2: "ahmet", 3: "burak", 4: "ahmet", 5: "can", 6: "elif"}
    occupants = {
        1: ("ayse", "OWNER"),
        2: ("selin", "TENANT"),
        4: ("ahmet", "OWNER"),
        5: ("deniz", "TENANT"),
        6: ("elif", "OWNER"),
    }
    statements = ["BEGIN;"]
    for unit_number, key in owner_by_unit.items():
        email = sql_text(emails[key])
        statements.extend([
            f"UPDATE units SET owner_person_id = (SELECT id FROM persons WHERE site_id = {site} AND email = {email}) "
            f"WHERE site_id = {site} AND unit_number = {unit_number};",
            f"INSERT INTO unit_ownerships (unit_id, person_id, share_percentage, start_date, is_active) "
            f"SELECT u.id, p.id, 100.00, DATE '2026-09-01', TRUE FROM units u JOIN persons p "
            f"ON p.site_id = u.site_id AND p.email = {email} WHERE u.site_id = {site} AND u.unit_number = {unit_number};",
        ])
    for unit_number, (key, occupancy_type) in occupants.items():
        email = sql_text(emails[key])
        tenant_person = (
            f"(SELECT id FROM persons WHERE site_id = {site} AND email = {email})"
            if occupancy_type == "TENANT"
            else "NULL"
        )
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
        f"SELECT p.site_id, p.id, p.email, {sql_text(password_hash)}, "
        f"CASE WHEN p.person_type = 'HOME_OWNER' THEN 'HOME_OWNER' ELSE 'HOME_RESIDENT' END, FALSE "
        f"FROM persons p WHERE p.site_id = {site} AND p.email IN ({', '.join(sql_text(email) for email in emails.values())});"
    )
    statements.append(
        f"INSERT INTO user_site_roles (user_id, site_id, role) SELECT id, site_id, role FROM users "
        f"WHERE site_id = {site} AND email IN ({', '.join(sql_text(email) for email in emails.values())}) "
        "ON CONFLICT (user_id, site_id, role) DO NOTHING;"
    )
    statements.append("COMMIT;")
    return insert_persons, " ".join(statements), emails


def create_period_no_residents_sql(site_id: str | int) -> str:
    site = safe_id(site_id)
    return (
        f"INSERT INTO dues_periods (site_id, period_name, period_key, due_date, status) "
        f"VALUES ({site}, 'Ekim 2026', '2026-10', DATE '2026-10-10', 'OPEN') "
        f"ON CONFLICT (site_id, period_name) DO UPDATE SET period_key = EXCLUDED.period_key, status = 'OPEN';"
    )


def build_f4_sql(site_id: str | int, unit_ids: tuple[str, ...]) -> str:
    site = safe_id(site_id)
    u1, u2, u3, u4, u5, u6, _ = [safe_id(uid) for uid in unit_ids]
    return (
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


def build_f5_sql(site_id: str | int, unit_ids: tuple[str, ...]) -> str:
    site = safe_id(site_id)
    u1, u2, u3, u4, u5, u6, _ = [safe_id(uid) for uid in unit_ids]

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

    statements.append(
        "INSERT INTO dues_liability_joint_owners (site_id, due_id, owner_person_id, tenant_person_id, liable_from, liable_through) "
        f"SELECT {site}, d.id, u.owner_person_id, d.liable_person_id, date_trunc('month', d.due_date)::date, "
        "(date_trunc('month', d.due_date) + interval '1 month - 1 day')::date "
        f"FROM dues_liabilities d JOIN units u ON u.id = d.unit_id WHERE u.site_id = {site} AND d.debtor_type = 'TENANT';"
    )
    statements.append("COMMIT;")
    return " ".join(statements)


def close_september_sql(site_id: str | int) -> str:
    site = safe_id(site_id)
    return (
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


def build_f8_sql(site_id: str | int, unit_ids: tuple[str, ...]) -> str:
    site = safe_id(site_id)
    u_ids = tuple(safe_id(uid) for uid in unit_ids)
    statements = [
        "BEGIN;",
        f"INSERT INTO capital_projects (site_id, title, category, description, total_budget, allocation_basis, target_start_date, target_completion_date, contractor_name, contractor_tax_no, contractor_iban, contract_amount, status) "
        f"VALUES ({site}, 'Exterior Facade Insulation', 'FACADE_INSULATION', 'Comprehensive exterior insulation and thermal wrapping project', 105000.00, 'BY_LAND_SHARE', DATE '2026-11-01', DATE '2027-02-28', 'Özkan Yalıtım İnşaat A.Ş.', '1234567890', 'TR330006100519786457841326', 105000.00, 'ACTIVE');",
        f"INSERT INTO capital_project_installments (project_id, installment_number, total_installments, due_date, installment_budget, percentage, is_accrued, accrued_at) "
        f"SELECT id, 1, 3, DATE '2026-11-30', 35000.00, 33.34, TRUE, TIMESTAMPTZ '2026-11-19 10:00:00+03' "
        f"FROM capital_projects WHERE site_id = {site} AND title = 'Exterior Facade Insulation';",
        f"INSERT INTO capital_project_installments (project_id, installment_number, total_installments, due_date, installment_budget, percentage, is_accrued) "
        f"SELECT id, 2, 3, DATE '2026-12-31', 35000.00, 33.33, FALSE "
        f"FROM capital_projects WHERE site_id = {site} AND title = 'Exterior Facade Insulation';",
        f"INSERT INTO capital_project_installments (project_id, installment_number, total_installments, due_date, installment_budget, percentage, is_accrued) "
        f"SELECT id, 3, 3, DATE '2027-01-31', 35000.00, 33.33, FALSE "
        f"FROM capital_projects WHERE site_id = {site} AND title = 'Exterior Facade Insulation';",
    ]
    for uid in u_ids:
        statements.append(
            f"INSERT INTO dues_liabilities (unit_id, period, debtor_type, expense_type, liable_person_id, principal_amount, due_date, effective_due_date, status, delay_penalty, paid_principal, paid_penalty, paid_amount, capital_project_id, installment_number, created_at) "
            f"SELECT {uid}, 'Kasım 2026', 'OWNER', 'CAPITAL_DUES', u.owner_person_id, 5000.00, DATE '2026-11-30', DATE '2026-11-30', 'PENDING', 0.00, 0.00, 0.00, 0.00, cp.id, 1, TIMESTAMPTZ '2026-11-19 10:00:00+03' "
            f"FROM units u, capital_projects cp WHERE u.id = {uid} AND cp.site_id = {site} AND cp.title = 'Exterior Facade Insulation';"
        )
    statements.append("COMMIT;")
    return " ".join(statements)


def build_f9_sql(site_id: str | int, unit_ids: tuple[str, ...], attempt_slug: str, password_hash: str) -> str:
    site = safe_id(site_id)
    u_ids = tuple(safe_id(uid) for uid in unit_ids)
    u1, u2, u3, u4, u5, u6, u7 = u_ids
    attempt = slug(attempt_slug)

    viban_updates = " ".join(
        f"UPDATE units SET virtual_iban = '{make_viban('00205', site, 'A', unit_no)}' WHERE site_id = {site} AND unit_number = {unit_no};"
        for unit_no in range(1, 8)
    )

    statements = [
        "BEGIN;",
        f"INSERT INTO persons (site_id, full_name, email, phone, person_type) VALUES "
        f"({site}, 'Mert Kılıç', '{attempt}.mert@journey.e2e.test', '+90 533 000 00 01', 'HOME_RESIDENT'), "
        f"({site}, 'Oya Çelik', '{attempt}.oya@journey.e2e.test', '+90 533 000 00 02', 'HOME_RESIDENT'), "
        f"({site}, 'Gül Tanrıverdi', '{attempt}.gul@journey.e2e.test', '+90 533 000 00 03', 'HOME_OWNER'), "
        f"({site}, 'Ahmet Yılmaz', '{attempt}.ahmet.duplicate@journey.e2e.test', '+90 532 111 22 33', 'HOME_OWNER');",
        f"INSERT INTO users (site_id, email, password_hash, role, is_active, must_change_password) VALUES "
        f"({site}, 'journey.reviewer.{attempt[:8]}@e2e.test', '{password_hash}', 'SITE_MANAGER', TRUE, FALSE);",
        f"UPDATE unit_occupancies SET is_active = FALSE, end_date = DATE '2026-11-15' WHERE unit_id = {u2};",
        f"INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type, start_date, is_active) "
        f"SELECT {u2}, id, 'TENANT', DATE '2026-11-15', TRUE FROM persons WHERE site_id = {site} AND full_name = 'Mert Kılıç' LIMIT 1;",
        f"UPDATE units SET tenant_person_id = (SELECT id FROM persons WHERE site_id = {site} AND full_name = 'Mert Kılıç' LIMIT 1), occupancy_status = 'TENANT_OCCUPIED' WHERE id = {u2};",
        f"INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type, start_date, is_active) "
        f"SELECT {u3}, id, 'TENANT', DATE '2026-11-18', TRUE FROM persons WHERE site_id = {site} AND full_name = 'Oya Çelik' LIMIT 1;",
        f"UPDATE units SET tenant_person_id = (SELECT id FROM persons WHERE site_id = {site} AND full_name = 'Oya Çelik' LIMIT 1), occupancy_status = 'TENANT_OCCUPIED' WHERE id = {u3};",
        f"UPDATE unit_ownerships SET is_active = FALSE, end_date = DATE '2026-11-05' WHERE unit_id = {u4};",
        f"INSERT INTO unit_ownerships (unit_id, person_id, share_numerator, share_denominator, start_date, is_active) "
        f"SELECT {u4}, id, 1, 1, DATE '2026-11-05', TRUE FROM persons WHERE site_id = {site} AND full_name = 'Gül Tanrıverdi' LIMIT 1;",
        f"UPDATE units SET owner_person_id = (SELECT id FROM persons WHERE site_id = {site} AND full_name = 'Gül Tanrıverdi' LIMIT 1), occupancy_status = 'OWNER_OCCUPIED' WHERE id = {u4};",
        viban_updates,
        f"INSERT INTO dues_periods (site_id, period_name, due_date, status) VALUES "
        f"({site}, 'Eylül 2026', DATE '2026-09-10', 'ACTIVE'), "
        f"({site}, 'Ekim 2026', DATE '2026-10-10', 'ACTIVE'), "
        f"({site}, 'Kasım 2026', DATE '2026-11-10', 'ACTIVE');",
    ]

    for uid in u_ids:
        statements.append(
            f"INSERT INTO dues_liabilities (unit_id, period, debtor_type, expense_type, liable_person_id, principal_amount, due_date, effective_due_date, status, delay_penalty, paid_principal, paid_penalty, paid_amount, created_at) "
            f"SELECT {uid}, 'Eylül 2026', 'OWNER', 'OPERATIONAL_DUES', u.owner_person_id, 0.00, DATE '2026-09-10', DATE '2026-09-10', 'CANCELLED', 0.00, 0.00, 0.00, 0.00, TIMESTAMPTZ '2026-09-01 08:00:00+03' "
            f"FROM units u WHERE u.id = {uid};"
        )
    for uid in u_ids:
        statements.append(
            f"INSERT INTO dues_liabilities (unit_id, period, debtor_type, expense_type, liable_person_id, principal_amount, due_date, effective_due_date, status, delay_penalty, paid_principal, paid_penalty, paid_amount, created_at) "
            f"SELECT {uid}, 'Ekim 2026', 'OWNER', 'OPERATIONAL_DUES', u.owner_person_id, 0.00, DATE '2026-10-10', DATE '2026-10-10', 'CANCELLED', 0.00, 0.00, 0.00, 0.00, TIMESTAMPTZ '2026-10-01 08:00:00+03' "
            f"FROM units u WHERE u.id = {uid};"
        )

    nov_liabilities = [
        (u1, "OWNER", "1500.00", "OVERDUE", "u.owner_person_id"),
        (u2, "TENANT", "1500.00", "OVERDUE", "u.tenant_person_id"),
        (u3, "TENANT", "1500.00", "OVERDUE", "u.tenant_person_id"),
        (u4, "OWNER", "1500.00", "OVERDUE", "u.owner_person_id"),
        (u5, "TENANT", "1500.00", "OVERDUE", "u.tenant_person_id"),
        (u6, "OWNER", "2250.00", "OVERDUE", "u.owner_person_id"),
        (u7, "OWNER", "0.00", "PENDING", "u.owner_person_id"),
    ]
    for uid, debtor, amount, status, person_expr in nov_liabilities:
        statements.append(
            f"INSERT INTO dues_liabilities (unit_id, period, debtor_type, expense_type, liable_person_id, principal_amount, due_date, effective_due_date, status, delay_penalty, paid_principal, paid_penalty, paid_amount, created_at) "
            f"SELECT {uid}, 'Kasım 2026', '{debtor}', 'OPERATIONAL_DUES', {person_expr}, {amount}, DATE '2026-11-10', DATE '2026-11-10', '{status}', 0.00, 0.00, 0.00, 0.00, TIMESTAMPTZ '2026-11-01 08:00:00+03' "
            f"FROM units u WHERE u.id = {uid};"
        )

    statements.append("COMMIT;")
    return " ".join(statements)


def build_f10_sql(
    site_id: str | int,
    unit_ids: tuple[str, ...],
    attempt_slug: str,
    password_hash: str,
    kardelen_site_id: str | int | None = None,
) -> str:
    site = safe_id(site_id)
    u_ids = tuple(safe_id(uid) for uid in unit_ids)
    u1, u2, u3, u4, u5, u6, u7 = u_ids
    attempt = slug(attempt_slug)

    k_site_sql = (
        f"INSERT INTO sites (site_name, proration_enabled, created_at) VALUES ('Kardelen Rezidans', TRUE, TIMESTAMPTZ '2026-09-01 00:00:00+00'); "
        "INSERT INTO blocks (site_id, block_name, total_floors) SELECT id, 'K Blok', 4 FROM sites WHERE site_name = 'Kardelen Rezidans' ORDER BY id DESC LIMIT 1; "
        "INSERT INTO house_types (site_id, type_name, dues_amount, description) SELECT id, 'Flat', 1500.00, 'Kardelen tariff' FROM sites WHERE site_name = 'Kardelen Rezidans' ORDER BY id DESC LIMIT 1; "
        "INSERT INTO units (block_id, site_id, unit_number, floor, land_share, occupancy_status, house_type, house_type_id, created_at) "
        "SELECT b.id, s.id, n.n, 1, 1, 'VACANT', h.type_name, h.id, TIMESTAMPTZ '2026-09-01 00:00:00+00' "
        "FROM sites s JOIN blocks b ON b.site_id = s.id JOIN house_types h ON h.site_id = s.id "
        "CROSS JOIN (VALUES (1), (2), (3), (4)) AS n(n) "
        "WHERE s.site_name = 'Kardelen Rezidans' ORDER BY s.id DESC LIMIT 4;"
    ) if kardelen_site_id is None else (
        f"INSERT INTO blocks (site_id, block_name, total_floors) VALUES ({safe_id(kardelen_site_id)}, 'K Blok', 4); "
        f"INSERT INTO house_types (site_id, type_name, dues_amount, description) VALUES ({safe_id(kardelen_site_id)}, 'Flat', 1500.00, 'Kardelen tariff'); "
        f"INSERT INTO units (block_id, site_id, unit_number, floor, land_share, occupancy_status, house_type, house_type_id, created_at) "
        f"SELECT b.id, {safe_id(kardelen_site_id)}, n.n, 1, 1, 'VACANT', h.type_name, h.id, TIMESTAMPTZ '2026-09-01 00:00:00+00' "
        f"FROM blocks b JOIN house_types h ON h.site_id = b.site_id CROSS JOIN (VALUES (1), (2), (3), (4)) AS n(n) "
        f"WHERE b.site_id = {safe_id(kardelen_site_id)} ORDER BY n.n;"
    )

    statements = [
        "BEGIN;",
        f"UPDATE sites SET site_name = 'Begonya Sitesi' WHERE id = {site};",
        k_site_sql,
        f"INSERT INTO dues_periods (site_id, period_name, due_date, status) VALUES "
        f"({site}, 'Haziran 2026', DATE '2026-06-10', 'ACTIVE'), "
        f"({site}, 'Eylül 2026', DATE '2026-09-10', 'ACTIVE'), "
        f"({site}, 'Ekim 2026', DATE '2026-10-10', 'ACTIVE'), "
        f"({site}, 'Kasım 2026', DATE '2026-11-10', 'ACTIVE');",
        f"INSERT INTO dues_liabilities (unit_id, period, debtor_type, expense_type, liable_person_id, principal_amount, due_date, effective_due_date, status, delay_penalty, paid_principal, paid_penalty, paid_amount, penalty_accrued_through, created_at) "
        f"SELECT {u2}, 'Haziran 2026', 'OWNER', 'OPERATIONAL_DUES', u.owner_person_id, 1500.00, DATE '2026-06-10', DATE '2026-06-10', 'OVERDUE', 350.00, 0.00, 0.00, 0.00, DATE '2026-11-19', TIMESTAMPTZ '2026-06-01 08:00:00+03' "
        f"FROM units u WHERE u.id = {u2};",
        f"INSERT INTO late_fee_accruals (site_id, due_id, accrual_date, outstanding_principal, segment_start, segment_base, cumulative_fee, daily_amount) "
        f"SELECT {site}, d.id, DATE '2026-11-19', 1500.00, DATE '2026-06-10', 0.00, 350.00, 2.50 "
        f"FROM dues_liabilities d WHERE d.unit_id = {u2} AND d.period = 'Haziran 2026';",
        f"INSERT INTO debt_aging_snapshots (site_id, unit_id, debtor_type, current_due, overdue_1_30_days, overdue_31_60_days, overdue_60_plus_days, accrued_delay_penalty, total_outstanding, as_of_date) "
        f"VALUES ({site}, {u2}, 'OWNER', 1500.00, 0.00, 0.00, 1500.00, 350.00, 3350.00, DATE '2026-11-19');",
        f"INSERT INTO dues_liabilities (unit_id, period, debtor_type, expense_type, liable_person_id, principal_amount, due_date, effective_due_date, status, delay_penalty, paid_principal, paid_penalty, paid_amount, created_at) VALUES "
        f"({u1}, 'Kasım 2026', 'OWNER', 'OPERATIONAL_DUES', (SELECT owner_person_id FROM units WHERE id = {u1}), 1500.00, DATE '2026-11-10', DATE '2026-11-10', 'OVERDUE', 0.00, 0.00, 0.00, 0.00, TIMESTAMPTZ '2026-11-01 08:00:00+03'), "
        f"({u2}, 'Kasım 2026', 'OWNER', 'OPERATIONAL_DUES', (SELECT owner_person_id FROM units WHERE id = {u2}), 1500.00, DATE '2026-11-10', DATE '2026-11-10', 'OVERDUE', 0.00, 0.00, 0.00, 0.00, TIMESTAMPTZ '2026-11-01 08:00:00+03'), "
        f"({u3}, 'Kasım 2026', 'OWNER', 'OPERATIONAL_DUES', (SELECT owner_person_id FROM units WHERE id = {u3}), 1500.00, DATE '2026-11-10', DATE '2026-11-10', 'OVERDUE', 0.00, 0.00, 0.00, 0.00, TIMESTAMPTZ '2026-11-01 08:00:00+03'), "
        f"({u4}, 'Kasım 2026', 'OWNER', 'OPERATIONAL_DUES', (SELECT owner_person_id FROM units WHERE id = {u4}), 1500.00, DATE '2026-11-10', DATE '2026-11-10', 'OVERDUE', 0.00, 0.00, 0.00, 0.00, TIMESTAMPTZ '2026-11-01 08:00:00+03'), "
        f"({u5}, 'Kasım 2026', 'OWNER', 'OPERATIONAL_DUES', (SELECT owner_person_id FROM units WHERE id = {u5}), 1500.00, DATE '2026-11-10', DATE '2026-11-10', 'OVERDUE', 0.00, 0.00, 0.00, 0.00, TIMESTAMPTZ '2026-11-01 08:00:00+03'), "
        f"({u6}, 'Kasım 2026', 'OWNER', 'OPERATIONAL_DUES', (SELECT owner_person_id FROM units WHERE id = {u6}), 2250.00, DATE '2026-11-10', DATE '2026-11-10', 'OVERDUE', 0.00, 0.00, 0.00, 0.00, TIMESTAMPTZ '2026-11-01 08:00:00+03'), "
        f"({u7}, 'Kasım 2026', 'OWNER', 'OPERATIONAL_DUES', (SELECT owner_person_id FROM units WHERE id = {u7}), 0.00, DATE '2026-11-10', DATE '2026-11-10', 'PENDING', 0.00, 0.00, 0.00, 0.00, TIMESTAMPTZ '2026-11-01 08:00:00+03');",
        f"INSERT INTO payment_plans (site_id, unit_id, debtor_type, due_ids, total_amount, installment_count, first_due_date, grace_days, waive_penalty_on_completion, status, opened_on, created_by, approved_by, note) "
        f"VALUES ({site}, {u4}, 'OWNER', '[]'::jsonb, 1500.00, 3, DATE '2026-11-15', 5, FALSE, 'ACTIVE', DATE '2026-11-01', 'manager', 'board_president', 'Kasım aidatı 3 taksit yapılandırma planı');",
        f"INSERT INTO payment_plan_installments (plan_id, seq, due_date, amount) "
        f"SELECT id, 1, DATE '2026-11-15', 500.00 FROM payment_plans WHERE site_id = {site} AND unit_id = {u4} ORDER BY id DESC LIMIT 1;",
        f"INSERT INTO payment_plan_installments (plan_id, seq, due_date, amount) "
        f"SELECT id, 2, DATE '2026-12-15', 500.00 FROM payment_plans WHERE site_id = {site} AND unit_id = {u4} ORDER BY id DESC LIMIT 1;",
        f"INSERT INTO payment_plan_installments (plan_id, seq, due_date, amount) "
        f"SELECT id, 3, DATE '2027-01-15', 500.00 FROM payment_plans WHERE site_id = {site} AND unit_id = {u4} ORDER BY id DESC LIMIT 1;",
        f"INSERT INTO heat_cost_periods (site_id, label, period_start, period_end, total_cost, consumption_share_percent, due_date, status, approved_by, approved_at, created_by, created_at) "
        f"VALUES ({site}, 'Kasım 2026 Isı Paylaşımı', DATE '2026-11-01', DATE '2026-11-30', 14000.00, 70.00, DATE '2026-12-10', 'APPROVED', 'manager', TIMESTAMPTZ '2026-11-19 10:00:00+03', 'manager', TIMESTAMPTZ '2026-11-19 09:00:00+03');",
    ]

    for idx, uid in enumerate(u_ids, start=1):
        prev = f"{100.000 + (idx * 10):.3f}"
        curr = f"{150.000 + (idx * 15):.3f}"
        statements.append(
            f"INSERT INTO heat_meter_readings (period_id, unit_id, area_weight, previous_reading, current_reading) "
            f"SELECT id, {uid}, 100, {prev}, {curr} FROM heat_cost_periods WHERE site_id = {site} AND label = 'Kasım 2026 Isı Paylaşımı' ORDER BY id DESC LIMIT 1;"
        )

    statements.extend([
        f"INSERT INTO assembly_meetings (site_id, kind, call_number, scheduled_at, location, status, created_by, created_at) "
        f"VALUES ({site}, 'ORDINARY', 1, TIMESTAMPTZ '2026-12-05 14:00:00+03', 'Site Toplantı Salonu', 'PLANNED', 'manager', TIMESTAMPTZ '2026-11-19 09:00:00+03');",
        f"INSERT INTO assembly_agenda_items (meeting_id, seq, title, description, rule, status) "
        f"SELECT id, 1, 'Açılış ve Divan Heyeti Seçimi', 'Toplantı açılışı, yoklama ve divan seçimi', 'SIMPLE', 'OPEN' "
        f"FROM assembly_meetings WHERE site_id = {site} AND status = 'PLANNED' ORDER BY id DESC LIMIT 1;",
        f"INSERT INTO assembly_agenda_items (meeting_id, seq, title, description, rule, status) "
        f"SELECT id, 2, '2026 Yılı Faaliyet ve Denetim Raporlarının Okunması', 'Geçmiş dönem faaliyet raporunun sunumu ve ibrası', 'SIMPLE', 'OPEN' "
        f"FROM assembly_meetings WHERE site_id = {site} AND status = 'PLANNED' ORDER BY id DESC LIMIT 1;",
        f"INSERT INTO assembly_agenda_items (meeting_id, seq, title, description, rule, status) "
        f"SELECT id, 3, '2027 Yılı İşletme Projesinin Görüşülmesi ve Karara Bağlanması', 'Tahmini bütçe ve aidat artış oranlarının müzakeresi', 'SIMPLE', 'OPEN' "
        f"FROM assembly_meetings WHERE site_id = {site} AND status = 'PLANNED' ORDER BY id DESC LIMIT 1;",
        f"INSERT INTO assembly_agenda_items (meeting_id, seq, title, description, rule, status) "
        f"SELECT id, 4, 'Yeni Yönetim ve Denetim Kurulunun Seçilmesi', 'Gelecek çalışma dönemi için kurul üye seçimleri', 'SIMPLE', 'OPEN' "
        f"FROM assembly_meetings WHERE site_id = {site} AND status = 'PLANNED' ORDER BY id DESC LIMIT 1;",
        "COMMIT;",
    ])

    return " ".join(statements)


# ---------------------------------------------------------------------------
# High-Level Seeding Handlers
# ---------------------------------------------------------------------------

def create_structure(sql_fn: Callable[[str], str], site_id: str | int, manifest: Any = None) -> tuple[str, ...]:
    sql_fn(create_structure_sql(site_id))
    unit_ids = tuple(sql_fn(f"SELECT id FROM units WHERE site_id = {safe_id(site_id)} ORDER BY unit_number;").splitlines())
    unit_ids = tuple(uid.strip() for uid in unit_ids if uid.strip())
    if len(unit_ids) != 7:
        raise AssertionError(f"F1: expected seven units, created {len(unit_ids)}")
    if manifest and hasattr(manifest, "record"):
        for unit_id in unit_ids:
            manifest.record("unit_ids", unit_id)
    return unit_ids


def create_residents(
    sql_fn: Callable[[str], str],
    site_id: str | int,
    manager_user_id: str | int,
    manifest: Any = None,
    attempt_slug: str | None = None,
) -> tuple[str, ...]:
    site = safe_id(site_id)
    manager_id = safe_id(manager_user_id)
    password_hash = sql_fn(f"SELECT password_hash FROM users WHERE id = {manager_id};").strip()
    if not password_hash:
        raise AssertionError("F2: permanent manager password hash is unavailable")
    attempt = attempt_slug or (manifest.attempt_id if manifest and hasattr(manifest, "attempt_id") else "seed")
    attempt = slug(attempt)

    insert_persons, statements, emails = create_residents_sql(site, attempt, password_hash)
    sql_fn(insert_persons)
    person_rows = sql_fn(
        f"SELECT id || '|' || email FROM persons WHERE site_id = {site} "
        f"AND email IN ({', '.join(sql_text(email) for email in emails.values())}) ORDER BY email;"
    ).splitlines()
    person_ids_by_email = {line.split("|", 1)[1].strip(): line.split("|", 1)[0].strip() for line in person_rows if "|" in line}
    if len(person_ids_by_email) != len(emails):
        raise AssertionError(f"F2: expected {len(emails)} reference people, created {len(person_ids_by_email)}")
    person_ids = tuple(person_ids_by_email[email] for email in emails.values())
    if manifest and hasattr(manifest, "record"):
        for person_id in person_ids:
            manifest.record("person_ids", person_id)

    sql_fn(statements)
    user_rows = sql_fn(
        f"SELECT id FROM users WHERE site_id = {site} AND email IN ({', '.join(sql_text(email) for email in emails.values())}) ORDER BY id;"
    ).splitlines()
    if manifest and hasattr(manifest, "record"):
        for user_id in user_rows:
            if user_id.strip():
                manifest.record("user_ids", user_id.strip())
    return person_ids


# ---------------------------------------------------------------------------
# Standalone HTTP & SQL Execution Clients
# ---------------------------------------------------------------------------

class ApiClient:
    """Lightweight REST client for SitePulse backend with zero external dependencies."""

    def __init__(self, base_url: str = "http://localhost:8080") -> None:
        self.base_url = base_url.rstrip("/")

    def call(
        self,
        method: str,
        path: str,
        token: str | None = None,
        body: dict[str, Any] | None = None,
        timeout: float = 30.0,
    ) -> Any:
        url = f"{self.base_url}{path}" if path.startswith("/") else f"{self.base_url}/{path}"
        data = json.dumps(body).encode("utf-8") if body is not None else None
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = f"Bearer {token}"

        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read().decode("utf-8")
                return json.loads(raw) if raw.strip() else {}
        except urllib.error.HTTPError as err:
            err_body = err.read().decode("utf-8")
            raise RuntimeError(f"HTTP {err.code} on {method} {path}: {err_body}") from err

    def login(self, email: str, password: str) -> dict[str, Any]:
        res = self.call("POST", "/api/v1/auth/login", body={"email": email, "password": password})
        token = res.get("token") or res.get("access_token")
        user = res.get("user") or {}
        return {"token": token, "user": user}

    def create_site(
        self,
        saas_token: str,
        site_name: str,
        manager_email: str,
        admin_name: str = "Journey Manager",
    ) -> dict[str, Any]:
        return self.call(
            "POST",
            "/api/v1/saas/sites",
            token=saas_token,
            body={"site_name": site_name, "manager_email": manager_email, "admin_name": admin_name, "blocks": []},
        )

    def change_password(self, email: str, old_pass: str, new_pass: str) -> dict[str, Any]:
        return self.call(
            "POST",
            "/api/v1/auth/change-password",
            body={"email": email, "current_password": old_pass, "new_password": new_pass},
        )

    def reload_state(self) -> dict[str, Any]:
        return self.call("POST", "/api/e2e/reload-state")

    def set_clock_date(self, date_str: str) -> dict[str, Any]:
        return self.call("POST", "/__e2e/clock", body={"action": "set_date", "date": date_str})


class PsqlRunner:
    """Runs SQL queries directly against PostgreSQL using psql CLI or docker."""

    def __init__(self, db_name: str = "sitepulse") -> None:
        self.db_name = db_name
        self.user = os.environ.get("DB_USER", "sitepulse_user")
        self.password = os.environ.get("DB_PASS", "")
        self.host = os.environ.get("DB_HOST", "127.0.0.1")
        self.port = os.environ.get("DB_PORT", "5432")
        self.container = os.environ.get("DB_CONTAINER", "sitepulse-postgres")
        if not self.password:
            self._try_load_env()

    def _try_load_env(self) -> None:
        candidates = [
            Path(__file__).resolve().parents[2] / "backend" / ".env",
            Path.cwd() / "apps" / "development-time" / "SitePulse" / "backend" / ".env",
        ]
        for env_path in candidates:
            if env_path.is_file():
                for line in env_path.read_text(encoding="utf-8").splitlines():
                    line = line.strip()
                    if line and not line.startswith("#") and "=" in line:
                        k, v = line.split("=", 1)
                        if k.strip() == "DB_PASS":
                            self.password = v.strip().strip('"').strip("'")
                        elif k.strip() == "DB_USER" and not os.environ.get("DB_USER"):
                            self.user = v.strip().strip('"').strip("'")

    def run(self, sql: str) -> str:
        if shutil.which("psql"):
            db_url = f"postgresql://{self.user}:{self.password}@{self.host}:{self.port}/{self.db_name}"
            argv = ["psql", db_url, "-v", "ON_ERROR_STOP=1", "-At", "-q"]
        elif shutil.which("docker"):
            argv = ["docker", "exec", "-i", self.container, "psql", "-U", self.user, "-d", self.db_name, "-v", "ON_ERROR_STOP=1", "-At", "-q"]
        else:
            raise RuntimeError("Neither psql nor docker is available to execute SQL")
        proc = subprocess.run(argv, input=sql, capture_output=True, text=True, timeout=120)
        if proc.returncode != 0:
            raise RuntimeError(f"psql failed: {proc.stderr}")
        return proc.stdout


# ---------------------------------------------------------------------------
# SeedPreset & Manifest Generation
# ---------------------------------------------------------------------------

@dataclass
class SeedResult:
    preset: str
    site_id: str
    manifest: ScenarioManifest
    fixture: Any = None


def seed_preset(
    preset: str,
    *,
    api: Any = None,
    sql_fn: Callable[[str], str] | None = None,
    saas: Any = None,
    manifest: Any = None,
    name_suffix: str = "",
    reload_fn: Callable[[], None] | None = None,
    set_clock: bool | None = None,
    api_url: str = "http://localhost:8080",
    saas_email: str = "admin@sitepulse.io",
    saas_password: str = "E2E-Bootstrap-Admin-1",
    db_name: str = "sitepulse",
    stack: Any = None,
) -> SeedResult:
    """Seeds reference preset F0-F7 and returns a SeedResult with ScenarioManifest."""
    if preset not in EXPECTED_TOTALS:
        raise ValueError(f"Unknown Site Admin reference state: {preset!r}")

    # Initialize SQL runner
    if sql_fn is None:
        if stack is not None and hasattr(stack, "sql"):
            sql_fn = stack.sql
        else:
            sql_fn = PsqlRunner(db_name=db_name).run

    # Initialize reload handler
    if reload_fn is None and stack is not None and hasattr(stack, "restart_backend"):
        reload_fn = stack.restart_backend

    # Initialize API client
    api_client: Any = api
    if api_client is None:
        api_client = ApiClient(base_url=api_url)

    # Initialize SaaS session
    saas_token: str | None = None
    if saas is not None:
        saas_token = getattr(saas, "token", None) or (saas.get("token") if isinstance(saas, dict) else str(saas))
    else:
        login_resp = api_client.login(saas_email, saas_password)
        saas_token = login_resp["token"]

    attempt_base = getattr(manifest, "attempt_id", None) if manifest else str(int(time.time()))
    attempt = slug(f"{attempt_base}{name_suffix}")
    site_name = f"SitePulse PM Test {preset} {attempt[:8]}"
    manager_email = f"pm.manager.{attempt}@sitepulse.test"
    manager_password = f"PM-Scenario-{attempt[:8]}-Permanent-1!"

    # Handle F6 specifically if journey_occupancy is used or requested
    if preset == "F6" and stack is not None:
        try:
            from support.journey_occupancy import build_f6  # type: ignore[import-not-found]
        except ImportError:
            from e2e.support.journey_occupancy import build_f6  # type: ignore[import-not-found]
        j = build_f6(api=api_client, stack=stack, saas=saas, manifest=manifest, name_suffix=name_suffix)
        if hasattr(api_client, "clock") and hasattr(api_client.clock, "set_date"):
            api_client.clock.set_date("2026-11-19")
        all_persons = tuple(
            sql_fn(f"SELECT id FROM persons WHERE site_id = {safe_id(j.site_id)} ORDER BY id;").splitlines()
        )
        unit_ids = j.fixture.unit_ids
        person_ids = all_persons
        manager_session = j.manager
        site_id = j.site_id
        manager_email = j.fixture.manager_email
        manager_password = j.fixture.manager_password
    else:
        # Create site via API
        if hasattr(api_client, "create_site") and saas is not None and not isinstance(api_client, ApiClient):
            credentials = api_client.create_site(saas, site_name, manager_email, admin_name="Journey Manager", blocks=())
        else:
            credentials = api_client.call(
                "POST",
                "/api/v1/saas/sites",
                token=saas_token,
                body={"site_name": site_name, "manager_email": manager_email, "admin_name": "Journey Manager", "blocks": []},
            )

        site_id = str(credentials["site_id"])
        if manifest and hasattr(manifest, "record"):
            manifest.record("site_ids", site_id)

        # Change password from temporary
        temp_pass = str(credentials["temporary_password"])
        if hasattr(api_client, "change_password"):
            api_client.change_password(manager_email, temp_pass, manager_password)
        else:
            api_client.call(
                "POST",
                "/api/v1/auth/change-password",
                body={"email": manager_email, "current_password": temp_pass, "new_password": manager_password},
            )

        # Login as manager
        manager_session = api_client.login(manager_email, manager_password)
        manager_token = manager_session["token"] if isinstance(manager_session, dict) else manager_session.token
        manager_user_id = str(manager_session["user"]["id"]) if isinstance(manager_session, dict) else str(manager_session.user["id"])
        if manifest and hasattr(manifest, "record"):
            manifest.record("user_ids", manager_user_id)

        unit_ids = ()
        person_ids = ()
        site = safe_id(site_id)

        # F0–F5, F7, or standalone F6, F8, F9, F10
        if preset == "F0":
            sql_fn(delete_blocks_sql(site))
        if preset in {"F1", "F2", "F3", "F4", "F5", "F7", "F8", "F8_CAPITAL", "F9", "F9_RECON", "F10", "F10_GOVERNANCE"}:
            unit_ids = create_structure(sql_fn, site_id, manifest)
        if preset in {"F2", "F4", "F5", "F7", "F8", "F8_CAPITAL", "F9", "F9_RECON", "F10", "F10_GOVERNANCE"}:
            person_ids = create_residents(sql_fn, site_id, manager_user_id, manifest, attempt_slug=attempt)
        if preset == "F3":
            sql_fn(create_period_no_residents_sql(site_id))
        elif preset == "F4":
            sql_fn(build_f4_sql(site_id, unit_ids))
        elif preset in {"F5", "F7"}:
            sql_fn(build_f5_sql(site_id, unit_ids))
            if preset == "F7":
                sql_fn(close_september_sql(site_id))
        elif preset in {"F8", "F8_CAPITAL"}:
            sql_fn(build_f5_sql(site_id, unit_ids))
            sql_fn(build_f8_sql(site_id, unit_ids))
        elif preset in {"F9", "F9_RECON"}:
            password_hash = sql_fn(f"SELECT password_hash FROM users WHERE id = {safe_id(manager_user_id)};").strip() or "$argon2id$mocked_hash"
            sql_fn(build_f9_sql(site_id, unit_ids, attempt_slug=attempt, password_hash=password_hash))
        elif preset in {"F10", "F10_GOVERNANCE"}:
            site_name = "Begonya Sitesi"
            password_hash = sql_fn(f"SELECT password_hash FROM users WHERE id = {safe_id(manager_user_id)};").strip() or "$argon2id$mocked_hash"
            sql_fn(build_f10_sql(site_id, unit_ids, attempt_slug=attempt, password_hash=password_hash))

        # Synchronize backend state with database
        if reload_fn is not None:
            reload_fn()
        elif hasattr(api_client, "reload_state"):
            api_client.reload_state()
        else:
            api_client.call("POST", "/api/e2e/reload-state")

        # Determine whether to set clock
        if set_clock is None:
            should_set_clock = (preset in {"F4", "F5", "F6", "F7", "F8", "F8_CAPITAL", "F9", "F9_RECON", "F10", "F10_GOVERNANCE"}) if stack is not None else True
        else:
            should_set_clock = bool(set_clock)

        # Set reference clock
        if should_set_clock:
            ref_clock = REFERENCE_CLOCKS[preset]
            if hasattr(api_client, "e2e_clock"):
                api_client.e2e_clock("set_date", ref_clock)
            elif hasattr(api_client, "clock") and hasattr(api_client.clock, "set_date"):
                api_client.clock.set_date(ref_clock)
            else:
                api_client.call("POST", "/__e2e/clock", body={"action": "set_date", "date": ref_clock})

        # Refresh manager session if backend was restarted
        if reload_fn is not None:
            manager_session = api_client.login(manager_email, manager_password)

    # Build Persona list for manifest
    personas_list: list[dict[str, Any]] = [
        {
            "role": "SITE_MANAGER",
            "name": "Journey Manager",
            "unit": None,
            "email": manager_email,
            "password": manager_password,
        }
    ]
    if preset in {"F2", "F4", "F5", "F7", "F8", "F8_CAPITAL", "F10", "F10_GOVERNANCE"}:
        for p in PERSONAS["reference_residents"]:
            personas_list.append({
                "role": p["role"],
                "name": p["name"],
                "unit": p["unit"],
                "email": f"{attempt}.{p['key']}@journey.e2e.test",
                "password": manager_password,
            })
    elif preset in {"F6", "F9", "F9_RECON"}:
        personas_list.append({
            "role": "SITE_MANAGER",
            "name": "Second Manager (Reviewer)",
            "unit": None,
            "email": f"journey.reviewer.{attempt[:8]}@e2e.test",
            "password": manager_password,
        })
        for p in PERSONAS["reference_residents"]:
            personas_list.append({
                "role": p["role"],
                "name": p["name"],
                "unit": p["unit"],
                "email": f"{attempt}.{p['key']}@journey.e2e.test",
                "password": manager_password,
            })
        if preset in {"F9", "F9_RECON"}:
            personas_list.append({
                "role": "HOME_OWNER",
                "name": "Ahmet Yılmaz (Duplicate)",
                "unit": None,
                "email": f"{attempt}.ahmet.duplicate@journey.e2e.test",
                "password": manager_password,
            })

    # Build Scenario Manifest
    scenario_manifest = ScenarioManifest(
        preset=preset,
        site_id=site_id,
        site_name=site_name,
        reference_clock=REFERENCE_CLOCKS[preset],
        expected_site_totals=EXPECTED_TOTALS[preset],
        unit_by_unit_expected_balances=EXPECTED_UNIT_BALANCES[preset],
        personas=personas_list,
        pm_checklist=PM_CHECKLISTS.get(preset, []),
    )

    fixture = JourneyFixture(
        state=preset,
        site_id=site_id,
        manager=manager_session,
        manager_email=manager_email,
        manager_password=manager_password,
        unit_ids=unit_ids,
        person_ids=person_ids,
        scenario_manifest=scenario_manifest.to_dict(),
    )

    return SeedResult(preset=preset, site_id=site_id, manifest=scenario_manifest, fixture=fixture)


# ---------------------------------------------------------------------------
# CLI Entry Point
# ---------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    valid_presets = [f"F{i}" for i in range(11)] + ["F8_CAPITAL", "F9_RECON", "F10_GOVERNANCE"]
    parser = argparse.ArgumentParser(
        description="SitePulse Product Manager Scenario Seeder (F0–F10)",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "preset",
        nargs="?",
        default="F4",
        choices=valid_presets,
        help="Scenario preset to seed (F0-F10)",
    )
    parser.add_argument(
        "--preset",
        dest="opt_preset",
        choices=valid_presets,
        help="Scenario preset to seed (alternative to positional argument)",
    )
    parser.add_argument(
        "--api-url",
        default=os.environ.get("SITEPULSE_API_URL", "http://localhost:8080"),
        help="SitePulse backend API base URL",
    )
    parser.add_argument(
        "--saas-email",
        default=os.environ.get("SITEPULSE_BOOTSTRAP_ADMIN_EMAIL", "admin@sitepulse.io"),
        help="SaaS admin bootstrap email",
    )
    parser.add_argument(
        "--saas-password",
        default=os.environ.get("SITEPULSE_BOOTSTRAP_ADMIN_PASSWORD", "E2E-Bootstrap-Admin-1"),
        help="SaaS admin password",
    )
    parser.add_argument(
        "--db-name",
        default=os.environ.get("DB_NAME", "sitepulse"),
        help="PostgreSQL database name",
    )
    parser.add_argument(
        "--skip-reload",
        action="store_true",
        help="Skip state reload",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output Scenario Manifest as structured JSON",
    )

    args = parser.parse_args(argv)
    target_preset = args.opt_preset or args.preset

    try:
        result = seed_preset(
            target_preset,
            api_url=args.api_url,
            saas_email=args.saas_email,
            saas_password=args.saas_password,
            db_name=args.db_name,
            reload_fn=(lambda: None) if args.skip_reload else None,
        )
    except Exception as err:
        if args.json:
            print(json.dumps({"status": "ERROR", "error": str(err)}, indent=2))
        else:
            print(f"Error seeding preset {target_preset}: {err}", file=sys.stderr)
        return 1

    if args.json:
        print(result.manifest.to_json(indent=2))
    else:
        m = result.manifest
        print("=" * 60)
        print(f"SitePulse Scenario Seeded: {m.preset}")
        print("=" * 60)
        print(f"Site ID:         {m.site_id}")
        print(f"Site Name:       {m.site_name}")
        print(f"Reference Clock: {m.reference_clock}")
        print("\nExpected Site Totals:")
        for k, v in m.expected_site_totals.items():
            print(f"  {k:20s}: {v}")
        print("\nPersonas:")
        for p in m.personas:
            print(f"  [{p['role']:15s}] {p['name']:18s} {p.get('unit') or '-':5s} -> {p['email']}")
        if m.unit_by_unit_expected_balances:
            print("\nUnit Balances:")
            for u in m.unit_by_unit_expected_balances:
                paid = "PAID" if u["is_paid"] else "OVERDUE"
                print(f"  Unit {u['unit']} ({u['house_type']}): Due={u['amount_due']} TRY, Advance={u['advance_balance']} TRY [{paid}]")
        if m.pm_checklist:
            print("\nPM Checklist:")
            for item in m.pm_checklist:
                print(f"  [ ] {item}")
        print("=" * 60)

    return 0


if __name__ == "__main__":
    sys.exit(main())
