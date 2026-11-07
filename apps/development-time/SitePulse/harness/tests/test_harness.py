"""Self-tests for the harness logic.

Every test builds its own temporary DAG, evidence and RTM fixtures, so these
tests check the harness itself, not the state of the project's task data.
Gates are replaced with tiny Python commands so the tests run in seconds.
"""

import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(PROJECT_ROOT))

from harness import harness_cli  # noqa: E402
from harness.graph.task_dag import DagValidationError, TaskDag, validate_document  # noqa: E402
from harness.loop import verification_gates as vg  # noqa: E402
from harness.loop.loop_runner import LoopRunner, read_evidence  # noqa: E402

PASS_GATE = [vg.CommandSpec([sys.executable, "-c", "print('ok')"], ".", 30)]
FAIL_GATE = [vg.CommandSpec([sys.executable, "-c", "import sys; print('error: boom'); sys.exit(3)"], ".", 30)]


def task(tid, deps=(), gates=("fake-pass",), status="UNVERIFIED", **extra):
    return {"id": tid, "name": tid, "module": "m", "status": status, "depends_on": list(deps),
            "spec_ref": "SPEC", "gates": list(gates), "acceptance_tests": [], **extra}


class DagFixture:
    def __init__(self, tasks, **top):
        self.dir = tempfile.TemporaryDirectory()
        self.root = Path(self.dir.name)
        self.path = self.root / "task-dag.json"
        self.path.write_text(json.dumps({"version": "9.9", "project": "fixture", "custom_key": [1, 2], **top, "tasks": tasks}))

    def doc(self):
        return json.loads(self.path.read_text())

    def cleanup(self):
        self.dir.cleanup()


@mock.patch.dict(vg.GATES, {"fake-pass": PASS_GATE, "fake-fail": FAIL_GATE})
class TestDagValidation(unittest.TestCase):
    def test_valid_dag_loads(self):
        f = DagFixture([task("task-01"), task("task-02", deps=["task-01"])])
        self.addCleanup(f.cleanup)
        dag = TaskDag(f.path)
        self.assertEqual(set(dag.tasks), {"task-01", "task-02"})

    def test_unknown_dependency_is_rejected(self):
        errors = validate_document({"tasks": [task("task-01", deps=["task-99"])]})
        self.assertTrue(any("unknown task 'task-99'" in e for e in errors))

    def test_unknown_gate_and_malformed_test_id_are_rejected(self):
        errors = validate_document({"tasks": [task("task-01", gates=["no-such-gate"], acceptance_tests=["pytest something"])]})
        self.assertTrue(any("unknown gate" in e for e in errors))
        self.assertTrue(any("malformed acceptance test id" in e for e in errors))

    def test_task_without_any_check_is_rejected(self):
        errors = validate_document({"tasks": [task("task-01", gates=[])]})
        self.assertTrue(any("can never be verified" in e for e in errors))

    def test_cycles_and_duplicates_are_rejected(self):
        cyc = validate_document({"tasks": [task("task-01", deps=["task-02"]), task("task-02", deps=["task-01"])]})
        self.assertTrue(any("cycle" in e for e in cyc))
        dup = validate_document({"tasks": [task("task-01"), task("task-01")]})
        self.assertTrue(any("duplicate" in e for e in dup))

    def test_invalid_file_raises(self):
        f = DagFixture([task("task-01", deps=["ghost"])])
        self.addCleanup(f.cleanup)
        with self.assertRaises(DagValidationError):
            TaskDag(f.path)

    def test_save_is_atomic_and_preserves_top_level_keys(self):
        f = DagFixture([task("task-01")])
        self.addCleanup(f.cleanup)
        dag = TaskDag(f.path)
        dag.update_task("task-01", status="COMPLETED")
        doc = f.doc()
        self.assertEqual(doc["version"], "9.9")
        self.assertEqual(doc["custom_key"], [1, 2])
        self.assertEqual(doc["tasks"][0]["status"], "COMPLETED")
        self.assertEqual([p.name for p in f.root.iterdir()], ["task-dag.json"], "no temp files left behind")

    def test_runnable_requires_completed_dependencies(self):
        f = DagFixture([task("task-01"), task("task-02", deps=["task-01"])])
        self.addCleanup(f.cleanup)
        dag = TaskDag(f.path)
        self.assertEqual([t["id"] for t in dag.get_runnable_tasks()], ["task-01"])
        dag.update_task("task-01", status="COMPLETED")
        self.assertEqual([t["id"] for t in dag.get_runnable_tasks()], ["task-02"])


