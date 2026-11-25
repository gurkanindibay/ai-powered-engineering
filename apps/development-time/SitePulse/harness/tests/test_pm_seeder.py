"""Unit tests for the Product Manager Scenario Seeder (F0–F7)."""
from __future__ import annotations

import json
import sys
import unittest
from decimal import Decimal
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock, patch

# Ensure harness and scripts are on sys.path
BASE_DIR = Path(__file__).resolve().parents[2]
SCRIPTS_DIR = BASE_DIR / "scripts"
E2E_DIR = BASE_DIR / "e2e"
for d in (str(SCRIPTS_DIR), str(E2E_DIR)):
    if d not in sys.path:
        sys.path.insert(0, d)

from pm_scenarios.seeder import (
    EXPECTED_TOTALS,
    EXPECTED_UNIT_BALANCES,
    PERSONAS,
    REFERENCE_CLOCKS,
    JourneyFixture,
    ScenarioManifest,
    build_f4_sql,
    build_f5_sql,
    close_september_sql,
    create_period_no_residents_sql,
    create_structure_sql,
    delete_blocks_sql,
    main,
    make_viban,
    safe_id,
    seed_preset,
    slug,
    sql_text,
)


class FakeStack:
    def __init__(self) -> None:
        self.db_name = "sitepulse_test_db"
        self.statements: list[str] = []
        self.restarts = 0

    def sql(self, statement: str) -> str:
        self.statements.append(statement)
        if "SELECT id FROM units" in statement:
            return "101\n102\n103\n104\n105\n106\n107"
        if "SELECT password_hash FROM users" in statement:
            return "$argon2id$mocked_hash"
        if "SELECT id || '|' || email FROM persons" in statement:
            import re
            found = re.findall(r"'([^'@]+@[^']+)'", statement)
            if found:
                return "\n".join(f"20{i+1}|{e}" for i, e in enumerate(found))
            return (
                "201|run.ayse@journey.e2e.test\n"
                "202|run.ahmet@journey.e2e.test\n"
                "203|run.selin@journey.e2e.test\n"
                "204|run.burak@journey.e2e.test\n"
                "205|run.can@journey.e2e.test\n"
                "206|run.deniz@journey.e2e.test\n"
                "207|run.elif@journey.e2e.test"
            )
        if "SELECT id FROM users" in statement:
            return "301\n302\n303\n304\n305\n306\n307"
        if "SELECT id FROM persons" in statement:
            return "201\n202\n203\n204\n205\n206\n207"
        return ""

    def restart_backend(self) -> None:
        self.restarts += 1


class FakeManifest:
    def __init__(self) -> None:
        self.run_id = "test-run-1"
        self.attempt_id = "test-attempt-1"
        self.database_name: str | None = None
        self.records: dict[str, list[str]] = {}

    def bind_database(self, db: str) -> None:
        self.database_name = db

    def record(self, bucket: str, resource_id: str | int) -> None:
        self.records.setdefault(bucket, []).append(str(resource_id))


