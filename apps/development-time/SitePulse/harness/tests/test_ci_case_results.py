"""Adapters for CI case collection retain native identity and status."""
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT_ROOT))
sys.path.insert(0, str(PROJECT_ROOT / "scripts"))
import ci_case_results as cases
from harness.loop import verification_gates as gates


class CaseAdapterTests(unittest.TestCase):
    def test_expected_manifest_includes_eight_shards_and_opt_in_database_cases(self):
        manifest = cases.expected_suites()
        e2e = next(row for row in manifest if row["suite"] == "e2e")
        self.assertEqual(e2e["shards"], [f"{i}/8" for i in range(1, 9)])
        db = next(row for row in manifest if row["suite"] == "rust-db-opt-in")
        self.assertEqual(len(db["shards"]), 2)

    def test_cargo_parser_keeps_doctest_names_and_ignored_status(self):
        output = """Running unittests src/lib.rs (target/debug/deps/sitepulse)
running 2 tests
test payment::works ... ok
test payment::slow ... ignored, needs database
test result: ok. 1 passed; 0 failed; 1 ignored; 0 measured; 0 filtered out
Doc-tests sitepulse
test src/lib.rs - amount (line 18) ... ok
test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out
"""
        parsed = cases.parse_cargo(output, "rust")
        self.assertEqual([(row["native_id"], row["status"]) for row in parsed], [
            ("lib::payment::works", "passed"), ("lib::payment::slow", "skipped"),
            ("doc-sitepulse::src/lib.rs - amount (line 18)", "passed")])
        self.assertEqual(cases.native_totals(output, "cargo"), {"passed": 2, "failed": 0, "skipped": 1})

    def test_flutter_parser_maps_results_and_runner_error(self):
        output = "\n".join([
            json.dumps({"type": "testStart", "test": {"id": 1, "name": "widget test"}}),
            json.dumps({"type": "testDone", "testID": 1, "name": "widget test", "result": "success", "time": 12}),
            json.dumps({"type": "testStart", "test": {"id": 2, "name": "skipped test"}}),
            json.dumps({"type": "testDone", "testID": 2, "result": "success", "skipped": True, "time": 0}),
            json.dumps({"type": "error", "error": "bad setup"}),
            json.dumps({"type": "done", "testCount": 2}),
        ])
        parsed = cases.parse_flutter_json(output, "flutter-test")
        self.assertEqual([row["status"] for row in parsed], ["passed", "skipped"])
        self.assertEqual(cases.flutter_reporter_errors(output), ["bad setup"])
        self.assertEqual(cases.native_totals(output, "flutter"), {"total": 2, "complete": True})

    def test_unittest_parser_retains_fail_error_and_skip(self):
        output = """test_a (module.Case.test_a) ... ok
test_b (module.Case.test_b) ... skipped (not supported)
test_c (module.Case.test_c) ... FAIL
test_d (module.Case.test_d) ... ERROR
Ran 4 tests in 0.100s
"""
        parsed = cases.parse_unittest_verbose(output, "harness-selftest")
        self.assertEqual([row["status"] for row in parsed], ["passed", "skipped", "failed", "error"])

    def test_api_and_schema_json_rows_become_cases(self):
        parsed = cases.parse_check_json({"checks": [{"name": "ok", "passed": True},
                                                     {"name": "failed", "passed": False}]}, "check", "api")
        self.assertEqual([row["status"] for row in parsed], ["passed", "failed"])

    def test_junit_rows_include_parameterized_names_and_skips(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "junit.xml"
            path.write_text('<testsuite><testcase classname="module" name="case[param=1]" time="0.2" />'
                            '<testcase classname="module" name="case[param=2]"><skipped /></testcase></testsuite>')
            parsed = cases.parse_junit(path)
        self.assertEqual([row["native_id"] for row in parsed], ["module::case[param=1]", "module::case[param=2]"])
        self.assertEqual([row["status"] for row in parsed], ["passed", "skipped"])


class GateCaptureTests(unittest.TestCase):
    def test_process_exit_code_is_preserved_in_gate_and_artifact(self):
        with tempfile.TemporaryDirectory() as tmp:
            artifact_dir = Path(tmp) / "artifacts"
            previous = os.environ.get("SITEPULSE_GATE_ARTIFACT_DIR")
            os.environ["SITEPULSE_GATE_ARTIFACT_DIR"] = str(artifact_dir)
            try:
                result = gates.run_command("fake", gates.CommandSpec(
                    [sys.executable, "-c", "import sys; print('captured'); sys.exit(7)"], ".", 10), Path(tmp))
                gates._write_gate_artifacts("fake", [gates.CommandSpec(["python"], ".")], [result], Path(tmp))
            finally:
                if previous is None:
                    os.environ.pop("SITEPULSE_GATE_ARTIFACT_DIR", None)
                else:
                    os.environ["SITEPULSE_GATE_ARTIFACT_DIR"] = previous
            self.assertFalse(result.passed)
            self.assertEqual(result.exit_code, 7)
            record = json.loads((artifact_dir / "fake-1.json").read_text())
            self.assertEqual(record["exit_code"], 7)
            self.assertIn("captured", record["native_output"])


if __name__ == "__main__":
    unittest.main()
