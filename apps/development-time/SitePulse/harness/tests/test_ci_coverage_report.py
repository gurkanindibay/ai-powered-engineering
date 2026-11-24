"""Unit and integration tests for ci_coverage_report, ci_test_report, and pages_site coverage."""
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS))

spec_cov = importlib.util.spec_from_file_location("ci_coverage_report", SCRIPTS / "ci_coverage_report.py")
cov = importlib.util.module_from_spec(spec_cov)
spec_cov.loader.exec_module(cov)

spec_ctr = importlib.util.spec_from_file_location("ci_test_report", SCRIPTS / "ci_test_report.py")
ctr = importlib.util.module_from_spec(spec_ctr)
spec_ctr.loader.exec_module(ctr)

spec_pages = importlib.util.spec_from_file_location("pages_site", SCRIPTS / "pages_site.py")
pages = importlib.util.module_from_spec(spec_pages)
spec_pages.loader.exec_module(pages)


class CiCoverageReportTests(unittest.TestCase):
    def test_parse_lcov_totals_with_summary_and_da_fallback(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "sample.lcov"
            p.write_text(
                "\n".join([
                    "SF:lib/a.dart",
                    "DA:1,1",
                    "DA:2,0",
                    "LF:2",
                    "LH:1",
                    "end_of_record",
                    "SF:lib/b.dart",
                    "DA:1,3",
                    "DA:2,1",
                    "BRDA:1,0,0,1",
                    "BRDA:1,0,1,0",
                    "end_of_record",
                ]),
                encoding="utf-8",
            )
            totals = cov.parse_lcov_totals(p)
            self.assertEqual(totals["lines_covered"], 3)
            self.assertEqual(totals["lines_total"], 4)
            self.assertEqual(totals["line_pct"], 75.0)
            self.assertEqual(totals["branches_covered"], 1)
            self.assertEqual(totals["branches_total"], 2)
            self.assertEqual(totals["branch_pct"], 50.0)

    def test_parse_rust_summary_and_python_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            rust_path = root / "rust-summary.json"
            rust_path.write_text(json.dumps({
                "data": [{
                    "totals": {
                        "lines": {"count": 200, "covered": 150, "percent": 75.0},
                        "branches": {"count": 0, "covered": 0, "percent": 0.0},
                    }
                }]
            }), encoding="utf-8")
            rust = cov.parse_rust_summary(rust_path)
            self.assertEqual(rust["line_pct"], 75.0)
            self.assertIsNone(rust["branch_pct"])
            self.assertEqual(rust["branches_total"], 0)

            py_path = root / "python.json"
            py_path.write_text(json.dumps({
                "totals": {
                    "num_statements": 100,
                    "covered_lines": 82,
                    "num_branches": 40,
                    "covered_branches": 30,
                }
            }), encoding="utf-8")
            py = cov.parse_python_json(py_path)
            self.assertEqual(py["line_pct"], 82.0)
            self.assertEqual(py["branch_pct"], 75.0)

    def test_normalize_lcov_and_cobertura_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            src_lcov = root / "in.lcov"
            dst_lcov = root / "out.lcov"
            src_lcov.write_text(
                "SF:/runner/work/repo/apps/development-time/SitePulse/backend/src/lib.rs\n"
                "SF:src/domain/dues.rs\n"
                "end_of_record\n",
                encoding="utf-8",
            )
            cov.normalize_lcov_file(src_lcov, dst_lcov, "apps/development-time/SitePulse/backend")
            lines = dst_lcov.read_text(encoding="utf-8").splitlines()
            self.assertEqual(lines[0], "SF:apps/development-time/SitePulse/backend/src/lib.rs")
            self.assertEqual(lines[1], "SF:apps/development-time/SitePulse/backend/src/domain/dues.rs")

            src_xml = root / "in.xml"
            dst_xml = root / "out.xml"
            src_xml.write_text(
                '<coverage><packages><package><classes>'
                '<class filename="scripts/run_tests.py" />'
                '</classes></package></packages></coverage>',
                encoding="utf-8",
            )
            cov.normalize_cobertura_xml(src_xml, dst_xml, "apps/development-time/SitePulse")
            self.assertIn('filename="apps/development-time/SitePulse/scripts/run_tests.py"',
                          dst_xml.read_text(encoding="utf-8"))

    def test_collect_coverage_and_markdown_rendering(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            artifacts = root / "artifacts"
            (artifacts / "rust" / "coverage").mkdir(parents=True)
            (artifacts / "flutter" / "coverage").mkdir(parents=True)
            (artifacts / "lint" / "coverage").mkdir(parents=True)

            (artifacts / "rust" / "coverage" / "rust-summary.json").write_text(json.dumps({
                "data": [{"totals": {"lines": {"count": 100, "covered": 80}, "branches": {"count": 0, "covered": 0}}}]
            }), encoding="utf-8")
            (artifacts / "rust" / "coverage" / "rust.lcov").write_text("SF:src/lib.rs\nLF:100\nLH:80\nend_of_record\n",
                                                                     encoding="utf-8")
            (artifacts / "flutter" / "coverage" / "flutter.lcov").write_text(
                "SF:lib/main.dart\nLF:50\nLH:35\nend_of_record\n", encoding="utf-8"
            )
            (artifacts / "lint" / "coverage" / "python.json").write_text(json.dumps({
                "totals": {"num_statements": 200, "covered_lines": 160, "num_branches": 50, "covered_branches": 40}
            }), encoding="utf-8")
            (artifacts / "lint" / "coverage" / "python.xml").write_text(
                '<coverage><packages><package><classes><class filename="scripts/a.py" /></classes></package></packages></coverage>',
                encoding="utf-8",
            )

            fake_diff = {"diff_status": "collected", "diff_lines_covered": 8, "diff_lines_total": 10, "diff_line_pct": 80.0}
            with mock.patch.object(cov, "run_diff_cover", return_value=fake_diff):
                out = root / "out"
                summary = cov.build_coverage(artifacts, out, base_ref="origin/master", repo_root=root)

            self.assertEqual(len(summary["layers"]), 3)
            self.assertEqual(summary["changed_lines"]["lines_covered"], 24)
            self.assertEqual(summary["changed_lines"]["lines_total"], 30)
            self.assertEqual(summary["changed_lines"]["line_pct"], 80.0)
            md = (out / "coverage-report.md").read_text(encoding="utf-8")
            self.assertIn("Backend (Rust)", md)
            self.assertIn("80.0% (80/100)", md)
            self.assertIn("Frontend (Flutter)", md)
            self.assertIn("70.0% (35/50)", md)
            self.assertIn("Harness & Scripts (Python)", md)
            self.assertIn("80.0% (40/50)", md)
            self.assertIn("**80.0% (24/30)**", md)

    def test_pages_site_sanitizes_and_renders_coverage(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            report = root / "report"
            report.mkdir()
            (report / "summary.json").write_text(json.dumps({
                "run_id": "20261124T120000Z-aaaaaaa",
                "commit": "a" * 40,
                "status": "PASS",
                "junit": {"tests": 1, "passed": 1, "failures": 0, "errors": 0, "skipped": 0, "seconds": 1.0},
            }), encoding="utf-8")
            (report / "public-report.json").write_text(json.dumps({
                "schema": 1,
                "gates": [],
                "cases": [],
                "coverage": {
                    "schema": 1,
                    "layers": [
                        {
                            "layer": "backend",
                            "label": "Backend (Rust)",
                            "tool": "cargo-llvm-cov",
                            "status": "collected",
                            "lines_covered": 80,
                            "lines_total": 100,
                            "line_pct": 80.0,
                            "diff_lines_covered": 9,
                            "diff_lines_total": 10,
                            "diff_line_pct": 90.0,
                            "secret_file_path": "/private/secret/path.rs",
                        },
                        {
                            "layer": "malicious_layer",
                            "label": "<script>alert(1)</script>",
                        },
                    ],
                    "changed_lines": {
                        "lines_covered": 9,
                        "lines_total": 10,
                        "line_pct": 90.0,
                        "status": "collected",
                    },
                },
            }), encoding="utf-8")

            site = root / "site"
            pages.build(site, report, "9001", "1", 1, "a" * 40, require_public_report=True)
            latest_html = (site / "latest.html").read_text(encoding="utf-8")
            self.assertIn("Code coverage (report-only)", latest_html)
            self.assertIn("80.0% (80/100)", latest_html)
            self.assertIn("90.0% (9/10)", latest_html)
            self.assertNotIn("/private/secret/path.rs", latest_html)
            self.assertNotIn("malicious_layer", latest_html)
            self.assertNotIn("<script>", latest_html)


if __name__ == "__main__":
    unittest.main()
