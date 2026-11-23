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
            latest = (site / "latest.html").read_text(encoding="utf-8")
            self.assertEqual(index, latest)  # no product status snapshot: the feature report stays the root
            self.assertIn("Feature test report", index)
            self.assertIn("View previous executions", index)
            self.assertIn("history.html", index)
            self.assertIn("reports/100-1/", history)
            self.assertIn("reports/200-1/", history)
            self.assertIn("../../history.html", archived)

    def test_root_is_the_product_status_dashboard_when_runs_carry_a_snapshot(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            report = root / "report"
            report.mkdir()
            site = root / "site"
            (report / "feature-report.html").write_text(
                "<!doctype html><body><main><h1>Feature test report</h1></main></body>", encoding="utf-8")
            junit = {"tests": 1, "passed": 1, "failures": 0, "errors": 0}
            for run_id, stamp in (("100", "20261114T090000Z-aaaaaaa"), ("200", "20261115T090000Z-bbbbbbb")):
                summary = {"run_id": stamp, "task": "master", "status": "PASS", "junit": junit}
                (report / "summary.json").write_text(json.dumps(summary), encoding="utf-8")
                snapshot = publisher.ps.build_snapshot(publisher.ps.ft.load_catalogue(), [], summary)
                snapshot["generated_at"] = publisher.ps.snapshot_from_summary(summary)["generated_at"]
                (report / "product-status.json").write_text(json.dumps(snapshot), encoding="utf-8")
                result = publisher.build(report, site, run_id, "1")

            self.assertTrue(result["product_status"])
            index = (site / "index.html").read_text(encoding="utf-8")
            self.assertIn("SitePulse product status", index)
            self.assertIn("2 published runs", index)
            self.assertIn('href="latest.html"', index)
            self.assertIn("reports/100-1/", index)
            self.assertIn('href="index.html">Product status', (site / "latest.html").read_text(encoding="utf-8"))
            self.assertIn('href="../../index.html">Product status',
                          (site / "reports" / "200-1" / "index.html").read_text(encoding="utf-8"))
            self.assertTrue((site / "reports" / "100-1" / "product-status.json").is_file())
            published = json.loads((site / "product-status.json").read_text(encoding="utf-8"))
            self.assertEqual(published["run_id"], "20261115T090000Z-bbbbbbb")

    def test_workflow_builds_and_deploys_pages_artifact_with_required_permissions(self):
        workflow = (Path(__file__).resolve().parents[5] / ".github" / "workflows" / "sitepulse-ci.yml").read_text(
            encoding="utf-8")
        self.assertIn("python3 scripts/pages_site.py build", workflow)
        self.assertIn("actions/upload-pages-artifact@", workflow)
        self.assertIn("actions/deploy-pages@", workflow)
        self.assertIn("name: github-pages", workflow)
        self.assertIn("pages: write", workflow)
        self.assertIn("id-token: write", workflow)
        self.assertIn("verify-remote", workflow)
        self.assertIn("vars.SITEPULSE_PAGES_ACTIONS_ENABLED == 'true'", workflow)


if __name__ == "__main__":
    unittest.main()