class TestPmSeederConstantsAndManifest(unittest.TestCase):
    def test_catalogue_contains_all_f0_to_f7_presets(self) -> None:
        for i in range(8):
            key = f"F{i}"
            self.assertIn(key, REFERENCE_CLOCKS)
            self.assertIn(key, EXPECTED_TOTALS)
            self.assertIn(key, EXPECTED_UNIT_BALANCES)

    def test_reference_clocks_match_specification(self) -> None:
        self.assertEqual(REFERENCE_CLOCKS["F0"], "2026-09-01")
        self.assertEqual(REFERENCE_CLOCKS["F1"], "2026-09-01")
        self.assertEqual(REFERENCE_CLOCKS["F2"], "2026-09-01")
        self.assertEqual(REFERENCE_CLOCKS["F3"], "2026-10-01")
        self.assertEqual(REFERENCE_CLOCKS["F4"], "2026-11-19")
        self.assertEqual(REFERENCE_CLOCKS["F5"], "2026-11-19")
        self.assertEqual(REFERENCE_CLOCKS["F6"], "2026-11-19")
        self.assertEqual(REFERENCE_CLOCKS["F7"], "2026-11-19")

    def test_expected_totals_invariants(self) -> None:
        # F0: Empty site
        self.assertEqual(EXPECTED_TOTALS["F0"]["units"], 0)
        self.assertEqual(EXPECTED_TOTALS["F0"]["overdue"], Decimal("0.00"))

        # F1: 7 units, 0 people
        self.assertEqual(EXPECTED_TOTALS["F1"]["units"], 7)
        self.assertEqual(EXPECTED_TOTALS["F1"]["people"], 0)

        # F4: Overdue 8800.00
        self.assertEqual(EXPECTED_TOTALS["F4"]["overdue"], Decimal("8800.00"))
        self.assertEqual(EXPECTED_TOTALS["F4"]["advance"], Decimal("0.00"))

        # F5 and F7: Overdue 4567.50, Advance 1250.00
        self.assertEqual(EXPECTED_TOTALS["F5"]["overdue"], Decimal("4567.50"))
        self.assertEqual(EXPECTED_TOTALS["F5"]["advance"], Decimal("1250.00"))
        self.assertEqual(EXPECTED_TOTALS["F7"]["overdue"], Decimal("4567.50"))
        self.assertEqual(EXPECTED_TOTALS["F7"]["advance"], Decimal("1250.00"))

        # F6: Overdue 9750.00
        self.assertEqual(EXPECTED_TOTALS["F6"]["overdue"], Decimal("9750.00"))

    def test_make_viban_checksum_and_format(self) -> None:
        iban = make_viban("00205", "1", "A", 1)
        self.assertTrue(iban.startswith("TR"))
        self.assertEqual(len(iban), 26)
        rearranged = f"{iban[4:]}2927{iban[2:4]}"
        self.assertEqual(int(rearranged) % 97, 1)

    def test_make_viban_deterministic_reference_vectors(self) -> None:
        self.assertEqual(make_viban("00205", "site-1", "A", 14), "TR410020504213991067000014")

    def test_scenario_manifest_serialization(self) -> None:
        manifest = ScenarioManifest(
            preset="F4",
            site_id="10",
            site_name="Test Site F4",
            reference_clock="2026-11-19",
            expected_site_totals=EXPECTED_TOTALS["F4"],
            unit_by_unit_expected_balances=EXPECTED_UNIT_BALANCES["F4"],
            personas=[{"role": "SITE_MANAGER", "name": "Manager", "email": "mgr@test.com", "password": "pass"}],
        )
        self.assertEqual(len(manifest.unit_balances), 7)
        self.assertEqual(len(manifest.persona_accounts), 1)

        manifest_dict = manifest.to_dict()
        self.assertEqual(manifest_dict["preset"], "F4")
        self.assertEqual(manifest_dict["site_id"], "10")
        self.assertEqual(manifest_dict["reference_clock"], "2026-11-19")

        manifest_json = manifest.to_json()
        parsed = json.loads(manifest_json)
        self.assertEqual(parsed["preset"], "F4")
        self.assertEqual(parsed["site_id"], "10")
        self.assertEqual(parsed["expected_site_totals"]["overdue"], "8800.00")

    def test_safe_id_and_sql_text(self) -> None:
        self.assertEqual(safe_id("42"), 42)
        self.assertEqual(safe_id(42), 42)
        with self.assertRaises(ValueError):
            safe_id("0")
        with self.assertRaises(ValueError):
            safe_id("-5")
        with self.assertRaises(ValueError):
            safe_id("abc; DROP TABLE sites")

        self.assertEqual(sql_text("O'Connor"), "'O''Connor'")
        self.assertEqual(slug("Journey Run #413!"), "journey-run-413")


