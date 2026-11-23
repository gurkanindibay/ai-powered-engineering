"""Tests for public-safe test inventory, field allowlist boundary, and failure fixture."""
import importlib.util
import json
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"

spec_ctr = importlib.util.spec_from_file_location("ci_test_report", SCRIPTS / "ci_test_report.py")
ctr = importlib.util.module_from_spec(spec_ctr)
spec_ctr.loader.exec_module(ctr)

spec_pub = importlib.util.spec_from_file_location("publish_test_report", SCRIPTS / "publish_test_report.py")
pub = importlib.util.module_from_spec(spec_pub)
spec_pub.loader.exec_module(pub)

spec_ps = importlib.util.spec_from_file_location("product_status", SCRIPTS / "product_status.py")
ps = importlib.util.module_from_spec(spec_ps)
spec_ps.loader.exec_module(ps)

spec_ft = importlib.util.spec_from_file_location("feature_traceability", SCRIPTS / "feature_traceability.py")
ft = importlib.util.module_from_spec(spec_ft)
spec_ft.loader.exec_module(ft)

SENSITIVE_VALUES = [
    "TR330006100519782134567890",
    "ghp_SUPER_SECRET_TOKEN_XYZ_12345",
    "SuperSecretP@ssword999!",
    "Selin Gizem",
    "/admin/private/internal/keys",
    "AssertionError: expected TR330006100519782134567890 but got empty",
    "Traceback (most recent call last):\n  File 'auth.py', line 42",
    "SELECT * FROM dues WHERE iban='TR330006100519782134567890'",
    "screenshot_failure_123.png",
    "trace_999.zip",
]

EPIC_DOC = """# Epic: Finance

### STORY-01-01: Statement reconciliation
"""

FEATURE = """@EPIC-01 @STORY-01-01
Feature: Statement reconciliation

  @SC-01-01-01 @gherkin
  Scenario Outline: Resident statements across outline examples
    Given resident <resident> with IBAN <iban>
    When paying with token <token>
    Then liability is settled

    Examples:
      | resident | iban | token |
      | alpha    | TR11 | tok1  |
      | beta     | TR22 | tok2  |

  @SC-01-01-02 @linked
  Scenario: Passing linked check
    Given clean state

  @SC-01-01-03 @pending
  Scenario: Planned future requirement
    Given pending logic
"""


def _setup_workspace(root: Path) -> Path:
    req = root / ".specify" / "requirements"
    feat = root / ".specify" / "features" / "EPIC-01"
    req.mkdir(parents=True, exist_ok=True)
    feat.mkdir(parents=True, exist_ok=True)
    (req / "EPIC-01-finance.md").write_text(EPIC_DOC, encoding="utf-8")
    (feat / "STORY-01-01-statements.feature").write_text(FEATURE, encoding="utf-8")
    return root


