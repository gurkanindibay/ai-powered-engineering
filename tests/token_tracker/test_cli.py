"""Unit tests for token_tracker.py CLI commands."""
from __future__ import annotations

import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from scripts.token_tracker import main


class TestTokenTrackerCLI(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.db_path = self.root / "test_ledger.sqlite3"

    def tearDown(self):
        self.temp_dir.cleanup()

    def run_cli(self, args: list[str]) -> tuple[int, str]:
        cmd = ["--db", str(self.db_path)] + args
        captured = io.StringIO()
        with patch("sys.stdout", captured):
            code = main(cmd)
        return code, captured.getvalue()

    def test_record_and_health(self):
        # 1. Record usage
        code, out = self.run_cli([
            "record",
            "--provider", "claude",
            "--model", "claude-sonnet-5-5",
            "--input", "5000",
            "--output", "1000",
            "--json"
        ])
        self.assertEqual(code, 0)
        data = json.loads(out)
        self.assertEqual(data["status"], "recorded")
        self.assertTrue(data["usage_event_inserted"])

        # 2. Health check -> HEALTHY
        code, out = self.run_cli(["health", "--json"])
        self.assertEqual(code, 0)
        health = json.loads(out)
        self.assertEqual(health["status"], "HEALTHY")
        self.assertIn("claude", health["providers"])
        self.assertEqual(health["providers"]["claude"]["status"], "HEALTHY")
        self.assertEqual(health["providers"]["claude"]["burn"]["total_tokens"], 6000)

    def test_budget_check_exit_codes(self):
        # Budget check on fresh DB -> 0 (HEALTHY)
        code, out = self.run_cli([
            "budget-check",
            "--provider", "claude",
            "--model", "claude-sonnet-5-5",
            "--json"
        ])
        self.assertEqual(code, 0)
        res = json.loads(out)
        self.assertEqual(res["status"], "HEALTHY")

        # Record 429 rate limit
        self.run_cli([
            "record",
            "--provider", "claude",
            "--model", "claude-sonnet-5-5",
            "--event", "429",
            "--json"
        ])

        # Budget check now -> 20 (EXHAUSTED)
        code, out = self.run_cli([
            "budget-check",
            "--provider", "claude",
            "--model", "claude-sonnet-5-5",
            "--json"
        ])
        self.assertEqual(code, 20)
        res = json.loads(out)
        self.assertEqual(res["status"], "EXHAUSTED")

        # Unknown provider -> exits 20
        code, out = self.run_cli([
            "budget-check",
            "--provider", "nonexistent_provider",
            "--model", "any-model",
            "--json"
        ])
        self.assertEqual(code, 20)
        res = json.loads(out)
        self.assertEqual(res["reason"], "Unknown provider")

        # Reset status back to HEALTHY via record --status HEALTHY
        code, out = self.run_cli([
            "record",
            "--provider", "claude",
            "--model", "claude-sonnet-5-5",
            "--status", "HEALTHY",
            "--json"
        ])
        self.assertEqual(code, 0)

        # Budget check returns to 0 (HEALTHY)
        code, out = self.run_cli([
            "budget-check",
            "--provider", "claude",
            "--model", "claude-sonnet-5-5",
            "--json"
        ])
        self.assertEqual(code, 0)
        res = json.loads(out)
        self.assertEqual(res["status"], "HEALTHY")

    def test_report_dimensions_and_json(self):
        # Record events across providers and models
        self.run_cli([
            "record",
            "--provider", "claude",
            "--model", "claude-sonnet-5-5",
            "--input", "10000",
            "--output", "2000",
            "--cache-read", "3000",
            "--issue", "546",
            "--pr", "550",
            "--agent-name", "Kuşçubaşı Eşref",
        ])
        self.run_cli([
            "record",
            "--provider", "copilot",
            "--model", "deepseek-v3",
            "--input", "8000",
            "--output", "1500",
            "--billing-mode", "api",
        ])

        # Report by provider
        code, out = self.run_cli(["report", "--by", "provider", "--json"])
        self.assertEqual(code, 0)
        rep = json.loads(out)
        self.assertEqual(rep["by"], "provider")
        self.assertEqual(len(rep["groups"]), 2)
        self.assertEqual(rep["total"]["events"], 2)
        # Cache hit rate on claude: 3000 / (10000 + 3000) = 23.08%
        claude_group = next(g for g in rep["groups"] if g["key"] == "claude")
        self.assertEqual(claude_group["cache_hit_rate_pct"], "23.08")

        # Report by issue
        code, out = self.run_cli(["report", "--by", "issue", "--json"])
        self.assertEqual(code, 0)
        rep_issue = json.loads(out)
        self.assertTrue(any(g["key"] == "546" for g in rep_issue["groups"]))

        # Report by agent
        code, out = self.run_cli(["report", "--by", "agent", "--json"])
        self.assertEqual(code, 0)
        rep_agent = json.loads(out)
        self.assertTrue(any("Kuşçubaşı Eşref" in g["key"] for g in rep_agent["groups"]))


if __name__ == "__main__":
    unittest.main()
