"""Self-tests for scripts/feature_traceability.py and the .specify/features catalogue."""
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "feature_traceability.py"
spec = importlib.util.spec_from_file_location("feature_traceability", SCRIPT)
ft = importlib.util.module_from_spec(spec)
sys.modules["feature_traceability"] = ft
spec.loader.exec_module(ft)

EPIC = "# Epic: Demo\n\n### STORY-42-01: First story\n\n### STORY-42-02: Second story\n"
FEATURE = '''@EPIC-42 @STORY-42-01
Feature: First story

  @SC-42-01-01 @layer:gui @smoke
  Scenario: Works
    Given a thing
    When it is used:
      | a | b |
    Then it works

  @SC-42-01-02 @pending
  Scenario: Later
    Given a thing
'''


def _workspace(tmp: str, feature: str = FEATURE, second_story: bool = True) -> Path:
    root = Path(tmp)
    (root / ".specify" / "requirements").mkdir(parents=True)
    (root / ".specify" / "requirements" / "EPIC-42-demo.md").write_text(EPIC, encoding="utf-8")
    features = root / ".specify" / "features" / "EPIC-42"
    features.mkdir(parents=True)
    (features / "STORY-42-01-first.feature").write_text(feature, encoding="utf-8")
    if second_story:
        (features / "STORY-42-02-second.feature").write_text(
            "@EPIC-42 @STORY-42-02\nFeature: Second\n\n  @SC-42-02-01 @layer:gui @linked\n"
            "  Scenario: Linked\n    Given a thing\n", encoding="utf-8")
    (root / "backend" / "tests").mkdir(parents=True)
    (root / "backend" / "tests" / "demo.rs").write_text(
        "#[test]\n// covers: SC-42-02-01\nfn when_linked_then_listed() {}\n", encoding="utf-8")
    return root


def _record(scenario: str, status: str, run: int, steps: list[dict] | None = None) -> dict:
    epic, story = ft.parents_of(scenario)
    return {"run_id": f"2026010{run}T000000Z-abc", "started_at": f"2026-01-0{run}T00:00:00Z", "commit": "abc1234",
            "branch": "master", "dirty": False, "epic": epic, "story": story, "scenario": scenario,
            "status": status, "duration_s": 1.5, "steps": steps or [], "test": "t", "error": ""}


class CatalogueTests(unittest.TestCase):
    def test_repository_catalogue_is_consistent(self):
        catalogue = ft.load_catalogue()
        self.assertEqual(ft.check(catalogue), [])
        self.assertIn("EPIC-10", catalogue.migrated_epics)

    def test_parses_tags_steps_and_modes(self):
        _, scenarios, problems = ft.parse_feature(FEATURE, "f.feature")
        self.assertEqual(problems, [])
        self.assertEqual([s.id for s in scenarios], ["SC-42-01-01", "SC-42-01-02"])
        self.assertEqual(scenarios[0].steps, ["Given a thing", "When it is used:", "Then it works"])
        self.assertEqual((scenarios[0].mode, scenarios[0].layer), ("gherkin", "gui"))
        self.assertEqual(scenarios[1].mode, "pending")

    def test_valid_workspace_has_no_problems(self):
        with tempfile.TemporaryDirectory() as tmp:
            catalogue = ft.load_catalogue(_workspace(tmp))
            self.assertEqual(ft.check(catalogue), [])
            self.assertEqual(catalogue.links["SC-42-02-01"][0]["test"], "when_linked_then_listed")

    def test_story_without_scenario_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            problems = ft.check(ft.load_catalogue(_workspace(tmp, second_story=False)))
            self.assertTrue(any(p.startswith("STORY-42-02: no scenario") for p in problems), problems)
            self.assertTrue(any("covers unknown scenario SC-42-02-01" in p for p in problems), problems)

    def test_duplicate_foreign_and_untagged_scenarios_are_reported(self):
        broken = (FEATURE.replace("@SC-42-01-02 @pending", "@SC-42-01-01 @layer:gui")
                  + "\n  @SC-42-09-01 @layer:gui\n  Scenario: Foreign\n    Given a thing\n"
                  + "\n  Scenario: No id\n    Given a thing\n"
                  + "\n  @SC-42-01-05\n  Scenario: No layer\n    Given a thing\n")
        with tempfile.TemporaryDirectory() as tmp:
            problems = "\n".join(ft.check(ft.load_catalogue(_workspace(tmp, broken))))
        self.assertIn("SC-42-01-01: used by 2 scenarios", problems)
        self.assertIn("SC-42-09-01 does not belong to STORY-42-01", problems)
        self.assertIn("needs exactly one @SC-xx-yy-nn tag", problems)
        self.assertIn("SC-42-01-05 needs a @layer:<name> tag", problems)

    def test_linked_scenario_without_a_covering_test_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = _workspace(tmp)
            (root / "backend" / "tests" / "demo.rs").write_text("fn nothing() {}\n", encoding="utf-8")
            problems = ft.check(ft.load_catalogue(root))
        self.assertTrue(any("is @linked but no test declares" in p for p in problems), problems)


