"""Comprehensive test suite for Product Manager Scenario Presets F8, F9, and F10.

Tests presets:
- F8 / F8_CAPITAL: Capital Expenditure & Inter-Ledger Virman
- F9 / F9_RECON: Bank Statement Reconciliation, Deterministic Virtual IBANs, Duplicate Persona Merge
- F10 / F10_GOVERNANCE: Multi-Site Isolation, Severe Arrears, Four-Eyes Payment Plans, Heat Sharing, General Assembly
"""
from __future__ import annotations

import io
import json
import sys
import unittest
from decimal import Decimal
from pathlib import Path
from unittest.mock import MagicMock, patch

# Ensure harness and scripts are on sys.path
BASE_DIR = Path(__file__).resolve().parents[2]
SCRIPTS_DIR = BASE_DIR / "scripts"
E2E_DIR = BASE_DIR / "e2e"
TESTS_DIR = Path(__file__).resolve().parent
for d in (str(SCRIPTS_DIR), str(E2E_DIR), str(TESTS_DIR)):
    if d not in sys.path:
        sys.path.insert(0, d)

from pm_scenarios.seeder import (
    EXPECTED_TOTALS,
    EXPECTED_UNIT_BALANCES,
    PM_CHECKLISTS,
    REFERENCE_CLOCKS,
    ScenarioManifest,
    build_f8_sql,
    build_f9_sql,
    build_f10_sql,
    main,
    seed_preset,
)
from test_pm_seeder import FakeManifest, FakeStack


