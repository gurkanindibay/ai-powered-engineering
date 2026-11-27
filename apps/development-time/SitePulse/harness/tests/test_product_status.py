"""scripts/product_status.py: product status snapshot, catalogue history from git, and the dashboard."""
import json
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import feature_traceability as ft  # noqa: E402
import product_status as ps  # noqa: E402

EPIC_DOC = "# Epic: Demo epic\n\n### STORY-01-01: First story\n\n### STORY-01-02: Second story\n"
FEATURE = """@EPIC-01 @STORY-01-01
Feature: First story

  @SC-01-01-01 @linked
  Scenario: Passing one
    Given a thing

  @SC-01-01-02 @linked
  Scenario: Failing one
    Given a thing

  @SC-01-01-03 @linked
  Scenario: No result
    Given a thing

  @SC-01-01-04 @pending
  Scenario: Planned one
    Given a thing
"""


def _write_catalogue(root: Path, feature: str = FEATURE, epic_doc: str = EPIC_DOC) -> None:
    (root / ".specify" / "requirements").mkdir(parents=True, exist_ok=True)
    (root / ".specify" / "features" / "EPIC-01").mkdir(parents=True, exist_ok=True)
    (root / ".specify" / "requirements" / "EPIC-01-demo.md").write_text(epic_doc, encoding="utf-8")
    (root / ".specify" / "features" / "EPIC-01" / "STORY-01-01-first.feature").write_text(feature, encoding="utf-8")


def _record(scenario: str, status: str) -> dict:
    return {"scenario": scenario, "status": status}


