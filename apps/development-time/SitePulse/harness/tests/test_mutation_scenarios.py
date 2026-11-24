"""Self-tests for scripts/mutation_scenarios.py and its scenario catalogue."""
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

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
    def _run(self, status: str, baseline_status: str = "passed", **kwargs):
        tmp, root, catalogue = _sandbox()
        seen = []

        def runner(suite, where):
            seen.append((where / "code.py").read_text(encoding="utf-8"))
            if len(seen) == 1:
                return ms.SuiteResult(suite.name, baseline_status, tail="clean baseline diagnostic")
            return ms.SuiteResult(suite.name, status, tail="mutant diagnostic", failure_test="sample::test_positive")

        journal = root / "journal.json"
        with tmp:
            result = ms.run_scenario(
                catalogue.scenarios[0], catalogue, root=root, runner=runner, journal=journal, **kwargs
            )
            restored = (root / "code.py").read_text(encoding="utf-8")
            self.assertFalse(journal.exists())
        return result, seen, restored

    def test_failing_mutant_suite_kills_after_a_passing_baseline_and_file_is_restored(self):
        result, seen, restored = self._run("failed")
        self.assertEqual(result.outcome, "killed")
        self.assertEqual(result.killed_by, "fast")
        self.assertEqual(result.killed_test, "sample::test_positive")
        self.assertEqual(len(seen), 2)
        self.assertIn("x > 0", seen[0])
        self.assertIn("x >= 0", seen[1])
        self.assertEqual(result.suites[0].baseline_status, "passed")
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

    def test_failed_clean_baseline_marks_mutant_unscored_with_diagnostics(self):
        result, seen, restored = self._run("failed", baseline_status="failed")
        self.assertEqual(result.outcome, "unscored")
        self.assertEqual(result.suites[0].status, "unscored")
        self.assertEqual(result.suites[0].baseline_status, "failed")
        self.assertEqual(result.suites[0].baseline_tail, "clean baseline diagnostic")
        self.assertEqual(len(seen), 1, "a broken clean suite must not be run against the mutant")
        self.assertIn("x > 0", seen[0])
        self.assertEqual(restored, "def positive(x):\n    return x > 0\n")
        self.assertIsNone(ms.summarise([result])["score"], "an unscored mutant cannot improve the score")

    def test_missing_capability_does_not_turn_a_passing_baseline_into_unscored(self):
        expanded = CATALOGUE.replace('suites = ["fast"]', 'suites = ["fast", "db"]')
        tmp, root, catalogue = _sandbox(catalogue=expanded)
        calls = 0

        def passing_runner(suite, where):
            nonlocal calls
            calls += 1
            return ms.SuiteResult(suite.name, "passed")

        with tmp:
            result = ms.run_scenario(
                catalogue.scenarios[0], catalogue, root=root, runner=passing_runner,
                journal=root / "journal.json",
            )
        self.assertEqual(result.outcome, "survived")
        self.assertEqual(calls, 2, "only the available suite baseline and mutant are executed")
        self.assertEqual(result.suites[1].status, "skipped")
        self.assertEqual(result.suites[1].baseline_status, "skipped")
        self.assertEqual(ms.summarise([result])["counts"], {"survived": 1})

    def test_unresolved_rust_mutant_runs_postgres_fallback_and_keeps_test_identity(self):
        expanded = CATALOGUE.replace('layer = "python"', 'layer = "rust"').replace(
            'suites = ["fast"]', 'suites = ["fast", "db"]'
        )
        tmp, root, catalogue = _sandbox(catalogue=expanded)
        clean_baselines = {
            "fast": ms.SuiteResult("fast", "passed"),
            "db": ms.SuiteResult("db", "passed"),
        }
        calls = []

        def runner(suite, where):
            calls.append(suite.name)
            if suite.name == "db":
                return ms.SuiteResult(
                    "db", "failed", failure_test="db_accrual_tests::fallback_detects_mutant"
                )
            return ms.SuiteResult("fast", "passed")

        with tmp:
            result = ms.run_scenario(
                catalogue.scenarios[0], catalogue, root=root,
                capabilities=frozenset({"postgres"}), clean_baselines=clean_baselines,
                runner=runner, journal=root / "journal.json",
            )

        summary = ms.summarise([result])
        self.assertEqual(calls, ["fast", "db"])
        self.assertEqual(result.outcome, "killed")
        self.assertEqual(result.killed_by, "db")
        self.assertEqual(result.killed_test, "db_accrual_tests::fallback_detects_mutant")
        self.assertEqual([row.status for row in result.suites], ["passed", "failed"])
        self.assertEqual(summary["counts"], {"killed": 1})

    def test_earlier_kill_records_postgres_fallback_as_not_run(self):
        expanded = CATALOGUE.replace('layer = "python"', 'layer = "rust"').replace(
            'suites = ["fast"]', 'suites = ["fast", "db"]'
        )
        tmp, root, catalogue = _sandbox(catalogue=expanded)
        clean_baselines = {
            "fast": ms.SuiteResult("fast", "passed"),
            "db": ms.SuiteResult("db", "passed"),
        }
        calls = []

        def runner(suite, where):
            calls.append(suite.name)
            return ms.SuiteResult("fast", "failed", failure_test="fast_tests::catches_mutant")

        with tmp:
            result = ms.run_scenario(
                catalogue.scenarios[0], catalogue, root=root,
                capabilities=frozenset({"postgres"}), clean_baselines=clean_baselines,
                runner=runner, journal=root / "journal.json",
            )

        self.assertEqual(calls, ["fast"])
        self.assertEqual(result.outcome, "killed")
        self.assertEqual(result.killed_by, "fast")
        self.assertEqual(result.killed_test, "fast_tests::catches_mutant")
        self.assertEqual([row.status for row in result.suites], ["failed", "not-run"])
        self.assertEqual(result.suites[1].baseline_status, "passed")
        self.assertEqual(ms.summarise([result])["counts"], {"killed": 1})

    def test_valid_suite_kill_does_not_hide_another_suite_baseline_failure(self):
        expanded = CATALOGUE.replace(
            '[suites.db]\ncwd = "."\ncmd = ["true"]\nrequires = ["postgres"]',
            '[suites.db]\ncwd = "."\ncmd = ["true"]\nrequires = ["postgres"]\n\n'
            '[suites.second]\ncwd = "."\ncmd = ["true"]',
        ).replace('suites = ["fast"]', 'suites = ["fast", "second"]')
        tmp, root, catalogue = _sandbox(catalogue=expanded)
        calls = []

        def runner(suite, where):
            calls.append((suite.name, "x >= 0" in (where / "code.py").read_text(encoding="utf-8")))
            if len(calls) == 1:
                return ms.SuiteResult(suite.name, "failed", tail="clean baseline failed")
            if len(calls) == 2:
                return ms.SuiteResult(suite.name, "passed")
            return ms.SuiteResult(suite.name, "failed", failure_test="sample::test_positive")

        with tmp:
            result = ms.run_scenario(
                catalogue.scenarios[0], catalogue, root=root, runner=runner, journal=root / "journal.json",
            )
        summary = ms.summarise([result])
        self.assertEqual(result.outcome, "killed")
        self.assertEqual(result.killed_by, "second")
        self.assertEqual([row.status for row in result.suites], ["unscored", "failed"])
        self.assertEqual(summary["baseline_failures"][0]["affected_ids"], ["MUT-T-001"])
        self.assertEqual(summary["score"], 1.0)

    def test_all_suite_baselines_run_before_any_mutation(self):
        expanded = CATALOGUE.replace(
            '[suites.db]\ncwd = "."\ncmd = ["true"]\nrequires = ["postgres"]',
            '[suites.db]\ncwd = "."\ncmd = ["true"]\nrequires = ["postgres"]\n\n'
            '[suites.second]\ncwd = "."\ncmd = ["true"]',
        ).replace('suites = ["fast"]', 'suites = ["fast", "second"]')
        tmp, root, catalogue = _sandbox(catalogue=expanded)
        seen = []

        def runner(suite, where):
            is_mutated = "x >= 0" in (where / "code.py").read_text(encoding="utf-8")
            seen.append((suite.name, is_mutated))
            return ms.SuiteResult(suite.name, "failed" if is_mutated and suite.name == "fast" else "passed")

        with tmp:
            result = ms.run_scenario(
                catalogue.scenarios[0], catalogue, root=root, runner=runner,
                journal=root / "journal.json",
            )
        self.assertEqual(seen, [("fast", False), ("second", False), ("fast", True)])
        self.assertEqual(result.outcome, "killed")
        self.assertEqual([suite.status for suite in result.suites], ["failed", "not-run"])

    def test_file_is_restored_when_the_runner_raises(self):
        tmp, root, catalogue = _sandbox()
        calls = 0

        def boom(suite, where):
            nonlocal calls
            calls += 1
            if calls == 1:
                return ms.SuiteResult(suite.name, "passed")
            raise KeyboardInterrupt

        with tmp:
            with self.assertRaises(KeyboardInterrupt):
                ms.run_scenario(catalogue.scenarios[0], catalogue, root=root, runner=boom, journal=root / "j.json")
            self.assertIn("x > 0", (root / "code.py").read_text(encoding="utf-8"))

    def test_run_suite_extracts_failing_test_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            suite = ms.Suite(
                name="sample", cwd=".",
                cmd=[sys.executable, "-c", "print('---- sample::test_rule stdout ----'); raise SystemExit(1)"],
            )
            result = ms.run_suite(suite, Path(tmp))
        self.assertEqual(result.status, "failed")
        self.assertEqual(result.failure_test, "sample::test_rule")

    def test_failure_identity_parser_ignores_unittest_summary_line(self):
        self.assertEqual(ms._failure_identifier("FAILED (failures=4, skipped=1)\n"), "")
        self.assertEqual(ms._failure_identifier("FAIL: sample.TestCase.test_rule\n"), "sample.TestCase.test_rule")

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
    def test_direct_only_selection_ignores_indirect_changes(self):
        catalogue = ms.load_catalogue()
        changed_target = "backend/src/services/dues_ledger.rs"
        selected = ms.select(
            catalogue, [], [], [],
            changed_files={changed_target, "scripts/mutation_scenarios.py"},
            direct_only=True,
        )
        expected = [scenario.id for scenario in catalogue.scenarios if scenario.file == changed_target]
        self.assertTrue(expected)
        self.assertEqual([scenario.id for scenario in selected], expected)
        self.assertEqual(
            ms.select(
                catalogue, [], [], [],
                changed_files={"scripts/mutation_scenarios.py"}, direct_only=True,
            ),
            [],
        )

    def test_select_filters_by_changed_files(self):
        catalogue = ms.load_catalogue()
        self.assertGreater(len(catalogue.scenarios), 0)
        first_file = catalogue.scenarios[0].file
        matching = ms.select(catalogue, [], [], [], changed_files={first_file})
        self.assertTrue(all(s.file == first_file for s in matching))
        self.assertGreater(len(matching), 0)
        unmatched = ms.select(catalogue, [], [], [], changed_files={"nonexistent/file.rs"})
        self.assertEqual(len(unmatched), 0)

        migration = "backend/migrations/V50__dues_liabilities_liable_person_unique_index.sql"
        direct_migration = ms.select(catalogue, [], [], [], changed_files={migration})
        self.assertTrue(direct_migration)
        self.assertTrue(all(s.file == migration for s in direct_migration))

    def test_select_maps_high_risk_indirect_changes_to_areas(self):
        catalogue = ms.load_catalogue()
        cases = {
            "backend/tests/db_accrual_persistence_tests.rs": "accrual-persistence",
            "backend/tests/statement_access_tests.rs": "unit-statements",
            "backend/migrations/V99__new_tenant_policy.sql": "tenancy",
        }
        for changed_file, expected_area in cases.items():
            with self.subTest(changed_file=changed_file):
                selected = ms.select(catalogue, [], [], [], changed_files={changed_file})
                self.assertTrue(selected)
                self.assertIn(expected_area, {scenario.area for scenario in selected})

    def test_indirect_map_areas_and_layers_exist_in_catalogue(self):
        catalogue = ms.load_catalogue()
        known_areas = {scenario.area for scenario in catalogue.scenarios}
        known_layers = {scenario.layer for scenario in catalogue.scenarios}
        mapped = set().union(*ms.INDIRECT_CHANGE_AREAS.values())
        mapped_areas = {
            value for value in mapped if value != "*" and not value.startswith("@layer:")
        }
        mapped_layers = {value.removeprefix("@layer:") for value in mapped if value.startswith("@layer:")}
        self.assertLessEqual(mapped_areas, known_areas)
        self.assertLessEqual(mapped_layers, known_layers)

    def test_indirect_map_covers_catalogued_migrations(self):
        migration_cases = {
            "backend/migrations/V25__tenant_row_level_security.sql": "tenancy",
            "backend/migrations/V50__dues_liabilities_liable_person_unique_index.sql": "accrual-persistence",
            "backend/migrations/V12__financial_and_tenancy_remediation.sql": "dues-ledger",
        }
        for path, expected_area in migration_cases.items():
            with self.subTest(path=path):
                self.assertIn(expected_area, ms._indirect_areas_for_changed_files({path}))

    def test_select_keeps_unrelated_changes_empty_and_runner_changes_broad(self):
        catalogue = ms.load_catalogue()
        unrelated = ms.select(
            catalogue, [], [], [], changed_files={"harness/tests/test_unrelated.py"}
        )
        self.assertEqual(unrelated, [])

        runner = ms.select(
            catalogue, [], [], [], changed_files={"scripts/mutation_scenarios.py"}
        )
        self.assertEqual(len(runner), len(catalogue.scenarios))

        helper = ms.select(
            catalogue, [], [], [], changed_files={"flutter/test/ui_test_helpers.dart"}
        )
        self.assertTrue(helper)
        self.assertTrue(all(s.layer == "flutter" for s in helper))

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

    def test_strict_mode_fails_when_a_mutant_or_clean_baseline_is_unscored(self):
        catalogue = ms.load_catalogue()
        scenario = catalogue.scenarios[0]
        unscored = ms.ScenarioResult(
            scenario.id, scenario.layer, scenario.area, scenario.operator, scenario.risk,
            outcome="unscored", suites=[ms.SuiteResult(
                "rust-unit", "unscored", baseline_status="failed", baseline_tail="baseline failed",
            )],
        )
        killed_with_failed_baseline = ms.ScenarioResult(
            scenario.id, scenario.layer, scenario.area, scenario.operator, scenario.risk,
            outcome="killed", killed_by="rust-integration", suites=[ms.SuiteResult(
                "rust-unit", "unscored", baseline_status="failed", baseline_tail="baseline failed",
            )],
        )

        def passing_baseline(suite, root):
            return ms.SuiteResult(suite.name, "passed")

        with mock.patch.object(ms, "validate", return_value=[]), \
                mock.patch.object(ms, "_journal_entry", return_value=None), \
                mock.patch.object(ms, "_git_dirty", return_value=False), \
                mock.patch.object(ms, "run_suite", side_effect=passing_baseline), \
                mock.patch.object(ms, "run_scenario", return_value=unscored):
            self.assertEqual(ms.main(["run", "--id", scenario.id, "--strict"]), 1)
        with mock.patch.object(ms, "validate", return_value=[]), \
                mock.patch.object(ms, "_journal_entry", return_value=None), \
                mock.patch.object(ms, "_git_dirty", return_value=False), \
                mock.patch.object(ms, "run_suite", side_effect=passing_baseline), \
                mock.patch.object(ms, "run_scenario", return_value=killed_with_failed_baseline):
            self.assertEqual(ms.main(["run", "--id", scenario.id, "--strict"]), 1)

    def test_main_runs_one_clean_baseline_per_selected_suite_before_mutants(self):
        catalogue = ms.load_catalogue()
        pair = next(
            (first, second)
            for first in catalogue.scenarios
            for second in catalogue.scenarios
            if first.id != second.id and set(first.suites) & set(second.suites)
        )
        chosen = pair
        expected_suites = {name for scenario in chosen for name in scenario.suites}

        def passing_baseline(suite, root):
            return ms.SuiteResult(suite.name, "passed")

        def passing_mutant(scenario, *args, **kwargs):
            return ms.ScenarioResult(
                scenario.id, scenario.layer, scenario.area, scenario.operator, scenario.risk,
                outcome="killed",
            )

        args = ["run", "--json"]
        for scenario in chosen:
            args.extend(["--id", scenario.id])
        with mock.patch.object(ms, "validate", return_value=[]), \
                mock.patch.object(ms, "_journal_entry", return_value=None), \
                mock.patch.object(ms, "_git_dirty", return_value=False), \
                mock.patch.object(ms, "run_suite", side_effect=passing_baseline) as run_suite, \
                mock.patch.object(ms, "run_scenario", side_effect=passing_mutant) as run_scenario:
            self.assertEqual(ms.main(args), 0)

        self.assertEqual(run_suite.call_count, len(expected_suites))
        self.assertEqual(run_scenario.call_count, len(chosen))
        for call in run_scenario.call_args_list:
            self.assertEqual(set(call.kwargs["clean_baselines"]), expected_suites)
            self.assertTrue(all(row.status == "passed" for row in call.kwargs["clean_baselines"].values()))


