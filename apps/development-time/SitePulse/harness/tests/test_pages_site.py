"""Public archive migration, ordering, and artifact verification tests."""
import importlib.util
import json
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import tempfile
from threading import Thread
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "pages_site.py"
spec = importlib.util.spec_from_file_location("pages_site", SCRIPT)
pages = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pages)


class PagesSiteTests(unittest.TestCase):
    def _report(self, root: Path, status: str = "PASS", sentinel: str = "UNSAFE_PAYLOAD_MARKER") -> Path:
        report = root / "report"
        report.mkdir(parents=True, exist_ok=True)
        (report / "summary.json").write_text(json.dumps({
            "run_id": "20261120T123456Z-aaaaaaa", "task": "master", "commit": "b" * 40,
            "status": status, "junit": {"tests": 3, "passed": 2, "failures": 1, "errors": 0,
                                          "skipped": 0, "seconds": 2.5, "unparseable": [sentinel]},
            "failure_message": sentinel, "scenario_counts": {"PASS": 2, "FAIL": 1},
        }), encoding="utf-8")
        snapshot = {
            "schema": 1, "generated_at": "2026-11-20T12:34:56Z", "run_id": "20261120T123456Z-aaaaaaa",
            "commit": "b" * 40, "status": status, "junit": {"tests": 3, "passed": 2, "failures": 1},
            "totals": {"stories": 1, "stories_with_scenarios": 1, "stories_passing": 0, "scenarios": 1,
                       "automated": 1, "passing": 0, "failing": 1, "no_result": 0, "planned": 0,
                       "epics": 1, "epics_verified": 0, "epics_failing": 1},
            "epics": [{"id": "EPIC-01", "title": "Safe title", "stories": 1, "stories_with_scenarios": 1,
                       "stories_passing": 0, "scenarios": 1, "automated": 1, "passing": 0, "failing": 1,
                       "no_result": 0, "planned": 0, "health": "failing", "ignored": sentinel}],
            "scenarios": {"SC-01-01-01": {"state": "failing", "name": "Safe scenario", "epic": "EPIC-01",
                                          "story": "STORY-01-01", "error": sentinel}},
            "recent_changes": [{"samples": [sentinel]}],
        }
        (report / "product-status.json").write_text(json.dumps(snapshot), encoding="utf-8")
        (report / "feature-report.html").write_text(f"<html>{sentinel}</html>", encoding="utf-8")
        (report / "test-report.md").write_text(sentinel, encoding="utf-8")
        (report / "public-report.json").write_text(json.dumps({
            "schema": 1,
            "gates": [{"name": "E2E suite", "status": "PASS", "duration_seconds": 3.5,
                       "failure": sentinel}],
            "cases": [{"id": "test_safe", "name": "Safe case", "status": "PASS",
                       "duration_seconds": 1, "scenario_id": "SC-01-01-01", "failure": sentinel},
                      {"id": "bad", "name": "Bad case", "status": "FAIL", "failure": sentinel}],
            "raw_xml": sentinel,
        }), encoding="utf-8")
        return report

    def test_migration_rebuilds_existing_routes_without_legacy_html_or_raw_fields(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            site = root / "site"
            legacy = site / "reports" / "12345-2"
            legacy.mkdir(parents=True)
            (legacy / "index.html").write_text("PRIVATE_OLD_HTML", encoding="utf-8")
            (legacy / "test-report.md").write_text("PRIVATE_OLD_MARKDOWN", encoding="utf-8")
            (legacy / "summary.json").write_text(json.dumps({"status": "PASS", "task": "old", "run_id": "20261101T010101Z-abc",
                                                               "junit": {"tests": 4, "passed": 4, "errors": 0,
                                                                         "failure_body": "PRIVATE_OLD_SUMMARY"}}), encoding="utf-8")
            (site / "index.html").write_text("PRIVATE_OLD_DASHBOARD", encoding="utf-8")
            report = self._report(root)
            result = pages.build(site, report, "23456", "1", 83, "b" * 40, "33445566")

            self.assertTrue(result["is_latest"])
            self.assertTrue((site / "index.html").is_file())
            self.assertTrue((site / "latest.html").is_file())
            self.assertTrue((site / "history.html").is_file())
            self.assertTrue((site / "reports/12345-2/index.html").is_file())
            self.assertIn("reports/12345-2/", (site / "history.html").read_text(encoding="utf-8"))
            all_public = "\n".join(path.read_text(encoding="utf-8") for path in site.rglob("*") if path.is_file())
            for sentinel in ("PRIVATE_OLD_HTML", "PRIVATE_OLD_MARKDOWN", "PRIVATE_OLD_SUMMARY", "UNSAFE_PAYLOAD_MARKER"):
                self.assertNotIn(sentinel, all_public)
            self.assertNotIn("feature-report.html", [p.name for p in (site / "reports/23456-1").iterdir()])
            public = json.loads((site / "reports/23456-1/public-report.json").read_text(encoding="utf-8"))
            self.assertEqual(public["cases"], [
                {"id": "test_safe", "name": "Safe case", "status": "PASS", "duration_seconds": 1,
                 "scenario_id": "SC-01-01-01"},
                {"id": "bad", "name": "Bad case", "status": "FAIL"},
            ])
            self.assertEqual(result["latest"]["run_number"], 83)

    def test_late_older_run_is_archived_but_cannot_replace_latest(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            site = root / "site"
            newer = self._report(root)
            pages.build(site, newer, "200", "2", 20, "b" * 40, "3000")
            # Put the older run's report in a sibling location because report fixtures are isolated.
            old_root = root / "old"
            old_root.mkdir()
            older = self._report(old_root)
            result = pages.build(site, older, "100", "1", 19, "c" * 40, "2000")

            self.assertFalse(result["is_latest"])
            marker = json.loads((site / "sitepulse-pages.json").read_text(encoding="utf-8"))
            self.assertEqual(marker["run_id"], "200")
            self.assertIn("200", (site / "latest.html").read_text(encoding="utf-8"))
            self.assertTrue((site / "reports/100-1/index.html").is_file())
            pages.verify_local(site, marker)

    def test_new_attempt_of_same_run_becomes_latest(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            site = root / "site"
            first = self._report(root / "first")
            pages.build(site, first, "300", "1", 30, "b" * 40, "4000")
            second = self._report(root / "second")
            result = pages.build(site, second, "300", "2", 30, "b" * 40, "4000")

            self.assertTrue(result["is_latest"])
            self.assertEqual(result["latest"]["run_attempt"], 2)
            self.assertTrue((site / "reports/300-1/index.html").is_file())
            self.assertTrue((site / "reports/300-2/index.html").is_file())

    def test_remote_verifier_fetches_served_identity_and_archive_url(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            site = root / "site"
            report = self._report(root)
            result = pages.build(site, report, "500", "1", 50, "b" * 40, "6000")
            handler = lambda *args, **kwargs: SimpleHTTPRequestHandler(*args, directory=str(site), **kwargs)
            server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
            thread = Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                verified = pages.verify_remote(f"http://127.0.0.1:{server.server_port}/", result["latest"],
                                               attempts=1, delay=0)
            finally:
                server.shutdown()
                thread.join()
                server.server_close()

            self.assertIn("reports/500-1/", verified["routes"])
            self.assertEqual(verified["identity"]["commit"], "b" * 40)


if __name__ == "__main__":
    unittest.main()
