"""Deterministic auto-handover decisions, dispatch and watchdog recovery (Phase 4)."""
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest

from scripts import handover
from scripts.engineering_harness import coordinator, leases


def moment(offset_seconds: float = 0) -> datetime:
    return datetime(2026, 11, 27, 12, 0, tzinfo=timezone.utc) + timedelta(seconds=offset_seconds)


def envelope(issue: int = 549, excluded: list[str] | None = None) -> dict:
    data = {
        "schema_version": 1,
        "handover_id": f"ho-{issue}-001",
        "created_at": "2026-11-27T07:15:00Z",
        "reason": "context_ceiling",
        "from": {"provider": "claudeAgent", "harness": "t3", "model": "claude-sonnet-5-5",
                 "agent_name": "Alparslan", "session_id": "ses_outgoing"},
        "target_constraints": {"risk_tier": "medium", "role": "developer",
                               "excluded_providers": excluded or ["claude"]},
        "git_state": {"issue": issue, "pr": 554, "branch": "feature/issue-549",
                      "base_sha": "a" * 40, "head_sha": "b" * 40, "wip_committed": True,
                      "worktree_path": "/tmp/worktree-549"},
        "progress": {"completed": ["Implemented the coordinator"], "remaining": ["Add transport tests"],
                     "last_verification": {"command": "python3 -m unittest", "status": "unverified",
                                           "summary": ""}},
        "decisions": [], "key_pointers": [],
    }
    data["checksum_sha256"] = handover.checksum(data)
    return data


def signal(**overrides) -> coordinator.Signal:
    data = {"issue": 549, "reason": "provider_quota_exhausted", "role": "developer", "tier": "medium",
            "from_provider": "claudeAgent", "from_harness": "t3", "from_session": "ses_outgoing",
            "excluded_providers": ("claude",), "pr": 554}
    data.update(overrides)
    return coordinator.Signal(**data)


def health(**providers) -> dict:
    values = {name: {"status": "HEALTHY"} for name in ("claude", "codex", "gemini", "copilot")}
    values.update(providers)
    status = "EXHAUSTED" if all(v["status"] == "EXHAUSTED" for v in values.values()) else "HEALTHY"
    return {"status": status, "providers": values}


class DecisionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.registry = coordinator.load_registry()
        cls.targets = coordinator.targets_from_registry(cls.registry)

    def test_healthy_t3_target_is_preferred(self):
        decision = coordinator.decide(signal(), targets=self.targets)
        self.assertEqual(decision.action, "dispatch")
        self.assertEqual(decision.transport, "t3")
        self.assertEqual(coordinator.canonical_provider(decision.target), "codex")

    def test_exhausted_claude_fails_over_to_another_t3_provider(self):
        decision = coordinator.decide(signal(), targets=self.targets,
                                      health=health(claude={"status": "EXHAUSTED",
                                                            "reset_at": "2026-11-28T00:00:00Z"}))
        self.assertEqual(decision.transport, "t3")
        self.assertEqual(decision.target["model"], "gpt-6.2-sol")

    def test_unavailable_t3_catalog_spills_to_a_headless_cli(self):
        decision = coordinator.decide(signal(), targets=self.targets, available_t3=set())
        self.assertIn(decision.transport, ("cli", "copilot_cli"))
        self.assertNotIn(decision.transport, ("t3", "pickup"))

    def test_exhausted_subscriptions_spill_to_deepseek_overflow(self):
        decision = coordinator.decide(
            signal(tier="low"), targets=self.targets, available_t3=set(),
            health=health(claude={"status": "EXHAUSTED"}, codex={"status": "EXHAUSTED"},
                          gemini={"status": "EXHAUSTED"}))
        self.assertEqual(decision.transport, "copilot_cli")
        self.assertEqual(decision.target["model"], "deepseek-chat")

    def test_risk_floor_parks_instead_of_downgrading_to_deepseek(self):
        decision = coordinator.decide(
            signal(role="architect", tier="critical"), targets=self.targets, available_t3=set(),
            health=health(claude={"status": "EXHAUSTED", "reset_at": "2026-11-28T04:00:00Z"},
                          codex={"status": "EXHAUSTED", "reset_at": "2026-11-28T02:00:00Z"},
                          gemini={"status": "EXHAUSTED", "reset_at": "2026-11-28T05:00:00Z"}))
        self.assertEqual(decision.action, "park")
        self.assertEqual(decision.reason, coordinator.NO_HEALTHY_PROVIDER)
        self.assertEqual(decision.resume_after, "2026-11-28T02:00:00Z")
        self.assertEqual(decision.escalation["reason"], coordinator.NO_HEALTHY_PROVIDER)

    def test_no_qualified_provider_is_a_clear_park(self):
        thin = [{"provider": "fixture", "model": "small", "transport": "t3", "priority": 1,
                 "roles": ["developer"], "tiers": ["low"], "options": {},
                 "max_tokens": 1000, "input_per_million": "1", "output_per_million": "1",
                 "price_date": "2026-11-27", "benchmark_id": "fixture"}]
        decision = coordinator.decide(signal(tier="critical"), targets=thin)
        self.assertEqual(decision.action, "park")
        self.assertEqual(decision.reason, coordinator.NO_QUALIFIED_PROVIDER)

    def test_second_handover_dispatches_but_wakes_reviewer(self):
        decision = coordinator.decide(signal(), targets=self.targets, handover_count=1)
        self.assertEqual(decision.action, "dispatch")
        self.assertEqual(decision.handover_count, 2)
        self.assertEqual(decision.escalation["reason"], coordinator.THRASH)

    def test_two_failed_repairs_raise_thrash_even_on_the_first_handover(self):
        decision = coordinator.decide(signal(failed_repairs=2), targets=self.targets)
        self.assertEqual(decision.escalation["reason"], coordinator.THRASH)

    def test_handover_cap_parks_for_a_human(self):
        decision = coordinator.decide(signal(), targets=self.targets,
                                      handover_count=coordinator.max_handovers())
        self.assertEqual(decision.action, "park")
        self.assertEqual(decision.reason, coordinator.HANDOVER_CAP)
        self.assertIsNone(decision.target)

    def test_forced_pickup_selects_a_target_without_spawning(self):
        decision = coordinator.decide(signal(), targets=self.targets, transport="pickup")
        self.assertEqual(decision.transport, "pickup")
        self.assertIsNotNone(decision.target)

    def test_excluded_provider_is_never_chosen(self):
        decision = coordinator.decide(signal(excluded_providers=("claude", "codex")),
                                      targets=self.targets)
        self.assertEqual(decision.action, "dispatch")
        self.assertNotIn(coordinator.canonical_provider(decision.target), ("claude", "codex"))

    def test_invalid_signal_is_rejected_before_any_action(self):
        for bad in ({"issue": 0}, {"reason": "bogus"}, {"role": "wizard"}, {"tier": "ultra"},
                    {"failed_repairs": -1}):
            with self.assertRaises(coordinator.CoordinatorError):
                coordinator.decide(signal(**bad), targets=self.targets)
        with self.assertRaises(coordinator.CoordinatorError):
            coordinator.decide(signal(), targets=self.targets, transport="carrier-pigeon")

    def test_registry_gives_cli_providers_a_canonical_health_twin(self):
        twins = {target["provider"]: target for target in self.targets
                 if target.get("transport") in ("cli", "copilot_cli")}
        self.assertEqual(twins["claude-cli"]["canonical_provider"], "claude")
        self.assertEqual(twins["codex-cli"]["canonical_provider"], "codex")
        self.assertEqual(twins["copilot"]["canonical_provider"], "copilot")

    def test_simulation_cases_all_pass(self):
        cases_path = Path(__file__).resolve().parents[2] / "config" / "engineering-harness" \
            / "coordinator-scenarios.json"
        cases = json.loads(cases_path.read_text())
        result = coordinator.run_simulation(cases, self.registry)
        self.assertEqual(result["failed"], 0, result)


class DispatchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.local = self.root / "local"
        self.worktree = self.root / "worktree"
        self.worktree.mkdir()
        self.registry = coordinator.load_registry()
        self.envelope = envelope()
        self.options = coordinator.DispatchOptions(
            root=self.local, repo=self.root, worktree=self.worktree, branch="feature/issue-549",
            pr=554, envelope_path=self.local / "handovers" / "549-001.json",
            launchers=coordinator.load_launchers())

    def tearDown(self):
        self.tmp.cleanup()

    def decision(self, transport: str, targets: list[dict] | None = None):
        targets = targets or coordinator.targets_from_registry(self.registry)
        return coordinator.decide(signal(), targets=targets, transport=transport)

    def test_t3_payload_requires_task_cancel_and_records_incoming_identity(self):
        decision = self.decision("t3")
        record = coordinator.dispatch(decision, self.envelope, self.options)
        self.assertEqual(record["status"], "queued")
        payload = json.loads(Path(record["payload_path"]).read_text())
        self.assertEqual(payload["kind"], "t3-dispatch")
        self.assertTrue(payload["requires"]["task_cancel_before_dispatch"])
        self.assertEqual(payload["delegate_task"]["provider"], payload["target"]["provider"])
        self.assertEqual(payload["delegate_task"]["mode"], "wait")
        self.assertEqual(payload["incoming"]["harness"], "t3")
        self.assertIn("feature/issue-549", payload["prompt"])
        self.assertTrue((self.local / "coordinator" / "dispatched" / "ho-549-001.json").is_file())

    def test_cli_dry_run_renders_argv_without_writing_or_spawning(self):
        decision = self.decision("cli")
        options = coordinator.DispatchOptions(**{**self.options.__dict__, "dry_run": True,
                                                 "runner": lambda *a, **k: (_ for _ in ()).throw(
                                                     AssertionError("must not spawn"))})
        record = coordinator.dispatch(decision, self.envelope, options)
        self.assertEqual(record["status"], "dry_run")
        self.assertEqual(record["command"][0], "gemini")
        self.assertNotIn("{prompt}", " ".join(record["command"]))
        self.assertFalse((self.local / "coordinator" / "dispatched" / "ho-549-001.json").exists())

    def test_cli_success_writes_a_log_and_skips_capture(self):
        def runner(argv, **kwargs):
            return subprocess.CompletedProcess(argv, 0, "finished", "")

        launchers = {"schema_version": 1, "launchers": {
            "gemini": {"transport": "cli", "argv": ["gemini", "-p", "{prompt}", "--model", "{model}"]},
            "claude": {"transport": "cli", "argv": ["claude", "-p", "{prompt}"]},
            "codex": {"transport": "cli", "argv": ["codex", "exec", "{prompt}"]},
            "copilot": {"transport": "copilot_cli", "argv": ["copilot", "-p", "{prompt}"]},
        }}
        targets = coordinator.targets_from_registry(self.registry, launchers=launchers)
        decision = coordinator.decide(signal(), targets=targets, transport="cli")
        options = coordinator.DispatchOptions(**{**self.options.__dict__, "runner": runner,
                                                 "launchers": launchers})
        record = coordinator.dispatch(decision, self.envelope, options)
        self.assertEqual(record["status"], "completed")
        self.assertEqual(Path(record["log_path"]).read_text(), "finished")

    def test_cli_429_triggers_deterministic_capture(self):
        def runner(argv, **kwargs):
            return subprocess.CompletedProcess(argv, 1, "", "HTTP 429: usage limit reached")

        captured = {}

        def capture_fn(**kwargs):
            captured.update(kwargs)
            return "local/handovers/549-002.json"

        options = coordinator.DispatchOptions(**{**self.options.__dict__, "runner": runner,
                                                 "capture_fn": capture_fn})
        decision = coordinator.decide(signal(), targets=coordinator.targets_from_registry(
            self.registry), transport="cli")
        record = coordinator.dispatch(decision, self.envelope, options)
        self.assertEqual(record["status"], "failed")
        self.assertTrue(record["rate_limited"])
        self.assertEqual(captured["reason"], "provider_quota_exhausted")
        self.assertEqual(record["captured"], "local/handovers/549-002.json")

    def test_pickup_brief_is_ready_to_paste(self):
        decision = self.decision("pickup")
        record = coordinator.dispatch(decision, self.envelope, self.options)
        brief = Path(record["pickup_path"]).read_text()
        self.assertIn("# Handover pickup: issue #549", brief)
        self.assertIn("git worktree add --detach <path> feature/issue-549", brief)
        self.assertIn("issue_claim.py accept 549", brief)
        self.assertEqual(record["status"], "queued")

    def test_prepare_worktree_never_reuses_an_existing_path(self):
        with self.assertRaises(coordinator.CoordinatorError):
            coordinator.prepare_worktree(self.root, "feature/x", self.worktree)

    def test_prepare_worktree_adds_a_fresh_detached_worktree(self):
        calls = []

        def runner(argv, **kwargs):
            calls.append(argv)
            return subprocess.CompletedProcess(argv, 0, "", "")

        path = self.root / "fresh"
        created = coordinator.prepare_worktree(self.root / "repo", "feature/x", path, runner)
        self.assertEqual(created, path)
        self.assertIn("--detach", calls[0])
        self.assertEqual(calls[0][-2:], [str(path), "feature/x"])

    def test_launcher_configuration_is_validated(self):
        bad = {"schema_version": 1, "launchers": {"claude": {"argv": ["claude", "run"]}}}
        path = self.root / "bad-launchers.json"
        path.write_text(json.dumps(bad))
        with self.assertRaises(coordinator.CoordinatorError):
            coordinator.load_launchers(path)
        self.assertIn("claude", coordinator.load_launchers()["launchers"])

    def test_rate_limit_detection(self):
        for text in ("HTTP 429", "rate limit exceeded", "quota exhausted", "Too Many Requests"):
            self.assertTrue(coordinator.detect_rate_limit(text))
        self.assertFalse(coordinator.detect_rate_limit("all tests passed"))