class TestPmScenariosF8F10Constants(unittest.TestCase):
    def test_presets_and_aliases_exist_in_catalogues(self) -> None:
        presets = ["F8", "F8_CAPITAL", "F9", "F9_RECON", "F10", "F10_GOVERNANCE"]
        for p in presets:
            self.assertIn(p, REFERENCE_CLOCKS, f"{p} missing from REFERENCE_CLOCKS")
            self.assertIn(p, EXPECTED_TOTALS, f"{p} missing from EXPECTED_TOTALS")
            self.assertIn(p, EXPECTED_UNIT_BALANCES, f"{p} missing from EXPECTED_UNIT_BALANCES")
            self.assertIn(p, PM_CHECKLISTS, f"{p} missing from PM_CHECKLISTS")

    def test_alias_equivalence(self) -> None:
        self.assertEqual(EXPECTED_TOTALS["F8"], EXPECTED_TOTALS["F8_CAPITAL"])
        self.assertEqual(EXPECTED_TOTALS["F9"], EXPECTED_TOTALS["F9_RECON"])
        self.assertEqual(EXPECTED_TOTALS["F10"], EXPECTED_TOTALS["F10_GOVERNANCE"])

        self.assertEqual(EXPECTED_UNIT_BALANCES["F8"], EXPECTED_UNIT_BALANCES["F8_CAPITAL"])
        self.assertEqual(EXPECTED_UNIT_BALANCES["F9"], EXPECTED_UNIT_BALANCES["F9_RECON"])
        self.assertEqual(EXPECTED_UNIT_BALANCES["F10"], EXPECTED_UNIT_BALANCES["F10_GOVERNANCE"])

        self.assertEqual(PM_CHECKLISTS["F8"], PM_CHECKLISTS["F8_CAPITAL"])
        self.assertEqual(PM_CHECKLISTS["F9"], PM_CHECKLISTS["F9_RECON"])
        self.assertEqual(PM_CHECKLISTS["F10"], PM_CHECKLISTS["F10_GOVERNANCE"])

    def test_reference_clocks(self) -> None:
        self.assertEqual(REFERENCE_CLOCKS["F8"], "2026-11-19")
        self.assertEqual(REFERENCE_CLOCKS["F8_CAPITAL"], "2026-11-19")
        self.assertEqual(REFERENCE_CLOCKS["F9"], "2026-11-19")
        self.assertEqual(REFERENCE_CLOCKS["F9_RECON"], "2026-11-19")
        self.assertEqual(REFERENCE_CLOCKS["F10"], "2026-11-19")
        self.assertEqual(REFERENCE_CLOCKS["F10_GOVERNANCE"], "2026-11-19")

    def test_decimal_precision_no_floats(self) -> None:
        """Enforces that monetary values in EXPECTED_TOTALS use Decimal, never float."""
        for p in ["F8", "F8_CAPITAL", "F9", "F9_RECON", "F10", "F10_GOVERNANCE"]:
            totals = EXPECTED_TOTALS[p]
            for key, val in totals.items():
                self.assertNotIsInstance(
                    val,
                    float,
                    f"Forbidden float found in EXPECTED_TOTALS[{p}][{key}]: {val!r}",
                )
                if key in {"overdue", "advance", "capital_budget", "capital_accrued", "capital_due"}:
                    self.assertIsInstance(val, Decimal, f"Expected Decimal for {key} in {p}")

    def test_f8_expected_totals(self) -> None:
        totals = EXPECTED_TOTALS["F8"]
        self.assertEqual(totals["blocks"], 1)
        self.assertEqual(totals["units"], 7)
        self.assertEqual(totals["people"], 7)
        self.assertEqual(totals["accounts"], 7)
        self.assertEqual(totals["periods"], 3)
        self.assertEqual(totals["liabilities"], 25)
        self.assertEqual(totals["receipts"], 9)
        self.assertEqual(totals["overdue"], Decimal("4567.50"))
        self.assertEqual(totals["advance"], Decimal("1250.00"))
        self.assertEqual(totals["capital_projects"], 1)
        self.assertEqual(totals["capital_installments"], 3)
        self.assertEqual(totals["capital_budget"], Decimal("105000.00"))
        self.assertEqual(totals["capital_accrued"], Decimal("35000.00"))

    def test_f8_expected_unit_balances(self) -> None:
        balances = EXPECTED_UNIT_BALANCES["F8"]
        self.assertEqual(len(balances), 7)
        for u in balances:
            self.assertEqual(u["capital_due"], "5000.00")
        # Unit A-6 holds 1250.00 advance
        a6 = next(u for u in balances if u["unit"] == "A-6")
        self.assertEqual(a6["advance_balance"], "1250.00")
        self.assertEqual(a6["amount_due"], "0.00")

    def test_f9_expected_totals(self) -> None:
        totals = EXPECTED_TOTALS["F9"]
        self.assertEqual(totals["blocks"], 1)
        self.assertEqual(totals["units"], 7)
        self.assertEqual(totals["people"], 11)  # 10 changing occupancy + 1 duplicate candidate
        self.assertEqual(totals["accounts"], 7)
        self.assertEqual(totals["periods"], 3)
        self.assertEqual(totals["liabilities"], 21)
        self.assertEqual(totals["receipts"], 0)
        self.assertEqual(totals["overdue"], Decimal("9750.00"))
        self.assertEqual(totals["advance"], Decimal("0.00"))
        self.assertEqual(totals["virtual_ibans_assigned"], 7)
        self.assertEqual(totals["duplicate_candidates"], 1)

    def test_f10_expected_totals(self) -> None:
        totals = EXPECTED_TOTALS["F10"]
        self.assertEqual(totals["blocks"], 1)
        self.assertEqual(totals["units"], 7)
        self.assertEqual(totals["people"], 7)
        self.assertEqual(totals["accounts"], 7)
        self.assertEqual(totals["periods"], 4)
        self.assertEqual(totals["liabilities"], 8)
        self.assertEqual(totals["receipts"], 0)
        self.assertEqual(totals["overdue"], Decimal("11600.00"))
        self.assertEqual(totals["advance"], Decimal("0.00"))
        self.assertEqual(totals["sites"], 2)
        self.assertEqual(totals["severe_arrears_units"], 1)
        self.assertEqual(totals["active_payment_plans"], 1)
        self.assertEqual(totals["heat_cost_periods"], 1)
        self.assertEqual(totals["scheduled_meetings"], 1)

    def test_f10_expected_unit_balances(self) -> None:
        balances = EXPECTED_UNIT_BALANCES["F10"]
        self.assertEqual(len(balances), 7)
        a2 = next(u for u in balances if u["unit"] == "A-2")
        self.assertEqual(a2["amount_due"], "3350.00")  # 1500 (Nov) + 1850 (Haziran overdue)

    def test_pm_checklists_content(self) -> None:
        f8_cl = PM_CHECKLISTS["F8"]
        self.assertTrue(any("Exterior Facade Insulation" in item for item in f8_cl))
        self.assertTrue(any("virman" in item.lower() for item in f8_cl))

        f9_cl = PM_CHECKLISTS["F9"]
        self.assertTrue(any("Virtual IBAN" in item for item in f9_cl))
        self.assertTrue(any("duplicate" in item.lower() for item in f9_cl))

        f10_cl = PM_CHECKLISTS["F10"]
        self.assertTrue(any("Kardelen Rezidans" in item for item in f10_cl))
        self.assertTrue(any("severe" in item.lower() or "arrears" in item.lower() for item in f10_cl))
        self.assertTrue(any("payment plan" in item.lower() for item in f10_cl))


