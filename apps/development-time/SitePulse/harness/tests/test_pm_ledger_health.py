"""Unit tests for ``scripts/pm_ledger_health.py``.

The module backs the Product Manager Workbench buttons **Verify Ledger Health**
and **Export Bug Bundle** (issue #419). PostgreSQL is never reached: every test
injects a ``sql_fn`` double, so the suite runs in the standard harness lane.
"""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

BASE_DIR = Path(__file__).resolve().parents[2]
SCRIPTS_DIR = BASE_DIR / "scripts"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import pm_ledger_health as health


def clean_checker() -> health.LedgerHealthChecker:
    """A checker whose every SQL statement returns no rows."""
    return health.LedgerHealthChecker(sql_fn=lambda _sql: "")


class InvariantCatalogueTests(unittest.TestCase):
    """The scorecard covers every journey invariant, automated or manual."""

    def test_all_twelve_invariants_are_defined(self) -> None:
        ids = [invariant.invariant_id for invariant in health.INVARIANTS]
        self.assertEqual(ids, [f"I{index}" for index in range(1, 13)])

    def test_every_invariant_is_automated_or_names_a_covering_suite(self) -> None:
        for invariant in health.INVARIANTS:
            with self.subTest(invariant=invariant.invariant_id):
                self.assertTrue(invariant.title)
                self.assertTrue(invariant.explanation)
                self.assertTrue(invariant.remediation)
                if invariant.automated:
                    self.assertTrue(invariant.checks)
                else:
                    self.assertTrue(invariant.manual_reason)
                    self.assertTrue(invariant.manual_suite.startswith("e2e/tests/"))

    def test_automated_checks_only_use_the_site_placeholder(self) -> None:
        for invariant in health.INVARIANTS:
            for check in invariant.checks:
                with self.subTest(check=check.name):
                    self.assertIn("{site}", check.sql)
                    # The only brace substitution is the validated site id.
                    self.assertEqual(check.sql.count("{"), check.sql.count("{site}"))

    def test_check_sql_accepts_a_validated_site_id(self) -> None:
        for invariant in health.INVARIANTS:
            for check in invariant.checks:
                rendered = check.sql.format(site="42")
                self.assertIn("42", rendered)
                self.assertNotIn("{site}", rendered)


class ViewParityTests(unittest.TestCase):
    """The checker mirrors the integrity view; drift would hide real violations."""

    MIGRATION = BASE_DIR / "backend" / "migrations" / "V39__advance_exit_settlements.sql"

    def _advance_sql(self) -> str:
        return next(
            check.sql
            for invariant in health.INVARIANTS
            for check in invariant.checks
            if check.name == "advance_balance_vs_ledger"
        )

    def test_advance_credit_entry_types_match_the_integrity_view(self) -> None:
        import re

        view_sql = self.MIGRATION.read_text(encoding="utf-8")
        arm = view_sql.split("'advance_balance_vs_ledger'", 1)[1].split("UNION ALL", 1)[0]
        quoted = re.search(r"IN \(\s*((?:'[A-Z_]+'\s*,?\s*)+)\)", arm)
        self.assertIsNotNone(quoted, "the migration arm no longer lists credit entry types")
        credit_types = set(re.findall(r"'([A-Z_]+)'", quoted.group(1)))
        self.assertTrue(credit_types, "the migration arm no longer lists credit entry types")
        for entry_type in credit_types:
            with self.subTest(entry_type=entry_type):
                self.assertIn(entry_type, self._advance_sql())

    def test_reversed_payment_allocations_are_excluded(self) -> None:
        allocations_sql = next(
            check.sql
            for invariant in health.INVARIANTS
            for check in invariant.checks
            if check.name == "allocations_vs_dues_paid"
        )
        self.assertIn("settlement_status = 'REVERSED'", allocations_sql)


class SiteIdValidationTests(unittest.TestCase):
    """The site id is interpolated into SQL, so it must be a bare integer."""

    def test_positive_integers_are_accepted(self) -> None:
        self.assertEqual(health.validate_site_id(7), "7")
        self.assertEqual(health.validate_site_id(" 4242 "), "4242")

    def test_injection_and_non_integers_are_refused(self) -> None:
        for candidate in ("0", "-1", "1; DROP TABLE units", "1 OR 1=1", "", "abc", "1.5", None):
            with self.subTest(candidate=candidate):
                with self.assertRaises(health.LedgerHealthError):
                    health.validate_site_id(candidate)

    def test_check_rejects_an_invalid_site_before_running_sql(self) -> None:
        calls: list[str] = []

        def sql_fn(sql: str) -> str:
            calls.append(sql)
            return ""

        with self.assertRaises(health.LedgerHealthError):
            health.LedgerHealthChecker(sql_fn=sql_fn).check("1; DROP TABLE units")
        self.assertEqual(calls, [])


