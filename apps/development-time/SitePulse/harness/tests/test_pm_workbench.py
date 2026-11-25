"""Unit tests for SitePulse PM Workbench CLI (pm_workbench.py).

Covers:
  - Argument parsing across all subcommands (up, down, seed, clock, status).
  - Safety production guardrails (APP_ENV and ENVIRONMENT).
  - Clock API wrapper (set, advance, tick, reset, clear, fallback).
  - Output formatting (valid structured JSON and human-readable tables).
  - Runtime PID file lifecycle.
"""
from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

# Ensure harness and scripts are on sys.path
BASE_DIR = Path(__file__).resolve().parents[2]
SCRIPTS_DIR = BASE_DIR / "scripts"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import pm_workbench as wb


class TestPmWorkbenchParser(unittest.TestCase):
    """Tests CLI argument parsing for all subcommands."""

    def setUp(self) -> None:
        self.parser = wb.build_parser()

    def test_top_level_arguments(self) -> None:
        args = self.parser.parse_args(["--json", "--pid-file", "/tmp/test.pid"])
        self.assertTrue(args.json)
        self.assertEqual(args.pid_file, "/tmp/test.pid")
        self.assertIsNone(args.subcommand)

    def test_up_subcommand_defaults(self) -> None:
        args = self.parser.parse_args(["up"])
        self.assertEqual(args.subcommand, "up")
        self.assertEqual(args.api_port, 8080)
        self.assertEqual(args.web_port, 9090)
        self.assertFalse(args.skip_db)
        self.assertFalse(args.skip_flutter)
        self.assertFalse(args.backend_release)
        self.assertEqual(args.timeout, 40.0)
        self.assertFalse(args.no_wait)
        self.assertFalse(args.json)

    def test_up_subcommand_custom_flags(self) -> None:
        args = self.parser.parse_args([
            "up",
            "--api-port", "8180",
            "--web-port", "9190",
            "--skip-db",
            "--skip-flutter",
            "--backend-release",
            "--timeout", "15",
            "--no-wait",
            "--json",
        ])
        self.assertEqual(args.subcommand, "up")
        self.assertEqual(args.api_port, 8180)
        self.assertEqual(args.web_port, 9190)
        self.assertTrue(args.skip_db)
        self.assertTrue(args.skip_flutter)
        self.assertTrue(args.backend_release)
        self.assertEqual(args.timeout, 15.0)
        self.assertTrue(args.no_wait)
        self.assertTrue(args.json)

    def test_down_subcommand(self) -> None:
        args = self.parser.parse_args(["down", "--stop-db", "--json"])
        self.assertEqual(args.subcommand, "down")
        self.assertTrue(args.stop_db)
        self.assertTrue(args.json)

    def test_seed_subcommand_positional_and_flags(self) -> None:
        args1 = self.parser.parse_args(["seed", "F5"])
        self.assertEqual(args1.subcommand, "seed")
        self.assertEqual(args1.preset, "F5")
        self.assertIsNone(args1.opt_preset)
        self.assertFalse(args1.json)

        args2 = self.parser.parse_args([
            "seed",
            "--preset", "F2",
            "--api-url", "http://127.0.0.1:8180",
            "--skip-reload",
            "--json",
        ])
        self.assertEqual(args2.subcommand, "seed")
        self.assertEqual(args2.opt_preset, "F2")
        self.assertEqual(args2.api_url, "http://127.0.0.1:8180")
        self.assertTrue(args2.skip_reload)
        self.assertTrue(args2.json)

    def test_clock_subcommand_actions(self) -> None:
        args_adv = self.parser.parse_args(["clock", "advance", "2026-11-29"])
        self.assertEqual(args_adv.subcommand, "clock")
        self.assertEqual(args_adv.action, "advance")
        self.assertEqual(args_adv.value, "2026-11-29")

        args_tick = self.parser.parse_args(["clock", "tick", "--json"])
        self.assertEqual(args_tick.subcommand, "clock")
        self.assertEqual(args_tick.action, "tick")
        self.assertIsNone(args_tick.value)
        self.assertTrue(args_tick.json)

        args_set = self.parser.parse_args(["clock", "set", "2026-11-19"])
        self.assertEqual(args_set.action, "set")
        self.assertEqual(args_set.value, "2026-11-19")

        args_reset = self.parser.parse_args(["clock", "reset"])
        self.assertEqual(args_reset.action, "reset")

    def test_status_subcommand(self) -> None:
        args = self.parser.parse_args(["status", "--json", "--api-url", "http://localhost:8180"])
        self.assertEqual(args.subcommand, "status")
        self.assertTrue(args.json)
        self.assertEqual(args.api_url, "http://localhost:8180")