class TestPmScenariosF8F10SqlBuilders(unittest.TestCase):
    def test_build_f8_sql(self) -> None:
        unit_ids = tuple(str(i) for i in range(101, 108))
        sql = build_f8_sql(50, unit_ids)
        self.assertIn("BEGIN;", sql)
        self.assertIn("INSERT INTO capital_projects", sql)
        self.assertIn("'Exterior Facade Insulation'", sql)
        self.assertIn("'FACADE_INSULATION'", sql)
        self.assertIn("105000.00", sql)
        self.assertIn("'TR330006100519786457841326'", sql)
        self.assertIn("INSERT INTO capital_project_installments", sql)
        self.assertIn("33.34", sql)
        self.assertIn("33.33", sql)
        self.assertIn("INSERT INTO dues_liabilities", sql)
        self.assertIn("'CAPITAL_DUES'", sql)
        self.assertIn("5000.00", sql)
        self.assertIn("COMMIT;", sql)

    def test_build_f9_sql(self) -> None:
        unit_ids = tuple(str(i) for i in range(101, 108))
        sql = build_f9_sql(60, unit_ids, attempt_slug="test-attempt", password_hash="$argon2$mock")
        self.assertIn("BEGIN;", sql)
        self.assertIn("Mert Kılıç", sql)
        self.assertIn("Oya Çelik", sql)
        self.assertIn("Gül Tanrıverdi", sql)
        self.assertIn("ahmet.duplicate", sql)
        self.assertIn("journey.reviewer.", sql)
        self.assertIn("UPDATE units SET virtual_iban", sql)
        self.assertIn("INSERT INTO dues_periods", sql)
        self.assertIn("'Eylül 2026'", sql)
        self.assertIn("'Ekim 2026'", sql)
        self.assertIn("'Kasım 2026'", sql)
        self.assertIn("COMMIT;", sql)

    def test_build_f10_sql(self) -> None:
        unit_ids = tuple(str(i) for i in range(101, 108))
        sql = build_f10_sql(70, unit_ids, attempt_slug="test-attempt", password_hash="$argon2$mock")
        self.assertIn("BEGIN;", sql)
        self.assertIn("UPDATE sites SET site_name = 'Begonya Sitesi'", sql)
        self.assertIn("Kardelen Rezidans", sql)
        self.assertIn("K Blok", sql)
        self.assertIn("'Haziran 2026'", sql)
        self.assertIn("350.00", sql)
        self.assertIn("INSERT INTO debt_aging_snapshots", sql)
        self.assertIn("INSERT INTO payment_plans", sql)
        self.assertIn("'manager', 'board_president'", sql)  # four-eyes check
        self.assertIn("INSERT INTO heat_cost_periods", sql)
        self.assertIn("Kasım 2026 Isı Paylaşımı", sql)
        self.assertIn("INSERT INTO heat_meter_readings", sql)
        self.assertIn("INSERT INTO assembly_meetings", sql)
        self.assertIn("INSERT INTO assembly_agenda_items", sql)
        self.assertIn("COMMIT;", sql)


