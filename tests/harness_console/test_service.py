"""Service-layer integration tests against synthetic SQLite fixture state."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import subprocess
import unittest

from scripts.engineering_harness import leases
from scripts.harness_console.store import ConsoleError
from tests.harness_console.fixtures import SyntheticHarnessEnv


class ConsoleServiceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.env = SyntheticHarnessEnv()
        self.service = self.env.make_service()

    def tearDown(self) -> None:
        self.service.close()
        self.env.cleanup()

    def test_provider_health_and_budget_override(self) -> None:
        health = self.service.provider_health()
        self.assertEqual(health["deepseek_overflow"]["spent_usd"], "12.000000")
        self.assertEqual(health["deepseek_overflow"]["budget_usd"], "25.00")
        self.assertEqual(health["deepseek_overflow"]["status"], "HEALTHY")

        # Lowering cap below $12.00 marks copilot EXHAUSTED without floating point math.
        self.service.set_budget(provider="copilot-deepseek", usd="10.00")
        tight = self.service.provider_health()
        self.assertEqual(tight["deepseek_overflow"]["budget_usd"], "10.00")
        self.assertEqual(tight["deepseek_overflow"]["status"], "EXHAUSTED")
        self.assertTrue(tight["deepseek_overflow"]["override_active"])

        # Raising cap restores HEALTHY.
        self.service.set_budget(provider="copilot-deepseek", usd="50.00")
        relaxed = self.service.provider_health()
        self.assertEqual(relaxed["deepseek_overflow"]["status"], "HEALTHY")
        self.assertGreaterEqual(len(relaxed["t3_instances"]), 1)

    def test_active_board_correlates_reservations_leases_and_handovers(self) -> None:
        board = self.service.active_board(issue=550)
        self.assertEqual(len(board["items"]), 1)
        item = board["items"][0]
        self.assertEqual(item["issue"], 550)
        self.assertEqual(item["agent_name"], "Alparslan")
        self.assertEqual(item["handover_count"], 1)
        self.assertEqual(item["context_pct"], "68")

        self.assertEqual(len(board["runs"]), 1)
        run = board["runs"][0]
        self.assertEqual(run["run_id"], self.env.run_id)
        self.assertEqual(run["reserved_tokens"], 4000)
        self.assertEqual(run["correlated_tokens"], 1500)
        self.assertEqual(run["active_attempt"]["transport"], "t3")

    def test_kill_cancels_t3_run_and_snapshots_dirty_worktree(self) -> None:
        # Make the repo worktree dirty before kill.
        (self.env.repo_root / "dirty.txt").write_text("uncommitted change\n", encoding="utf-8")
        res = self.service.kill(issue=550, run_id=self.env.run_id)
        self.assertTrue(res["ok"])
        self.assertEqual(res["actions"]["run_cancel"]["status"], "CANCELLED")
        self.assertEqual(len(res["actions"]["t3_task_cancel_required"]), 1)
        self.assertEqual(len(res["actions"]["wip_captures"]), 1)
        self.assertTrue(res["actions"]["wip_captures"][0]["wip_committed"])
        self.assertTrue(self.env.repo_root.is_dir())

    def test_takeover_pin_steer_gate_and_mark_status(self) -> None:
        tk = self.service.takeover(issue=550)
        self.assertEqual(tk["branch"], "feature/issue-550")
        self.assertEqual(tk["worktree"], str(self.env.repo_root))
        self.assertIsNotNone(self.service.store.is_paused(issue=550))

        self.service.resume(issue=550)
        self.service.steer(issue=550, note="Focus on unit tests")
        self.service.handover(issue=550, to="codex")
        self.assertEqual(self.service.store.get_pin(issue=550)["provider"], "codex")

        self.service.set_gate(tier="critical", require_approval=True)
        self.assertTrue(self.service.store.gate_requires_approval("critical"))
        self.service.approve(issue=550)
        self.assertTrue(self.service.store.is_approved(issue=550))

        ms = self.service.mark_status(provider="claude", status="THROTTLED")
        self.assertEqual(ms["status"], "THROTTLED")
        self.assertEqual(self.service.provider_health()["providers"]["claude"]["status"], "THROTTLED")

    def test_privacy_redacts_secrets_and_never_reads_track_b_transcripts(self) -> None:
        canary_transcript_msg = "CANARY_TRANSCRIPT_SECRET_NEVER_EXPOSE"
        fake_transcript = self.env.root / ".claude" / "projects" / "p" / "s.jsonl"
        fake_transcript.parent.mkdir(parents=True, exist_ok=True)
        fake_transcript.write_text(json.dumps({"message": canary_transcript_msg}) + "\n", encoding="utf-8")

        tail = self.service.tail(issue=550, run_id=self.env.run_id)
        joined = json.dumps(tail)
        self.assertNotIn("SECRET_SHOULD_BE_REDACTED", joined)
        self.assertNotIn(canary_transcript_msg, joined)
        self.assertIn("[REDACTED]", joined)

        tl = self.service.timeline(issue=550, pr=560, run_id=self.env.run_id)
        self.assertEqual(tl["burn_summary"]["total_tokens"], 13500)
        self.assertEqual(tl["burn_summary"]["estimated_cost_usd"], "12.008100")
        self.assertNotIn(canary_transcript_msg, json.dumps(tl))

    def test_invalid_inputs_raise_console_error(self) -> None:
        with self.assertRaises(ConsoleError):
            self.service.kill()
        with self.assertRaises(ConsoleError):
            self.service.timeline()
        with self.assertRaises(ConsoleError):
            self.service.pause(all_scopes=True, issue=550)

    def test_kill_does_not_signal_expired_or_stale_lease_unrelated_pid(self) -> None:
        unrelated = subprocess.Popen(["sleep", "30"], cwd="/tmp")
        try:
            ticks = leases.process_start_ticks(unrelated.pid)
            self.assertIsNotNone(ticks)
            old_ts = leases.isoformat(datetime.now(timezone.utc) - timedelta(hours=2))
            store = leases.LeaseStore(self.env.sessions_dir)
            # Overwrite ses_550 with an expired lease pointing at unrelated PID.
            store.write(
                leases.Lease(
                    harness="claude_code",
                    session="ses_550",
                    model="claude-sonnet-5-5",
                    issue=550,
                    worktree=str(self.env.repo_root),
                    branch="feature/issue-550",
                    transport="cli",
                    updated_at=old_ts,
                    ttl_seconds=60,
                    pid=unrelated.pid,
                    pid_start_ticks=ticks,
                )
            )
            (self.env.repo_root / "dirty_expired.txt").write_text("keep me\n", encoding="utf-8")

            res = self.service.kill(issue=550)
            self.assertIsNone(unrelated.poll(), "Unrelated process on expired lease must not be signalled")
            self.assertEqual(res["actions"]["process_kills"][0]["not_signalled"], "lease_expired")
            self.assertEqual(len(res["actions"]["wip_captures"]), 1)
            self.assertTrue(res["actions"]["wip_captures"][0]["wip_committed"])

            # Also verify stale state (1.5x TTL) is not signalled.
            stale_ts = leases.isoformat(datetime.now(timezone.utc) - timedelta(seconds=90))
            store.write(
                leases.Lease(
                    harness="claude_code",
                    session="ses_550",
                    model="claude-sonnet-5-5",
                    issue=550,
                    worktree=str(self.env.repo_root),
                    branch="feature/issue-550",
                    transport="cli",
                    updated_at=stale_ts,
                    ttl_seconds=60,
                    pid=unrelated.pid,
                    pid_start_ticks=ticks,
                )
            )
            res_stale = self.service.kill(issue=550)
            self.assertIsNone(unrelated.poll(), "Unrelated process on stale lease must not be signalled")
            self.assertEqual(res_stale["actions"]["process_kills"][0]["not_signalled"], "lease_expired")
        finally:
            unrelated.kill()
            unrelated.wait(timeout=5)

    def test_kill_verifies_pid_identity_and_worktree_cwd(self) -> None:
        outside = subprocess.Popen(["sleep", "30"], cwd="/tmp")
        try:
            real_ticks = leases.process_start_ticks(outside.pid)
            self.assertIsNotNone(real_ticks)
            store = leases.LeaseStore(self.env.sessions_dir)

            # 1. Mismatched pid_start_ticks on alive lease -> refused.
            store.heartbeat(
                leases.Lease(
                    harness="claude_code",
                    session="ses_550",
                    model="claude-sonnet-5-5",
                    issue=550,
                    worktree=str(self.env.repo_root),
                    pid=outside.pid,
                    pid_start_ticks=real_ticks + 999,
                )
            )
            res = self.service.kill(issue=550)
            self.assertIsNone(outside.poll())
            self.assertEqual(res["actions"]["process_kills"][0]["not_signalled"], "pid_mismatch")

            # 2. Matching ticks, but live cwd outside worktree -> refused.
            store.heartbeat(
                leases.Lease(
                    harness="claude_code",
                    session="ses_550",
                    model="claude-sonnet-5-5",
                    issue=550,
                    worktree=str(self.env.repo_root),
                    pid=outside.pid,
                    pid_start_ticks=real_ticks,
                )
            )
            res_cwd = self.service.kill(issue=550)
            self.assertIsNone(outside.poll())
            self.assertEqual(res_cwd["actions"]["process_kills"][0]["not_signalled"], "cwd_outside_worktree")
        finally:
            outside.kill()
            outside.wait(timeout=5)

    def test_kill_signals_verified_worker_waits_for_exit_then_captures_wip(self) -> None:
        worker = subprocess.Popen(["sleep", "30"], cwd=str(self.env.repo_root))
        try:
            store = leases.LeaseStore(self.env.sessions_dir)
            # heartbeat() auto-records pid_start_ticks when pid is provided.
            lease_path = store.heartbeat(
                leases.Lease(
                    harness="claude_code",
                    session="ses_550",
                    model="claude-sonnet-5-5",
                    issue=550,
                    worktree=str(self.env.repo_root),
                    pid=worker.pid,
                )
            )
            recorded = store.read(lease_path)
            self.assertIsNotNone(recorded.pid_start_ticks)
            (self.env.repo_root / "worker_edit.txt").write_text("wip\n", encoding="utf-8")

            res = self.service.kill(issue=550, wait_seconds=3.0)
            kill_info = res["actions"]["process_kills"][0]
            self.assertTrue(kill_info["attempted"])
            self.assertTrue(kill_info["exited"])
            self.assertIsNotNone(worker.poll())
            self.assertEqual(len(res["actions"]["wip_captures"]), 1)
            self.assertTrue(res["actions"]["wip_captures"][0]["wip_committed"])
        finally:
            if worker.poll() is None:
                worker.kill()
            worker.wait(timeout=5)

    def test_kill_defers_wip_capture_when_process_ignores_sigterm(self) -> None:
        stubborn = subprocess.Popen(
            [
                "python3",
                "-c",
                "import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print('ready', flush=True); time.sleep(30)",
            ],
            cwd=str(self.env.repo_root),
            stdout=subprocess.PIPE,
            text=True,
        )
        try:
            assert stubborn.stdout is not None
            self.assertEqual(stubborn.stdout.readline().strip(), "ready")
            store = leases.LeaseStore(self.env.sessions_dir)
            store.heartbeat(
                leases.Lease(
                    harness="claude_code",
                    session="ses_550",
                    model="claude-sonnet-5-5",
                    issue=550,
                    worktree=str(self.env.repo_root),
                    pid=stubborn.pid,
                )
            )
            (self.env.repo_root / "stubborn_edit.txt").write_text("still writing\n", encoding="utf-8")

            res = self.service.kill(issue=550, wait_seconds=0.2)
            kill_info = res["actions"]["process_kills"][0]
            self.assertTrue(kill_info["attempted"])
            self.assertFalse(kill_info["exited"])
            self.assertEqual(res["actions"]["wip_captures"][0]["capture_deferred"], True)
            self.assertEqual(res["actions"]["wip_captures"][0]["reason"], "process_still_running")
        finally:
            stubborn.kill()
            stubborn.wait(timeout=5)
            if stubborn.stdout is not None:
                stubborn.stdout.close()

    def test_failed_kill_records_attempted_command_and_failed_ack(self) -> None:
        with self.assertRaises(Exception):
            self.service.kill(run_id="missing-run-id")
        latest = self.service.store.list_commands(limit=1)[0]
        self.assertEqual(latest["command"], "kill")
        self.assertEqual(latest["ack"]["status"], "failed")
        self.assertTrue(self.service.store.audit_chain())


if __name__ == "__main__":
    unittest.main()
