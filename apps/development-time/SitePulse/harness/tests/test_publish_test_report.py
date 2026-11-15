"""Self-tests for publishing the latest dashboard alongside its full archive."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "publish_test_report.py"
spec = importlib.util.spec_from_file_location("publish_test_report", SCRIPT)
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


class PublishTestReportTests(unittest.TestCase):
    def test_root_opens_latest_dashboard_and_history_keeps_all_runs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            report = root / "report"
            report.mkdir()
            site = root / "site"
            for run_id, task in (("100", "old run"), ("200", "latest run")):
                (report / "feature-report.html").write_text(
                    "<!doctype html><body><main><h1>Feature test report</h1></main></body>", encoding="utf-8")
                (report / "summary.json").write_text(json.dumps({
                    "run_id": run_id, "task": task, "status": "PASS",
                    "junit": {"tests": 1, "passed": 1, "failures": 0, "errors": 0},
                }), encoding="utf-8")
                publisher.build(report, site, run_id, "1")

            index = (site / "index.html").read_text(encoding="utf-8")
            history = (site / "history.html").read_text(encoding="utf-8")
            archived = (site / "reports" / "200-1" / "index.html").read_text(encoding="utf-8")
            self.assertIn("Feature test report", index)
            self.assertIn("View previous executions", index)
            self.assertIn("history.html", index)
            self.assertIn("reports/100-1/", history)
            self.assertIn("reports/200-1/", history)
            self.assertIn("../../history.html", archived)


if __name__ == "__main__":
    unittest.main()