class ScorecardTests(unittest.TestCase):
    """A clean snapshot is green; a failing row turns its invariant red."""

    def test_clean_snapshot_is_green_and_reports_manual_journeys(self) -> None:
        report = clean_checker().check("42")
        self.assertEqual(report.status, health.OVERALL_GREEN)
        self.assertEqual(report.failed_count, 0)
        self.assertEqual(report.error_count, 0)
        self.assertGreater(report.manual_count, 0, "journey-only invariants stay visible")
        self.assertEqual(report.passed_count + report.manual_count, len(report.invariants))
        manual = [item for item in report.invariants if item.status == health.STATUS_MANUAL]
        self.assertTrue(all(item.manual_suite for item in manual))
        # A manual result is never counted as a pass.
        self.assertNotIn("MANUAL", (health.STATUS_PASS,))

    def test_a_violation_row_marks_its_invariant_failed(self) -> None:
        def sql_fn(sql: str) -> str:
            if "allocations_vs_dues_paid" in sql and "HAVING" in sql:
                return "allocations_vs_dues_paid|91|recorded=1500.00, allocated=1400.00\n"
            return ""

        report = health.LedgerHealthChecker(sql_fn=sql_fn).check("42")
        self.assertEqual(report.status, health.OVERALL_RED)
        self.assertEqual(report.failed_count, 1)
        failed = [item for item in report.invariants if item.status == health.STATUS_FAIL]
        self.assertEqual(failed[0].invariant_id, "I1")
        self.assertEqual(failed[0].violations[0].subject, "91")
        self.assertIn("recorded=1500.00", failed[0].violations[0].detail)

    def test_a_broken_check_is_an_error_not_a_pass(self) -> None:
        def sql_fn(_sql: str) -> str:
            raise RuntimeError("relation dues_liabilities does not exist")

        report = health.LedgerHealthChecker(sql_fn=sql_fn).check("42")
        self.assertEqual(report.status, health.OVERALL_RED)
        self.assertEqual(report.error_count, len([i for i in report.invariants if i.automated]))
        error = next(item for item in report.invariants if item.error)
        self.assertIn("does not exist", error.error)

    def test_a_violation_in_the_integrity_view_turns_the_scorecard_red(self) -> None:
        def sql_fn(sql: str) -> str:
            if "v_integrity_violations" in sql:
                return "advance_balance_vs_ledger|7/OWNER|balance differs from the advance ledger by 10.00\n"
            return ""

        report = health.LedgerHealthChecker(sql_fn=sql_fn).check("42")
        self.assertEqual(report.status, health.OVERALL_RED)
        self.assertEqual(report.failed_count, 0, "view rows are reported separately")
        self.assertEqual(report.view_violations[0].subject, "7/OWNER")

    def test_an_unreadable_integrity_view_is_reported(self) -> None:
        def sql_fn(sql: str) -> str:
            if "v_integrity_violations" in sql:
                raise RuntimeError("permission denied for view v_integrity_violations")
            return ""

        report = health.LedgerHealthChecker(sql_fn=sql_fn).check("42")
        self.assertEqual(report.status, health.OVERALL_RED)
        self.assertIn("permission denied", report.view_error)

    def test_malformed_rows_surface_instead_of_disappearing(self) -> None:
        violations = health.parse_check_rows("not-a-three-column-row\n")
        self.assertEqual(len(violations), 1)
        self.assertEqual(violations[0].check_name, "unparsed_check_row")

    def test_blank_output_means_no_violations(self) -> None:
        self.assertEqual(health.parse_check_rows("\n\n  \n"), [])

    def test_report_payload_is_json_safe_and_keeps_decimal_text(self) -> None:
        payload = clean_checker().check("42").to_dict()
        self.assertEqual(payload["site_id"], "42")
        self.assertEqual(payload["integrity_view"]["view"], "v_integrity_violations")
        self.assertEqual(len(payload["invariants"]), 12)
        for item in payload["invariants"]:
            self.assertIn(item["status"], {health.STATUS_PASS, health.STATUS_MANUAL})


