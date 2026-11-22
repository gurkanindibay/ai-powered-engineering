"""CI suite selection exposes missing evidence, retries and native count drift."""
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import ci_suite_collection as collection


class SuiteCollectionTests(unittest.TestCase):
    def test_selects_latest_attempt_and_marks_unavailable_shards(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            suites, e2e = tmp / "suites", tmp / "e2e"
            old = suites / "sitepulse-suite-rust-attempt-1"
            gates = old / "gates"
            gates.mkdir(parents=True)
            (old / "producer.json").write_text(json.dumps({"job": "rust", "run_id": "42", "attempt": "1",
                                                            "commit": "abc", "job_result": "success"}))
            (gates / "rust-test-1.json").write_text(json.dumps({
                "gate": "rust-test", "passed": True, "duration_s": 4.0, "exit_code": 0,
                "argv": ["cargo", "test"], "adapter_case_count": 1,
                "native_runner_totals": {"passed": 1, "failed": 0, "skipped": 0},
                "cases": [{"runner": "cargo", "suite": "rust", "native_id": "unit::works",
                           "status": "passed", "duration_s": None}]}))
            shard = e2e / "e2e-shard-1-attempt-1"
            shard.mkdir(parents=True)
            (shard / "collection.json").write_text(json.dumps({"shard": "1/8", "run_id": "42", "attempt": "1",
                                                                "commit": "abc", "job_result": "success"}))
            (shard / "junit.xml").write_text('<testsuite><testcase classname="tests.test_demo" name="case[param=x]" time="0.1"/></testsuite>')
            (shard / "executions.jsonl").write_text(json.dumps({"test": "tests.test_demo::case[param=x]", "scenario": "SC-01-02-03"}) + "\n")

            report = collection.collect(suites, e2e, "42", "2", "abc", {"rust": "skipped", "e2e": "skipped"})

        self.assertEqual(report["producers"]["rust"]["attempt"], "1")
        self.assertTrue(any(row["suite"] == "rust" and row["status"] == "reused" for row in report["suites"]))
        e2e_status = next(row for row in report["suites"] if row["suite"] == "e2e")
        self.assertEqual(e2e_status["status"], "incomplete")
        self.assertEqual(len(e2e_status["missing_shards"]), 7)
        browser_case = next(row for row in report["cases"] if row["runner"] == "pytest-playwright")
        self.assertEqual(browser_case["scenario_ids"], ["SC-01-02-03"])
        self.assertEqual(browser_case["parameter_id"], "param=x")
        self.assertEqual(report["unique_case_count"], report["case_count"])
        cargo_gate = next(row for row in report["gates"] if row["gate"] == "rust-test")
        self.assertTrue(cargo_gate["count_parity"][0])

    def test_duplicate_cases_are_preserved_as_attempts_but_not_unique_ids(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "sitepulse-suite-lint-attempt-1"
            gates = source / "gates"
            gates.mkdir(parents=True)
            (source / "producer.json").write_text(json.dumps({"job": "lint", "run_id": "42", "attempt": "1",
                                                               "commit": "abc", "job_result": "success"}))
            (gates / "harness-selftest-1.json").write_text(json.dumps({"gate": "harness-selftest", "passed": True,
                "duration_s": 1, "exit_code": 0, "cases": [
                    {"runner": "unittest", "suite": "harness-selftest", "native_id": "test_case", "status": "passed"},
                    {"runner": "unittest", "suite": "harness-selftest", "native_id": "test_case", "status": "failed"}]}))
            report = collection.collect(root, root / "missing-e2e", "42", "1", "abc", {"lint": "success"})
        self.assertEqual(report["case_count"], 2)
        self.assertEqual(report["unique_case_count"], 1)
        self.assertEqual([row["attempt_index"] for row in report["cases"]], [1, 2])

    def test_cancelled_not_run_and_missing_inputs_are_distinct(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            report = collection.collect(root / "suites", root / "e2e", "42", "1", "abc",
                                        {"e2e": "cancelled", "lint": "skipped", "rust": "success"})
        self.assertEqual(next(row for row in report["suites"] if row["suite"] == "e2e")["status"], "cancelled")
        self.assertEqual(next(row for row in report["suites"] if row["suite"] == "harness-selftest")["status"], "not-run")
        self.assertEqual(next(row for row in report["suites"] if row["suite"] == "rust")["status"], "missing")
        self.assertEqual(next(row for row in report["gates"] if row["gate"] == "gui-e2e")["status"], "cancelled")


if __name__ == "__main__":
    unittest.main()