class TestPmWorkbenchProductionGuardrail(unittest.TestCase):
    """Tests production environment safety guardrails."""

    def test_check_production_guardrail_clean_env(self) -> None:
        clean_env = {"APP_ENV": "development", "ENVIRONMENT": "test"}
        # Should not raise
        wb.check_production_guardrail(clean_env)

    def test_check_production_guardrail_app_env_production(self) -> None:
        prod_env = {"APP_ENV": "production"}
        with self.assertRaises(wb.ProductionGuardrailError) as ctx:
            wb.check_production_guardrail(prod_env)
        self.assertIn("Refusing execution in production environment", str(ctx.exception))

    def test_check_production_guardrail_environment_production(self) -> None:
        prod_env = {"ENVIRONMENT": "PRODUCTION"}
        with self.assertRaises(wb.ProductionGuardrailError) as ctx:
            wb.check_production_guardrail(prod_env)
        self.assertIn("Refusing execution in production environment", str(ctx.exception))

    def test_main_with_production_env_returns_code_1_and_error(self) -> None:
        stderr_capture = io.StringIO()
        with patch("sys.stderr", stderr_capture):
            code = wb.main(["status"], env={"APP_ENV": "production"})
        self.assertEqual(code, 1)
        self.assertIn("Refusing execution in production environment", stderr_capture.getvalue())

    def test_main_with_production_env_json_output(self) -> None:
        stdout_capture = io.StringIO()
        with patch("sys.stdout", stdout_capture):
            code = wb.main(["status", "--json"], env={"ENVIRONMENT": "production"})
        self.assertEqual(code, 1)
        data = json.loads(stdout_capture.getvalue())
        self.assertEqual(data["status"], "ERROR")
        self.assertIn("Refusing execution in production environment", data["error"])


class TestPmWorkbenchPidLifecycle(unittest.TestCase):
    """Tests pidfile reading, writing, and cleanup."""

    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.pid_file = Path(self.temp_dir.name) / "test_workbench.pid"

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def test_resolve_pid_path_custom(self) -> None:
        p = wb.resolve_pid_path(self.pid_file)
        self.assertEqual(p, self.pid_file.resolve())

    def test_resolve_pid_path_env_var(self) -> None:
        test_env = {"SITEPULSE_WORKBENCH_PIDFILE": str(self.pid_file)}
        p = wb.resolve_pid_path(None, env=test_env)
        self.assertEqual(p, self.pid_file.resolve())

    def test_read_write_remove_pidfile(self) -> None:
        self.assertIsNone(wb.read_pidfile(self.pid_file))

        payload = {
            "backend_pid": 12345,
            "flutter_pid": 67890,
            "api_port": 8080,
            "web_port": 9090,
        }
        wb.write_pidfile(self.pid_file, payload)
        self.assertTrue(self.pid_file.is_file())

        loaded = wb.read_pidfile(self.pid_file)
        self.assertIsNotNone(loaded)
        self.assertEqual(loaded["backend_pid"], 12345)
        self.assertEqual(loaded["flutter_pid"], 67890)

        wb.remove_pidfile(self.pid_file)
        self.assertFalse(self.pid_file.exists())
        self.assertIsNone(wb.read_pidfile(self.pid_file))

    def test_read_corrupt_pidfile(self) -> None:
        self.pid_file.write_text("not-a-json-object", encoding="utf-8")
        self.assertIsNone(wb.read_pidfile(self.pid_file))