class RedactionTests(unittest.TestCase):
    """LOGGING_STANDARDS.md section 5 applies to every exported value."""

    def test_passwords_secrets_and_tokens_are_removed(self) -> None:
        for secret, value in (
            ("password=E2E-Manager-1", "E2E-Manager-1"),
            ("admin_password: hunter2", "hunter2"),
            ("db_secret='s3cr3t'", "s3cr3t"),
            ("access_token=abcdef", "abcdef"),
            ("pwd=passw0rd", "passw0rd"),
        ):
            with self.subTest(secret=secret):
                redacted = health.redact_text(secret)
                self.assertIn(health.REDACTED, redacted)
                self.assertNotIn(value, redacted)

    def test_bearer_tokens_are_removed(self) -> None:
        redacted = health.redact_text("Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig")
        self.assertNotIn("eyJhbGciOiJIUzI1NiJ9", redacted)
        self.assertIn(health.REDACTED, redacted)

    def test_email_local_part_is_masked(self) -> None:
        self.assertEqual(health.mask_email("gurkan@example.com"), "g***n@example.com")
        self.assertEqual(health.mask_email("a@example.com"), "*@example.com")

    def test_email_masking_is_idempotent(self) -> None:
        once = health.mask_email("manager@example.test")
        self.assertEqual(health.mask_email(once), once)

    def test_turkish_iban_keeps_bank_code_and_last_four(self) -> None:
        masked = health.mask_iban("TR330006100519786457841326")
        self.assertTrue(masked.startswith("TR33 "))
        self.assertTrue(masked.endswith("13 26"))
        self.assertNotIn("000610051978645784", masked)
        self.assertIn("••••", masked)

    def test_turkish_identification_number_is_masked(self) -> None:
        self.assertEqual(health.redact_text("tckn 12345678901"), "tckn [redacted]")

    def test_hex_tokens_are_masked(self) -> None:
        redacted = health.redact_text("trace 4f8a9c1d2e3b4a5c6d7e8f9012345678")
        self.assertNotIn("4f8a9c1d2e3b4a5c6d7e8f9012345678", redacted)

    def test_persona_never_carries_a_password(self) -> None:
        persona = health.redact_persona(
            {
                "role": "SITE_MANAGER",
                "name": "Journey Manager",
                "unit": None,
                "email": "manager@example.test",
                "password": "E2E-Manager-1",
            }
        )
        self.assertNotIn("password", persona)
        self.assertNotIn("E2E-Manager-1", str(persona))
        self.assertEqual(persona["email"], "m***r@example.test")
        self.assertEqual(persona["unit"], "—")


class BackendLogParsingTests(unittest.TestCase):
    """Only structured request fields reach the bundle; free text does not."""

    LOG_LINE = (
        "2026-11-25T10:00:00Z WARN sitepulse::audit: request: request_id=req-1 "
        "method=GET path=/api/units status=500 latency_ms=42 payer=Mehmet "
        '"<-- HTTP request completed with server error"'
    )

    def test_only_4xx_and_5xx_entries_are_kept(self) -> None:
        raw = (
            "request: request_id=req-1 method=GET path=/api/ok status=200 latency_ms=3\n"
            f"{self.LOG_LINE}\n"
            "request: request_id=req-2 method=POST path=/api/seed status=422 latency_ms=9\n"
        )
        entries = health.parse_error_entries(raw)
        self.assertEqual([entry["request_id"] for entry in entries], ["req-1", "req-2"])
        self.assertEqual(entries[0]["status"], "500")

    def test_free_text_and_unlisted_fields_are_dropped(self) -> None:
        entries = health.parse_error_entries(self.LOG_LINE)
        self.assertEqual(len(entries), 1)
        entry = entries[0]
        self.assertEqual(
            sorted(entry), ["latency_ms", "method", "path", "request_id", "status", "trace_id"]
        )
        self.assertNotIn("Mehmet", str(entry))

    def test_sensitive_values_in_structured_fields_are_redacted(self) -> None:
        raw = (
            "request: request_id=req-3 method=GET "
            "path=/api/reconcile?email=ayse@example.com status=403 latency_ms=5"
        )
        entry = health.parse_error_entries(raw)[0]
        self.assertNotIn("ayse@example.com", entry["path"])
        self.assertIn("a***e@example.com", entry["path"])

    def test_duplicate_request_ids_appear_once(self) -> None:
        entries = health.parse_error_entries(f"{self.LOG_LINE}\n{self.LOG_LINE}\n")
        self.assertEqual(len(entries), 1)

    def test_entry_limit_keeps_the_most_recent_entries(self) -> None:
        raw = "\n".join(
            f"request: request_id=req-{index} method=GET path=/api/x status=500 latency_ms=1"
            for index in range(30)
        )
        entries = health.parse_error_entries(raw, limit=5)
        self.assertEqual([entry["request_id"] for entry in entries], [f"req-{i}" for i in range(25, 30)])

    def test_missing_log_file_yields_no_entries(self) -> None:
        missing = Path(tempfile.gettempdir()) / "sitepulse-missing-backend-log.log"
        self.assertEqual(health.read_log_tail(missing), "")
        self.assertEqual(health.parse_error_entries(""), [])


