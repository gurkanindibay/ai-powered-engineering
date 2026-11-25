"""scripts/ci_test_report.py: merges CI e2e shard results into one report without touching the history."""
import importlib.util
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location("ci_test_report", ROOT / "scripts" / "ci_test_report.py")
ctr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ctr)
evidence_spec = importlib.util.spec_from_file_location("ci_scenario_evidence", ROOT / "scripts" / "ci_scenario_evidence.py")
cse = importlib.util.module_from_spec(evidence_spec)
evidence_spec.loader.exec_module(cse)


def _record(scenario: str, status: str) -> dict:
    return {"epic": "EPIC-06", "story": "STORY-06-06", "scenario": scenario, "name": scenario, "binding": "linked",
            "layer": "gui", "feature_file": "", "test": f"tests/demo.py::{scenario}", "status": status,
            "duration_s": 1.5, "steps": [], "error": "", "gui_ids": []}


class CiTestReportTest(unittest.TestCase):
    def test_counts_tests_with_ignored_webkit_page_errors(self):
        with tempfile.TemporaryDirectory() as tmp:
            counted = Path(tmp) / "counted.xml"
            counted.write_text(
                '<?xml version="1.0"?><testsuite tests="1"><testcase name="one"><properties>'
                '<property name="ignored_page_errors" value="pageerror: &lt;empty message: x&gt;" />'
                '</properties></testcase></testsuite>', encoding="utf-8")
            blank = Path(tmp) / "blank.xml"
            blank.write_text(
                '<?xml version="1.0"?><testsuite tests="1"><testcase name="two"><properties>'
                '<property name="ignored_page_errors" value="" /></properties></testcase></testsuite>',
                encoding="utf-8")
            broken = Path(tmp) / "broken.xml"
            broken.write_text("<not-xml", encoding="utf-8")

            self.assertEqual(ctr.junit_ignored_page_errors([counted, blank, broken]), 1)

    def test_scenario_evidence_distinguishes_ci_outcomes_scheduled_and_unresolved(self):
        scenarios = {sid: {"state": "no_result"} for sid in
                     ("SC-01-01-01", "SC-01-01-02", "SC-01-01-03", "SC-01-01-04",
                      "SC-01-01-06", "SC-01-01-07")}
        scenarios["SC-01-01-05"] = {"state": "planned"}
        links = {
            "SC-01-01-01": [{"file": "backend/tests/example.rs", "line": 1, "test": "works"}],
            "SC-01-01-02": [{"file": "backend/tests/example.rs", "line": 2, "test": "fails"}],
            "SC-01-01-03": [{"file": "e2e/nightly/test_later.py", "line": 3, "test": "test_later"}],
            "SC-01-01-04": [{"file": "harness/tests/test_missing.py", "line": 4,
                             "test": "missing | `case`"}],
            "SC-01-01-06": [{"file": "flutter/test/people_widget_test.dart", "line": 6,
                             "test": "Resident detail"}],
            "SC-01-01-07": [{"file": "harness/tests/test_people.py", "line": 7,
                             "test": "test_disable"}],
        }
        cases = [
            {"producer": "rust", "suite": "rust-test", "native_id": "example::works", "status": "passed"},
            {"producer": "rust", "suite": "rust-test", "native_id": "example::fails", "status": "failed"},
            {"producer": "flutter", "suite": "flutter-test",
             "native_id": "flutter/test/people_widget_test.dart::Resident details show occupancy", "status": "passed"},
            {"producer": "lint", "suite": "harness-selftest",
             "native_id": "test_people.PersonTests.test_disable", "status": "passed"},
        ]

        report = cse.build_evidence(scenarios, cases, links, "run-1", "commit-1")

        self.assertEqual(report["evidence_counts"],
                         {"failing": 1, "passing": 2, "planned": 1, "scheduled": 1, "unresolved": 2})
        self.assertEqual(report["scenarios"]["SC-01-01-03"]["evidence"], "scheduled")
        self.assertEqual(report["scenarios"]["SC-01-01-04"]["evidence"], "unresolved")
        self.assertEqual(report["scenarios"]["SC-01-01-06"]["evidence"], "unresolved")
        self.assertEqual(report["scenarios"]["SC-01-01-07"]["evidence"], "passing")
        self.assertIn(r"missing \| \`case\`", cse.render_markdown(report))
        self.assertEqual({item["scenario_id"] for item in report["unresolved_links"]},
                         {"SC-01-01-04", "SC-01-01-06"})

    def test_long_case_names_match_while_published_outputs_stay_sanitized(self):
        test_name = ("when_a_tenant_pays_owner_capital_dues_then_the_receipt_cites_the_statute_and_a_rent_"
                     "certificate_is_issued")
        native_id = f"sitepulse-backend::it::long_name_tests::{test_name}"
        parameterized = "tests.test_private.test_private_value[resident@example.com]"
        self.assertGreater(len(test_name), 100)
        links = {"SC-06-06-01": [{"file": "backend/tests/long_name_tests.rs", "line": 1, "test": test_name}],
                 "SC-06-06-02": [{"file": "harness/tests/test_private.py", "line": 1,
                                  "test": "test_private_value"}]}
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            producer = tmp / "artifacts" / "sitepulse-suite-rust-attempt-1"
            (producer / "gates").mkdir(parents=True)
            (producer / "producer.json").write_text(json.dumps(
                {"job": "rust", "run_id": "42", "attempt": "1", "commit": "abc", "job_result": "success"}))
            (producer / "gates" / "rust-test.json").write_text(json.dumps({
                "gate": "rust-test", "passed": True, "exit_code": 0, "cases": [
                    {"runner": "cargo-test", "suite": "rust-test", "native_id": name, "status": "passed"}
                    for name in (native_id, parameterized)]}))
            out = tmp / "out"
            with mock.patch.object(ctr.scenario_evidence, "named_links", return_value=links):
                ctr.build(tmp / "artifacts", out, None, tmp / "history", run_id="42", attempt="1",
                          suite_artifacts=tmp / "artifacts", commit_override="abc")

            report = json.loads((out / "scenario-evidence.json").read_text(encoding="utf-8"))
            for scenario_id in links:
                self.assertEqual(report["scenarios"][scenario_id]["evidence"], "passing", scenario_id)
            published = [case["native_id"] for row in report["scenarios"].values() for case in row["cases"]]
            # Over the 120-character label limit a name is replaced; a parameter suffix is cut.
            self.assertEqual(sorted(published), ["test case", "tests.test_private.test_private_value"])
            for name in ("scenario-evidence.json", "scenario-evidence.md", "feature-report.html",
                         "public-report.json"):
                text = (out / name).read_text(encoding="utf-8")
                self.assertNotIn(native_id, text, name)
                self.assertNotIn(native_id[:101], text, name)
                self.assertNotIn("resident@example.com", text, name)

    def test_interpolated_titles_and_api_check_ids_match_only_their_own_cases(self):
        title = "Owner details cannot change occupancy for $status"
        prefix = "flutter/test/owners_test.dart::Owners Owner details cannot change occupancy for "
        scenarios = {sid: {"state": "no_result"} for sid in ("SC-01-01-01", "SC-01-01-02", "SC-01-01-03")}
        links = {
            "SC-01-01-01": [{"file": "flutter/test/owners_test.dart", "line": 1, "test": title}],
            "SC-01-01-02": [{"file": "scripts/api_system_check.py", "line": 2, "test": "check_desk",
                             "case_id": "desk_over_http"}],
            # A template with almost no literal text cannot identify a case.
            "SC-01-01-03": [{"file": "flutter/test/owners_test.dart", "line": 3, "test": "for $status"}],
        }
        cases = [{"producer": "flutter", "suite": "flutter-test", "native_id": prefix + value, "status": "passed"}
                 for value in ("OWNER_OCCUPIED", "VACANT", "VACANT units after a sale")]
        cases += [{"producer": "rust", "suite": suite, "native_id": "desk_over_http", "status": "passed"}
                  for suite in ("api-system", "rust-test")]

        report = cse.build_evidence(scenarios, cases, links)

        matched = {sid: row["cases"] for sid, row in report["scenarios"].items()}
        self.assertEqual(len(matched["SC-01-01-01"]), 2)
        self.assertEqual([case["suite"] for case in matched["SC-01-01-02"]], ["api-system"])
        self.assertEqual(report["scenarios"]["SC-01-01-03"]["evidence"], "unresolved")

    def test_pending_scenario_stays_planned_unless_a_linked_case_fails(self):
        scenarios = {sid: {"state": "planned"} for sid in ("SC-01-01-01", "SC-01-01-02")}
        links = {sid: [{"file": "backend/tests/example.rs", "line": 1, "test": test}]
                 for sid, test in (("SC-01-01-01", "works"), ("SC-01-01-02", "fails"))}
        cases = [{"producer": "rust", "suite": "rust-test", "native_id": f"example::{name}", "status": status}
                 for name, status in (("works", "passed"), ("fails", "failed"))]

        report = cse.build_evidence(scenarios, cases, links)

        self.assertEqual(report["evidence_counts"], {"failing": 1, "planned": 1})
        self.assertEqual(len(report["scenarios"]["SC-01-01-01"]["cases"]), 1)

    def test_named_links_completes_multiline_dart_and_api_check_declarations(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "apps" / "development-time" / "SitePulse"
            (root / "flutter" / "test").mkdir(parents=True)
            (root / "scripts").mkdir()
            (root / "flutter" / "test" / "pager_test.dart").write_text(
                "void main() {\n"
                "  // covers: SC-01-01-01\n"
                "  testWidgets(\n"
                "    'pager shows the next range',\n"
                "    (tester) async {\n"
                "      // covers: SC-01-01-02\n"
                "      expect(1, 1);\n"
                "    },\n"
                "  );\n"
                "  test('an unrelated later test', () => expect(2, 2));\n"
                "}\n", encoding="utf-8")
            (root / "scripts" / "api_system_check.py").write_text(
                "# covers: SC-01-01-03\n"
                "def check_desk(ctx):\n"
                "    return ctx.status == 200, ''\n\n\n"
                "CHECK_FUNCS: dict = {'desk_over_http': check_desk}\n", encoding="utf-8")

            links = cse.named_links(cse.ft.load_catalogue(root))

        self.assertEqual([links[f"SC-01-01-0{n}"][0]["test"] for n in (1, 2, 3)],
                         ["pager shows the next range", "pager shows the next range", "check_desk"])
        self.assertEqual(links["SC-01-01-03"][0]["case_id"], "desk_over_http")

    def test_incomplete_suite_count_includes_mixed_and_reused_evidence(self):
        suites = [
            {"status": "collected"},
            {"status": "collected-with-failures"},
            {"status": "incomplete"},
            {"status": "missing"},
            {"status": "cancelled"},
            {"status": "mixed-attempts"},
            {"status": "reused"},
            {"status": "not-run"},
        ]

        self.assertEqual(ctr.incomplete_suite_count(suites), 5)

    def test_inventory_uses_combined_collection_and_public_allowlist(self):
        secret = "TR330006100519782134567890"
        collection = {
            "suites": [
                {"suite": "e2e", "runner": "pytest-playwright", "producer": "e2e",
                 "status": "mixed-attempts", "case_count": 12, "missing_shards": ["4/8"],
                 "internal": secret},
                {"suite": "rust", "runner": "cargo", "producer": "rust",
                 "status": "reused", "case_count": 230, "missing_shards": [], "error": secret},
            ],
            "gates": [{"gate": "gui-e2e", "status": "passed", "duration_s": 7.5, "exit_codes": [0]},
                      {"gate": "rust-test", "status": "incomplete", "duration_s": 7.5,
                       "exit_codes": [1], "command": secret}],
            "cases": [
                {"runner": "cargo", "suite": "rust", "producer": "rust", "shard": "rust-test",
                 "native_id": "unit::case", "parameter_id": None, "status": "failed",
                 "duration_s": 0.2, "scenario_ids": [], "detail": secret, "traceback": secret},
                {"runner": "pytest-playwright", "suite": "e2e", "producer": "e2e", "shard": "1/8",
                 "native_id": f"tests.test_page::test_page[{secret}]", "parameter_id": secret,
                 "status": "passed", "duration_s": 0.3, "scenario_ids": ["SC-01-01-01"], "detail": secret},
            ],
        }

        inventory = ctr.collect_inventory(Path("/does/not/exist"), collection=collection)

        self.assertEqual([suite["suite"] for suite in inventory["suites"]], ["e2e", "rust"])
        self.assertEqual([suite["status"] for suite in inventory["suites"]], ["mixed-attempts", "reused"])
        self.assertEqual([gate["status"] for gate in inventory["gates"]], ["passed", "incomplete"])
        self.assertEqual([case["native_id"] for case in inventory["unmapped_cases"]], ["unit::case"])
        self.assertNotIn(secret, json.dumps(inventory))

        public = ctr.public_report_from_inventory(inventory)
        self.assertEqual(public["schema"], 1)
        self.assertEqual(set(public["gates"][0]), {"name", "status", "duration_seconds"})
        self.assertEqual(set(public["cases"][0]), {"id", "name", "status", "duration_seconds"})
        self.assertNotIn(secret, json.dumps(public))
        public_e2e = next(case for case in public["cases"] if case.get("scenario_id") == "SC-01-01-01")
        self.assertEqual(public_e2e["name"], "tests.test_page::test_page example-1")
        self.assertEqual(public_e2e["scenario_id"], "SC-01-01-01")
        self.assertNotIn("parameter_id", public_e2e)
        e2e_gate = next(gate for gate in public["gates"] if gate["name"] == "gui-e2e")
        self.assertEqual(e2e_gate["status"], "INCOMPLETE")

    def test_outline_examples_use_ordinals_in_public_safe_html(self):
        secret = "TR330006100519782134567890"
        scenario = {"id": "SC-01-01-01", "name": "Statements", "status": "PASS", "last_run": None,
                    "recent": [], "runs": 0, "passed_runs": 0, "linked_tests": [], "feature_file": ""}
        report = {"epics": [{"id": "EPIC-01", "title": "Finance", "status": "PASS", "stories": [
            {"id": "STORY-01-01", "title": "Statements", "status": "PASS", "scenarios": [scenario]}]}]}
        records = [
            {"scenario": scenario["id"], "name": f"test_statements[{secret}]", "parameter_id": secret,
             "status": "FAIL", "duration_s": 0.2},
            {"scenario": scenario["id"], "name": "test_statements[second-sensitive-value]", "parameter_id": "second-sensitive-value",
             "status": "PASS", "duration_s": 0.3},
        ]

        ctr.attach_outline_examples(report, records)
        page = ctr.ft.render_html(report, "now", "test", public_safe=True)

        self.assertNotIn(secret, page)
        self.assertNotIn("second-sensitive-value", page)
        self.assertIn("example-1", page)
        self.assertIn("example-2", page)

    def test_legacy_inventory_ignores_malformed_nonfinite_and_negative_junit_durations(self):
        with tempfile.TemporaryDirectory() as tmp:
            shards = Path(tmp) / "shards"
            shard = shards / "e2e-shard-1"
            shard.mkdir(parents=True)
            (shard / "junit.xml").write_text(
                '<testsuite><testcase name="bad" time="oops"/>'
                '<testcase name="nan" time="NaN"/>'
                '<testcase name="negative" time="-1.5"/>'
                '<testcase name="valid" time="1.25"/></testsuite>',
                encoding="utf-8",
            )
            (shard / "suite-collection.json").write_text("[]", encoding="utf-8")
            (shard / "case-results.jsonl").write_text("null\n[]\n{}\n", encoding="utf-8")

            inventory = ctr.collect_inventory(shards)

            self.assertEqual([case["duration_s"] for case in inventory["cases"]],
                             [None, None, None, 1.25])

    def test_attempt_metadata_selects_latest_artifact_for_history_and_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            history, artifacts = tmp / "history", tmp / "artifacts"
            (history / "runs").mkdir(parents=True)
            for attempt, scenario in (("1", "SC-06-06-01"), ("2", "SC-06-06-02")):
                shard = artifacts / f"e2e-shard-1-attempt-{attempt}"
                shard.mkdir(parents=True)
                (shard / "collection.json").write_text(json.dumps({"shard": "1/8", "run_id": "42",
                    "attempt": attempt, "commit": "abc", "job_result": "success"}))
                (shard / "executions.jsonl").write_text(json.dumps(_record(scenario, "PASS")) + "\n")
                (shard / "junit.xml").write_text('<testsuite tests="1"><testcase classname="tests.demo" name="case" time="1"/></testsuite>')
            out = tmp / "out"
            summary = ctr.build(artifacts, out, None, history, run_id="42", attempt="2",
                                suite_artifacts=artifacts, commit_override="abc")
            records = [json.loads(line) for line in (out / "executions.jsonl").read_text().splitlines()]
            self.assertEqual(summary["executions"], 1)
            self.assertEqual([row["scenario"] for row in records], ["SC-06-06-02"])
            collection = json.loads((out / "suite-collection.json").read_text())
            self.assertEqual(collection["shard_inputs"]["1/8"]["attempt"], "2")
            e2e_suite = next(suite for suite in json.loads((out / "product-status.json").read_text())
                             ["inventory"]["suites"] if suite["suite"] == "e2e")
            self.assertEqual(e2e_suite["status"], "incomplete")
            self.assertGreater(summary["ci_suites"]["incomplete_suites"], 0)
            public = json.loads((out / "public-report.json").read_text())
            self.assertEqual(public["schema"], 1)
            self.assertTrue(all(set(gate) <= {"name", "status", "duration_seconds"} for gate in public["gates"]))
            self.assertTrue(all(set(case) <= {"id", "name", "status", "duration_seconds", "scenario_id"}
                                for case in public["cases"]))
            gui_gate = next(gate for gate in public["gates"] if gate["name"] == "gui-e2e")
            self.assertEqual(gui_gate["status"], "INCOMPLETE")

    def test_merges_shards_into_report_without_changing_history(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            history = tmp / "history"
            (history / "runs").mkdir(parents=True)
            for n, status in ((1, "PASS"), (2, "FAIL")):
                shard = tmp / "shards" / f"e2e-shard-{n}"
                shard.mkdir(parents=True)
                (shard / "executions.jsonl").write_text(json.dumps(_record(f"SC-06-06-0{n}", status)) + "\n",
                                                        encoding="utf-8")
                (shard / "junit.xml").write_text(
                    f'<testsuites><testsuite tests="1" failures="{n - 1}" errors="0" skipped="0" time="2"/></testsuites>',
                    encoding="utf-8")
            out = tmp / "out"
            evidence = tmp / "actions-evidence"
            summary = ctr.build(tmp / "shards", out, "demo task", history, evidence, "45054743421", "2")
            self.assertEqual((summary["shards"], summary["executions"], summary["status"]), (2, 2, "FAIL"))
            self.assertEqual((summary["junit"]["tests"], summary["junit"]["passed"], summary["junit"]["failures"]),
                             (2, 1, 1))
            self.assertEqual(sorted(p.name for p in out.iterdir()),
                             ["case-results.jsonl", "executions.jsonl", "feature-report.html", "product-status.html",
                              "product-status.json", "public-report.json", "scenario-evidence.json", "scenario-evidence.md",
                              "suite-collection.json", "suite-report.md", "summary.json", "test-report.md"])
            status = json.loads((out / "product-status.json").read_text(encoding="utf-8"))
            self.assertEqual((status["status"], status["scenarios"]["SC-06-06-01"]["state"],
                              status["scenarios"]["SC-06-06-02"]["state"]), ("FAIL", "passing", "failing"))
            report = (out / "test-report.md").read_text(encoding="utf-8")
            self.assertIn("**Task:** demo task", report)
            self.assertIn("SC-06-06-02", report)
            self.assertIn("Scenario evidence across CI lanes", report)
            self.assertIn("unresolved", json.loads((out / "scenario-evidence.json").read_text())["evidence_counts"])
            self.assertIn("CI scenario evidence", (out / "feature-report.html").read_text(encoding="utf-8"))
            self.assertEqual(list((history / "runs").iterdir()), [])
            # The Actions consumer downloads this separate artifact and resolves the same
            # run/attempt path. Evidence stays out of the report directory uploaded to Pages.
            evidence_runs = evidence / "run-45054743421" / "attempt-2" / "runs"
            self.assertTrue(evidence_runs.is_dir())
            current_runs = list(evidence_runs.rglob("*.jsonl"))
            self.assertEqual(len(current_runs), 1)
            records = [json.loads(line) for line in current_runs[0].read_text(encoding="utf-8").splitlines()]
            self.assertEqual({record["name"] for record in records}, {"SC-06-06-01", "SC-06-06-02"})
            self.assertFalse((out / "history").exists())
            page = ctr.step_summary(summary, report)
            self.assertIn("| 2 | 1 | 1 | 0 | 0 |", page)
            self.assertIn("### Test run", page)
            repeated = ctr.build(tmp / "shards", out, "demo task", history, evidence, "45054743421", "2")
            self.assertEqual((repeated["executions"], repeated["status"]), (2, "FAIL"))
            self.assertEqual(len(list(evidence_runs.rglob("*.jsonl"))), 1)

    def test_workflow_upload_and_consume_the_producer_attempt_payload(self):
        workflow_path = Path(__file__).resolve().parents[5] / ".github" / "workflows" / "sitepulse-ci.yml"
        workflow = workflow_path.read_text(encoding="utf-8")
        report_job = re.search(r"(?ms)^  test-report:\n(.*?)(?=^  [a-z][a-z0-9-]*:\n)", workflow)
        evidence_job = re.search(r"(?ms)^  record-evidence:\n(.*?)(?=^  [a-z][a-z0-9-]*:\n|\Z)", workflow)
        self.assertIsNotNone(report_job)
        self.assertIsNotNone(evidence_job)
        producer, consumer = report_job.group(1), evidence_job.group(1)

        self.assertIn("--evidence-out", producer)
        self.assertIn('--run-id "${{ github.run_id }}"', producer)
        self.assertIn('--attempt "${{ github.run_attempt }}"', producer)
        self.assertIn("evidence_artifact: ${{ steps.evidence_metadata.outputs.artifact_name }}", producer)
        self.assertIn("evidence_path: ${{ steps.evidence_metadata.outputs.evidence_path }}", producer)
        self.assertIn('name: ${{ steps.evidence_metadata.outputs.artifact_name }}', producer)
        self.assertIn('path: ${{ runner.temp }}/sitepulse-actions-evidence/', producer)
        self.assertIn('name: ${{ needs.test-report.outputs.evidence_artifact }}', consumer)
        self.assertIn('needs.test-report.outputs.evidence_path', consumer)
        self.assertIn('test -d "$EVIDENCE_RUNS"', consumer)
        self.assertIn('name: e2e-test-report', producer)
        self.assertIn('path: ${{ runner.temp }}/e2e-test-report/', producer)

    def test_malformed_execution_records_keep_valid_evidence_and_mark_incomplete(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            shard = root / "shards" / "e2e-shard-1"
            shard.mkdir(parents=True)
            (shard / "executions.jsonl").write_text(
                json.dumps(_record("SC-06-06-01", "PASS")) + "\n{invalid\nnull\n",
                encoding="utf-8",
            )
            out = root / "out"
            summary = ctr.build(root / "shards", out, None, root / "missing-history")
            self.assertEqual((summary["executions"], summary["status"]), (1, "INCOMPLETE"))
            collection = json.loads((out / "suite-collection.json").read_text(encoding="utf-8"))
            self.assertEqual(collection["invalid_execution_inputs"], 2)

    def test_no_shard_results_still_writes_a_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / "shards").mkdir()
            evidence = tmp / "actions-evidence"
            summary = ctr.build(tmp / "shards", tmp / "out", None, tmp / "missing", evidence, "123", "1")
            self.assertFalse(evidence.exists())
            self.assertEqual((summary["status"], summary["executions"]), ("NO RESULTS", 0))
            self.assertIn("No execution records", (tmp / "out" / "test-report.md").read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
