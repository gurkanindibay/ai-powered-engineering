"""Tests for the public-safe Cucumber pilot summary exporter."""
import importlib.util
import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "cucumber_pilot_report.py"
spec = importlib.util.spec_from_file_location("cucumber_pilot_report", SCRIPT)
reporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reporter)


class CucumberPilotReportTests(unittest.TestCase):
    def write_inputs(self, root: Path):
        junit = root / "junit.xml"
        executions = root / "executions.jsonl"
        fixture_marker = "fixture-marker-92741"
        junit.write_text(
            "<testsuites tests='5' failures='0' errors='0' skipped='0'>"
            + "".join(f"<testsuite><testcase name='{fixture_marker}-{index}'/></testsuite>" for index in range(5))
            + "</testsuites>", encoding="utf-8")
        records = []
        for scenario, example_row, _, _ in reporter.CASES:
            records.append(json.dumps({
                "scenario": scenario, "example_row": example_row, "status": "PASS", "duration_s": 1.25,
                "example": {"bank_code": fixture_marker}, "steps": [{"text": fixture_marker, "error": fixture_marker}],
                "error": fixture_marker, "transaction_id": fixture_marker,
            }))
        executions.write_text("\n".join(records) + "\n", encoding="utf-8")
        return junit, executions, fixture_marker

    def test_emits_five_allowlisted_cases_without_raw_fields(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            junit, executions, fixture_marker = self.write_inputs(root)
            result = reporter.build(junit, executions, "123456", "1", "a" * 40, "owner/repo")
            serialized = json.dumps(result)
            self.assertEqual(result["status"], "PASS")
            self.assertEqual(result["counts"]["tests"], 5)
            self.assertEqual([case["case_id"] for case in result["cases"]], [case[2] for case in reporter.CASES])
            self.assertEqual(result["cases"][-2]["example_id"], "SC-07-06-03-example-1")
            self.assertEqual(result["cases"][-1]["example_id"], "SC-07-06-03-example-2")
            self.assertIn("pytest remains authoritative", serialized)
            self.assertNotIn(fixture_marker, serialized)
            self.assertNotIn("steps", serialized)
            self.assertNotIn("transaction_id", serialized)

    def test_pages_schema_adapter_is_comparison_only_and_allowlisted(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            junit, executions, fixture_marker = self.write_inputs(root)
            result = reporter.build(junit, executions, "123456", "1", "a" * 40, "owner/repo")

            public = reporter.public_report_from_result(result)

            self.assertEqual(public["schema"], 1)
            self.assertEqual(len(public["gates"]), 1)
            self.assertIn("comparison-only", public["gates"][0]["name"])
            self.assertIn("pytest remains authoritative", public["gates"][0]["name"])
            self.assertEqual(public["gates"][0]["status"], "PASS")
            self.assertEqual([case["id"] for case in public["cases"]], [case[2] for case in reporter.CASES])
            self.assertEqual(public["cases"][0]["scenario_id"], "SC-10-01-01")
            self.assertEqual(public["cases"][0]["duration_seconds"], 1.25)
            self.assertEqual(set(public["cases"][0]), {"id", "name", "status", "duration_seconds", "scenario_id"})
            self.assertNotIn(fixture_marker, json.dumps(public))

    def test_pages_schema_adapter_preserves_incomplete_statuses(self):
        result = {
            "status": "INCOMPLETE",
            "duration_s": 1.0,
            "cases": [{
                "case_id": case_id, "scenario_id": scenario, "label": label,
                "status": "NOT_RUN", "duration_s": 0.0,
            } for scenario, _row, case_id, label in reporter.CASES],
        }

        public = reporter.public_report_from_result(result)

        self.assertEqual(public["gates"][0]["status"], "INCOMPLETE")
        self.assertTrue(all(case["status"] == "NOT RUN" for case in public["cases"]))

    def test_cli_writes_distinct_allowlisted_public_report(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            junit, executions, fixture_marker = self.write_inputs(root)
            output = root / "cucumber-results.json"
            public_output = root / "public-report.json"
            with redirect_stdout(io.StringIO()):
                result = reporter.main([
                    "--junit", str(junit), "--executions", str(executions),
                    "--run-id", "123456", "--attempt", "1", "--commit", "a" * 40,
                    "--repository", "owner/repo", "--out", str(output),
                    "--public-out", str(public_output),
                ])

            self.assertEqual(result, 0)
            safe_summary = json.loads(output.read_text(encoding="utf-8"))
            public_report = json.loads(public_output.read_text(encoding="utf-8"))
            self.assertEqual(safe_summary["authority"], "comparison-only")
            self.assertEqual(public_report["schema"], 1)
            self.assertNotIn(fixture_marker, output.read_text(encoding="utf-8"))
            self.assertNotIn(fixture_marker, public_output.read_text(encoding="utf-8"))

    def test_cli_validates_both_payloads_before_writing_either(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            junit, executions, _ = self.write_inputs(root)
            output = root / "cucumber-results.json"
            public_output = root / "public-report.json"
            args = ["--junit", str(junit), "--executions", str(executions),
                    "--run-id", "123456", "--attempt", "1", "--commit", "a" * 40,
                    "--repository", "owner/repo", "--out", str(output),
                    "--public-out", str(public_output)]
            with mock.patch.object(reporter, "public_report_from_result", side_effect=ValueError("invalid")):
                with redirect_stderr(io.StringIO()):
                    result = reporter.main(args)

            self.assertEqual(result, 1)
            self.assertFalse(output.exists())
            self.assertFalse(public_output.exists())

    def test_cli_writes_only_safe_failure_diagnostics_to_job_summary(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            junit, executions, fixture_marker = self.write_inputs(root)
            junit_text = junit.read_text(encoding="utf-8")
            junit.write_text(junit_text.replace(
                f"name='{fixture_marker}-0'/>", f"name='{fixture_marker}-0'><failure/></testcase>", 1),
                encoding="utf-8")
            records = [json.loads(line) for line in executions.read_text(encoding="utf-8").splitlines()]
            records[0]["status"] = "FAIL"
            executions.write_text("\n".join(json.dumps(record) for record in records) + "\n", encoding="utf-8")
            summary = root / "step-summary.md"
            args = ["--junit", str(junit), "--executions", str(executions),
                    "--run-id", "123456", "--attempt", "1", "--commit", "a" * 40,
                    "--repository", "owner/repo", "--out", str(root / "cucumber-results.json"),
                    "--public-out", str(root / "public-report.json"), "--pilot-exit-code", "23"]
            with mock.patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": str(summary)}):
                with redirect_stdout(io.StringIO()):
                    result = reporter.main(args)

            safe_summary = summary.read_text(encoding="utf-8")
            self.assertEqual(result, 0)
            self.assertIn("SC-10-01-01", safe_summary)
            self.assertIn("Pilot process exit code: `23`", safe_summary)
            self.assertNotIn(fixture_marker, safe_summary)

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

    def test_invalid_jsonl_shapes_and_values_become_incomplete(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            junit, executions, _ = self.write_inputs(root)
            invalid_records = (
                "[]",
                "null",
                json.dumps({"scenario": "SC-07-06-03", "example_row": [], "duration_s": 1}),
                json.dumps({"scenario": "SC-10-01-01", "duration_s": float("nan")}),
                json.dumps({"scenario": "SC-10-01-01", "duration_s": float("inf")}),
            )
            for invalid_record in invalid_records:
                with self.subTest(record=invalid_record):
                    executions.write_text(invalid_record + "\n", encoding="utf-8")
                    result = reporter.build(junit, executions, "123456", "1", "d" * 40, "owner/repo")
                    self.assertEqual(result["status"], "INCOMPLETE")
                    self.assertEqual(result["counts"]["passed"], 0)

    def test_malformed_record_preserves_valid_case_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            junit, executions, _ = self.write_inputs(root)
            with executions.open("a", encoding="utf-8") as stream:
                stream.write("{malformed json}\n")

            result = reporter.build(junit, executions, "123456", "1", "e" * 40, "owner/repo")

            self.assertEqual(result["status"], "INCOMPLETE")
            self.assertEqual(result["counts"]["passed"], 5)
            self.assertEqual(result["counts"]["not_run"], 0)
            self.assertTrue(all(case["status"] == "PASS" for case in result["cases"]))

    def test_workflow_retains_only_allowlisted_pilot_payload(self):
        workflow = (Path(__file__).resolve().parents[5] / ".github" / "workflows"
                    / "sitepulse-cucumber-pilot.yml").read_text(encoding="utf-8")
        self.assertIn("workflow_dispatch", workflow)
        self.assertIn("cucumber-pilot-results", workflow)
        self.assertIn("cucumber-results.json", workflow)
        self.assertIn("public-report.json", workflow)
        self.assertIn("PILOT_EXIT_CODE=$pilot_exit_code", workflow)
        self.assertNotIn("target/site/serenity", workflow)
        self.assertNotIn("cucumber-pilot-private.log\n          retention-days", workflow)


if __name__ == "__main__":
    unittest.main()
