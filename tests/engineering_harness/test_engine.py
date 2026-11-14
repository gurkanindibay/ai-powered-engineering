import json
from pathlib import Path
import tempfile
import time
import unittest

from scripts.engineering_harness.contracts import digest
from scripts.engineering_harness.engine import Engine
from scripts.engineering_harness.routing import HarnessError
from scripts.engineering_harness.store import Store
from scripts.engineering_harness.workspace import git
from support import FakeBackend, capabilities, policy, repository


class EngineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = repository(self.root / "repo")
        self.store = Store(self.root / "state")
        self.addCleanup(self.store.close)
        self.policy = policy()
        self.backend = FakeBackend(self.policy)
        self.engine = Engine(self.store, lambda _: self.backend)

    def create(self, **options):
        return self.engine.create(self.repo, "Adjust value", self.policy, capabilities=capabilities(), scope="mechanical", **options)

    def finish(self, run_id, limit=20):
        for _ in range(limit):
            status = self.engine.step(run_id)
            if status in {"READY_FOR_REVIEW", "BLOCKED", "TIMED_OUT", "CANCELLED"}:
                return status
        self.fail("Run failed to terminate within bounded steps")

    def test_full_flow_integrates_and_verifies_without_touching_user_tree(self):
        (self.repo / "src" / "value.py").write_text("UNCOMMITTED USER CHANGE\n")
        run_id = self.create()
        self.assertEqual(self.finish(run_id), "READY_FOR_REVIEW")
        self.assertEqual((self.repo / "src" / "value.py").read_text(), "UNCOMMITTED USER CHANGE\n")
        self.assertEqual((self.engine.workspace(run_id).path / "src" / "value.py").read_text(), "VALUE = 1\n")
        self.assertTrue(self.store.audit(run_id))
        run = self.store.run(run_id)
        self.assertEqual(run["tokens"], 30)
        self.assertEqual(run["cost"], "0.00004")
        evidence = self.store.directory / "evidence" / run_id
        self.assertTrue((evidence / "verification-1.json").exists())
        tester = [kwargs["payload"] for _, kwargs in self.backend.calls if kwargs.get("payload", {}).get("role") == "tester"][0]
        self.assertEqual(tester["candidate"], run["candidate"])
        self.assertTrue(tester["handoffs"])

    def test_final_gate_failure_repairs_and_retests_candidate(self):
        run_id = self.create()
        self.backend.mode = "fail_once"
        self.assertEqual(self.finish(run_id), "READY_FOR_REVIEW")
        self.assertEqual(self.backend.gate_runs, 2)
        self.assertEqual(self.store.tasks(run_id)[0]["repairs"], 1)
        folder = self.store.directory / "evidence" / run_id
        self.assertTrue((folder / "verification-1.json").exists())
        self.assertTrue((folder / "verification-2.json").exists())
        failure = json.loads((folder / "verification-1.json").read_text())
        self.assertEqual(failure["gates"][0]["status"], "failed")

    def test_zero_test_gate_exhausts_bounded_repair_budget(self):
        self.policy["limits"]["max_repairs"] = 1
        run_id = self.create()
        self.backend.mode = "zero"
        self.assertEqual(self.finish(run_id), "BLOCKED")
        self.assertEqual(self.backend.gate_runs, 2)

    def test_gate_captures_reach_evidence_and_export_without_changing_the_candidate(self):
        self.policy["gates"][0]["captures"] = ["records"]
        run_id = self.create()
        self.backend.mode = "capture"
        self.assertEqual(self.finish(run_id), "READY_FOR_REVIEW")
        workspace = self.engine.workspace(run_id)
        self.assertFalse((workspace.path / "records").exists())
        self.assertTrue(workspace.clean())
        listed = self.engine.captures(run_id)
        self.assertEqual(listed["files"], ["records/runs/run-1.jsonl"])
        self.assertEqual((listed["written"], listed["candidate"]), ([], self.store.run(run_id)["candidate"]))
        target = self.repo.parent / "delivered"
        target.mkdir()
        self.assertEqual(self.engine.captures(run_id, target)["written"], ["records/runs/run-1.jsonl"])
        self.assertIn("SC-01-01-01", (target / "records" / "runs" / "run-1.jsonl").read_text())
        with self.assertRaises(HarnessError):  # recorded runs are append-only
            self.engine.captures(run_id, target)

    def test_sitepulse_policy_lets_the_tester_write_scenarios_but_no_worker_write_records(self):
        from scripts.engineering_harness.contracts import under
        from scripts.engineering_harness.sitepulse import policy_for_sitepulse
        policy = policy_for_sitepulse("sha256:" + "a" * 64)
        root = "apps/development-time/SitePulse"

        def writable(role, path):
            return (any(under(path, p) for p in policy["role_paths"][role])
                    and not any(under(path, p) for p in policy["protected_paths"]))

        self.assertTrue(writable("tester", f"{root}/.specify/features/EPIC-10/STORY-10-01-x.feature"))
        self.assertTrue(writable("tester", f"{root}/e2e/steps/capital_steps.py"))
        for role in policy["role_paths"]:
            self.assertFalse(writable(role, f"{root}/.specify/executions/runs/2026/x.jsonl"), role)
            self.assertFalse(writable(role, f"{root}/.specify/requirements/EPIC-10-x.md"), role)
            self.assertFalse(writable(role, f"{root}/e2e/support/executions.py"), role)
        full = next(g for g in policy["gates"] if g["id"] == "sitepulse-full")
        self.assertEqual(full["captures"], [f"{root}/.specify/executions"])
        self.assertIn("SITEPULSE_TASK=engineering-harness", full["argv"])

    def test_gate_source_mutation_cannot_pass(self):
        self.policy["limits"]["max_repairs"] = 0
        run_id = self.create()
        self.backend.mode = "mutate_gate"
        self.assertEqual(self.finish(run_id), "BLOCKED")

    def test_stale_or_invalid_result_blocks_without_integration(self):
        run_id = self.create()
        self.backend.transform = lambda r: dict(r, candidate="stale")
        self.assertEqual(self.engine.step(run_id), "BLOCKED")
        run = self.store.run(run_id)
        self.assertNotEqual(git(self.repo, "rev-parse", "HEAD"), run["candidate"])
        self.assertGreater(run["tokens"], 0, "Unknown usage reservation must remain charged")
        self.assertEqual(self.store.tasks(run_id)[0]["status"], "BLOCKED")

    def test_post_result_over_budget_never_marks_ready(self):
        run_id = self.create()
        self.backend.transform = lambda r: dict(r, usage={"input_tokens": 100000, "output_tokens": 0})
        self.assertEqual(self.engine.step(run_id), "BLOCKED")
        self.assertEqual(self.store.run(run_id)["tokens"], 100000)

    def test_reserved_budget_prevents_dispatch(self):
        self.policy["limits"]["tokens"] = 1
        run_id = self.create()
        self.assertEqual(self.engine.step(run_id), "BLOCKED")
        self.assertFalse(self.backend.calls)

    def test_duplicate_completion_does_not_charge_or_integrate_twice(self):
        run_id = self.create()
        self.engine.step(run_id)
        row = self.store.db.execute("SELECT id,result FROM attempts").fetchone()
        before = self.store.run(run_id)
        self.assertFalse(self.store.finish(row[0], json.loads(row[1]), before["candidate"], "0.00002", 15))
        self.assertEqual(self.store.run(run_id)["cost"], before["cost"])
        with self.assertRaises(HarnessError):
            self.store.finish(row[0], {"different": True}, before["candidate"], "0", 0)

    def test_concurrent_claim_and_crash_recovery(self):
        run_id = self.create()
        self.engine.step(run_id)
        row = self.store.db.execute("SELECT id FROM attempts").fetchone()
        envelope = self.store.attempt(row[0])["envelope"]
        # Simulate controller death after a claim but before receiving provider output.
        self.store.db.execute("UPDATE attempts SET status='RUNNING',result_hash=NULL WHERE id=?", (row[0],))
        self.store.db.execute("UPDATE tasks SET status='RUNNING' WHERE run_id=? AND id=?", (run_id, envelope["task_id"]))
        self.store.db.execute("UPDATE runs SET status='RUNNING' WHERE id=?", (run_id,))
        second = Store(self.store.directory)
        self.addCleanup(second.close)
        with self.assertRaises(HarnessError):
            second.claim(run_id, dict(envelope, attempt_id="duplicate"), "0", 1)
        with self.assertRaises(HarnessError):
            self.engine.recover(run_id)
        self.store.db.execute("UPDATE attempts SET lease=?", (time.time() - 1,))
        self.assertEqual(self.engine.recover(run_id), "BLOCKED")
        self.assertTrue(self.backend.stopped)

    def test_cancel_prevents_further_dispatch(self):
        run_id = self.create()
        self.assertEqual(self.engine.cancel(run_id), "CANCELLED")
        self.assertEqual(self.engine.step(run_id), "CANCELLED")
        self.assertFalse(self.backend.calls)

    def test_dirty_or_modified_candidate_cannot_reuse_evidence(self):
        run_id = self.create()
        self.engine.step(run_id)
        (self.engine.workspace(run_id).path / "src" / "value.py").write_text("VALUE = 10\n")
        self.assertEqual(self.engine.step(run_id), "BLOCKED")

    def test_deadline_survives_restart(self):
        run_id = self.create()
        self.store.db.execute("UPDATE runs SET deadline=? WHERE id=?", (time.time() - 1, run_id))
        self.assertEqual(self.engine.step(run_id), "TIMED_OUT")

    def test_evidence_cannot_be_overwritten_and_events_cannot_be_updated(self):
        run_id = self.create()
        with self.assertRaises(FileExistsError):
            self.engine.record(run_id, "intake", {"forged": True})
        import sqlite3
        with self.assertRaises(sqlite3.DatabaseError):
            self.store.db.execute("UPDATE events SET body='{}'")

    def test_evidence_audit_detects_file_tampering(self):
        run_id = self.create()
        file = self.store.directory / "evidence" / run_id / "intake.json"
        file.write_text('{"forged": true}')
        self.assertFalse(self.store.audit(run_id))

    def test_infrastructure_failure_never_spends_repairs(self):
        run_id = self.create()
        self.backend.mode = "infra"
        self.assertEqual(self.finish(run_id), "BLOCKED")
        self.assertEqual(self.backend.gate_runs, 1)
        self.assertEqual(self.store.tasks(run_id)[0]["repairs"], 0)

    def test_risk_is_reassessed_against_integrated_diff(self):
        run_id = self.create()
        self.engine.step(run_id)
        workspace = self.engine.workspace(run_id)
        (workspace.path / "src" / "authorization.py").write_text("POLICY = 'changed'\n")
        candidate = workspace.integrate(["src"], [], "Higher risk fixture")
        self.store.db.execute("UPDATE runs SET candidate=? WHERE id=?", (candidate, run_id))
        self.assertEqual(self.finish(run_id), "BLOCKED")
        self.assertEqual(self.backend.gate_runs, 0)

    def test_routing_fixture_set(self):
        from scripts.engineering_harness.evaluation import evaluate
        cases = json.loads(Path("config/engineering-harness/routing-cases.json").read_text())
        result = evaluate(cases)
        self.assertEqual(result["sample_size"], 36)
        self.assertEqual(result["matched"], 36)
        self.assertEqual(result["under_classified"], 0)