class ReportTests(unittest.TestCase):
    def test_latest_run_wins_and_story_takes_the_worst_status(self):
        failed_steps = [{"keyword": "Given", "text": "a thing", "status": "PASS", "duration_s": 0.1},
                        {"keyword": "Then", "text": "it works", "status": "FAIL", "duration_s": 0.2}]
        history = [_record("SC-42-01-01", "PASS", 1), _record("SC-42-01-01", "FAIL", 2, failed_steps),
                   _record("SC-42-02-01", "PASS", 2)]
        with tempfile.TemporaryDirectory() as tmp:
            report = ft.build_report(ft.load_catalogue(_workspace(tmp)), history)
        stories = {s["id"]: s for s in report["epics"][0]["stories"]}
        first = {r["id"]: r for r in stories["STORY-42-01"]["scenarios"]}
        self.assertEqual(first["SC-42-01-01"]["status"], "FAIL")
        self.assertEqual(first["SC-42-01-01"]["failing_step"], "Then it works")
        self.assertEqual((first["SC-42-01-01"]["runs"], first["SC-42-01-01"]["passed_runs"]), (2, 1))
        self.assertEqual(first["SC-42-01-02"]["status"], "PENDING")
        self.assertEqual(stories["STORY-42-01"]["status"], "FAIL")
        self.assertEqual(stories["STORY-42-02"]["status"], "PASS")
        self.assertEqual(report["epics"][0]["status"], "FAIL")

    def test_html_report_shows_scenarios_steps_and_escapes_text(self):
        steps = [{"keyword": "Then", "text": "a <b> & c", "status": "FAIL", "duration_s": 0.2, "error": "boom <x>"}]
        history = [_record("SC-42-01-01", "PASS", 1), _record("SC-42-01-01", "FAIL", 2, steps)]
        with tempfile.TemporaryDirectory() as tmp:
            report = ft.build_report(ft.load_catalogue(_workspace(tmp)), history)
        page = ft.render_html(report, "2026-01-02 00:00 UTC", "store")
        self.assertIn("SC-42-01-01", page)
        self.assertIn("a &lt;b&gt; &amp; c", page)
        self.assertIn("boom &lt;x&gt;", page)
        self.assertNotIn("<script", page)
        self.assertEqual(page.count('<i class="'), 2)  # one bar per recorded run
        self.assertIn('class="badge NOT-RUN"', page)

    def test_runs_report_what_executed_and_what_changed(self):
        history = [_record("SC-42-01-01", "PASS", 1), _record("SC-42-02-01", "FAIL", 1),
                   _record("SC-42-01-01", "FAIL", 2), _record("SC-42-02-01", "PASS", 2),
                   _record("SC-42-01-01", "FAIL", 3)]
        with tempfile.TemporaryDirectory() as tmp:
            catalogue = ft.load_catalogue(_workspace(tmp))
            runs = ft.build_runs(history, catalogue)
            page = ft.render_html(ft.build_report(catalogue, history), "now", "store", runs)
        self.assertEqual([r["run_id"][:8] for r in runs], ["20260103", "20260102", "20260101"])
        latest, second, first = runs
        self.assertEqual((latest["executed"], latest["automated"], latest["not_executed"]), (1, 2, ["SC-42-02-01"]))
        self.assertEqual(latest["changes"], {})  # still failing: neither regressed nor fixed
        self.assertEqual(second["changes"], {"regressed": 1, "fixed": 1})
        self.assertEqual(first["changes"], {"new": 2})
        self.assertEqual((second["status"], second["task"]), ("FAIL", "master"))
        self.assertIn("1/2</b><span>executed in the latest run", page)
        self.assertIn('<span class="chg regressed">1 regressed</span>', page)
        self.assertIn("Not executed in this run (1)", page)

    def test_run_markdown_lists_result_changes_and_gaps(self):
        history = [_record("SC-42-01-01", "PASS", 1), _record("SC-42-01-01", "FAIL", 2)]
        with tempfile.TemporaryDirectory() as tmp:
            runs = ft.build_runs(history, ft.load_catalogue(_workspace(tmp)))
        text = ft.run_markdown(runs[0])
        self.assertIn("- **Result:** FAIL (1 FAIL)", text)
        self.assertIn("- **regressed**: `SC-42-01-01` Works", text)
        self.assertIn("| `SC-42-01-01` | FAIL | regressed |", text)
        self.assertIn("`SC-42-02-01`", text.split("## Not executed in this run")[1])
        self.assertEqual(ft.runs_of_task(runs, None, "master"), runs)
        self.assertEqual(ft.runs_of_task(runs, "other-task", "master"), [])

    def test_unexecuted_scenario_is_not_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            report = ft.build_report(ft.load_catalogue(_workspace(tmp)), [])
        self.assertEqual(report["story_status_counts"], {"NOT RUN": 2})

    def test_history_is_newest_first_per_scenario_and_aggregated_per_story(self):
        history = [_record("SC-42-01-01", "PASS", 1), _record("SC-42-01-03", "FAIL", 1),
                   _record("SC-42-01-01", "PASS", 2), _record("SC-42-01-03", "PASS", 2)]
        scenario = ft.build_history(history, "SC-42-01-03", 10)
        self.assertEqual([e["status"] for e in scenario["entries"]], ["PASS", "FAIL"])
        story = ft.build_history(history, "STORY-42-01", 10)
        self.assertEqual([e["status"] for e in story["entries"]], ["PASS", "FAIL"])
        self.assertEqual(story["entries"][1]["counts"], {"PASS": 1, "FAIL": 1})
        self.assertEqual((story["runs"], story["passed"]), (2, 1))


