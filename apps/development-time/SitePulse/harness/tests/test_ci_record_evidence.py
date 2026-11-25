"""The master-only `record-evidence` job must be able to pass every DAG task.

It never runs on a PR, so these tests catch on the PR what would otherwise only fail after merge:
a gate tool the job does not install, or an acceptance test CI can never produce evidence for.
"""
import json
import os
import re
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

PROJECT_ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = PROJECT_ROOT.parents[2] / ".github" / "workflows" / "sitepulse-ci.yml"
sys.path.insert(0, str(PROJECT_ROOT / "scripts"))

import feature_traceability as ft  # noqa: E402
import unittest_json_runner  # noqa: E402


def _job(name: str) -> str:
    match = re.search(rf"(?ms)^  {name}:\n(.*?)(?=^  [a-z][a-z0-9-]*:\n|\Z)", WORKFLOW.read_text(encoding="utf-8"))
    assert match, f"job {name} not found"
    return match.group(1)


class RecordEvidenceJobTools(unittest.TestCase):
    def test_installs_the_same_nextest_as_the_gate_jobs(self):
        pins = {job: re.findall(r"tool: (cargo-nextest@\S+)", _job(job))
                for job in ("rust", "flutter", "record-evidence")}
        self.assertEqual(pins["record-evidence"], pins["rust"], pins)
        self.assertEqual(pins["flutter"], pins["rust"], pins)

    def test_runs_on_the_same_python_as_the_gate_jobs(self):
        pattern = r'python-version: "([^"]+)"'
        self.assertEqual(re.findall(pattern, _job("record-evidence")), re.findall(pattern, _job("lint")))


class ScenarioAcceptanceTestsAreRecordableInCi(unittest.TestCase):
    def test_every_scenario_gate_can_get_a_ci_execution_record(self):
        """A `scenario:` gate reads CI's execution history, which only the browser lanes write."""
        catalogue = ft.load_catalogue()
        scenarios = {s.id: s for s in catalogue.scenarios}
        dag = json.loads((PROJECT_ROOT / ".specify" / "tasks" / "task-dag.json").read_text(encoding="utf-8"))
        unrecordable = []
        for task in dag["tasks"]:
            for test_id in task.get("acceptance_tests", []):
                if not test_id.startswith("scenario:"):
                    continue
                scenario = scenarios[test_id.removeprefix("scenario:")]
                browser = scenario.mode == "gherkin" or any(
                    link["file"].startswith("e2e/") for link in catalogue.links.get(scenario.id, []))
                if scenario.mode == "pending" or not browser:
                    unrecordable.append(f"{task['id']} {test_id}")
        self.assertEqual(unrecordable, [], "name the covering test directly (flutter:/rust:/system:) instead")


class NestedDiscovery(unittest.TestCase):
    def test_json_runner_does_not_reuse_the_shared_loader(self):
        """On Python 3.12.3 the shared loader keeps the outer run's top-level directory."""
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(unittest.defaultTestLoader, "discover", side_effect=AssertionError("shared")):
            code = unittest_json_runner.main(["-s", tmp, "--json-output", str(Path(tmp) / "results.json")])
        self.assertEqual(code, 0)


if __name__ == "__main__":
    unittest.main()