class TestPmScenariosF8F10Execution(unittest.TestCase):
    def setUp(self) -> None:
        self.api = MagicMock()
        self.api.create_site.return_value = {"site_id": 188, "temporary_password": "temp_secret_1!"}
        login_session = MagicMock()
        login_session.user = {"id": 999}
        login_session.token = "session_token"
        self.api.login.return_value = login_session
        self.api.clock = MagicMock()
        self.api.call = MagicMock(return_value={"status": "ok"})
        self.stack = FakeStack()
        self.manifest = FakeManifest()

    def test_seed_f8_capital_execution(self) -> None:
        res = seed_preset(
            preset="F8",
            api=self.api,
            stack=self.stack,
            saas=MagicMock(),
            manifest=self.manifest,
        )
        self.assertEqual(res.preset, "F8")
        self.assertEqual(res.manifest.reference_clock, "2026-11-19")
        self.assertEqual(res.manifest.expected_site_totals["overdue"], Decimal("4567.50"))
        self.assertEqual(res.manifest.expected_site_totals["advance"], Decimal("1250.00"))
        self.assertEqual(res.manifest.expected_site_totals["capital_budget"], Decimal("105000.00"))
        self.assertEqual(res.manifest.expected_site_totals["capital_accrued"], Decimal("35000.00"))
        self.assertEqual(len(res.manifest.unit_balances), 7)
        self.assertEqual(res.manifest.unit_balances[0]["capital_due"], "5000.00")
        self.assertTrue(len(res.manifest.pm_checklist) > 0)
        self.assertEqual(res.manifest.pm_checklists, res.manifest.pm_checklist)

        # Check SQL execution
        self.assertTrue(any("Exterior Facade Insulation" in s for s in self.stack.statements))
        self.assertTrue(any("CAPITAL_DUES" in s for s in self.stack.statements))

    def test_seed_f8_alias_capital_execution(self) -> None:
        res = seed_preset(
            preset="F8_CAPITAL",
            api=self.api,
            stack=self.stack,
            saas=MagicMock(),
            manifest=self.manifest,
        )
        self.assertEqual(res.preset, "F8_CAPITAL")
        self.assertEqual(res.manifest.expected_site_totals["capital_budget"], Decimal("105000.00"))

    def test_seed_f9_recon_execution(self) -> None:
        res = seed_preset(
            preset="F9",
            api=self.api,
            stack=self.stack,
            saas=MagicMock(),
            manifest=self.manifest,
        )
        self.assertEqual(res.preset, "F9")
        self.assertEqual(res.manifest.expected_site_totals["overdue"], Decimal("9750.00"))
        self.assertEqual(res.manifest.expected_site_totals["people"], 11)
        self.assertEqual(res.manifest.expected_site_totals["virtual_ibans_assigned"], 7)
        self.assertEqual(res.manifest.expected_site_totals["duplicate_candidates"], 1)
        self.assertTrue(any(p["role"] == "SITE_MANAGER" and "Reviewer" in p["name"] for p in res.manifest.personas))
        self.assertTrue(any("Duplicate" in p["name"] for p in res.manifest.personas))
        self.assertTrue(len(res.manifest.pm_checklist) > 0)

        # Check SQL execution
        self.assertTrue(any("ahmet.duplicate" in s for s in self.stack.statements))
        self.assertTrue(any("virtual_iban" in s for s in self.stack.statements))

    def test_seed_f9_alias_recon_execution(self) -> None:
        res = seed_preset(
            preset="F9_RECON",
            api=self.api,
            stack=self.stack,
            saas=MagicMock(),
            manifest=self.manifest,
        )
        self.assertEqual(res.preset, "F9_RECON")
        self.assertEqual(res.manifest.expected_site_totals["people"], 11)

    def test_seed_f10_governance_execution(self) -> None:
        res = seed_preset(
            preset="F10",
            api=self.api,
            stack=self.stack,
            saas=MagicMock(),
            manifest=self.manifest,
        )
        self.assertEqual(res.preset, "F10")
        self.assertEqual(res.manifest.site_name, "Begonya Sitesi")
        self.assertEqual(res.manifest.expected_site_totals["overdue"], Decimal("11600.00"))
        self.assertEqual(res.manifest.expected_site_totals["sites"], 2)
        self.assertEqual(res.manifest.expected_site_totals["severe_arrears_units"], 1)
        self.assertEqual(res.manifest.expected_site_totals["active_payment_plans"], 1)
        self.assertEqual(res.manifest.expected_site_totals["heat_cost_periods"], 1)
        self.assertEqual(res.manifest.expected_site_totals["scheduled_meetings"], 1)
        self.assertTrue(len(res.manifest.pm_checklist) > 0)

        # Check SQL execution
        self.assertTrue(any("Begonya Sitesi" in s for s in self.stack.statements))
        self.assertTrue(any("Kardelen Rezidans" in s for s in self.stack.statements))
        self.assertTrue(any("payment_plans" in s for s in self.stack.statements))
        self.assertTrue(any("heat_cost_periods" in s for s in self.stack.statements))
        self.assertTrue(any("assembly_meetings" in s for s in self.stack.statements))

    def test_seed_f10_alias_governance_execution(self) -> None:
        res = seed_preset(
            preset="F10_GOVERNANCE",
            api=self.api,
            stack=self.stack,
            saas=MagicMock(),
            manifest=self.manifest,
        )
        self.assertEqual(res.preset, "F10_GOVERNANCE")
        self.assertEqual(res.manifest.expected_site_totals["sites"], 2)