class StoreTests(unittest.TestCase):
    META = {"run_id": "20260102T030405Z-abc1234", "started_at": "2026-01-02T03:04:05Z", "commit": "abc1234",
            "branch": "master", "dirty": False, "trigger": "local"}

    def _executions(self, tmp: str) -> Path:
        path = Path(tmp) / "executions.jsonl"
        path.write_text(json.dumps({"epic": "EPIC-42", "story": "STORY-42-01", "scenario": "SC-42-01-01",
                                    "status": "PASS", "duration_s": 1.0, "steps": []}) + "\n", encoding="utf-8")
        return path

    def test_directory_store_round_trip(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = ft.DirStore(Path(tmp) / "history")
            self.assertEqual(ft.record_run(self._executions(tmp), store, self.META), 1)
            self.assertTrue((Path(tmp) / "history" / "runs" / "2026" / "20260102T030405Z-abc1234.jsonl").exists())
            history = ft.load_history(store)
        self.assertEqual((history[0]["scenario"], history[0]["commit"]), ("SC-42-01-01", "abc1234"))

    def test_empty_run_is_not_recorded(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = ft.DirStore(Path(tmp) / "history")
            self.assertEqual(ft.record_run(Path(tmp) / "missing.jsonl", store, self.META), 0)
            self.assertEqual(ft.load_history(store), [])

    def test_git_store_appends_commits_without_touching_the_checkout(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "repo"
            repo.mkdir()
            subprocess.run(["git", "init", "-q", "-b", "main"], cwd=repo, check=True)
            (repo / "nested").mkdir()
            store = ft.GitStore(repo / "nested", "test-history")  # a subdirectory, like SitePulse in the workspace
            self.assertEqual(ft.load_history(store), [])
            ft.record_run(self._executions(tmp), store, self.META)
            ft.record_run(self._executions(tmp), store, {**self.META, "run_id": "20260103T000000Z-def5678",
                                                         "started_at": "2026-01-03T00:00:00Z"})
            log = subprocess.run(["git", "log", "--format=%s", "test-history"], cwd=repo, capture_output=True, text=True)
            self.assertEqual(len(log.stdout.splitlines()), 2)
            self.assertEqual([r["run_id"][:8] for r in ft.load_history(store)], ["20260102", "20260103"])
            self.assertEqual(list(repo.glob("runs")), [])
            self.assertEqual([r["run_id"][:8] for r in ft.load_history(store, limit=1)], ["20260103"])

    def test_require_run_applies_to_task_branches_that_change_behaviour(self):
        def git(repo, *args):
            subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid", *args],
                           cwd=repo, check=True, capture_output=True)

        def run(status, n):
            return {**_record("SC-42-01-01", status, n), "branch": "task-1"}

        with tempfile.TemporaryDirectory() as tmp:
            repo = _workspace(tmp)
            git(repo, "init", "-q", "-b", "master")
            git(repo, "add", "-A")
            git(repo, "commit", "-q", "-m", "base")
            catalogue, store = ft.load_catalogue(repo), ft.DirStore(repo / "history")
            self.assertEqual(ft.require_run(catalogue, store, repo)[0], [])  # main branch
            git(repo, "checkout", "-q", "-b", "task-1")
            (repo / "notes.md").write_text("docs only\n", encoding="utf-8")
            self.assertIn("changes no backend", ft.require_run(catalogue, store, repo)[1])
            (repo / "backend" / "tests" / "demo.rs").write_text("fn changed() {}\n", encoding="utf-8")
            problems, _ = ft.require_run(catalogue, store, repo)
            self.assertIn("no test run is recorded for branch task-1", problems[0])
            store.write("runs/2026/a.jsonl", json.dumps(run("FAIL", 1)) + "\n", "")
            self.assertIn("has failing scenarios: SC-42-01-01", ft.require_run(catalogue, store, repo)[0][0])
            store.write("runs/2026/b.jsonl", json.dumps(run("PASS", 2)) + "\n", "")
            problems, note = ft.require_run(catalogue, store, repo)
            self.assertEqual(problems, [])
            self.assertIn("1/2 automated scenarios executed, PASS", note)

    def test_run_metadata_shape(self):
        meta = ft.run_metadata(now=datetime(2026, 1, 2, 3, 4, 5, tzinfo=timezone.utc), trigger="ci")
        self.assertTrue(meta["run_id"].startswith("20260102T030405Z-"))
        self.assertEqual((meta["started_at"], meta["trigger"]), ("2026-01-02T03:04:05Z", "ci"))
        self.assertEqual(ft.run_metadata(task="issue-7")["task"], "issue-7")


if __name__ == "__main__":
    unittest.main()
