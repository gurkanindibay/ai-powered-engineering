"""The CI gate groups in scripts/run_tests.py must cover every gate exactly once.

CI runs one job per group (`run_tests.py --group <name>`), so a gate in ORDER that no group
lists, or a group that no CI job runs, would silently never run in CI.
"""
import importlib.util
import re
import sys
import unittest
from pathlib import Path

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


class GateGroupTests(unittest.TestCase):
    def test_groups_partition_order(self):
        grouped = [gate for gates in run_tests.GATE_GROUPS.values() for gate in gates]
        self.assertEqual(len(grouped), len(set(grouped)), "a gate is listed in more than one group")
        self.assertEqual(set(grouped), set(run_tests.ORDER), "groups must list every gate in ORDER exactly once")

    def test_every_gate_is_known(self):
        self.assertFalse(set(run_tests.ORDER) - set(run_tests.GATES))

    def test_lint_gates_run_before_compiles(self):
        order = run_tests.ORDER
        first_compile = order.index("rust-build")
        for gate in run_tests.GATE_GROUPS["lint"]:
            self.assertLess(order.index(gate), first_compile, gate)
        self.assertEqual(order[-1], "test-run-recorded")

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
