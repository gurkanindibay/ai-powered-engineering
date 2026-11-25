import json
import sys
import tempfile
import unittest
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT_ROOT / "scripts"))

import serenity_report as serenity  # noqa: E402

FEATURE = """@EPIC-01 @STORY-01-01
Feature: Dues

  @SC-01-01-01 @layer:gui
  Scenario: Executed
    Given a debt of 10.00
    Then it is shown

  @SC-01-01-02 @linked
  Scenario: Linked
    Given a rule

  # Pending: waits for the provider
  @SC-01-01-03 @pending
  Scenario: Planned
    Given a provider

  @SC-01-01-04
  Scenario: Unmatched
    Given nothing
"""
SECRET = "Resident Jane Doe jane@example.test"


def _run(status, steps, **extra):
    return {"scenario": "SC-01-01-01", "binding": "gherkin", "status": status, "duration_s": 1.5,
            "test": "tests/test_features.py::test_x[chromium]", "error": "", "steps": steps, **extra}


class SerenityReportTests(unittest.TestCase):
    def _convert(self, evidence_rows, executions):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        features = root / "app/.specify/features/EPIC-01"
        features.mkdir(parents=True)
        (features / "STORY-01-01-dues.feature").write_text(FEATURE, encoding="utf-8")
        requirements = root / "app/.specify/requirements"
        requirements.mkdir()
        (requirements / "EPIC-01-dues.md").write_text("# Epic: Dues\n\n### STORY-01-01: Balance\n", encoding="utf-8")
        artifact = root / "artifact"
        artifact.mkdir()
        (artifact / "scenario-evidence.json").write_text(
            json.dumps({"run_id": "20260101T101500Z-abc1234", "scenarios": evidence_rows}), encoding="utf-8")
        (artifact / "executions.jsonl").write_text(
            "".join(json.dumps(r) + "\n" for r in executions), encoding="utf-8")
        summary = serenity.convert(artifact, root / "out", root / "app")
        outcomes = [json.loads(p.read_text(encoding="utf-8")) for p in (root / "out").glob("*.json")]
        return summary, {o["methodName"].upper(): o for o in outcomes}

    def test_every_catalogue_scenario_is_reported_with_its_evidence(self):
        rows = {"SC-01-01-01": {"evidence": "passing"},
                "SC-01-01-02": {"evidence": "passing", "cases": [
                    {"suite": "rust-test", "native_id": "dues::rounds", "status": "passing"}]},
                "SC-01-01-03": {"evidence": "planned"}}
        steps = [{"keyword": "Given", "text": "a debt of 10.00", "status": "PASS", "duration_s": 0.5}]
        linked = {**_run("PASS", []), "scenario": "SC-01-01-02", "binding": "linked", "duration_s": 9}

        summary, outcomes = self._convert(rows, [_run("PASS", steps), linked])

        self.assertEqual(summary["scenarios"], 4)
        self.assertEqual(summary["results"], {"IGNORED": 1, "PENDING": 1, "SUCCESS": 2})
        self.assertEqual(summary["with_gherkin_steps"], 1)
        executed = outcomes["SC-01-01-01"]
        self.assertEqual([s["description"] for s in executed["testSteps"]], ["Given a debt of 10.00"])
        self.assertEqual(executed["duration"], 1500)
        self.assertEqual(executed["startTime"], "2026-01-01T10:15:00.000Z")
        self.assertEqual(executed["userStory"]["pathElements"][0]["name"], "EPIC-01 Dues")
        other = outcomes["SC-01-01-02"]
        self.assertEqual([s["description"] for s in other["testSteps"]], ["[rust-test] dues::rounds"])
        self.assertEqual(other["duration"], 0, "a linked test's time is not counted per scenario")
        self.assertIn("not executed one by one", other["description"])
        self.assertIn("waits for the provider", outcomes["SC-01-01-03"]["description"])
        self.assertEqual(outcomes["SC-01-01-04"]["result"], "IGNORED")
        self.assertIn({"name": "unresolved", "type": "evidence", "displayName": "unresolved"},
                      outcomes["SC-01-01-04"]["tags"])

    def test_failure_is_reported_without_the_raw_error_text(self):
        error = f"AssertionError: {SECRET}"
        steps = [{"keyword": "Then", "text": "it is shown", "status": "FAIL", "error": error}]
        rows = {"SC-01-01-01": {"evidence": "passing"}}

        _, outcomes = self._convert(rows, [_run("FAIL", steps, error=error)])

        failed = outcomes["SC-01-01-01"]
        self.assertEqual(failed["result"], "FAILURE")
        self.assertEqual(failed["testFailureClassname"], "AssertionError")
        self.assertEqual(failed["testSteps"][0]["exception"]["errorType"], "AssertionError")
        self.assertNotIn("Jane", json.dumps(failed))

    def test_outline_rows_are_grouped_and_numbered(self):
        step = {"keyword": "Given", "text": "a row", "status": "PASS"}
        runs = [_run("PASS", [step], example_id=f"SC-01-01-01[{n}]") for n in (1, 2)]

        _, outcomes = self._convert({"SC-01-01-01": {"evidence": "passing"}}, runs)

        groups = outcomes["SC-01-01-01"]["testSteps"]
        self.assertEqual([g["description"] for g in groups], ["SC-01-01-01[1]", "SC-01-01-01[2]"])
        self.assertEqual([groups[0]["number"], groups[0]["children"][0]["number"], groups[1]["number"]], [1, 2, 3])

    def test_known_defect_is_not_reported_as_passed(self):
        _, outcomes = self._convert({"SC-01-01-01": {"evidence": "passing"}}, [_run("DEFECT", [])])

        self.assertEqual(outcomes["SC-01-01-01"]["result"], "PENDING")

    def test_missing_evidence_file_is_an_error(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaises(ValueError):
                serenity.convert(Path(temporary), Path(temporary) / "out")


if __name__ == "__main__":
    unittest.main()