@mock.patch.dict(vg.GATES, {"fake-pass": PASS_GATE, "fake-fail": FAIL_GATE})
class TestGatesAndLoop(unittest.TestCase):
    def test_missing_tool_fails_the_gate(self):
        res = vg.run_command("x", vg.CommandSpec(["definitely-not-a-real-tool-xyz"], "."), PROJECT_ROOT)
        self.assertFalse(res.passed)
        self.assertIn("not installed", res.diagnostics[0])

    def test_failing_command_reports_diagnostics(self):
        res = vg.run_gate("fake-fail", PROJECT_ROOT)
        self.assertFalse(res.passed)
        self.assertTrue(any("error: boom" in d for d in res.diagnostics))

    def test_unknown_gate_fails(self):
        self.assertFalse(vg.run_gate("nope", PROJECT_ROOT).passed)

    def test_task_with_nothing_to_run_cannot_pass(self):
        res = LoopRunner(include_global=False).run_task_gates({"id": "t", "gates": []}, PROJECT_ROOT)
        self.assertFalse(res["passed"])

    def test_retry_budget(self):
        runner = LoopRunner(max_budget=3)
        self.assertEqual(runner.next_status(True, 0), "COMPLETED")
        self.assertEqual(runner.next_status(False, 1), "FAILED")
        self.assertEqual(runner.next_status(False, 3), "BLOCKED")

    def test_acceptance_id_format(self):
        self.assertTrue(vg.is_valid_acceptance_id("rust:integration_tests::when_x"))
        self.assertTrue(vg.is_valid_acceptance_id("flutter:test/a_test.dart"))
        self.assertTrue(vg.is_valid_acceptance_id("system:restart_persistence"))
        self.assertFalse(vg.is_valid_acceptance_id("SyntaxGate"))

    def test_rust_test_lines_are_parsed_per_test(self):
        out = "test a_ok ... ok\ntest b_bad ... FAILED\n"
        self.assertEqual(vg._rust_tests_reported(out, ["a_ok", "b_bad", "c_missing"]), {"a_ok": True, "b_bad": False, "c_missing": False})


@mock.patch.dict(vg.GATES, {"fake-pass": PASS_GATE, "fake-fail": FAIL_GATE})
class TestCli(unittest.TestCase):
    def run_cli(self, f, *args, env=None):
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, env or {}, clear=False), redirect_stdout(out), redirect_stderr(err):
            code = harness_cli.main(["verify", *args, "--dag", str(f.path), "--evidence-dir", str(f.root / "evidence"),
                                     "--root", str(PROJECT_ROOT), "--no-global"])
        return code, out.getvalue() + err.getvalue()

    def test_verify_is_read_only_by_default(self):
        f = DagFixture([task("task-01")])
        self.addCleanup(f.cleanup)
        before = f.path.read_text()
        code, _ = self.run_cli(f, "--task", "task-01")
        self.assertEqual(code, 0)
        self.assertEqual(f.path.read_text(), before)
        self.assertFalse((f.root / "evidence").exists())

    def test_record_is_reserved_for_ci(self):
        f = DagFixture([task("task-01")])
        self.addCleanup(f.cleanup)
        code, out = self.run_cli(f, "--task", "task-01", "--record", env={"CI": "false"})
        self.assertEqual(code, 2)
        self.assertIn("reserved for CI", out)

    def test_record_refuses_incomplete_dependencies(self):
        f = DagFixture([task("task-01"), task("task-02", deps=["task-01"])])
        self.addCleanup(f.cleanup)
        code, out = self.run_cli(f, "--task", "task-02", "--record", env={"CI": "true"})
        self.assertEqual(code, 2)
        self.assertIn("dependencies", out)

    def test_record_writes_evidence_and_status(self):
        f = DagFixture([task("task-01")])
        self.addCleanup(f.cleanup)
        code, _ = self.run_cli(f, "--task", "task-01", "--record", env={"CI": "true"})
        self.assertEqual(code, 0)
        self.assertEqual(f.doc()["tasks"][0]["status"], "COMPLETED")
        evidence = read_evidence(f.root / "evidence", "task-01")
        self.assertTrue(evidence["passed"])
        self.assertIn("commit", evidence)
        self.assertIn("finished_at", evidence)

    def test_failures_consume_the_budget_then_block(self):
        f = DagFixture([task("task-01", gates=["fake-fail"], max_attempts=2)])
        self.addCleanup(f.cleanup)
        self.assertEqual(self.run_cli(f, "--task", "task-01", "--record", env={"CI": "true"})[0], 1)
        self.assertEqual(f.doc()["tasks"][0]["status"], "FAILED")
        self.run_cli(f, "--task", "task-01", "--record", env={"CI": "true"})
        self.assertEqual(f.doc()["tasks"][0]["status"], "BLOCKED")
        code, out = self.run_cli(f, "--task", "task-01", "--record", env={"CI": "true"})
        self.assertEqual(code, 2)
        self.assertIn("BLOCKED", out)


