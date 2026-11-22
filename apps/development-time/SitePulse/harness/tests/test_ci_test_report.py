"""scripts/ci_test_report.py: merges CI e2e shard results into one report without touching the history."""
import importlib.util
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location("ci_test_report", ROOT / "scripts" / "ci_test_report.py")
ctr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ctr)


def _record(scenario: str, status: str) -> dict:
    return {"epic": "EPIC-06", "story": "STORY-06-06", "scenario": scenario, "name": scenario, "binding": "linked",
            "layer": "gui", "feature_file": "", "test": f"tests/demo.py::{scenario}", "status": status,
            "duration_s": 1.5, "steps": [], "error": "", "gui_ids": []}


class CiTestReportTest(unittest.TestCase):
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
                              "product-status.json", "suite-collection.json", "suite-report.md", "summary.json", "test-report.md"])
            status = json.loads((out / "product-status.json").read_text(encoding="utf-8"))
            self.assertEqual((status["status"], status["scenarios"]["SC-06-06-01"]["state"],
                              status["scenarios"]["SC-06-06-02"]["state"]), ("FAIL", "passing", "failing"))
            report = (out / "test-report.md").read_text(encoding="utf-8")
            self.assertIn("**Task:** demo task", report)
            self.assertIn("SC-06-06-02", report)
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
