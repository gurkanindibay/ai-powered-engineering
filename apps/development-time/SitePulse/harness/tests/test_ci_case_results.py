"""Adapters for CI case collection retain native identity and status."""
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from io import StringIO
from unittest import mock
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT_ROOT))
sys.path.insert(0, str(PROJECT_ROOT / "scripts"))
import ci_case_results as cases
import ci_suite_collection as suite_collection
from harness.loop import verification_gates as gates
import unittest_json_runner


class CaseAdapterTests(unittest.TestCase):
    def test_expected_manifest_includes_eight_shards_and_database_suite(self):
        manifest = cases.expected_suites()
        e2e = next(row for row in manifest if row["suite"] == "e2e")
        self.assertEqual(e2e["shards"], [f"{i}/8" for i in range(1, 9)])
        db = next(row for row in manifest if row["suite"] == "rust-db-test")
        self.assertEqual(db["shards"], ["rust-db-test"])

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

    def test_flutter_ids_include_file_path_and_malformed_json_is_ignored(self):
        output = "\n".join([
            "[]",
            json.dumps({"type": "suite", "suite": {"id": 1, "path": "flutter/test/one_test.dart"}}),
            json.dumps({"type": "suite", "suite": {"id": 2, "path": "flutter/test/two_test.dart"}}),
            json.dumps({"type": "testStart", "testID": 1, "suiteID": 1, "name": "same"}),
            json.dumps({"type": "testStart", "testID": 2, "suiteID": 2, "name": "same"}),
            json.dumps({"type": "testDone", "testID": 1, "name": "same", "result": "success", "time": "bad"}),
            json.dumps({"type": "testDone", "testID": 2, "name": "same", "result": "success", "time": "Infinity"}),
        ])
        parsed = cases.parse_flutter_json(output, "flutter-test")
        self.assertEqual([row["native_id"] for row in parsed], [
            "flutter/test/one_test.dart::same", "flutter/test/two_test.dart::same"])
        self.assertEqual([row["duration_s"] for row in parsed], [None, None])

    def test_junit_failure_and_error_elements_are_handled_and_bad_times_are_null(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "junit.xml"
            path.write_text('<testsuite><testcase classname="m" name="bad" time="nan"><failure message="no">trace</failure></testcase>'
                            '<testcase classname="m" name="err" time="oops"><error message="broken">trace</error></testcase></testsuite>')
            parsed = cases.parse_junit(path)
        self.assertEqual([row["status"] for row in parsed], ["failed", "error"])
        self.assertEqual([row["detail"] for row in parsed], ["no", "broken"])
        self.assertEqual([row["duration_s"] for row in parsed], [None, None])

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

    def test_missing_required_gate_evidence_is_reported_as_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            result = suite_collection.collect(root / "suites", root / "e2e", "42", "1", "abc")

        rust_gate = next(gate for gate in result["gates"] if gate["gate"] == "rust-test")
        rust_suite = next(suite for suite in result["suites"] if suite["suite"] == "rust")
        self.assertEqual(rust_gate["status"], "missing")
        self.assertEqual(rust_suite["status"], "missing")

    def test_failed_case_is_counted_as_failed_in_collection_totals(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            shard = root / "e2e" / "e2e-shard-1-attempt-1"
            shard.mkdir(parents=True)
            (shard / "collection.json").write_text(json.dumps({
                "shard": "1/8", "run_id": "42", "attempt": "1", "commit": "abc",
                "job_result": "failure",
            }), encoding="utf-8")
            (shard / "junit.xml").write_text(
                '<testsuite tests="1"><testcase classname="suite" name="broken">'
                '<failure message="expected failure" /></testcase></testsuite>',
                encoding="utf-8",
            )
            result = suite_collection.collect(root / "suites", root / "e2e", "42", "1", "abc")

        self.assertEqual(result["case_totals"], {"passed": 0, "failed": 1, "skipped": 0, "error": 0})


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
            self.assertNotIn("native_output", record)

    def test_sidecar_write_failure_does_not_change_native_gate_outcome(self):
        result = gates.GateResult("fake", True, [], "fake", 0.1, 0, output="ok", stdout="ok")
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(os.environ, {"SITEPULSE_GATE_ARTIFACT_DIR": tmp}), \
                mock.patch.object(Path, "write_text", side_effect=OSError("disk full")):
            gates._write_gate_artifacts("fake", [gates.CommandSpec(["fake"], ".")], [result], Path(tmp))
        self.assertTrue(result.passed)
        self.assertEqual(result.exit_code, 0)

    def test_unittest_sidecar_failure_keeps_success_exit_status(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(Path, "write_text", side_effect=OSError("disk full")):
            stderr = StringIO()
            with redirect_stderr(stderr):
                code = unittest_json_runner.main(["-s", tmp, "--json-output", str(Path(tmp) / "results.json")])
        self.assertEqual(code, 0)
        self.assertIn("evidence collection warning", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
