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
                    {"id": "MUT-RS-002", "layer": "rust", "area": "dues", "operator": "op", "risk": "high", "outcome": "survived"}
                ]
            }
            (tmp_path / "py.json").write_text(json.dumps(payload_py), encoding="utf-8")
            (tmp_path / "rust.json").write_text(json.dumps(payload_rust), encoding="utf-8")

            aggregated = mr.aggregate_reports([tmp_path / "py.json", tmp_path / "rust.json"])
            summary = aggregated["summary"]

            self.assertEqual(summary["total_scenarios"], 3)
            self.assertEqual(summary["killed"], 2)
            self.assertEqual(summary["survived"], 1)
            self.assertAlmostEqual(summary["score"], 2 / 3)
            self.assertEqual(summary["survivors"], ["MUT-RS-002"])

            md = mr.format_markdown(aggregated)
            self.assertIn("67%", md)
            self.assertIn("MUT-RS-002", md)


if __name__ == "__main__":
    unittest.main()
