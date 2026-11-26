"""The CI gate groups in scripts/run_tests.py must cover every gate exactly once.

CI runs one job per group (`run_tests.py --group <name>`), so a gate in ORDER that no group
lists, or a group that no CI job runs, would silently never run in CI.
"""
import importlib.util
import io
import re
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

PROJECT_ROOT = Path(__file__).resolve().parents[2]
REPO_ROOT = PROJECT_ROOT.parents[2]
WORKFLOW = REPO_ROOT / ".github" / "workflows" / "sitepulse-ci.yml"


def _load_run_tests():
    spec = importlib.util.spec_from_file_location("sitepulse_run_tests", PROJECT_ROOT / "scripts" / "run_tests.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


run_tests = _load_run_tests()
import ci_case_results


class GateGroupTests(unittest.TestCase):
    # covers: SC-05-05-01
    def test_groups_partition_order(self):
        grouped = [gate for gates in run_tests.GATE_GROUPS.values() for gate in gates]
        self.assertEqual(len(grouped), len(set(grouped)), "a gate is listed in more than one group")
        self.assertEqual(set(grouped), set(run_tests.ORDER), "groups must list every gate in ORDER exactly once")

    def test_every_gate_is_known(self):
        self.assertFalse(set(run_tests.ORDER) - set(run_tests.GATES))

    def test_report_gate_manifest_tracks_ci_group_partition(self):
        expected = dict(run_tests.GATE_GROUPS)
        expected["verify"] = expected.pop("final")
        self.assertEqual(ci_case_results.expected_gates(), expected)

    def test_lint_gates_run_before_compiles(self):
        order = run_tests.ORDER
        first_compile = order.index("rust-build")
        for gate in run_tests.GATE_GROUPS["lint"]:
            self.assertLess(order.index(gate), first_compile, gate)
        self.assertEqual(order[-1], "test-run-recorded")

    # covers: SC-05-05-01
    def test_one_command_runs_every_lane_and_returns_their_exit_code(self):
        executed = []

        def passing(name, root):
            executed.append(name)
            return run_tests.GateResult(name, True)

        with mock.patch.object(run_tests, "run_gate", passing), redirect_stdout(io.StringIO()):
            self.assertEqual(run_tests.main([]), 0, "exit code 0 when every gate passes")
        self.assertEqual(executed, run_tests.ORDER, "the single command runs every gate in order")
        for lane in ("harness-selftest", "feature-traceability", "rust-test", "flutter-test"):
            self.assertIn(lane, executed, f"the {lane} lane executes")
        self.assertIn(
            "harness/tests",
            [arg for spec in run_tests.GATES["harness-selftest"] for arg in spec.argv],
            "the harness lane runs the suite that holds the task DAG tests",
        )

        def rust_fails(name, root):
            return run_tests.GateResult(name, name != "rust-test")

        with mock.patch.object(run_tests, "run_gate", rust_fails), redirect_stdout(io.StringIO()):
            self.assertEqual(run_tests.main([]), 1, "a failing gate makes the exit code non-zero")

    def test_unknown_group_is_rejected(self):
        self.assertEqual(run_tests.main(["--group", "nope"]), 2)

    @unittest.skipUnless(WORKFLOW.exists(), "workflow file not in this checkout")
    def test_ci_runs_every_group(self):
        used = set()
        for match in re.finditer(r"run_tests\.py\s+--group\s+([a-z0-9,-]+)", WORKFLOW.read_text()):
            used.update(match.group(1).split(","))
        self.assertEqual(used, set(run_tests.GATE_GROUPS), "every gate group must run in sitepulse-ci.yml")


if __name__ == "__main__":
    unittest.main()