def git_repo(path: Path) -> Path:
    path.mkdir()
    subprocess.run(["git", "init", "--quiet"], cwd=path, check=True)
    subprocess.run(["git", "-c", "user.name=T", "-c", "user.email=t@example.com",
                    "commit", "--quiet", "--allow-empty", "-m", "base"], cwd=path, check=True)
    (path / "app.py").write_text("VALUE = 1\n")
    subprocess.run(["git", "add", "app.py"], cwd=path, check=True)
    subprocess.run(["git", "-c", "user.name=T", "-c", "user.email=t@example.com",
                    "commit", "--quiet", "-m", "app"], cwd=path, check=True)
    return path


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.local = self.root / "local"
        self.sessions = self.local / "sessions"
        self.store = leases.LeaseStore(self.sessions)

    def tearDown(self):
        self.tmp.cleanup()

    def expired(self, **overrides):
        data = {"harness": "antigravity", "session": "ide-1", "model": "gemini-3.8-flash",
                "issue": 549, "pr": 554, "worktree": str(self.root / "worktree"),
                "transport": "antigravity", "ttl_seconds": 60,
                "updated_at": leases.isoformat(moment(-300))}
        data.update(overrides)
        return self.store.write(leases.Lease(**data))

    def test_clean_expired_session_is_released_without_touching_the_worktree(self):
        worktree = git_repo(self.root / "worktree")
        self.expired()
        report = coordinator.recover(self.local, now=moment())
        self.assertEqual([action["action"] for action in report["actions"]], ["clean"])
        self.assertTrue(worktree.is_dir())
        self.assertEqual(self.store.all(), [])

    def test_dirty_expired_session_is_captured_and_its_worktree_preserved(self):
        worktree = git_repo(self.root / "worktree")
        (worktree / "app.py").write_text("VALUE = 2\n")
        self.expired()
        report = coordinator.recover(self.local, now=moment())
        self.assertEqual([action["action"] for action in report["actions"]], ["captured"])
        envelope_file = self.local / "handovers" / "549-001.json"
        self.assertTrue(envelope_file.is_file())
        captured, errors = handover.validate_file(envelope_file)
        self.assertEqual(errors, [])
        self.assertEqual(captured["reason"], "stale_lease")
        self.assertEqual(subprocess.run(["git", "status", "--porcelain"], cwd=worktree,
                                        capture_output=True, text=True).stdout, "")
        self.assertTrue(worktree.is_dir())  # never removed
        escalation = json.loads(next((self.local / "coordinator" / "escalations").glob("*.json")).read_text())
        self.assertEqual(escalation["reason"], coordinator.DIRTY_WORKTREE_PRESERVED)

    def test_capture_failure_escalates_and_keeps_the_lease_and_worktree(self):
        worktree = git_repo(self.root / "worktree")
        (worktree / "app.py").write_text("VALUE = 3\n")
        self.expired()

        def boom(**kwargs):
            raise RuntimeError("index locked")

        report = coordinator.recover(self.local, now=moment(), capture_fn=boom)
        self.assertEqual(report["actions"][0]["action"], "escalate")
        self.assertTrue(worktree.is_dir())
        self.assertEqual(len(self.store.all()), 1)

    def test_missing_worktree_escalates_without_touching_anything(self):
        self.expired(worktree=str(self.root / "gone"))
        report = coordinator.recover(self.local, now=moment())
        self.assertEqual(report["actions"][0]["action"], "escalate")
        self.assertEqual(report["actions"][0]["escalation"]["reason"], coordinator.STALE_LEASE)

    def test_expired_t3_attempt_escalates_before_any_export(self):
        db = self.root / "runs.sqlite3"
        connection = sqlite3.connect(db)
        connection.executescript(
            "CREATE TABLE attempts (id TEXT, run_id TEXT, task_id TEXT, status TEXT, lease REAL);"
            "INSERT INTO attempts VALUES ('att-1','run-1','stage-01','RUNNING',100);")
        connection.commit()
        connection.close()
        report = coordinator.recover(self.local, now=moment(1000), t3_db=db)
        self.assertEqual(report["actions"][-1]["kind"], "t3")
        self.assertEqual(report["actions"][-1]["escalation"]["reason"], coordinator.T3_LEASE_EXPIRED)
        self.assertIn("task_cancel", report["actions"][-1]["escalation"]["detail"])

    def test_dry_run_changes_nothing(self):
        worktree = git_repo(self.root / "worktree")
        (worktree / "app.py").write_text("VALUE = 4\n")
        self.expired()
        report = coordinator.recover(self.local, now=moment(), dry_run=True)
        self.assertEqual(report["actions"][0]["action"], "would_capture")
        self.assertFalse((self.local / "handovers").exists())
        self.assertEqual(len(self.store.all()), 1)


if __name__ == "__main__":
    unittest.main()
