"""Integration tests verifying Phase 4 Coordinator honors Phase 5 console controls."""
from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import io
import json
from pathlib import Path
import unittest
from unittest import mock

from scripts import harness_coordinator as coord_cli
from tests.harness_console.fixtures import SyntheticHarnessEnv


def call_coordinator(argv: list[str]) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        code = coord_cli.main(argv)
    return code, out.getvalue(), err.getvalue()


class CoordinatorConsoleIntegrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.env = SyntheticHarnessEnv()
        self.service = self.env.make_service()

    def tearDown(self) -> None:
        self.service.close()
        self.env.cleanup()

    def _serve_once(self, *, dry_run: bool = False) -> tuple[int, dict]:
        argv = [
            "serve",
            "--once",
            "--offline",
            "--no-recover",
            "--no-transfer",
            "--state-root",
            str(self.env.local_root),
            "--repo",
            str(self.env.repo_root),
            "--json",
        ]
        if dry_run:
            argv.append("--dry-run")
        code, out, err = call_coordinator(argv)
        return code, json.loads(out)

    def test_pause_and_approval_gate_block_dispatch_until_cleared(self) -> None:
        # 1. Pause issue #550: coordinator must not dispatch ho-550-001.
        self.service.pause(issue=550, reason="hold")
        code, payload = self._serve_once()
        self.assertEqual(code, 0)
        self.assertEqual(payload["handled"][0]["status"], "paused")
        self.assertFalse((self.env.local_root / "coordinator" / "dispatched" / "ho-550-001.json").exists())

        # 2. Resume, but gate medium tier: coordinator holds in awaiting_approval.
        self.service.resume(issue=550)
        self.service.set_gate(tier="medium", require_approval=True)
        code, payload = self._serve_once()
        self.assertEqual(code, 0)
        self.assertEqual(payload["handled"][0]["status"], "awaiting_approval")

        # 3. Approve, steer, and pin to gemini (via pickup transport or cli mock):
        #    Note: simulate CLI dispatch with a mock subprocess runner so no real CLI runs.
        self.service.approve(issue=550)
        self.service.steer(issue=550, note="Verify Decimal totals before PR ready")
        self.service.pin(issue=550, to="codex")

        import subprocess
        real_run = subprocess.run
        fake_proc = mock.Mock(returncode=0, stdout="done", stderr="")

        def git_or_cli(argv, **kwargs):
            if argv and argv[0] == "git":
                return real_run(argv, **kwargs)
            return fake_proc

        with mock.patch("scripts.engineering_harness.coordinator.subprocess.run", side_effect=git_or_cli):
            code, payload = self._serve_once()

        self.assertEqual(code, 0)
        handled = payload["handled"][0]
        self.assertEqual(handled["status"], "dispatched")
        self.assertEqual(handled["decision"]["target"]["canonical_provider"], "codex")
        if handled["dispatch"]["transport"] == "t3":
            payload_file = Path(handled["dispatch"]["payload_path"])
            dispatched_prompt = json.loads(payload_file.read_text(encoding="utf-8"))["delegate_task"]["prompt"]
        else:
            dispatched_prompt = handled["dispatch"]["command"][-1]
        self.assertIn("Verify Decimal totals before PR ready", dispatched_prompt)
        self.assertEqual(self.service.store.pending_steering(issue=550), [])

        # All prior console commands are acknowledged by the coordinator pass.
        unacked = self.service.store.list_commands(limit=50, unacked_only=True)
        self.assertEqual(unacked, [])


if __name__ == "__main__":
    unittest.main()