class BugBundleTests(unittest.TestCase):
    """The Markdown bundle is self-contained and redacted."""

    def _report(self) -> health.LedgerHealthReport:
        def sql_fn(sql: str) -> str:
            if "allocations_vs_dues_paid" in sql and "HAVING" in sql:
                return "allocations_vs_dues_paid|91|recorded=1500.00, allocated=1400.00\n"
            return ""

        return health.LedgerHealthChecker(sql_fn=sql_fn).check("42")

    def test_bundle_names_environment_checklist_and_failure(self) -> None:
        markdown = health.render_bug_bundle(
            self._report(),
            preset="F5",
            preset_label="Late fee fixture",
            site_name="Test Site",
            reference_clock="2026-11-19",
            personas=[],
        )
        self.assertIn("`F5`", markdown)
        self.assertIn("Late fee fixture", markdown)
        self.assertIn("Test Site", markdown)
        self.assertIn("2026-11-19", markdown)
        self.assertIn("🔴 RED", markdown)
        self.assertIn("I1 — Debt components add up to the booked payment", markdown)
        self.assertIn("recorded=1500.00, allocated=1400.00", markdown)
        self.assertIn("## Reproduction", markdown)
        self.assertIn("## Backend error responses", markdown)

    def test_bundle_redacts_personas_and_notes(self) -> None:
        markdown = health.render_bug_bundle(
            self._report(),
            preset="F5",
            personas=[
                {
                    "role": "SITE_MANAGER",
                    "name": "Journey Manager",
                    "unit": None,
                    "email": "manager@example.test",
                    "password": "E2E-Manager-1",
                }
            ],
            notes="Payer password=E2E-Manager-1, mail manager@example.test, IBAN TR330006100519786457841326",
        )
        self.assertNotIn("E2E-Manager-1", markdown)
        self.assertNotIn("manager@example.test", markdown)
        self.assertNotIn("TR330006100519786457841326", markdown)
        self.assertIn("m***r@example.test", markdown)
        self.assertIn("Passwords are never exported", markdown)

    def test_bundle_omits_free_text_log_messages(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            log = Path(tmpdir) / "backend.log"
            log.write_text(
                'request: request_id=req-7 method=POST path=/api/seed status=500 '
                'latency_ms=12 payer="Mehmet Yilmaz"\n',
                encoding="utf-8",
            )
            markdown = health.render_bug_bundle(self._report(), preset="F5", backend_log_path=log)
        self.assertIn("req-7", markdown)
        self.assertIn("/api/seed", markdown)
        self.assertNotIn("Mehmet", markdown)

    def test_bundle_survives_a_missing_backend_log(self) -> None:
        markdown = health.render_bug_bundle(
            self._report(), preset="F5", backend_log_path=Path(tempfile.gettempdir()) / "nope.log"
        )
        self.assertIn("No 4xx/5xx entry was found", markdown)

    def test_table_cells_cannot_break_the_markdown_table(self) -> None:
        markdown = health.render_bug_bundle(
            clean_checker().check("42"), preset="F5", preset_label="a|b\nc"
        )
        self.assertIn("a\\|b c", markdown)


class RendererContractTests(unittest.TestCase):
    """Status vocabulary is shared by API, UI and tests; keep it stable."""

    def test_status_vocabulary(self) -> None:
        self.assertEqual(
            (health.STATUS_PASS, health.STATUS_FAIL, health.STATUS_MANUAL, health.STATUS_ERROR),
            ("PASS", "FAIL", "MANUAL", "ERROR"),
        )
        self.assertEqual((health.OVERALL_GREEN, health.OVERALL_RED), ("GREEN", "RED"))

    def test_manual_invariant_id_lookup_covers_the_catalogue(self) -> None:
        self.assertEqual(
            sorted(health.INVARIANTS_BY_ID, key=lambda key: int(key[1:])),
            [f"I{i}" for i in range(1, 13)],
        )

    def test_summary_marks_manual_invariants_and_names_their_suite(self) -> None:
        summary = health.render_scorecard_summary(clean_checker().check("42"))
        self.assertIn("Ledger health for site 42: GREEN", summary)
        self.assertIn("7 need a GUI journey", summary)
        self.assertIn("I2   MANUAL", summary)
        self.assertIn("e2e/tests/test_journey_accruals_payments.py", summary)

    def test_cli_parser_accepts_check_and_bundle(self) -> None:
        parser = health._build_parser()
        parsed = parser.parse_args(["check", "--site-id", "12"])
        self.assertEqual((parsed.command, parsed.site_id), ("check", "12"))
        parsed = parser.parse_args(["bundle", "--site-id", "12", "--preset", "F5"])
        self.assertEqual(parsed.preset, "F5")


class CliTests(unittest.TestCase):
    """The CLI is the tooling entry point and must not need a live database."""

    def test_invalid_site_id_exits_with_two(self) -> None:
        import contextlib
        import io

        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            # The invalid id is refused before any database access happens.
            self.assertEqual(health.main(["check", "--site-id", "nope"]), 2)
        self.assertIn("not a positive integer", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
