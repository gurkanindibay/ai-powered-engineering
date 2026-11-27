"""CLI integration tests for scripts/harness_console.py."""
from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import io
import json
import unittest

from scripts import harness_console as cli
from tests.harness_console.fixtures import SyntheticHarnessEnv


def run_cli(argv: list[str]) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        try:
            code = cli.main(argv)
        except SystemExit as exc:
            code = int(exc.code or 0)
    return code, out.getvalue(), err.getvalue()


class ConsoleCliTests(unittest.TestCase):
    def setUp(self) -> None:
        self.env = SyntheticHarnessEnv()
        self.common = [
            "--state-root",
            str(self.env.local_root),
            "--repo",
            str(self.env.repo_root),
            "--console-db",
            str(self.env.console_db),
            "--ledger",
            str(self.env.ledger_db),
            "--runs-db",
            str(self.env.runs_db),
            "--offline",
            "--json",
        ]

    def tearDown(self) -> None:
        self.env.cleanup()

    def test_help_and_all_intervention_commands(self) -> None:
        code, out, _ = run_cli(["--help"])
        self.assertEqual(code, 0)
        self.assertIn("harness_console.py", out)

        code, out, _ = run_cli(["status", *self.common])
        self.assertEqual(code, 0)
        status = json.loads(out)
        self.assertEqual(status["board"]["items"][0]["issue"], 550)

        code, out, _ = run_cli(["tail", "550", *self.common])
        self.assertEqual(code, 0)
        self.assertNotIn("SECRET_SHOULD_BE_REDACTED", out)

        code, out, _ = run_cli(["timeline", "--issue", "550", "--run", self.env.run_id, *self.common])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out)["burn_summary"]["total_tokens"], 13500)

        for argv in (
            ["dispatch", "--task", "Fix ledger check", "--financial", *self.common],
            ["pause", "--issue", "550", *self.common],
            ["steer", "--issue", "550", "--note", "Check Decimal rounding", *self.common],
            ["handover", "--issue", "550", "--to", "codex", *self.common],
            ["pin", "--issue", "550", "--to", "gemini", *self.common],
            ["unpin", "--issue", "550", *self.common],
            ["takeover", "--issue", "550", *self.common],
            ["set-budget", "--provider", "copilot-deepseek", "--usd", "40.00", *self.common],
            ["mark-status", "--provider", "claude", "--status", "THROTTLED", *self.common],
            ["set-gate", "--tier", "critical", "--require-approval", *self.common],
            ["approve", "--issue", "550", *self.common],
            ["resume", "--issue", "550", *self.common],
            ["kill", "--run", self.env.run_id, *self.common],
            ["pickups", *self.common],
            ["commands", *self.common],
        ):
            code, out, err = run_cli(argv)
            self.assertEqual(code, 0, f"{argv} failed: {err} / {out}")
            json.loads(out)

    def test_invalid_arguments_return_exit_2(self) -> None:
        code, out, _ = run_cli(["set-budget", "--provider", "copilot-deepseek", "--usd", "not-a-number", *self.common])
        self.assertEqual(code, 2)
        self.assertFalse(json.loads(out)["ok"])


if __name__ == "__main__":
    unittest.main()
