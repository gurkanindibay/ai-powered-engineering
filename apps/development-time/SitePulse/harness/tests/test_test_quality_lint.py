"""Tests for the test-quality ratchet and its shortcut detectors."""
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "test_quality_lint.py"
spec = importlib.util.spec_from_file_location("test_quality_lint", SCRIPT)
test_quality_lint = importlib.util.module_from_spec(spec)
sys.modules["test_quality_lint"] = test_quality_lint
spec.loader.exec_module(test_quality_lint)


class TestQualityLintTests(unittest.TestCase):
    def test_counts_baselined_shortcuts_and_per_test_scenario_cap(self):
        with tempfile.TemporaryDirectory() as temp:
            repo = Path(temp)
            rel = "apps/development-time/SitePulse/backend/tests/example.rs"
            path = repo / rel
            path.parent.mkdir(parents=True)
            path.write_text(
                "#[test]\nfn weak() {\n"
                "    assert!(operation().is_err());\n"
                "    thread::" + "sleep(Duration::from_millis(1));\n"
                "    std::env::" + "set_var(\"SITE\", \"test\");\n"
                "    let _clock = Utc::now();\n}\n",
                encoding="utf-8",
            )
            tests = [{
                "lang": "rust", "file": rel, "line": 1, "end": 6, "name": "weak",
                "flags": ["only-unwrap (passes if nothing panics)"], "scenarios_claimed": 4,
            }]

            counts, overages, findings = test_quality_lint.analyze(repo, tests)

        self.assertEqual(counts["any-error-is-err-checks"], 1)
        self.assertEqual(counts["fixed-sleep-calls"], 1)
        self.assertEqual(counts["environment-mutations"], 1)
        self.assertEqual(counts["utc-now-backend-test-reads"], 1)
        self.assertEqual(counts["unwrap-only-tests"], 1)
        self.assertEqual(overages, {f"{rel}::weak": 4})
        self.assertEqual({finding.rule for finding in findings}, {
            "any-error-is-err", "fixed-sleep", "environment-mutation", "utc-now-in-backend-test", "unwrap-only-test",
        })

    def test_existing_baseline_is_allowed_and_new_findings_include_locations(self):
        baseline = {
            "counts": {"fixed-sleep-calls": 2},
            "over_limit_tests": {"example.rs::test_existing": 5},
        }
        findings = [test_quality_lint.Finding("fixed-sleep", "example.rs", 12, "sleep()")]
        allowed = test_quality_lint.compare_to_baseline(
            {"fixed-sleep-calls": 2}, {"example.rs::test_existing": 5}, baseline, findings,
        )
        self.assertEqual(allowed, [])

        exceeded = test_quality_lint.compare_to_baseline(
            {"fixed-sleep-calls": 3},
            {"example.rs::test_existing": 6, "example.rs::new_test": 4},
            baseline,
            findings,
        )
        self.assertEqual([item["rule"] for item in exceeded], [
            "fixed-sleep-calls", "scenarios-per-test", "scenarios-per-test",
        ])
        self.assertEqual(exceeded[0]["examples"][0]["line"], 12)

    def test_improvement_requires_baseline_update_and_new_scenario_claim_has_rename_hint(self):
        baseline = {
            "counts": {"fixed-sleep-calls": 2},
            "over_limit_tests": {"example.rs::old_name": 5},
        }
        exceeded = test_quality_lint.compare_to_baseline(
            {"fixed-sleep-calls": 1}, {"example.rs::new_name": 5}, baseline, [],
        )
        self.assertEqual([item["rule"] for item in exceeded], ["fixed-sleep-calls", "scenarios-per-test"])
        self.assertIn("--update-baseline", exceeded[0]["message"])
        self.assertIn("renamed or moved", exceeded[1]["message"])

    def test_committed_workspace_baseline_passes(self):
        project = SCRIPT.parents[1]
        repo = project.parents[2]
        baseline = project / "scripts" / "test_quality_baseline.json"
        report = test_quality_lint.lint(repo, baseline)
        self.assertTrue(report["passed"], json.dumps(report["ratchet_exceeded"], indent=2))


if __name__ == "__main__":
    unittest.main()
