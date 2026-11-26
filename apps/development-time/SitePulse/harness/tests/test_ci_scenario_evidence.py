"""Named scenario evidence preserves test identity and run provenance."""
from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location("ci_scenario_evidence", SCRIPTS / "ci_scenario_evidence.py")
cse = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cse)


class ScenarioEvidenceTest(unittest.TestCase):
    def test_same_commit_failed_skipped_stale_and_missing_outcomes(self):
        commit = "a" * 40
        scenarios = {f"SC-01-01-{index:02d}": {"state": "no_result"} for index in range(1, 6)}
        links = {
            scenario_id: [{"file": "tests/test_nightly_scenarios.py", "test": name}]
            for scenario_id, name in zip(scenarios, ("test_pass", "test_failure", "test_skip", "test_stale", "test_missing"))
        }
        cases = [
            {"producer": "pytest-playwright", "suite": "e2e", "native_id":
             "tests/test_nightly_scenarios.py::test_pass", "status": "passed"},
            {"producer": "pytest-playwright", "suite": "e2e", "native_id":
             "tests/test_nightly_scenarios.py::test_failure", "status": "failed"},
            {"producer": "pytest-playwright", "suite": "e2e", "native_id":
             "tests/test_nightly_scenarios.py::test_skip", "status": "skipped"},
            {"producer": "pytest-playwright", "suite": "e2e", "native_id":
             "tests/test_nightly_scenarios.py::test_stale", "status": "passed", "tested_commit": "b" * 40},
        ]
        report = cse.build_evidence(
            scenarios, cases, links, "12345", commit, "2", "https://github.com/owner/repo/actions/runs/12345")

        self.assertEqual(report["scenarios"]["SC-01-01-01"]["evidence"], "passing")
        self.assertEqual(report["scenarios"]["SC-01-01-02"]["evidence"], "failing")
        self.assertEqual(report["scenarios"]["SC-01-01-03"]["evidence"], "skipped")
        stale = report["scenarios"]["SC-01-01-04"]
        self.assertEqual(stale["evidence"], "historical")
        self.assertEqual(stale["cases"][0]["test_status"], "passing")
        self.assertEqual(report["scenarios"]["SC-01-01-05"]["evidence"], "scheduled")
        passed = report["scenarios"]["SC-01-01-01"]["cases"][0]
        self.assertEqual(passed["test_name"], "test_pass")
        self.assertEqual(passed["workflow_run"], "https://github.com/owner/repo/actions/runs/12345")
        self.assertEqual(passed["attempt"], "2")
        self.assertEqual(passed["tested_commit"], commit)


if __name__ == "__main__":
    unittest.main()