def _snapshot(root: Path, records: list[dict], when: str = "2026-11-15T10:00:00Z", **summary) -> dict:
    now = datetime.strptime(when, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    return ps.build_snapshot(ft.load_catalogue(root), records, summary, None, now)


class SnapshotTest(unittest.TestCase):
    def test_scenario_state_uses_only_the_tests_that_ran(self):
        self.assertEqual(ps.scenario_state("pending", ["PASS"]), "planned")
        self.assertEqual(ps.scenario_state("linked", []), "no_result")
        self.assertEqual(ps.scenario_state("linked", ["SKIPPED"]), "no_result")
        self.assertEqual(ps.scenario_state("linked", ["PASS", "SKIPPED"]), "passing")
        self.assertEqual(ps.scenario_state("gherkin", ["PASS", "FAIL"]), "failing")

    def test_snapshot_counts_states_per_epic(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write_catalogue(root)
            snap = _snapshot(root, [_record("SC-01-01-01", "PASS"), _record("SC-01-01-02", "FAIL")], status="FAIL")
        epic = snap["epics"][0]
        self.assertEqual((epic["stories"], epic["stories_with_scenarios"], epic["scenarios"], epic["automated"]),
                         (2, 1, 4, 3))
        self.assertEqual([epic[s] for s in ps.STATES], [1, 1, 1, 1])
        self.assertEqual(epic["health"], "failing")
        self.assertEqual(snap["totals"]["epics_failing"], 1)
        self.assertEqual(snap["scenarios"]["SC-01-01-03"]["state"], "no_result")
        first_story = epic["story_details"][0]
        self.assertEqual((first_story["id"], first_story["state"]), ("STORY-01-01", "failing"))
        self.assertEqual([scenario["state"] for scenario in first_story["scenarios"]],
                         ["passing", "failing", "no_result", "planned"])
        self.assertEqual(snap["generated_at"], "2026-11-15T10:00:00Z")

    def test_epic_is_verified_only_when_every_scenario_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write_catalogue(root, FEATURE.split("  @SC-01-01-02")[0])
            snap = _snapshot(root, [_record("SC-01-01-01", "PASS")], status="PASS")
        self.assertEqual((snap["epics"][0]["health"], snap["totals"]["epics_verified"]), ("verified", 1))

    def test_named_evidence_drives_totals_and_preserves_browser_history(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write_catalogue(root)
            evidence = {"attempt": "2", "workflow_run": "https://github.com/owner/repo/actions/runs/123",
                        "scenarios": {"SC-01-01-01": {"evidence": "passing", "cases": [{
                            "test_name": "test_named_scenario", "status": "passing",
                            "workflow_run": "https://github.com/owner/repo/actions/runs/123", "attempt": "2",
                            "tested_commit": "a" * 40}]},
                         "SC-01-01-02": {"evidence": "failing"},
                         "SC-01-01-03": {"evidence": "historical", "cases": [{
                             "test_name": "test_stale_result", "status": "historical", "test_status": "passing",
                             "workflow_run": "https://github.com/owner/repo/actions/runs/122", "attempt": "1",
                             "tested_commit": "b" * 40}]},
                         "SC-01-01-04": {"evidence": "planned"}}}
            snap = ps.build_snapshot(ft.load_catalogue(root), [_record("SC-01-01-01", "FAIL")], evidence=evidence)
        self.assertEqual((snap["totals"]["passing"], snap["totals"]["failing"],
                          snap["totals"]["no_result"]), (1, 1, 1))
        self.assertEqual(snap["totals"]["evidence_counts"],
                         {"failing": 1, "historical": 1, "passing": 1, "pending": 1})
        self.assertEqual(snap["scenarios"]["SC-01-01-03"]["state"], "no_result")
        self.assertEqual((snap["scenarios"]["SC-01-01-04"]["state"],
                          snap["scenarios"]["SC-01-01-04"]["evidence"]), ("planned", "pending"))
        row = snap["scenarios"]["SC-01-01-01"]
        self.assertEqual((row["state"], row["browser_state"], row["browser_step_history"]),
                         ("passing", "failing", ["FAIL"]))
        self.assertEqual((snap["attempt"], snap["workflow_run"], row["evidence_cases"][0]["test_name"]),
                         ("2", "https://github.com/owner/repo/actions/runs/123", "test_named_scenario"))
        page = ps.render_html([snap], {"detail": "feature-report.html", "history": "history.html"})
        self.assertIn("test_named_scenario", page)
        self.assertIn("commit <code>aaaaaaaaaaaa</code>", page)
        self.assertIn("evidence-exceptions", page)
        self.assertIn("commit <code>bbbbbbbbbbbb</code>", page)
        self.assertIn("Browse all 2 scenarios across 1 epic", page)

    def test_named_evidence_collapses_duplicate_parameterized_cases_and_omits_repeated_provenance(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write_catalogue(root)
            commit = "c" * 40
            run_url = "https://github.com/owner/repo/actions/runs/456"
            repeated = [
                {"test_name": "test_param_case", "status": "passing", "workflow_run": run_url,
                 "attempt": "1", "tested_commit": commit}
                for _ in range(12)
            ]
            evidence = {
                "attempt": "1", "workflow_run": run_url,
                "scenarios": {
                    "SC-01-01-01": {"evidence": "passing", "cases": repeated},
                    "SC-01-01-02": {"evidence": "passing", "cases": [{
                        "test_name": "test_second_case", "status": "passing", "workflow_run": run_url,
                        "attempt": "1", "tested_commit": commit}]},
                },
            }
            snap = ps.build_snapshot(ft.load_catalogue(root), [], evidence=evidence)
        page = ps.render_html([snap])
        self.assertIn("×12", page)
        self.assertEqual(page.count("test_param_case"), 1)
        self.assertEqual(page.count("commit <code>cccccccccccc</code>"), 1)
        self.assertNotIn('<details class="evidence-exceptions"', page)
        self.assertIn('<details class="evidence-browser">', page)

    def test_summary_fallback_reads_the_time_from_the_run_id(self):
        snap = ps.snapshot_from_summary({"run_id": "20261115T203425Z-c3318fa", "status": "PASS", "junit": {"tests": 3}})
        self.assertEqual((snap["generated_at"], snap["junit"]["tests"]), ("2026-11-15T20:34:25Z", 3))
        self.assertIsNone(ps.snapshot_from_summary({"run_id": "200"}))


class CatalogueHistoryTest(unittest.TestCase):
    def _commit(self, repo: Path, day: str) -> None:
        env = {"GIT_AUTHOR_DATE": f"{day}T12:00:00Z", "GIT_COMMITTER_DATE": f"{day}T12:00:00Z",
               "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid", "PATH": "/usr/bin:/bin"}
        subprocess.run(["git", "add", "-A"], cwd=repo, check=True, env=env)
        subprocess.run(["git", "commit", "-q", "-m", day], cwd=repo, check=True, env=env)

    def test_history_has_one_point_per_day_and_lists_what_was_added(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
            (repo / ".specify" / "requirements").mkdir(parents=True)
            (repo / ".specify" / "requirements" / "EPIC-01-demo.md").write_text(EPIC_DOC, encoding="utf-8")
            self._commit(repo, "2026-11-01")
            _write_catalogue(repo)
            self._commit(repo, "2026-11-02")
            _write_catalogue(repo, FEATURE.replace("@SC-01-01-04 @pending", "@SC-01-01-04 @linked"))
            self._commit(repo, "2026-11-03")
            history = ps.catalogue_history(repo)
        self.assertEqual([(p["date"], p["stories"], p["stories_with_scenarios"], p["scenarios"], p["automated"])
                          for p in history["points"]],
                         [("2026-11-01", 2, 0, 0, 0), ("2026-11-02", 2, 1, 4, 3), ("2026-11-03", 2, 1, 4, 4)])
        newest, oldest = history["changes"]
        self.assertEqual((newest["date"], newest["new_scenarios"], newest["newly_automated"]), ("2026-11-03", 0, 1))
        self.assertEqual((oldest["date"], oldest["new_scenarios"], oldest["newly_automated"]), ("2026-11-02", 4, 3))
        self.assertIn("SC-01-01-01: Passing one", oldest["samples"])

    def test_directory_outside_git_has_no_history(self):
        with tempfile.TemporaryDirectory() as tmp:
            env_free = Path(tmp) / "plain"
            env_free.mkdir()
            history = ps.catalogue_history(env_free)
        self.assertEqual(history["points"], [])


class DashboardTest(unittest.TestCase):
    def test_dashboard_shows_epics_trends_and_escapes_text(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write_catalogue(root, epic_doc=EPIC_DOC.replace("Demo epic", "Demo <epic>"))
            junit = {"tests": 2, "passed": 2, "failures": 0, "errors": 0, "skipped": 0}
            first = _snapshot(root, [_record("SC-01-01-01", "PASS")], "2026-11-14T10:00:00Z", status="PASS", junit=junit)
            second = _snapshot(root, [_record("SC-01-01-01", "PASS"), _record("SC-01-01-02", "FAIL")],
                               "2026-11-15T10:00:00Z", status="FAIL", junit={**junit, "passed": 1, "failures": 1})
        legacy = ps.snapshot_from_summary({"run_id": "20261113T080000Z-abc1234", "status": "PASS", "junit": junit})
        page = ps.render_html([legacy, first, {**second, "href": "reports/2-1/"}])
        self.assertIn("SitePulse product status", page)
        self.assertIn("Show 2 stories", page)
        self.assertIn("STORY-01-01", page)
        self.assertIn("SC-01-01-02", page)
        self.assertIn("Demo &lt;epic&gt;", page)
        self.assertNotIn("Demo <epic>", page)
        self.assertIn("1 failing scenario", page)
        self.assertIn("1 of 2 tests passed", page)
        self.assertNotIn("0 tests failed", page)
        self.assertIn("+1 vs previous run", page)
        trends = ps.trend_series([legacy, first, second])
        self.assertEqual([(d["date"], d["passing"], d["failing"]) for d in trends["days"]],
                         [("2026-11-14", 1, 0), ("2026-11-15", 1, 1)])
        self.assertEqual([(r["passed"], r["failed"]) for r in trends["runs"]], [(2, 0), (2, 0), (1, 1)])

    def test_dashboard_needs_a_full_snapshot(self):
        with self.assertRaises(ValueError):
            ps.render_html([ps.snapshot_from_summary({"run_id": "20261113T080000Z-abc1234"})])

    def test_site_snapshots_are_read_oldest_first_with_links(self):
        with tempfile.TemporaryDirectory() as tmp:
            site = Path(tmp)
            for folder, payload, name in (
                    ("200-1", {"generated_at": "2026-11-15T10:00:00Z", "totals": {}}, "product-status.json"),
                    ("100-1", {"run_id": "20261114T090000Z-abc1234", "status": "PASS"}, "summary.json")):
                (site / "reports" / folder).mkdir(parents=True)
                (site / "reports" / folder / name).write_text(json.dumps(payload), encoding="utf-8")
            (site / "reports" / "300-1").mkdir()
            (site / "reports" / "300-1" / "summary.json").write_text("{broken", encoding="utf-8")
            snapshots = ps.load_site_snapshots(site)
        self.assertEqual([s["href"] for s in snapshots], ["reports/100-1/", "reports/200-1/"])


if __name__ == "__main__":
    unittest.main()
