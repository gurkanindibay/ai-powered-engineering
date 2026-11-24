"""The SitePulse test strategy stays the single source of truth and stays wired into the harness.

docs/testing/TEST_STRATEGY.md governs how SitePulse is tested. These checks keep agents and
harness workers pointed at it, keep the superseded documents labelled, and keep the gate fixes
the strategy relies on (sale-clearance DB tests, e2e-feature clock tests) in the gate catalogue.
"""
import importlib.util
import sys
import unittest
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]
REPO_ROOT = PROJECT_ROOT.parents[2]
STRATEGY = PROJECT_ROOT / "docs" / "testing" / "TEST_STRATEGY.md"
STRATEGY_FROM_ROOT = "apps/development-time/SitePulse/docs/testing/TEST_STRATEGY.md"

REQUIRED_SECTIONS = (
    "## Executive summary",
    "## Governance",
    "## Principles",
    "## Test levels and ownership",
    "## Test data, fixtures and environments",
    "## Execution lanes and CI",
    "## Quality signals and gates",
    "## Non-functional and security testing",
    "## Reporting and evidence",
    "## Roadmap and KPIs",
    "## Method and reproduction",
)

# Every testing document the strategy absorbed must say so at its top.
LABELLED_DOCS = (
    "docs/testing/TEST_PLAN_AND_EXECUTION_MATRIX.md",
    "docs/testing/GUI_TEST_PLAN.md",
    "docs/testing/GUI_AUTOMATION_PLAN.md",
    "docs/testing/GUI_COVERAGE_GAPS.md",
    "docs/testing/TEST_PLAN_EPIC_10_CAPITAL_EXPENDITURE.md",
    "docs/testing/test-coverage-assessment-2026-11-10.md",
    "docs/testing/mutation-testing-analysis.md",
    "docs/testing/mutation-testing-ci-integration.md",
    "docs/testing/mutation-coverage-improvement.md",
    "docs/testing/cucumber-serenity-migration-analysis.md",
    "docs/testing/test-reporting-pages-analysis.md",
    "docs/testing/journey-plan/README.md",
    "docs/engineering-process/test-time-analysis.md",
)


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


class TestStrategyDocument(unittest.TestCase):
    def test_strategy_has_every_section(self):
        text = STRATEGY.read_text(encoding="utf-8")
        missing = [s for s in REQUIRED_SECTIONS if s not in text]
        self.assertEqual(missing, [], f"TEST_STRATEGY.md lost sections: {missing}")

    def test_superseded_documents_point_to_the_strategy(self):
        unlabelled = []
        for rel in LABELLED_DOCS:
            head = "\n".join((PROJECT_ROOT / rel).read_text(encoding="utf-8").splitlines()[:6])
            if "SitePulse Test Strategy" not in head or "TEST_STRATEGY.md" not in head:
                unlabelled.append(rel)
        self.assertEqual(unlabelled, [], "these documents need the strategy banner in their first lines")


class TestStrategyIsWiredIn(unittest.TestCase):
    def test_agents_md_names_the_strategy(self):
        # Harness workers are told to read AGENTS.md (scripts/engineering_harness/engine.py).
        self.assertIn(STRATEGY_FROM_ROOT, (REPO_ROOT / "AGENTS.md").read_text(encoding="utf-8"))

    def test_tester_agent_and_test_rule_name_the_strategy(self):
        tester = (PROJECT_ROOT / ".specify" / "agents" / "tester-agent.md").read_text(encoding="utf-8")
        rule = (REPO_ROOT / ".agents" / "rules" / "test-execution-records.md").read_text(encoding="utf-8")
        self.assertIn("docs/testing/TEST_STRATEGY.md", tester)
        self.assertIn("TEST_STRATEGY.md", rule)

    def test_harness_workers_cannot_rewrite_the_strategy(self):
        # sitepulse.py uses package-relative imports, so load it through its package.
        sys.path.insert(0, str(REPO_ROOT / "scripts"))
        try:
            from engineering_harness.sitepulse import policy_for_sitepulse
        finally:
            sys.path.remove(str(REPO_ROOT / "scripts"))
        policy = policy_for_sitepulse("sha256:" + "0" * 64)
        self.assertIn(STRATEGY_FROM_ROOT, policy["protected_paths"])


class TestGateFixesTheStrategyReliesOn(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Same import setup as test_ci_case_results.py: the gate catalogue imports scripts/ modules.
        for path in (str(PROJECT_ROOT), str(PROJECT_ROOT / "scripts")):
            if path not in sys.path:
                sys.path.insert(0, path)
        from harness.loop.verification_gates import GATES
        cls.gates = GATES

    def _argvs(self, gate):
        return [" ".join(spec.argv) for spec in self.gates[gate]]

    def test_sale_clearance_postgresql_tests_run_in_the_db_gate(self):
        ignored_run = next(a for a in self._argvs("rust-db-test") if "--ignored" in a)
        self.assertIn("--test sale_clearance_tests", ignored_run)

    def test_e2e_feature_clock_tests_run_in_rust_test(self):
        feature_runs = [a for a in self._argvs("rust-test") if "--features e2e" in a]
        self.assertTrue(feature_runs, "rust-test must compile the e2e feature for the clock tests")
        self.assertIn("--test e2e_clock_tests", feature_runs[0])
        self.assertIn("--test e2e_clock_reset_tests", feature_runs[0])


class TestScannerRuns(unittest.TestCase):
    def test_scanner_finds_no_test_outside_every_gate_except_known_ones(self):
        scanner = _load("_test_strategy_scan", PROJECT_ROOT / "scripts" / "test_strategy_scan.py")
        result = scanner.scan(REPO_ROOT)
        never = {t["name"] for t in result["tests"] if t["run"] in ("never-in-ci", "silent-skip")}
        # Known and tracked in the strategy: a visual review helper, and the Google redirect
        # test that needs an identity-provider stub (roadmap phase 1).
        self.assertLessEqual(never, {"sample_receipt_pdf", "test_google_sign_in_redirects_to_the_provider"})

    def test_scanner_collects_api_system_checks_and_excludes_helpers(self):
        scanner = _load("_test_strategy_scan", PROJECT_ROOT / "scripts" / "test_strategy_scan.py")
        result = scanner.scan(REPO_ROOT)
        api_tests = [t for t in result["tests"] if t["file"].endswith("api_system_check.py")]
        api_test_names = {t["name"] for t in api_tests}
        self.assertIn("check_finance_desk", api_test_names)
        self.assertIn("check_exit_settlement_self_approval_audited", api_test_names)
        self.assertNotIn("login", api_test_names)
        self.assertNotIn("seed", api_test_names)
        self.assertNotIn("http", api_test_names)
        self.assertTrue(all(t["run"] == "ci" for t in api_tests))


if __name__ == "__main__":
    unittest.main()