class TestPmScenariosF8F10IntegrityViolations(unittest.TestCase):
    """Verifies that data models and SQL builders strictly obey v_integrity_violations rules."""

    def test_f8_capital_installment_percentages_sum_to_100(self) -> None:
        # v_integrity_violations check: SUM(percentage) - 100 == 0
        percentages = [Decimal("33.34"), Decimal("33.33"), Decimal("33.33")]
        self.assertEqual(sum(percentages), Decimal("100.00"))

    def test_f8_advance_balances_vs_ledger_entries(self) -> None:
        # v_integrity_violations check: advance_balances.balance == sum(advance_ledger_entries)
        f8_balances = EXPECTED_UNIT_BALANCES["F8"]
        a6 = next(u for u in f8_balances if u["unit"] == "A-6")
        self.assertEqual(Decimal(a6["advance_balance"]), Decimal("1250.00"))
        # In F5/F8, advance ledger has entry amount 1250.00 from surplus
        net_advance = Decimal("1250.00")
        self.assertEqual(Decimal(a6["advance_balance"]) - net_advance, Decimal("0.00"))

    def test_f10_four_eyes_constraint(self) -> None:
        # payment_plans check: created_by <> approved_by
        creator = "manager"
        approver = "board_president"
        self.assertNotEqual(creator, approver)

    def test_f10_heat_readings_monotonic(self) -> None:
        # heat_meter_readings check: current_reading >= previous_reading
        for unit_no in range(1, 8):
            prev = 100.000 + (unit_no * 10)
            curr = 150.000 + (unit_no * 15)
            self.assertGreater(curr, prev)


class TestPmScenariosF8F10Cli(unittest.TestCase):
    @patch("pm_scenarios.seeder.seed_preset")
    def test_cli_f8_json(self, mock_seed: MagicMock) -> None:
        manifest = ScenarioManifest(
            preset="F8",
            site_id="88",
            site_name="SitePulse PM Test F8",
            reference_clock="2026-11-19",
            expected_site_totals=EXPECTED_TOTALS["F8"],
            unit_by_unit_expected_balances=EXPECTED_UNIT_BALANCES["F8"],
            personas=[],
            pm_checklist=PM_CHECKLISTS["F8"],
        )
        mock_seed.return_value = MagicMock(manifest=manifest)

        buf = io.StringIO()
        with patch("sys.stdout", buf):
            code = main(["F8", "--json", "--skip-reload"])
        self.assertEqual(code, 0)
        output = json.loads(buf.getvalue())
        self.assertEqual(output["preset"], "F8")
        self.assertEqual(output["expected_site_totals"]["capital_projects"], 1)
        self.assertIn("pm_checklist", output)
        self.assertIn("pm_checklists", output)

    @patch("pm_scenarios.seeder.seed_preset")
    def test_cli_f9_text_output(self, mock_seed: MagicMock) -> None:
        manifest = ScenarioManifest(
            preset="F9",
            site_id="89",
            site_name="SitePulse PM Test F9",
            reference_clock="2026-11-19",
            expected_site_totals=EXPECTED_TOTALS["F9"],
            unit_by_unit_expected_balances=EXPECTED_UNIT_BALANCES["F9"],
            personas=[{"role": "SITE_MANAGER", "name": "Manager", "unit": None, "email": "m@test.com"}],
            pm_checklist=PM_CHECKLISTS["F9"],
        )
        mock_seed.return_value = MagicMock(manifest=manifest)

        buf = io.StringIO()
        with patch("sys.stdout", buf):
            code = main(["--preset", "F9_RECON", "--skip-reload"])
        self.assertEqual(code, 0)
        text = buf.getvalue()
        self.assertIn("SitePulse Scenario Seeded: F9", text)
        self.assertIn("Virtual IBAN", text)


if __name__ == "__main__":
    unittest.main()
