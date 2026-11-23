"""Tests for scripts/ci_mutation_report.py."""
import importlib.util
import json
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


mr = _load("ci_mutation_report")


class CiMutationReportTest(unittest.TestCase):
    def _write_complete_fixture(self, root: Path, outcome: str = "killed") -> tuple[Path, Path]:
        reports = root / "shards"
        catalogue = root / "scenarios.toml"
        catalogue.write_text(
            '[[scenario]]\nid = "PY-1"\nlayer = "python"\nrisk = "high"\nsuites = ["python-tests"]\n\n'
            '[[scenario]]\nid = "RS-1"\nlayer = "rust"\nrisk = "high"\nsuites = ["rust-tests"]\n',
            encoding="utf-8",
        )
        for layer, filename in mr.SHARD_FILES.items():
            shard = reports / f"mutation-shard-{layer}"
            shard.mkdir(parents=True)
            rows = []
            if layer in ("python", "rust"):
                scenario_id = "PY-1" if layer == "python" else "RS-1"
                suite = f"{layer}-tests"
                rows = [{"id": scenario_id, "layer": layer, "risk": "high", "outcome": outcome,
                         "killed_by": suite if outcome == "killed" else None,
                         "suites": [{"suite": suite, "status": "failed" if outcome == "killed" else "passed",
                                     "baseline_status": "passed"}]}]
            (shard / filename).write_text(json.dumps({"results": rows}), encoding="utf-8")
        return reports, catalogue

    def test_aggregate_reports_combines_layers_and_scores(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            payload_py = {
                "results": [
                    {"id": "MUT-PY-001", "layer": "python", "area": "lint", "operator": "op", "risk": "high", "outcome": "killed"}
                ]
            }
            payload_rust = {
                "results": [
                    {"id": "MUT-RS-001", "layer": "rust", "area": "dues", "operator": "op", "risk": "high", "outcome": "killed"},
                    {"id": "MUT-RS-002", "layer": "dues", "area": "dues", "operator": "op", "risk": "high", "outcome": "survived"},
                    {"id": "MUT-RS-003", "layer": "rust", "area": "dues", "operator": "op", "risk": "high",
                     "outcome": "unscored", "suites": [{"suite": "rust-unit", "baseline_status": "failed",
                                                              "baseline_tail": "baseline assertion failed"}]}
                ]
            }
            (tmp_path / "py.json").write_text(json.dumps(payload_py), encoding="utf-8")
            (tmp_path / "rust.json").write_text(json.dumps(payload_rust), encoding="utf-8")

            aggregated = mr.aggregate_reports([tmp_path / "py.json", tmp_path / "rust.json"])
            summary = aggregated["summary"]

            self.assertEqual(summary["total_scenarios"], 4)
            self.assertEqual(summary["killed"], 2)
            self.assertEqual(summary["survived"], 1)
            self.assertEqual(summary["unscored"], 1)
            self.assertEqual(summary["unscored_ids"], ["MUT-RS-003"])
            self.assertAlmostEqual(summary["score"], 2 / 3)
            self.assertEqual(summary["survivors"], ["MUT-RS-002"])

            md = mr.format_markdown(aggregated)
            self.assertIn("67%", md)
            self.assertIn("MUT-RS-002", md)
            self.assertIn("MUT-RS-003", md)
            self.assertIn("baseline assertion failed", md)

    def test_strict_run_reports_baseline_failure_even_when_another_suite_kills(self):
        with tempfile.TemporaryDirectory() as tmp:
            reports = Path(tmp)
            (reports / "mutation.json").write_text(json.dumps({"results": [{
                "id": "MUT-RS-004", "layer": "rust", "area": "dues", "operator": "op",
                "risk": "high", "outcome": "killed", "killed_by": "rust-integration",
                "killed_test": "statement_access::rejects_tenant",
                "suites": [
                    {"suite": "rust-unit", "status": "unscored", "baseline_status": "failed",
                     "baseline_tail": "clean unit test failed"},
                    {"suite": "rust-integration", "status": "failed", "baseline_status": "passed",
                     "failure_test": "statement_access::rejects_tenant"},
                ],
            }]}), encoding="utf-8")

            aggregated = mr.aggregate_reports([reports / "mutation.json"])
            self.assertEqual(aggregated["summary"]["killed"], 1)
            self.assertEqual(aggregated["summary"]["unscored"], 0)
            self.assertEqual(aggregated["summary"]["baseline_failures"][0]["affected_ids"], ["MUT-RS-004"])
            markdown = mr.format_markdown(aggregated)
            self.assertIn("Failed clean baselines", markdown)
            self.assertIn("clean unit test failed", markdown)
            self.assertIn("statement_access::rejects_tenant", markdown)
            self.assertEqual(mr.main(["--reports-dir", str(reports), "--strict"]), 1)

    def test_main_with_nested_artifact_directories_and_strict(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            reports_dir, catalogue = self._write_complete_fixture(tmp_path)
            out_dir = tmp_path / "out"
            args = ["--reports-dir", str(reports_dir), "--catalogue", str(catalogue), "--out", str(out_dir), "--strict"]
            code = mr.main(args)
            self.assertEqual(code, 0)
            self.assertTrue((out_dir / "mutation_summary.json").exists())
            self.assertTrue((out_dir / "mutation_summary.md").exists())

            # Failing run with survivor
            (reports_dir / "mutation-shard-rust" / "mutation_rust.json").write_text(
                json.dumps({"results": [{"id": "RS-1", "layer": "rust", "area": "dues", "operator": "op", "risk": "high", "outcome": "survived", "suites": [{"suite": "rust-tests", "status": "passed", "baseline_status": "passed"}]}]}), encoding="utf-8"
            )
            code_failing = mr.main(args)
            self.assertEqual(code_failing, 1)

            # A failed clean baseline must also fail the strict nightly report.
            (reports_dir / "mutation-shard-rust" / "mutation_rust.json").write_text(
                json.dumps({"results": [{"id": "RS-3", "layer": "rust", "area": "dues", "operator": "op",
                                          "risk": "high", "outcome": "unscored", "suites": [{
                                              "suite": "rust-tests", "status": "unscored", "baseline_status": "failed",
                                              "baseline_tail": "clean test suite failed"}]}]}), encoding="utf-8"
            )
            code_unscored = mr.main(args)
            self.assertEqual(code_unscored, 1)

    def test_strict_incomplete_evidence_still_writes_reports(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            reports, catalogue = self._write_complete_fixture(root)
            rust_file = reports / "mutation-shard-rust" / "mutation_rust.json"
            rust_file.write_text('{not-json', encoding="utf-8")
            (reports / "mutation-shard-python" / "mutation_python.json").write_text(
                json.dumps({"results": [
                    {"id": "PY-1", "layer": "python", "outcome": "killed", "killed_by": "python-tests",
                     "suites": []},
                    {"id": "PY-1", "layer": "python", "outcome": "killed", "killed_by": "python-tests",
                     "suites": [{"suite": "python-tests", "status": "failed", "baseline_status": "passed"}]},
                    {"id": "EXTRA", "layer": "python", "outcome": "survived"},
                ]}), encoding="utf-8")
            (reports / "mutation-shard-db" / "mutation_db.json").unlink()
            (reports / "mutation-shard-db").rmdir()
            (reports / "mutation-shard-flutter" / "mutation_flutter.json").unlink()
            out = root / "out"
            code = mr.main(["--reports-dir", str(reports), "--catalogue", str(catalogue), "--out", str(out), "--strict"])
            self.assertEqual(code, 1)
            self.assertTrue((out / "mutation_summary.json").is_file())
            self.assertTrue((out / "mutation_summary.md").is_file())
            summary = json.loads((out / "mutation_summary.json").read_text(encoding="utf-8"))["summary"]
            diagnostics = "\n".join(summary["incompleteness"])
            for phrase in ("malformed or unreadable report", "duplicate scenario ID", "unexpected scenario ID",
                           "missing expected scenario ID", "missing required-suite evidence",
                           "missing required shard", "missing required payload"):
                self.assertIn(phrase, diagnostics)


if __name__ == "__main__":
    unittest.main()