class PublicSafeReportingTests(unittest.TestCase):
    def test_failure_fixture_excludes_sensitive_values_from_all_public_surfaces(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            ws = _setup_workspace(tmp_path / "workspace")
            history = ws / ".specify" / "executions"
            (history / "runs").mkdir(parents=True, exist_ok=True)

            shards = tmp_path / "shards"
            shard1 = shards / "e2e-shard-1"
            shard1.mkdir(parents=True, exist_ok=True)

            # Failure record containing representative sensitive values
            failing_record = {
                "epic": "EPIC-06",
                "story": "STORY-06-06",
                "scenario": "SC-06-06-01",
                "name": "test_statement_reconciliation[example-1]",
                "binding": "gherkin",
                "layer": "e2e",
                "feature_file": "EPIC-06/STORY-06-06-forced-password-change-gate.feature",
                "test": "tests/test_statements.py::test_reconciliation[example-1]",
                "status": "FAIL",
                "duration_s": 2.4,
                "steps": [
                    {
                        "keyword": "Given",
                        "text": f'resident "{SENSITIVE_VALUES[3]}" with IBAN "{SENSITIVE_VALUES[0]}"',
                        "status": "PASS",
                        "duration_s": 0.8,
                    },
                    {
                        "keyword": "When",
                        "text": f'paying at "{SENSITIVE_VALUES[4]}" with token "{SENSITIVE_VALUES[1]}" and pass "{SENSITIVE_VALUES[2]}"',
                        "status": "FAIL",
                        "duration_s": 1.2,
                        "error": SENSITIVE_VALUES[5] + "\n" + SENSITIVE_VALUES[6] + "\n" + SENSITIVE_VALUES[7],
                    },
                    {
                        "keyword": "Then",
                        "text": "liability is settled",
                        "status": "NOT RUN",
                        "duration_s": 0.0,
                    },
                ],
                "error": f"Failed with {SENSITIVE_VALUES[5]} (see {SENSITIVE_VALUES[8]} and {SENSITIVE_VALUES[9]})",
                "gui_ids": [],
            }

            # Outline example 2 (passing)
            passing_outline = {
                "epic": "EPIC-06",
                "story": "STORY-06-06",
                "scenario": "SC-06-06-01",
                "name": "test_statement_reconciliation[example-2]",
                "binding": "gherkin",
                "layer": "e2e",
                "feature_file": "EPIC-06/STORY-06-06-forced-password-change-gate.feature",
                "test": "tests/test_statements.py::test_reconciliation[example-2]",
                "status": "PASS",
                "duration_s": 1.1,
                "steps": [],
                "error": "",
                "gui_ids": [],
            }

            # Passing mapped linked scenario
            linked_record = {
                "epic": "EPIC-06",
                "story": "STORY-06-06",
                "scenario": "SC-06-06-02",
                "name": "test_passing_linked",
                "binding": "linked",
                "layer": "backend",
                "feature_file": "EPIC-06/STORY-06-06-forced-password-change-gate.feature",
                "test": "tests/test_linked.py::test_passing_linked",
                "status": "PASS",
                "duration_s": 0.5,
                "steps": [],
                "error": "",
                "gui_ids": [],
            }

            (shard1 / "executions.jsonl").write_text(
                "\n".join(json.dumps(r) for r in (failing_record, passing_outline, linked_record)) + "\n",
                encoding="utf-8",
            )

            # Shard junit.xml containing sensitive stack trace and unmapped test
            junit_xml = f"""<testsuites>
  <testsuite name="e2e" tests="4" failures="1" errors="0" skipped="0" time="5.0">
    <testcase classname="tests.test_statements" name="test_reconciliation[example-1]" time="2.4">
      <failure message="{SENSITIVE_VALUES[5]}">{SENSITIVE_VALUES[6]}</failure>
    </testcase>
    <testcase classname="tests.test_statements" name="test_reconciliation[example-2]" time="1.1"/>
    <testcase classname="tests.test_linked" name="test_passing_linked" time="0.5"/>
    <testcase classname="tests.test_internal" name="test_unmapped_backend_check" time="1.0"/>
  </testsuite>
</testsuites>"""
            (shard1 / "junit.xml").write_text(junit_xml, encoding="utf-8")

            out = tmp_path / "out"
            actions_evidence = tmp_path / "actions-evidence"
            site = tmp_path / "site"

            # 1. Run ci_test_report.build
            summary = ctr.build(shards, out, "CI test run", history, actions_evidence, "45054743421", "1")
            self.assertEqual(summary["status"], "FAIL")
            self.assertEqual(summary["junit"]["tests"], 4)
            self.assertEqual(summary["junit"]["failures"], 1)

            # 2. Run publish_test_report.build
            pub_result = pub.build(out, site, "45054743421", "1")
            self.assertEqual(pub_result["reports"], 1)

            # 3. VERIFY: None of the sensitive values appear in ANY public surface
            public_files = list(site.rglob("*"))
            self.assertTrue(len(public_files) > 0)
            checked_count = 0
            for p in public_files:
                if not p.is_file():
                    continue
                checked_count += 1
                content = p.read_text(encoding="utf-8", errors="replace")
                for sensitive in SENSITIVE_VALUES:
                    self.assertNotIn(
                        sensitive,
                        content,
                        f"Sensitive value '{sensitive[:20]}...' leaked in public file {p.relative_to(site)}",
                    )

            self.assertTrue(checked_count >= 5)  # index.html, latest.html, history.html, report index, json files

            # 4. VERIFY: Public surfaces do NOT contain test-report.md or raw XML/JSON logs
            self.assertFalse((site / "reports" / "45054743421-1" / "test-report.md").exists())
            self.assertFalse((site / "reports" / "45054743421-1" / "junit.xml").exists())
            self.assertFalse((site / "reports" / "45054743421-1" / "executions.jsonl").exists())

            # 5. VERIFY: Explicit allowlist items ARE present
            index_html = (site / "index.html").read_text(encoding="utf-8")
            latest_html = (site / "latest.html").read_text(encoding="utf-8")
            archived_html = (site / "reports" / "45054743421-1" / "index.html").read_text(encoding="utf-8")
            status_json = json.loads((site / "product-status.json").read_text(encoding="utf-8"))

            # Allowed statuses, durations, IDs
            self.assertIn("SC-01-01-01", latest_html)
            self.assertIn("FAIL", latest_html)
            self.assertIn("PASS", latest_html)
            self.assertIn("PENDING", latest_html)
            self.assertIn("45054743421", index_html)

            # 6. VERIFY: Unmapped cases appear in the case inventory
            self.assertIn("test_unmapped_backend_check", latest_html)
            self.assertIn("test_unmapped_backend_check", index_html)
            self.assertIn("test_unmapped_backend_check", archived_html)
            unmapped_in_json = status_json.get("inventory", {}).get("unmapped_cases", [])
            self.assertEqual(len(unmapped_in_json), 1)
            self.assertEqual(unmapped_in_json[0]["native_id"], "test_unmapped_backend_check")

            # 7. VERIFY: Pending requirements remain in the scenario view
            self.assertIn("SC-06-05-02", latest_html)
            self.assertEqual(status_json["scenarios"]["SC-06-05-02"]["state"], "planned")

            # 8. VERIFY: Distinct outline examples are shown distinctly
            self.assertIn("example-1", latest_html)
            self.assertIn("example-2", latest_html)

            # 9. VERIFY: Diagnostic artifact retains the raw execution history for authorized consumers
            evidence_file = actions_evidence / "run-45054743421" / "attempt-1" / "runs"
            self.assertTrue(evidence_file.is_dir())
            evidence_records = [
                json.loads(line)
                for f in evidence_file.rglob("*.jsonl")
                for line in f.read_text(encoding="utf-8").splitlines()
            ]
            self.assertEqual({r["scenario"] for r in evidence_records if r.get("scenario")},
                             {"SC-06-06-01", "SC-06-06-02"})

    def test_historical_reports_show_suites_actually_collected(self):
        with tempfile.TemporaryDirectory() as tmp:
            site = Path(tmp) / "site"
            report_dir = site / "reports" / "100-1"
            report_dir.mkdir(parents=True)

            # Older historical summary with only JUnit counts
            (report_dir / "summary.json").write_text(
                json.dumps({
                    "run_id": "20261114T100000Z-aaa1111",
                    "task": "master",
                    "status": "PASS",
                    "junit": {"tests": 12, "passed": 12, "failures": 0, "errors": 0},
                }),
                encoding="utf-8",
            )

            snapshots = ps.load_site_snapshots(site)
            self.assertEqual(len(snapshots), 1)
            snap = snapshots[0]
            suites = snap["inventory"]["suites"]
            # Only the suite actually collected back then is reported
            self.assertEqual(len(suites), 1)
            self.assertEqual(suites[0]["suite"], "e2e")
            self.assertEqual(suites[0]["case_count"], 12)
            self.assertEqual(suites[0]["status"], "collected")
            self.assertEqual(snap["inventory"]["gates"], [])
            self.assertEqual(snap["inventory"]["unmapped_cases"], [])


if __name__ == "__main__":
    unittest.main()
