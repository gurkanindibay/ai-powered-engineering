import json
from pathlib import Path
import tempfile
import unittest

from scripts.engineering_harness import t3
from scripts.engineering_harness.engine import Engine
from scripts.engineering_harness.routing import HarnessError, route
from scripts.engineering_harness.store import Store
from scripts.engineering_harness.workspace import git
from support import FakeBackend, capabilities, policy, repository

ROOT = Path(__file__).resolve().parents[2]


def catalog(*, disable_codex=False, drop_haiku=False):
    claude = [{"id": m, "options": [{"id": "effort", "values": ["low", "medium", "high", "xhigh", "max"]}]}
              for m in ("claude-opus-5-5", "claude-sonnet-5-5") + (() if drop_haiku else ("claude-haiku-5-5",))]
    codex = [{"id": "gpt-6.1-sol", "options": [{"id": "reasoningEffort", "values": ["low", "medium", "high"]}]}]
    return {"providers": [
        {"providerInstanceId": "claudeAgent", "canRunChildTask": True, "models": claude},
        {"providerInstanceId": "codex", "canRunChildTask": not disable_codex, "models": codex},
        {"providerInstanceId": "cursor", "canRunChildTask": False, "models": []},
    ]}


def child_message(envelope, status="completed", **overrides):
    role = envelope["role"]
    artifacts = {
        "tester": {"criteria": {c: "pass" for c in envelope["acceptance"]}, "verdict": "pass", "residual_risks": []},
    }.get(role, {"changes": ["src/value.py"], "tests": ["unit"]})
    body = {"status": status, "summary": f"{role} done", "artifacts": artifacts, "issues": [], **overrides}
    return f"Work finished.\n{t3.RESULT_BEGIN}\n{json.dumps(body)}\n{t3.RESULT_END}\n"


class RegistryTests(unittest.TestCase):
    def setUp(self):
        self.registry = json.loads(t3.DEFAULT_REGISTRY.read_text())

    def test_committed_registry_is_valid(self):
        self.assertTrue(t3.validate_registry(self.registry))

    def test_tiers_route_to_progressively_stronger_models(self):
        live = t3.capabilities_from_catalog(self.registry, catalog())
        chosen = {tier: t3.with_tier_options(route(live, "developer", tier), tier) for tier in ("low", "medium", "high", "critical")}
        self.assertEqual(chosen["low"]["model"], "claude-haiku-5-5")
        self.assertEqual(chosen["medium"]["model"], "claude-sonnet-5-5")
        self.assertEqual(chosen["critical"]["model"], "claude-opus-5-5")
        self.assertEqual(chosen["critical"]["selected_options"], {"effort": "xhigh"})

    def test_unavailable_providers_models_and_options_are_dropped(self):
        live = t3.capabilities_from_catalog(self.registry, catalog(disable_codex=True, drop_haiku=True))
        models = {t["model"] for t in live["targets"]}
        self.assertNotIn("claude-haiku-5-5", models)
        self.assertNotIn("gpt-6.1-sol", models)
        self.assertEqual(route(live, "developer", "low")["model"], "claude-sonnet-5-5")
        # Catalog offers no xhigh for codex, so its high/critical defaults are withdrawn.
        codex = t3.capabilities_from_catalog(self.registry, catalog())
        sol = next(t for t in codex["targets"] if t["model"] == "gpt-6.1-sol")
        self.assertEqual(sol["tiers"], ["medium", "high"])

    def test_explicit_preference_is_not_substituted(self):
        live = t3.capabilities_from_catalog(self.registry, catalog(disable_codex=True))
        with self.assertRaises(HarnessError):
            route(live, "tester", "high", {"provider": "codex", "model": "gpt-6.1-sol"})

    def test_tier_options_must_be_declared(self):
        bad = json.loads(json.dumps(self.registry))
        bad["targets"][0]["tier_options"] = {"low": {"effort": "ultra"}}
        with self.assertRaises(HarnessError):
            t3.validate_registry(bad)