class TestPmWorkbenchClockCommand(unittest.TestCase):
    """Tests the deterministic clock API CLI wrapper and fallback."""

    @patch("urllib.request.urlopen")
    def test_clock_advance_payload(self, mock_urlopen: MagicMock) -> None:
        mock_resp = MagicMock()
        mock_resp.read.return_value = json.dumps({"action": "advanced", "date": "2026-11-29"}).encode("utf-8")
        mock_resp.status = 200
        mock_urlopen.return_value.__enter__.return_value = mock_resp

        stdout = io.StringIO()
        with patch("sys.stdout", stdout):
            code = wb.run_clock("advance", "2026-11-29", api_url="http://localhost:8080", as_json=False)

        self.assertEqual(code, 0)
        self.assertIn("Clock date advanced to 2026-11-29", stdout.getvalue())

        req = mock_urlopen.call_args[0][0]
        self.assertEqual(req.full_url, "http://localhost:8080/api/e2e/clock")
        self.assertEqual(req.get_method(), "POST")
        sent = json.loads(req.data.decode("utf-8"))
        self.assertEqual(sent, {"action": "advance_to", "date": "2026-11-29"})

    @patch("urllib.request.urlopen")
    def test_clock_tick_json_output(self, mock_urlopen: MagicMock) -> None:
        tick_resp = {
            "action": "ticked",
            "date": "2026-11-29",
            "report": {"dues_periods": 3, "penalties_accrued": 0},
        }
        mock_resp = MagicMock()
        mock_resp.read.return_value = json.dumps(tick_resp).encode("utf-8")
        mock_resp.status = 200
        mock_urlopen.return_value.__enter__.return_value = mock_resp

        stdout = io.StringIO()
        with patch("sys.stdout", stdout):
            code = wb.run_clock("tick", api_url="http://localhost:8080", as_json=True)

        self.assertEqual(code, 0)
        data = json.loads(stdout.getvalue())
        self.assertEqual(data["action"], "ticked")
        self.assertEqual(data["date"], "2026-11-29")
        self.assertEqual(data["report"]["dues_periods"], 3)

    @patch("urllib.request.urlopen")
    def test_clock_fallback_from_api_to_dunder(self, mock_urlopen: MagicMock) -> None:
        import urllib.error

        mock_resp = MagicMock()
        mock_resp.read.return_value = json.dumps({"action": "cleared"}).encode("utf-8")
        mock_resp.status = 200

        err_fp = io.BytesIO(b"")
        http_err = urllib.error.HTTPError(
            "http://localhost:8080/api/e2e/clock", 404, "Not Found", {}, err_fp
        )

        mock_urlopen.side_effect = [
            http_err,
            MagicMock(__enter__=MagicMock(return_value=mock_resp), __exit__=MagicMock()),
        ]

        result = wb.call_clock_api("http://localhost:8080", {"action": "clear"})
        self.assertEqual(result, {"action": "cleared"})
        self.assertEqual(mock_urlopen.call_count, 2)
        second_call_req = mock_urlopen.call_args_list[1][0][0]
        self.assertEqual(second_call_req.full_url, "http://localhost:8080/__e2e/clock")

    def test_clock_missing_required_value(self) -> None:
        with self.assertRaises(ValueError):
            wb.run_clock("advance", value=None)
        with self.assertRaises(ValueError):
            wb.run_clock("set", value=None)


class TestPmWorkbenchSeedCommand(unittest.TestCase):
    """Tests the seed subcommand and output formatting."""

    @patch("pm_workbench.call_clock_api")
    @patch("pm_workbench.seed_preset")
    def test_seed_f5_json_returns_valid_manifest_with_credentials(
        self,
        mock_seed: MagicMock,
        mock_clock: MagicMock,
    ) -> None:
        from pm_scenarios.seeder import ScenarioManifest

        manifest = ScenarioManifest(
            preset="F5",
            site_id="site-101",
            site_name="Test Complex",
            reference_clock="2026-11-19",
            expected_site_totals={"total_overdue": "4567.50", "total_advance": "1250.00"},
            unit_by_unit_expected_balances=[
                {"unit": "A-1", "amount_due": "500.00", "advance_balance": "0.00", "is_paid": False}
            ],
            personas=[
                {
                    "role": "SITE_MANAGER",
                    "name": "Journey Manager",
                    "unit": None,
                    "email": "manager@test.com",
                    "password": "E2E-Bootstrap-Admin-1",
                }
            ],
        )
        mock_result = MagicMock()
        mock_result.manifest = manifest
        mock_seed.return_value = mock_result
        mock_clock.return_value = {"action": "date_set", "date": "2026-11-19"}

        stdout = io.StringIO()
        with patch("sys.stdout", stdout):
            code = wb.run_seed("F5", api_url="http://localhost:8080", as_json=True)

        self.assertEqual(code, 0)
        data = json.loads(stdout.getvalue())
        self.assertEqual(data["preset"], "F5")
        self.assertEqual(data["site_id"], "site-101")
        self.assertEqual(data["reference_clock"], "2026-11-19")
        self.assertEqual(data["expected_site_totals"]["total_overdue"], "4567.50")
        self.assertEqual(len(data["personas"]), 1)
        self.assertEqual(data["personas"][0]["email"], "manager@test.com")
        self.assertEqual(data["personas"][0]["password"], "E2E-Bootstrap-Admin-1")

        # Verify clock API was called to set reference date
        mock_clock.assert_called_once_with("http://localhost:8080", {"action": "set_date", "date": "2026-11-19"})

    @patch("pm_workbench.call_clock_api")
    @patch("pm_workbench.seed_preset")
    def test_seed_human_readable_cheat_sheet(
        self,
        mock_seed: MagicMock,
        mock_clock: MagicMock,
    ) -> None:
        from pm_scenarios.seeder import ScenarioManifest

        manifest = ScenarioManifest(
            preset="F4",
            site_id="site-202",
            site_name="Sunrise Valley",
            reference_clock="2026-11-19",
            expected_site_totals={"total_overdue": "8800.00", "total_advance": "0.00"},
            unit_by_unit_expected_balances=[
                {"unit": "B-2", "amount_due": "880.00", "advance_balance": "0.00", "is_paid": False}
            ],
            personas=[
                {
                    "role": "SITE_MANAGER",
                    "name": "Journey Manager",
                    "unit": None,
                    "email": "manager@test.com",
                    "password": "E2E-Bootstrap-Admin-1",
                }
            ],
        )
        mock_result = MagicMock()
        mock_result.manifest = manifest
        mock_seed.return_value = mock_result

        stdout = io.StringIO()
        with patch("sys.stdout", stdout):
            code = wb.run_seed("F4", api_url="http://localhost:8080", as_json=False)

        self.assertEqual(code, 0)
        output = stdout.getvalue()
        self.assertIn("SitePulse Scenario Seeded: F4", output)
        self.assertIn("Sunrise Valley", output)
        self.assertIn("total_overdue", output)
        self.assertIn("Personas Credentials Cheat Sheet", output)
        self.assertIn("manager@test.com", output)
        self.assertIn("Unit Balances:", output)