class TestRtmValidator(unittest.TestCase):
    def make_workspace(self, status, evidence=None):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        spec = root / "apps" / "development-time" / "SitePulse" / ".specify"
        (spec / "tasks").mkdir(parents=True)
        (spec / "tasks" / "task-dag.json").write_text(json.dumps({"tasks": [task("task-01", gates=[], acceptance_tests=["rust:t::a"], status="COMPLETED" if status == "VERIFIED" else "UNVERIFIED")]}))
        (root / "src.rs").write_text("")
        (root / "docs" / "cmmi-pipeline").mkdir(parents=True)
        (root / "docs" / "cmmi-pipeline" / "traceability-matrix.md").write_text(
            f"| **REQ-001** | intent | spec | arch | `task-01` | `src.rs` | `rust:t::a` | criteria | **{status}** |\n")
        if evidence is not None:
            (spec / "evidence").mkdir()
            (spec / "evidence" / "task-01.json").write_text(json.dumps(evidence))
        return root

    def validator(self, root, stale=False):
        from harness.rtm_validator import RtmValidator
        return RtmValidator(workspace_root=root, allow_stale_evidence=stale)

    def test_unverified_requirements_need_no_evidence(self):
        self.assertTrue(self.validator(self.make_workspace("UNVERIFIED")).validate()["passed"])

    def test_verified_without_evidence_fails(self):
        report = self.validator(self.make_workspace("VERIFIED")).validate()
        self.assertFalse(report["passed"])
        self.assertTrue(any("evidence file is missing" in i for i in report["issues"]))

    def test_verified_with_passing_evidence_passes_and_stale_commit_fails(self):
        ev = {"passed": True, "commit": "abc", "dirty": False, "acceptance_tests": [{"id": "rust:t::a", "passed": True}]}
        root = self.make_workspace("VERIFIED", ev)
        self.assertTrue(self.validator(root, stale=True).validate()["passed"])
        report = self.validator(root).validate()
        self.assertFalse(report["passed"])
        self.assertTrue(any("not the current HEAD" in i for i in report["issues"]))

    def test_named_test_must_have_passed(self):
        ev = {"passed": True, "commit": "abc", "acceptance_tests": [{"id": "rust:t::a", "passed": False}]}
        report = self.validator(self.make_workspace("VERIFIED", ev), stale=True).validate()
        self.assertFalse(report["passed"])


class TestProjectData(unittest.TestCase):
    """The real project DAG and RTM must at least be well-formed and consistent."""

    def test_project_dag_is_valid(self):
        TaskDag(PROJECT_ROOT / ".specify" / "tasks" / "task-dag.json")

    def test_project_rtm_is_consistent(self):
        from harness.rtm_validator import RtmValidator
        report = RtmValidator().validate()
        self.assertTrue(report["passed"], report["issues"])


class TestPersistenceLint(unittest.TestCase):
    """The persistence lint enforces repository boundaries and result handling."""

    def test_backend_passes_persistence_lint(self):
        from scripts.memory_persistence_lint import lint
        findings = lint(PROJECT_ROOT / "backend")
        self.assertEqual(findings, [])

    def test_service_repository_boundary_violation_caught(self):
        from scripts.memory_persistence_lint import lint
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            src_dir = root / "src"
            services_dir = src_dir / "services"
            services_dir.mkdir(parents=True)
            (src_dir / "lib.rs").write_text("#![deny(unused_must_use)]\n")
            (services_dir / "saas_tenant_service.rs").write_text(
                'pub async fn bad_code() { client.query("SELECT * FROM sites", &[]).await; }\n'
            )
            findings = lint(root)
            rules = [f["rule"] for f in findings]
            self.assertIn("service-repository-boundary", rules)


if __name__ == "__main__":
    unittest.main()
