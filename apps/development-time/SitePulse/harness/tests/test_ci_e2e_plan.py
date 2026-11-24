"""Tests for GitHub Actions E2E lane selection."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]


def _load():
    spec = importlib.util.spec_from_file_location("ci_e2e_plan", PROJECT_ROOT / "scripts" / "ci_e2e_plan.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


plan = _load()


class SelectionPlanTests(unittest.TestCase):
    def test_docs_only_pull_request_skips_browser_lane(self):
        result = plan.selection_plan("pull_request", "refs/pull/1/merge", {"mode": "none", "epics": []})
        self.assertFalse(result["run_e2e"])
        self.assertEqual(result["pytest_addopts"], plan.LINKED_SUITE_IGNORE)

    def test_targeted_pull_request_runs_smoke_core_and_impacted_epics(self):
        result = plan.selection_plan(
            "pull_request", "refs/pull/2/merge", {"mode": "targeted", "epics": ["EPIC-09", "EPIC-01"]},
        )
        self.assertTrue(result["run_e2e"])
        self.assertEqual(result["marker"], "smoke or core or epic_01 or epic_09")
        self.assertIn("-m 'smoke or core or epic_01 or epic_09'", result["pytest_addopts"])

    def test_full_suite_runs_for_shared_changes_and_master(self):
        shared = plan.selection_plan("pull_request", "refs/pull/3/merge", {"mode": "full", "epics": []})
        master = plan.selection_plan("push", "refs/heads/master", {"mode": "none", "epics": []})
        self.assertTrue(shared["run_e2e"])
        self.assertEqual(shared["marker"], "")
        self.assertTrue(master["run_e2e"])
        self.assertEqual(master["mode"], "full")

    def test_github_output_contains_single_line_selection(self):
        selection = plan.selection_plan("pull_request", "refs/pull/4/merge",
                                        {"mode": "targeted", "epics": ["EPIC-08"]})
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "outputs"
            plan.write_github_output(output, selection)
            values = dict(line.split("=", 1) for line in output.read_text(encoding="utf-8").splitlines())
        self.assertEqual(values["run_e2e"], "true")
        self.assertEqual(values["marker"], "smoke or core or epic_08")


if __name__ == "__main__":
    unittest.main()