class TestPmWorkbenchUpAndDownLifecycle(unittest.TestCase):
    """Tests up, down, and status commands."""

    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.pid_file = Path(self.temp_dir.name) / "test.pid"

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    @patch("pm_workbench.is_process_alive")
    def test_up_when_already_running(self, mock_alive: MagicMock) -> None:
        mock_alive.return_value = True
        wb.write_pidfile(self.pid_file, {
            "backend_pid": 1111,
            "flutter_pid": 2222,
            "api_url": "http://localhost:8080",
            "web_url": "http://localhost:9090",
        })

        stdout = io.StringIO()
        with patch("sys.stdout", stdout):
            code = wb.run_up(pid_file=self.pid_file, as_json=True)

        self.assertEqual(code, 0)
        data = json.loads(stdout.getvalue())
        self.assertEqual(data["status"], "ALREADY_RUNNING")
        self.assertEqual(data["backend_pid"], 1111)

    @patch("pm_workbench.check_url_health")
    @patch("pm_workbench.subprocess.Popen")
    @patch("shutil.which")
    def test_up_launches_processes_and_writes_pidfile(
        self,
        mock_which: MagicMock,
        mock_popen: MagicMock,
        mock_health: MagicMock,
    ) -> None:
        mock_which.return_value = "/mock/cargo"
        mock_health.return_value = True

        mock_backend = MagicMock()
        mock_backend.pid = 4321
        mock_backend.poll.return_value = None

        mock_popen.return_value = mock_backend

        stdout = io.StringIO()
        with patch("sys.stdout", stdout):
            code = wb.run_up(
                api_port=8080,
                web_port=9090,
                skip_db=True,
                skip_flutter=True,
                pid_file=self.pid_file,
                as_json=True,
            )

        self.assertEqual(code, 0)
        data = json.loads(stdout.getvalue())
        self.assertEqual(data["status"], "ONLINE")
        self.assertEqual(data["backend_pid"], 4321)
        self.assertTrue(self.pid_file.is_file())

        saved = wb.read_pidfile(self.pid_file)
        self.assertIsNotNone(saved)
        self.assertEqual(saved["backend_pid"], 4321)

    @patch("pm_workbench.terminate_process")
    def test_down_terminates_processes_and_cleans_pidfile(
        self,
        mock_term: MagicMock,
    ) -> None:
        mock_term.return_value = True
        wb.write_pidfile(self.pid_file, {
            "backend_pid": 5555,
            "flutter_pid": 6666,
        })

        stdout = io.StringIO()
        with patch("sys.stdout", stdout):
            code = wb.run_down(pid_file=self.pid_file, as_json=True)

        self.assertEqual(code, 0)
        data = json.loads(stdout.getvalue())
        self.assertEqual(data["status"], "STOPPED")
        self.assertEqual(data["backend_pid"], 5555)
        self.assertFalse(self.pid_file.exists())
        mock_term.assert_any_call(5555)
        mock_term.assert_any_call(6666)

    def test_down_when_not_running(self) -> None:
        stdout = io.StringIO()
        with patch("sys.stdout", stdout):
            code = wb.run_down(pid_file=self.pid_file, as_json=True)
        self.assertEqual(code, 0)
        data = json.loads(stdout.getvalue())
        self.assertEqual(data["status"], "NOT_RUNNING")


if __name__ == "__main__":
    unittest.main()