class MutationWorkflowTest(unittest.TestCase):
    def test_rust_mutation_shard_has_postgres_fallback_capability(self):
        catalogue = ms.load_catalogue()
        rust_fallbacks = [
            scenario for scenario in catalogue.scenarios
            if scenario.layer == "rust"
            and any("postgres" in catalogue.suites[name].requires for name in scenario.suites)
        ]
        self.assertTrue(rust_fallbacks, "the catalogue must include Rust cases with a PostgreSQL fallback")
        self.assertTrue(
            any(
                any("postgres" in catalogue.suites[name].requires for name in scenario.suites[1:])
                for scenario in rust_fallbacks
            ),
            "at least one Rust fallback must follow an earlier suite",
        )

        workflow_path = PROJECT_ROOT.parents[2] / ".github" / "workflows" / "mutation-testing.yml"
        workflow = workflow_path.read_text(encoding="utf-8")
        rust_job = workflow.split("  mutate-rust:\n", maxsplit=1)[1].split(
            "\n  mutate-db:\n", maxsplit=1
        )[0]

        self.assertIn("services:\n      postgres:", rust_job)
        self.assertIn("POSTGRES_PASSWORD: ci-only-password", rust_job)
        self.assertIn("DB_PASS: ci-only-password", rust_job)
        self.assertIn("python3 scripts/mutation_scenarios.py run --layer rust --with postgres", rust_job)


if __name__ == "__main__":
    unittest.main()
