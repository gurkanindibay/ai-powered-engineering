"""Tests for the public-safe Cucumber pilot summary exporter."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "cucumber_pilot_report.py"
spec = importlib.util.spec_from_file_location("cucumber_pilot_report", SCRIPT)
reporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reporter)


class CucumberPilotReportTests(unittest.TestCase):
    def write_inputs(self, root: Path):
        junit = root / "junit.xml"
        executions = root / "executions.jsonl"
        secret = "SENSITIVE-TEST-VALUE-92741"
        junit.write_text(
            "<testsuites tests='5' failures='0' errors='0' skipped='0'>"
            + "".join(f"<testsuite><testcase name='{secret}-{index}'/></testsuite>" for index in range(5))
            + "</testsuites>", encoding="utf-8")
        records = []
        for scenario, example_row, _, _ in reporter.CASES:
            records.append(json.dumps({
                "scenario": scenario, "example_row": example_row, "status": "PASS", "duration_s": 1.25,
                "example": {"bank_code": secret}, "steps": [{"text": secret, "error": secret}],
                "error": secret, "transaction_id": secret,
            }))
        executions.write_text("\n".join(records) + "\n", encoding="utf-8")
        return junit, executions, secret

    def test_emits_five_allowlisted_cases_without_raw_fields(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            junit, executions, secret = self.write_inputs(root)
            result = reporter.build(junit, executions, "123456", "1", "a" * 40, "owner/repo")
            serialized = json.dumps(result)
            self.assertEqual(result["status"], "PASS")
            self.assertEqual(result["counts"]["tests"], 5)
            self.assertEqual([case["case_id"] for case in result["cases"]], [case[2] for case in reporter.CASES])
            self.assertEqual(result["cases"][-2]["example_id"], "SC-07-06-03-example-1")
            self.assertEqual(result["cases"][-1]["example_id"], "SC-07-06-03-example-2")
            self.assertIn("pytest remains authoritative", serialized)
            self.assertNotIn(secret, serialized)
            self.assertNotIn("steps", serialized)
            self.assertNotIn("transaction_id", serialized)

    def test_incomplete_inputs_are_not_counted_as_passes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result = reporter.build(root / "missing.xml", root / "missing.jsonl",
                                    "123456", "1", "b" * 40, "owner/repo")
            self.assertEqual(result["status"], "INCOMPLETE")
            self.assertEqual(result["counts"]["not_run"], 5)
            self.assertEqual(result["counts"]["passed"], 0)

    def test_rejects_non_numeric_run_identifiers(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaises(ValueError):
                reporter.build(root / "junit.xml", root / "executions.jsonl",
                               "run-123", "1", "c" * 40, "owner/repo")

    def test_workflow_retains_only_allowlisted_pilot_payload(self):
        workflow = (Path(__file__).resolve().parents[5] / ".github" / "workflows"
                    / "sitepulse-cucumber-pilot.yml").read_text(encoding="utf-8")
        self.assertIn("workflow_dispatch", workflow)
        self.assertIn("cucumber-pilot-results", workflow)
        self.assertIn("cucumber-results.json", workflow)
        self.assertNotIn("target/site/serenity", workflow)
        self.assertNotIn("cucumber-pilot-private.log\n          retention-days", workflow)


if __name__ == "__main__":
    unittest.main()