class TestPmSeederSqlBuilders(unittest.TestCase):
    def test_delete_blocks_sql(self) -> None:
        sql = delete_blocks_sql(15)
        self.assertEqual(sql, "DELETE FROM blocks WHERE site_id = 15;")

    def test_create_structure_sql(self) -> None:
        sql = create_structure_sql(20)
        self.assertIn("INSERT INTO blocks (site_id, block_name, total_floors) VALUES (20, 'A Blok', 7);", sql)
        self.assertIn("UPDATE sites SET proration_enabled = TRUE WHERE id = 20;", sql)
        self.assertIn("INSERT INTO house_types", sql)
        self.assertIn("INSERT INTO units", sql)

    def test_create_period_no_residents_sql(self) -> None:
        sql = create_period_no_residents_sql(25)
        self.assertIn("INSERT INTO dues_periods", sql)
        self.assertIn("'Ekim 2026'", sql)

    def test_build_f4_sql(self) -> None:
        units = tuple(str(i) for i in range(1, 8))
        sql = build_f4_sql(30, units)
        self.assertIn("INSERT INTO dues_periods (site_id, period_name, due_date, status) VALUES (30, 'Ekim 2026'", sql)
        self.assertIn("INSERT INTO dues_liabilities", sql)
        self.assertIn("INSERT INTO payment_receipts", sql)
        self.assertIn("INSERT INTO payment_allocations", sql)

    def test_build_f5_sql(self) -> None:
        units = tuple(str(i) for i in range(1, 8))
        sql = build_f5_sql(35, units)
        self.assertIn("'Eylül 2026'", sql)
        self.assertIn("'Ekim 2026'", sql)
        self.assertIn("'Kasım 2026'", sql)
        self.assertIn("INSERT INTO advance_balances", sql)
        self.assertIn("TAH-2026-000009", sql)

    def test_close_september_sql(self) -> None:
        sql = close_september_sql(40)
        self.assertIn("UPDATE dues_periods SET status = 'CLOSED' WHERE site_id = 40 AND period_name = 'Eylül 2026';", sql)
        self.assertIn("INSERT INTO dues_period_snapshots", sql)


class TestPmSeederExecution(unittest.TestCase):
    def setUp(self) -> None:
        self.api = MagicMock()
        self.api.create_site.return_value = {"site_id": 88, "temporary_password": "temp_secret_1!"}
        login_session = MagicMock()
        login_session.user = {"id": 999}
        login_session.token = "session_token"
        self.api.login.return_value = login_session
        self.api.clock = MagicMock()
        self.api.call = MagicMock(return_value={"status": "ok"})
        self.stack = FakeStack()
        self.manifest = FakeManifest()

    def test_seed_f0_deletes_empty_blocks(self) -> None:
        res = seed_preset(
            preset="F0",
            api=self.api,
            stack=self.stack,
            saas=MagicMock(),
            manifest=self.manifest,
        )
        self.assertEqual(res.preset, "F0")
        self.assertEqual(res.site_id, "88")
        self.assertEqual(res.fixture.unit_ids, ())
        self.assertEqual(res.fixture.person_ids, ())
        self.assertTrue(any("DELETE FROM blocks WHERE site_id = 88;" in s for s in self.stack.statements))
        self.assertEqual(self.stack.restarts, 1)

    def test_seed_f1_creates_structure_only(self) -> None:
        res = seed_preset(
            preset="F1",
            api=self.api,
            stack=self.stack,
            saas=MagicMock(),
            manifest=self.manifest,
        )
        self.assertEqual(res.preset, "F1")
        self.assertEqual(len(res.fixture.unit_ids), 7)
        self.assertEqual(res.fixture.person_ids, ())
        self.assertTrue(any("INSERT INTO blocks" in s for s in self.stack.statements))
        self.assertEqual(self.stack.restarts, 1)

    def test_seed_f2_creates_structure_and_residents(self) -> None:
        res = seed_preset(
            preset="F2",
            api=self.api,
            stack=self.stack,
            saas=MagicMock(),
            manifest=self.manifest,
        )
        self.assertEqual(res.preset, "F2")
        self.assertEqual(len(res.fixture.unit_ids), 7)
        self.assertEqual(len(res.fixture.person_ids), 7)
        self.assertTrue(any("INSERT INTO persons" in s for s in self.stack.statements))
        self.assertTrue(any("INSERT INTO unit_ownerships" in s for s in self.stack.statements))
        self.assertTrue(any("INSERT INTO unit_occupancies" in s for s in self.stack.statements))

    def test_seed_f4_creates_debts_and_single_receipt(self) -> None:
        res = seed_preset(
            preset="F4",
            api=self.api,
            stack=self.stack,
            saas=MagicMock(),
            manifest=self.manifest,
        )
        self.assertEqual(res.preset, "F4")
        self.assertEqual(res.manifest.expected_site_totals["overdue"], Decimal("8800.00"))
        self.assertTrue(any("Ekim 2026" in s and "INSERT INTO dues_periods" in s for s in self.stack.statements))
        self.assertTrue(any("TAH-2026-000001" in s for s in self.stack.statements))

    def test_seed_f5_creates_three_periods_and_nine_receipts(self) -> None:
        res = seed_preset(
            preset="F5",
            api=self.api,
            stack=self.stack,
            saas=MagicMock(),
            manifest=self.manifest,
        )
        self.assertEqual(res.preset, "F5")
        self.assertEqual(res.manifest.expected_site_totals["overdue"], Decimal("4567.50"))
        self.assertEqual(res.manifest.expected_site_totals["advance"], Decimal("1250.00"))
        self.assertTrue(any("Kasım 2026" in s for s in self.stack.statements))

    def test_seed_f7_closes_september(self) -> None:
        res = seed_preset(
            preset="F7",
            api=self.api,
            stack=self.stack,
            saas=MagicMock(),
            manifest=self.manifest,
        )
        self.assertEqual(res.preset, "F7")
        self.assertTrue(any("UPDATE dues_periods SET status = 'CLOSED'" in s for s in self.stack.statements))
        self.assertTrue(any("INSERT INTO dues_period_snapshots" in s for s in self.stack.statements))

    def test_unknown_preset_raises_value_error(self) -> None:
        for bad in ["F8", "F9", "F_UNKNOWN", ""]:
            with self.assertRaises(ValueError):
                seed_preset(
                    preset=bad,
                    api=self.api,
                    stack=self.stack,
                    saas=MagicMock(),
                    manifest=self.manifest,
                )

    def test_reload_state_invoked_via_api_when_no_reload_fn(self) -> None:
        api_mock = MagicMock(spec=["create_site", "login", "call"])
        def mock_call(method: str, path: str, **kwargs: Any) -> Any:
            if path == "/api/v1/saas/sites":
                return {"site_id": 55, "temporary_password": "temp"}
            if path == "/api/v1/auth/login":
                return {"token": "token", "user": {"id": 1}}
            return {"status": "ok"}
        api_mock.call.side_effect = mock_call
        api_mock.create_site.return_value = {"site_id": 55, "temporary_password": "temp"}
        login_session = MagicMock()
        login_session.user = {"id": 1}
        api_mock.login.return_value = login_session

        sql_statements: list[str] = []

        def mock_sql(s: str) -> str:
            sql_statements.append(s)
            if "SELECT id FROM units" in s:
                return "1\n2\n3\n4\n5\n6\n7"
            return ""

        res = seed_preset(
            preset="F1",
            api=api_mock,
            sql_fn=mock_sql,
            reload_fn=None,  # triggers api call to /api/e2e/reload-state
        )
        api_mock.call.assert_any_call("POST", "/api/e2e/reload-state")


