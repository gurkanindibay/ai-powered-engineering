import json
from pathlib import Path
import tempfile
import unittest

from scripts.engineering_harness.contracts import redact, validate_result
from scripts.engineering_harness.evaluation import evaluate
from scripts.engineering_harness.routing import HarnessError
from scripts.engineering_harness.workspace import Workspace, git
from support import repository, response


class ContractTests(unittest.TestCase):
    def test_worker_cannot_invent_completion_on_different_input(self):
        envelope = dict(run_id="r", task_id="t", attempt_id="a", candidate="c", role="tester", acceptance={"criterion": ["unit"]})
        result = response(envelope)
        self.assertEqual(validate_result(result, envelope), result)
        for key, value in [("input_hash", "forged"), ("issues", ["unresolved"]), ("artifacts", {}), ("usage", {"input_tokens": -1, "output_tokens": 0})]:
            with self.assertRaises(HarnessError):
                validate_result(dict(result, **{key: value}), envelope)

    def test_secret_redaction_preserves_valid_json(self):
        text = json.dumps({"summary": "password=hunter2 token=private", "log": "explicit secret"})
        output = redact(text, ("explicit secret",))
        self.assertNotIn("hunter2", output)
        self.assertNotIn("private", output)
        self.assertNotIn("explicit secret", output)
        json.loads(output)

    def test_workspace_rejects_protected_changes_and_symlink_escapes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = repository(root / "source")
            workspace = Workspace(root / "owned")
            workspace.create(source)
            (workspace.path / "checks" / "test_value.py").write_text("# weakened\n")
            with self.assertRaises(HarnessError):
                workspace.integrate(["checks"], ["checks"], "test")
            git(workspace.path, "restore", "checks/test_value.py")
            (workspace.path / "src" / "escape").symlink_to(root)
            with self.assertRaises(HarnessError):
                workspace.integrate(["src"], [], "test")

    def test_paired_metrics_include_failed_cost_and_require_matching_pairs(self):
        cases = [{"id": "a", "task": "Change", "expected": "low"}]
        measurements = [dict(task_id="a", arm="baseline", accepted=True, duration_ms=100, cost="0.1"),
                        dict(task_id="a", arm="routed", accepted=False, duration_ms=10, cost="0.05")]
        metrics = evaluate(cases, measurements)["measurements"]
        self.assertEqual(metrics["routed"]["total_cost"], "0.05")
        self.assertIsNone(metrics["routed"]["cost_per_accepted"])
        with self.assertRaises(HarnessError):
            evaluate(cases, measurements[:1])

    def test_snapshot_refuses_credential_files(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = repository(root / "source")
            (source / ".env").write_text("sensitive")
            git(source, "add", "-f", ".env")
            git(source, "commit", "-m", "unsafe fixture")
            with self.assertRaises(HarnessError):
                Workspace(root / "owned").create(source)
