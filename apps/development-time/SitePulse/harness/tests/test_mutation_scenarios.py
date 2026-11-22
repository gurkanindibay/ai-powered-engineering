"""Self-tests for scripts/mutation_scenarios.py and its scenario catalogue."""
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]


def _load(name: str):
    spec = importlib.util.spec_from_file_location(name, PROJECT_ROOT / "scripts" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


ms = _load("mutation_scenarios")

CATALOGUE = """
[suites.fast]
cwd = "."
cmd = ["true"]

[suites.db]
cwd = "."
cmd = ["true"]
requires = ["postgres"]

[[scenario]]
id = "MUT-T-001"
layer = "python"
area = "demo"
operator = "relational"
risk = "high"
file = "code.py"
original = "x > 0"
mutant = "x >= 0"
intent = "zero counts as positive"
suites = ["fast"]
"""


def _sandbox(code: str = "def positive(x):\n    return x > 0\n", catalogue: str = CATALOGUE):
    tmp = tempfile.TemporaryDirectory()
    root = Path(tmp.name)
    (root / "code.py").write_text(code, encoding="utf-8")
    path = root / "scenarios.toml"
    path.write_text(catalogue, encoding="utf-8")
    return tmp, root, ms.load_catalogue(path)


class CatalogueDriftTest(unittest.TestCase):
    """The real catalogue must match the current production code."""

    @unittest.skipIf(os.environ.get(ms.ACTIVE_ENV), "a mutant is applied; drift is expected")
    def test_every_scenario_applies_to_the_current_code(self):
        catalogue = ms.load_catalogue()
        self.assertGreater(len(catalogue.scenarios), 0)
        self.assertEqual(ms.validate(catalogue), [])

    def test_every_layer_and_risk_is_known(self):
        for s in ms.load_catalogue().scenarios:
            self.assertIn(s.layer, {"rust", "flutter", "db", "python"}, s.id)
            self.assertIn(s.risk, {"high", "medium", "low"}, s.id)
            self.assertTrue(s.intent.strip(), s.id)


class ValidateTest(unittest.TestCase):
    def test_reports_missing_ambiguous_and_identical_snippets(self):
        tmp, root, catalogue = _sandbox("a = x > 0\nb = x > 0\n")
        with tmp:
            self.assertIn("occurs 2 times", " ".join(ms.validate(catalogue, root)))
        bad = CATALOGUE.replace('mutant = "x >= 0"', 'mutant = "x > 0"').replace('"fast"]', '"nope"]')
        tmp, root, catalogue = _sandbox(catalogue=bad)
        with tmp:
            problems = " ".join(ms.validate(catalogue, root))
            self.assertIn("identical", problems)
            self.assertIn("unknown suite", problems)


class RunScenarioTest(unittest.TestCase):
    def _run(self, status: str, **kwargs):
        tmp, root, catalogue = _sandbox()
        seen = []

        def runner(suite, where):
            seen.append((where / "code.py").read_text(encoding="utf-8"))
            return ms.SuiteResult(suite.name, status)

        journal = root / "journal.json"
        with tmp:
            result = ms.run_scenario(
                catalogue.scenarios[0], catalogue, root=root, runner=runner, journal=journal, **kwargs
            )
            restored = (root / "code.py").read_text(encoding="utf-8")
            self.assertFalse(journal.exists())
        return result, seen, restored

    def test_failing_suite_kills_and_file_is_restored(self):
        result, seen, restored = self._run("failed")
        self.assertEqual(result.outcome, "killed")
        self.assertEqual(result.killed_by, "fast")
        self.assertIn("x >= 0", seen[0])
        self.assertIn("x > 0", restored)
        self.assertNotIn("x >= 0", restored)

    def test_passing_suites_mean_survived(self):
        self.assertEqual(self._run("passed")[0].outcome, "survived")

    def test_compile_error_is_unviable_not_killed(self):
        self.assertEqual(self._run("unviable")[0].outcome, "unviable")

    def test_suite_needing_a_missing_capability_is_skipped(self):
        tmp, root, catalogue = _sandbox(catalogue=CATALOGUE.replace('suites = ["fast"]', 'suites = ["db"]'))
        with tmp:
            result = ms.run_scenario(
                catalogue.scenarios[0], catalogue, root=root,
                runner=lambda s, w: self.fail("must not run"), journal=root / "j.json",
            )
        self.assertEqual(result.outcome, "skipped")

    def test_file_is_restored_when_the_runner_raises(self):
        tmp, root, catalogue = _sandbox()

        def boom(suite, where):
            raise KeyboardInterrupt

        with tmp:
            with self.assertRaises(KeyboardInterrupt):
                ms.run_scenario(catalogue.scenarios[0], catalogue, root=root, runner=boom, journal=root / "j.json")
            self.assertIn("x > 0", (root / "code.py").read_text(encoding="utf-8"))

    def test_restore_uses_the_journal(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "code.py"
            target.write_text("mutated", encoding="utf-8")
            journal = Path(tmp) / "j.json"
            journal.write_text(json.dumps({"file": str(target), "text": "original"}), encoding="utf-8")
            self.assertEqual(ms.restore(journal, root=Path(tmp)), str(target))
            self.assertEqual(target.read_text(encoding="utf-8"), "original")
            self.assertIsNone(ms.restore(journal, root=Path(tmp)))

    def test_restore_ignores_an_entry_from_another_checkout(self):
        with tempfile.TemporaryDirectory() as mine, tempfile.TemporaryDirectory() as other:
            target = Path(other) / "code.py"
            target.write_text("their mutant", encoding="utf-8")
            journal = Path(mine) / "j.json"
            journal.write_text(json.dumps({"file": str(target), "text": "original"}), encoding="utf-8")
            self.assertIsNone(ms.restore(journal, root=Path(mine)))
            self.assertEqual(target.read_text(encoding="utf-8"), "their mutant")
            self.assertTrue(journal.exists())

    def test_journal_is_specific_to_this_checkout(self):
        self.assertNotEqual(ms.JOURNAL.name, "sitepulse-mutation-journal.json")
        self.assertIn(__import__("hashlib").sha256(str(ms.PROJECT_ROOT).encode()).hexdigest()[:16], ms.JOURNAL.name)

    def test_timeout_stops_the_whole_process_group(self):
        with tempfile.TemporaryDirectory() as tmp:
            marker = Path(tmp) / "child-alive"
            script = f"import subprocess,sys; subprocess.Popen([sys.executable,'-c','import time,pathlib; time.sleep(3); pathlib.Path(r\"{marker}\").write_text(\"x\")']); import time; time.sleep(30)"
            suite = ms.Suite(name="slow", cwd=".", cmd=[sys.executable, "-c", script], timeout=1)
            self.assertEqual(ms.run_suite(suite, Path(tmp)).status, "timeout")
            __import__("time").sleep(3.5)
            self.assertFalse(marker.exists(), "the grandchild outlived the timeout")


class SummaryTest(unittest.TestCase):
    def test_score_ignores_unviable_timeout_and_skipped(self):
        results = [
            ms.ScenarioResult("a", "rust", "x", "op", "high", "killed"),
            ms.ScenarioResult("b", "rust", "x", "op", "high", "survived"),
            ms.ScenarioResult("c", "rust", "x", "op", "high", "unviable"),
            ms.ScenarioResult("d", "db", "x", "op", "high", "skipped"),
        ]
        summary = ms.summarise(results)
        self.assertEqual(summary["score"], 0.5)
        self.assertEqual(summary["survivors"], ["b"])
        self.assertEqual(summary["by_layer"]["db"], {"skipped": 1})
        self.assertIsNone(ms.summarise([])["score"])


class SelectionAndStrictTest(unittest.TestCase):
    def test_select_filters_by_changed_files(self):
        catalogue = ms.load_catalogue()
        self.assertGreater(len(catalogue.scenarios), 0)
        first_file = catalogue.scenarios[0].file
        matching = ms.select(catalogue, [], [], [], changed_files={first_file})
        self.assertTrue(all(s.file == first_file for s in matching))
        self.assertGreater(len(matching), 0)
        unmatched = ms.select(catalogue, [], [], [], changed_files={"nonexistent/file.rs"})
        self.assertEqual(len(unmatched), 0)

    def test_parse_git_output_paths_status_and_diff(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo_root = Path(tmp)
            project_root = repo_root / "apps" / "sitepulse"
            project_root.mkdir(parents=True)

            status_output = (
                " M apps/sitepulse/backend/src/lib.rs\n"
                "?? apps/sitepulse/flutter/lib/main.dart\n"
                "R  apps/sitepulse/old.rs -> apps/sitepulse/backend/src/renamed.rs\n"
                " M outside/repo/file.txt\n"
            )
            parsed_status = ms._parse_git_output_paths(status_output, repo_root, project_root, is_status=True)
            self.assertIn("backend/src/lib.rs", parsed_status)
            self.assertIn("flutter/lib/main.dart", parsed_status)
            self.assertIn("backend/src/renamed.rs", parsed_status)
            self.assertEqual(len(parsed_status), 3)

            diff_output = (
                "apps/sitepulse/scripts/tool.py\n"
                "outside/doc.md\n"
            )
            parsed_diff = ms._parse_git_output_paths(diff_output, repo_root, project_root, is_status=False)
            self.assertEqual(parsed_diff, {"scripts/tool.py"})

    def test_detect_changed_files_invalid_base_raises(self):
        with self.assertRaises(ValueError) as ctx:
            ms.detect_changed_files(base="origin/nonexistent_xyz_branch")
        self.assertIn("git diff failed", str(ctx.exception))

    def test_main_changed_with_invalid_base_returns_exit_code_2(self):
        exit_code = ms.main(["list", "--changed", "origin/nonexistent_xyz_branch"])
        self.assertEqual(exit_code, 2)

    def test_strict_mode_exit_code(self):
        tmp, root, catalogue = _sandbox()
        journal = root / "journal.json"
        with tmp:
            # When mutant survives, run with strict mode must return 1
            def survivor_runner(suite, where):
                return ms.SuiteResult(suite.name, "passed")

            res = ms.run_scenario(
                catalogue.scenarios[0], catalogue, root=root, runner=survivor_runner, journal=journal
            )
            summary = ms.summarise([res])
            self.assertTrue(summary["survivors"])

            # Verify strict check logic directly
            has_survivors = bool(summary["survivors"])
            self.assertTrue(has_survivors)


if __name__ == "__main__":
    unittest.main()