class TestPmSeederCli(unittest.TestCase):
    @patch("pm_scenarios.seeder.seed_preset")
    @patch("pm_scenarios.seeder.PsqlRunner")
    @patch("pm_scenarios.seeder.ApiClient")
    def test_cli_runs_and_outputs_json(self, mock_client_cls: MagicMock, mock_psql_cls: MagicMock, mock_seed: MagicMock) -> None:
        mock_manifest = ScenarioManifest(
            preset="F4",
            site_id="77",
            site_name="CLI Test Site",
            reference_clock="2026-11-19",
            expected_site_totals=EXPECTED_TOTALS["F4"],
            unit_by_unit_expected_balances=EXPECTED_UNIT_BALANCES["F4"],
            personas=[],
        )
        mock_fixture = JourneyFixture(
            state="F4",
            site_id="77",
            manager=MagicMock(),
            manager_email="cli@test.com",
            manager_password="pass",
            unit_ids=("1", "2", "3", "4", "5", "6", "7"),
            person_ids=(),
            scenario_manifest=mock_manifest.to_dict(),
        )
        mock_res = MagicMock()
        mock_res.manifest = mock_manifest
        mock_res.fixture = mock_fixture
        mock_seed.return_value = mock_res

        from io import StringIO
        stdout = StringIO()
        with patch("sys.stdout", stdout):
            code = main(["F4", "--json", "--skip-reload"])

        self.assertEqual(code, 0)
        output = stdout.getvalue()
        parsed = json.loads(output)
        self.assertEqual(parsed["preset"], "F4")
        self.assertEqual(parsed["site_id"], "77")
        self.assertEqual(parsed["reference_clock"], "2026-11-19")


if __name__ == "__main__":
    unittest.main()