class T3EngineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.repo = repository(root / "repo")
        self.store = Store(root / "state")
        self.addCleanup(self.store.close)
        self.policy = policy()
        self.backend = FakeBackend(self.policy)
        self.engine = Engine(self.store, lambda _: self.backend)
        self.run_id = self.engine.create(self.repo, "Adjust value", self.policy, capabilities=capabilities(), scope="mechanical")
        self.workspace = self.engine.workspace(self.run_id).path

    def dispatch(self):
        value = self.engine.t3_dispatch(self.run_id, capabilities())
        self.assertEqual(value["status"], "RUNNING")
        return value, self.store.attempt(value["attempt_id"])["envelope"]

    def test_full_flow_dispatches_payloads_and_verifies(self):
        value, envelope = self.dispatch()
        payload = value["delegate_task"]
        self.assertEqual(payload["target"], {"providerInstanceId": "fixture", "model": "deterministic", "options": {}})
        self.assertEqual(payload["role"], "implementation")
        self.assertIn(str(self.workspace), payload["task"])
        self.assertIn("src", payload["task"])
        self.assertNotIn(str(self.repo), payload["task"])
        (self.workspace / "src" / "value.py").write_text("VALUE = 1\n")
        self.assertEqual(self.engine.t3_submit(self.run_id, value["attempt_id"], child_message(envelope)), "QUEUED")
        tester, tester_envelope = self.dispatch()
        self.assertEqual(tester["role"], "tester")
        self.assertIn("read-only", tester["delegate_task"]["task"])
        self.assertEqual(self.engine.t3_submit(self.run_id, tester["attempt_id"], child_message(tester_envelope)), "QUEUED")
        self.assertEqual(self.engine.t3_dispatch(self.run_id, capabilities())["status"], "READY_FOR_REVIEW")
        self.assertEqual((self.workspace / "src" / "value.py").read_text(), "VALUE = 1\n")
        self.assertTrue(self.store.audit(self.run_id))
        # Unmetered children keep the whole reservation charged.
        self.assertEqual(self.store.run(self.run_id)["tokens"], 2000)

    def test_duplicate_submission_is_idempotent(self):
        value, envelope = self.dispatch()
        message = child_message(envelope)
        (self.workspace / "src" / "value.py").write_text("VALUE = 1\n")
        self.assertEqual(self.engine.t3_submit(self.run_id, value["attempt_id"], message), "QUEUED")
        self.assertEqual(self.engine.t3_submit(self.run_id, value["attempt_id"], message), "QUEUED")
        with self.assertRaises(HarnessError):
            self.engine.t3_submit(self.run_id, value["attempt_id"], child_message(envelope, summary="different"))

    def test_second_dispatch_while_child_runs_is_refused(self):
        self.dispatch()
        with self.assertRaises(HarnessError):
            self.engine.t3_dispatch(self.run_id, capabilities())

    def test_child_writing_outside_assignment_blocks(self):
        value, envelope = self.dispatch()
        (self.workspace / "checks" / "test_value.py").write_text("# weakened\n")
        self.assertEqual(self.engine.t3_submit(self.run_id, value["attempt_id"], child_message(envelope)), "BLOCKED")

    def test_test_run_caches_do_not_block_or_get_integrated(self):
        value, envelope = self.dispatch()
        (self.workspace / "src" / "value.py").write_text("VALUE = 1\n")
        for folder in ("src", "checks"):
            (self.workspace / folder / "__pycache__").mkdir()
            (self.workspace / folder / "__pycache__" / "x.cpython-314.pyc").write_bytes(b"\0")
        self.assertEqual(self.engine.t3_submit(self.run_id, value["attempt_id"], child_message(envelope)), "QUEUED")
        tracked = git(self.workspace, "ls-files")
        self.assertNotIn("__pycache__", tracked)

    def test_missing_or_forged_result_blocks(self):
        value, _ = self.dispatch()
        self.assertEqual(self.engine.t3_submit(self.run_id, value["attempt_id"], "I am done, trust me."), "BLOCKED")

    def test_child_cannot_override_controller_fields(self):
        value, envelope = self.dispatch()
        forged = child_message(envelope, usage={"input_tokens": 1, "output_tokens": 1})
        self.assertEqual(self.engine.t3_submit(self.run_id, value["attempt_id"], forged), "BLOCKED")

    def test_code_defect_requeues_for_repair(self):
        value, envelope = self.dispatch()
        message = child_message(envelope, status="code_defect", issues=["Edge case unhandled"])
        self.assertEqual(self.engine.t3_submit(self.run_id, value["attempt_id"], message), "REPAIRING")
        repair, repair_envelope = self.dispatch()
        self.assertEqual(repair_envelope["previous_failure"]["issues"], ["Edge case unhandled"])

    def test_cancel_does_not_touch_docker_for_t3_attempts(self):
        self.dispatch()
        self.assertEqual(self.engine.cancel(self.run_id), "CANCELLED")
        self.assertEqual(self.backend.stopped, [])


if __name__ == "__main__":
    unittest.main()
