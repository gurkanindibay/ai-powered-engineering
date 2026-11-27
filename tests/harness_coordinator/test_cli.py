"""CLI contract for scripts/harness_coordinator.py (0-token daemon, Phase 4)."""
from contextlib import redirect_stderr, redirect_stdout
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

from scripts import harness_coordinator as cli


def envelope(issue: int = 549) -> dict:
    from scripts import handover

    data = {
        "schema_version": 1, "handover_id": f"ho-{issue}-001", "created_at": "2026-11-27T07:15:00Z",
        "reason": "context_ceiling",
        "from": {"provider": "claudeAgent", "harness": "t3", "model": "claude-sonnet-5-5",
                 "agent_name": "Alparslan", "session_id": "ses_outgoing"},
        "target_constraints": {"risk_tier": "medium", "role": "developer",
                               "excluded_providers": []},
        "git_state": {"issue": issue, "pr": None, "branch": "feature/issue-549",
                      "base_sha": "a" * 40, "head_sha": "b" * 40, "wip_committed": True,
                      "worktree_path": "/tmp/worktree-549"},
        "progress": {"completed": ["x"], "remaining": ["y"],
                     "last_verification": {"command": "true", "status": "unverified", "summary": ""}},
        "decisions": [], "key_pointers": [],
    }
    data["checksum_sha256"] = handover.checksum(data)
    return data


def call(arguments: list[str]) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        code = cli.main(arguments)
    return code, out.getvalue(), err.getvalue()


def git_repo(path: Path, branch: str) -> Path:
    path.mkdir(parents=True)
    for argv in (["init", "--quiet", "-b", "main"],):
        subprocess.run(["git", "-C", str(path), *argv], check=True)
    subprocess.run(["git", "-C", str(path), "-c", "user.name=T", "-c", "user.email=t@example.com",
                    "commit", "--quiet", "--allow-empty", "-m", "base"], check=True)
    subprocess.run(["git", "-C", str(path), "checkout", "--quiet", "-b", branch], check=True)
    return path


class CliTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state = Path(self.tmp.name) / "local"
        self.envelope_path = Path(self.tmp.name) / "549-001.json"
        self.envelope_path.write_text(json.dumps(envelope()))

    def tearDown(self):
        self.tmp.cleanup()

    def test_simulate_runs_the_shipped_scenarios(self):
        code, out, _ = call(["simulate", "--json"])
        self.assertEqual(code, 0)
        payload = json.loads(out)
        self.assertEqual(payload["failed"], 0)
        self.assertGreaterEqual(payload["passed"], 8)

    def test_heartbeat_then_status_reports_the_lease(self):
        code, _, _ = call(["heartbeat", "--harness", "t3", "--session", "ses_abc",
                           "--model", "deepseek-flash", "--issue", "549", "--pr", "554",
                           "--state-root", str(self.state), "--context-pct", "82", "--json"])
        self.assertEqual(code, 0)
        code, out, _ = call(["status", "--state-root", str(self.state), "--json"])
        self.assertEqual(code, 0)
        payload = json.loads(out)
        self.assertEqual(payload["leases"]["counts"]["alive"], 1)
        self.assertEqual(payload["leases"]["leases"]["alive"][0]["context_pct"], "82")

    def test_handover_dry_run_plans_without_writing(self):
        code, out, _ = call(["handover", "--issue", "549", "--reason", "context_ceiling",
                             "--from-harness", "t3", "--from-session", "ses_outgoing",
                             "--from-provider", "claudeAgent", "--envelope", str(self.envelope_path),
                             "--transport", "cli", "--offline", "--dry-run",
                             "--state-root", str(self.state), "--json"])
        self.assertEqual(code, 0)
        payload = json.loads(out)
        self.assertEqual(payload["decision"]["action"], "dispatch")
        self.assertEqual(payload["dispatch"]["status"], "dry_run")
        self.assertFalse((self.state / "coordinator").exists())

    def test_handover_writes_a_pickup_brief_when_transfer_is_skipped(self):
        code, out, _ = call(["handover", "--issue", "549", "--reason", "provider_quota_exhausted",
                             "--from-harness", "t3", "--from-session", "ses_outgoing",
                             "--envelope", str(self.envelope_path), "--transport", "pickup",
                             "--offline", "--no-transfer", "--state-root", str(self.state), "--json"])
        self.assertEqual(code, 0)
        payload = json.loads(out)
        pickup = Path(payload["dispatch"]["pickup_path"])
        self.assertTrue(pickup.is_file())
        self.assertIn("Handover pickup", pickup.read_text())
        self.assertTrue((self.state / "coordinator" / "dispatched" / "ho-549-001.json").is_file())

    def test_handover_transfers_the_claim_with_the_selected_model(self):
        recorded = {}

        def fake_transfer(args, repo):
            recorded["args"] = args
            return {"ok": True, "message": "transferred"}

        with mock.patch.object(cli, "run_issue_claim", fake_transfer):
            code, _, _ = call(["handover", "--issue", "549", "--reason", "context_ceiling",
                               "--from-harness", "t3", "--from-session", "ses_outgoing",
                               "--envelope", str(self.envelope_path), "--transport", "pickup",
                               "--offline", "--state-root", str(self.state), "--json"])
        self.assertEqual(code, 0)
        self.assertEqual(recorded["args"][0], "transfer")
        self.assertIn("--to-harness", recorded["args"])
        self.assertIn("--to-model", recorded["args"])
        self.assertIn("--to-session", recorded["args"])

    def test_cli_dispatch_uses_a_fresh_incoming_worktree(self):
        repo = git_repo(Path(self.tmp.name) / "repo", "feature/issue-549")
        prepared = Path(self.tmp.name) / "incoming"
        with mock.patch.object(cli.coordinator, "prepare_worktree", return_value=prepared) as prepare, \
                mock.patch.object(cli.coordinator, "dispatch",
                                  return_value={"status": "queued"}) as dispatch:
            code, _, _ = call(["handover", "--issue", "549", "--reason", "context_ceiling",
                               "--from-harness", "t3", "--from-session", "ses_outgoing",
                               "--envelope", str(self.envelope_path), "--transport", "cli",
                               "--offline", "--no-transfer", "--repo", str(repo),
                               "--state-root", str(self.state), "--json"])
        self.assertEqual(code, 0)
        prepare.assert_called_once()
        self.assertEqual(prepare.call_args[0][1], "feature/issue-549")
        self.assertEqual(dispatch.call_args[0][2].worktree, prepared)

    def test_cli_preflight_does_not_transfer_when_the_branch_is_missing(self):
        from scripts import handover

        repo = git_repo(Path(self.tmp.name) / "repo", "feature/issue-549")
        data = envelope()
        data["git_state"]["branch"] = "feature/missing"
        data["checksum_sha256"] = handover.checksum(data)
        missing = Path(self.tmp.name) / "missing.json"
        missing.write_text(json.dumps(data))
        transferred = mock.Mock()
        with mock.patch.object(cli, "run_issue_claim", transferred):
            code, _, err = call(["handover", "--issue", "549", "--reason", "context_ceiling",
                                 "--from-harness", "t3", "--from-session", "ses_outgoing",
                                 "--envelope", str(missing), "--transport", "cli",
                                 "--offline", "--repo", str(repo),
                                 "--state-root", str(self.state), "--json"])
        self.assertEqual(code, 2)
        self.assertIn("does not exist", err)
        transferred.assert_not_called()

    def test_serve_escalates_a_pending_label_without_a_local_envelope(self):
        with mock.patch.object(cli, "pending_label_issues", return_value=[999]):
            code, out, _ = call(["serve", "--once", "--no-transfer", "--state-root", str(self.state),
                                 "--json"])
        self.assertEqual(code, 1)
        payload = json.loads(out)
        self.assertEqual(payload["handled"][0]["status"], "invalid_checkpoint")
        self.assertTrue((self.state / "coordinator" / "escalations" / "issue-999.json").is_file())

    def test_serve_survives_a_failed_transfer_and_reuses_its_worktree(self):
        from scripts import handover

        repo = git_repo(Path(self.tmp.name) / "repo", "feature/issue-549")
        data = envelope()
        data["git_state"]["branch"] = "feature/issue-549"
        data["checksum_sha256"] = handover.checksum(data)
        handovers = self.state / "handovers"
        handovers.mkdir(parents=True)
        (handovers / "549-001.json").write_text(json.dumps(data))
        catalog = Path(self.tmp.name) / "catalog.json"
        catalog.write_text(json.dumps({"providers": []}))
        calls = {"transfer": 0}

        def transfer(args, path):
            calls["transfer"] += 1
            return {"ok": calls["transfer"] > 1, "message": "simulated"}

        dispatched = []

        def fake_dispatch(decision, env, options):
            dispatched.append(options.worktree)
            return {"status": "queued", "payload_path": "unused"}

        arguments = ["serve", "--once", "--offline", "--no-recover", "--t3-catalog", str(catalog),
                     "--repo", str(repo), "--state-root", str(self.state), "--json"]
        with mock.patch.object(cli, "run_issue_claim", transfer), \
                mock.patch.object(cli.coordinator, "dispatch", fake_dispatch), \
                mock.patch.object(cli.coordinator, "prepare_worktree",
                                  wraps=cli.coordinator.prepare_worktree) as prepare:
            first, _, _ = call(arguments)
            self.assertEqual(first, 1)
            self.assertFalse((self.state / "coordinator" / "worktrees" / "ho-549-001").exists())
            second, out, _ = call(arguments)
            self.assertEqual(second, 0)
            third, _, _ = call(arguments)
            self.assertEqual(third, 0)
        self.assertEqual(prepare.call_count, 1)
        self.assertEqual(len(dispatched), 2)
        self.assertEqual(dispatched[0], self.state / "coordinator" / "worktrees" / "ho-549-001")

    def test_serve_once_dispatches_a_pending_checkpoint_and_is_idempotent(self):
        handovers = self.state / "handovers"
        handovers.mkdir(parents=True)
        (handovers / "549-001.json").write_text(json.dumps(envelope()))
        arguments = ["serve", "--once", "--offline", "--no-transfer", "--state-root", str(self.state),
                     "--json"]
        code, out, _ = call(arguments)
        self.assertEqual(code, 0)
        first = json.loads(out)
        self.assertEqual(len(first["handled"]), 1)
        self.assertEqual(first["handled"][0]["status"], "dispatched")
        payload = self.state / "dispatch" / "t3" / "ho-549-001.json"
        self.assertTrue(payload.is_file())
        code, out, _ = call(arguments)
        self.assertEqual(code, 0)
        payload = json.loads(out)
        self.assertEqual(payload["handled"], [])
        with mock.patch.object(cli, "pending_label_issues", return_value=[549]):
            code, out, _ = call(["serve", "--once", "--no-transfer",
                                 "--state-root", str(self.state), "--json"])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out)["handled"], [])  # label stays pending until `accept`

    def test_handover_parks_and_exits_one_at_the_handover_cap(self):
        code, out, _ = call(["handover", "--issue", "549", "--reason", "provider_quota_exhausted",
                             "--from-harness", "t3", "--from-session", "ses_outgoing",
                             "--envelope", str(self.envelope_path), "--offline",
                             "--handover-count", "3", "--dry-run",
                             "--state-root", str(self.state), "--json"])
        self.assertEqual(code, 1)
        payload = json.loads(out)
        self.assertEqual(payload["decision"]["action"], "park")
        self.assertEqual(payload["decision"]["reason"], "handover_cap")
        self.assertFalse((self.state / "coordinator").exists())

    def test_invalid_envelope_is_a_usage_error(self):
        broken = Path(self.tmp.name) / "broken.json"
        broken.write_text('{"schema_version": 1}')
        code, _, err = call(["handover", "--issue", "549", "--envelope", str(broken),
                             "--offline", "--state-root", str(self.state), "--json"])
        self.assertEqual(code, 2)
        self.assertIn("invalid handover envelope", err)

    def test_t3_candidate_export_requires_task_cancel_confirmation(self):
        candidate = Path(self.tmp.name) / "candidate"
        candidate.mkdir()
        code, _, err = call(["handover", "--issue", "549", "--candidate", str(candidate),
                             "--branch", "feature/issue-549", "--offline",
                             "--state-root", str(self.state), "--json"])
        self.assertEqual(code, 2)
        self.assertIn("--child-cancelled", err)

    def test_recover_reports_expired_leases_and_exits_one_on_escalation(self):
        code, _, _ = call(["heartbeat", "--harness", "codex", "--session", "dead",
                           "--worktree", str(Path(self.tmp.name) / "gone"),
                           "--state-root", str(self.state), "--ttl", "1", "--json"])
        self.assertEqual(code, 0)
        lease_path = next((self.state / "sessions").glob("*.json"))
        data = json.loads(lease_path.read_text())
        data["updated_at"] = "2026-11-27T00:00:00Z"
        lease_path.write_text(json.dumps(data))
        code, out, _ = call(["recover", "--state-root", str(self.state), "--json"])
        self.assertEqual(code, 1)
        payload = json.loads(out)
        self.assertEqual(payload["counts"]["escalate"], 1)

    def test_provider_failure_marks_health_exhausted(self):
        code, _, _ = call(["provider-failed", "--provider", "codex", "--status", "EXHAUSTED",
                           "--reset-at", "2099-01-01T00:00:00Z", "--state-root", str(self.state),
                           "--json"])
        self.assertEqual(code, 0)
        code, out, _ = call(["status", "--state-root", str(self.state), "--json"])
        self.assertEqual(code, 0)
        providers = json.loads(out)["providers"]["providers"]
        self.assertEqual(providers["codex"]["status"], "EXHAUSTED")


if __name__ == "__main__":
    unittest.main()
