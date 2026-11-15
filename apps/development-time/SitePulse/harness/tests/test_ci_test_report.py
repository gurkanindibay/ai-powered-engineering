"""scripts/ci_test_report.py: merges CI e2e shard results into one report without touching the history."""
import importlib.util
import json
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
            summary = ctr.build(tmp / "shards", out, "demo task", history)
            self.assertEqual((summary["shards"], summary["executions"], summary["status"]), (2, 2, "FAIL"))
            self.assertEqual((summary["junit"]["tests"], summary["junit"]["passed"], summary["junit"]["failures"]),
                             (2, 1, 1))
            self.assertEqual(sorted(p.name for p in out.iterdir()),
                             ["executions.jsonl", "feature-report.html", "summary.json", "test-report.md"])
            report = (out / "test-report.md").read_text(encoding="utf-8")
            self.assertIn("**Task:** demo task", report)
            self.assertIn("SC-06-06-02", report)
            self.assertEqual(list((history / "runs").iterdir()), [])
            page = ctr.step_summary(summary, report)
            self.assertIn("| 2 | 1 | 1 | 0 | 0 |", page)
            self.assertIn("### Test run", page)

    def test_no_shard_results_still_writes_a_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / "shards").mkdir()
            summary = ctr.build(tmp / "shards", tmp / "out", None, tmp / "missing")
            self.assertEqual((summary["status"], summary["executions"]), ("NO RESULTS", 0))
            self.assertIn("No execution records", (tmp / "out" / "test-report.md").read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
