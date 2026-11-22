"""Self-tests for the site-scoped admin journey attempt manifest and cleanup."""
from __future__ import annotations

import sys
import tempfile
import unittest
import warnings
from pathlib import Path
from unittest.mock import patch

E2E = Path(__file__).resolve().parents[2] / "e2e"
sys.path.insert(0, str(E2E))

from support.api import Api  # noqa: E402
from support.journey_attempts import (  # noqa: E402
    JourneyClock,
    JourneyFixturePending,
    JourneyManifest,
    make_viban,
    reclaim_stale_attempts,
    site_in_state,
    teardown_sites,
    teardown_with_evidence,
)


class FakeStack:
    def __init__(self) -> None:
        self.db_name = "sitepulse_e2e_test"
        self.statements: list[str] = []
        self.restarts = 0

    def sql(self, statement: str) -> str:
        self.statements.append(statement)
        if "SELECT id FROM units" in statement:
            return "1\n2\n3\n4\n5\n6\n7"
        return ""

    def restart_backend(self) -> None:
        self.restarts += 1


class JourneyAttemptTests(unittest.TestCase):
    def test_clock_client_uses_e2e_control_endpoint_and_enforces_monotonic_advance(self) -> None:
        api = Api("http://127.0.0.1")
        with patch.object(api, "call", return_value={"action": "date_set"}) as call:
            clock = JourneyClock(api, "2026-09-01")
            clock.advance_to("2026-10-11")

            self.assertEqual(call.call_args_list[0].args, ("POST", "/__e2e/clock"))
            self.assertEqual(call.call_args_list[0].kwargs["body"], {"action": "set_date", "date": "2026-09-01"})
            self.assertEqual(call.call_args_list[1].kwargs["body"], {"action": "advance_to", "date": "2026-10-11"})
            self.assertEqual(clock.current_date.isoformat(), "2026-10-11")
            with self.assertRaisesRegex(ValueError, "earlier date"):
                clock.advance_to("2026-10-10")
            self.assertEqual(call.call_count, 2)

    def test_clock_client_rejects_unknown_and_incomplete_commands(self) -> None:
        api = Api("http://127.0.0.1")
        with self.assertRaisesRegex(ValueError, "Unsupported E2E clock action"):
            api.e2e_clock("freeze")
        with self.assertRaisesRegex(ValueError, "requires a date"):
            api.e2e_clock("advance_to")
        with self.assertRaisesRegex(ValueError, "does not accept a date"):
            api.e2e_clock("tick", "2026-11-19")

    def test_manifest_persists_each_created_resource_without_personal_data(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            manifest = JourneyManifest.create(Path(directory), "run 1", "shard 2", "attempt 3")
            manifest.record("site_ids", 17)
            manifest.record("unit_ids", 29)
            manifest.record("person_ids", 31)
            manifest.record("user_ids", 37)

            loaded = JourneyManifest.load(manifest.path)

            self.assertEqual((loaded.site_ids, loaded.unit_ids), (["17"], ["29"]))
            self.assertEqual((loaded.person_ids, loaded.user_ids), (["31"], ["37"]))
            self.assertNotIn("email", manifest.path.read_text(encoding="utf-8"))
            manifest.release_lock()

    def test_active_manifest_is_not_reclaimed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            manifest = JourneyManifest.create(Path(directory), "run", "shard", "active")
            manifest.bind_database("sitepulse_e2e_test")
            manifest.record("site_ids", 48)
            stack = FakeStack()

            self.assertEqual(reclaim_stale_attempts(stack, Path(directory)), [])
            self.assertEqual(stack.statements, [])
            manifest.release_lock()

    def test_stale_manifest_is_reclaimed_only_for_its_database(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            manifest = JourneyManifest.create(Path(directory), "run", "shard", "stale")
            manifest.bind_database("sitepulse_e2e_test")
            manifest.record("site_ids", 49)
            manifest.release_lock()
            stack = FakeStack()

            self.assertEqual(reclaim_stale_attempts(stack, Path(directory)), ["stale"])
            self.assertEqual(stack.restarts, 1)
            self.assertTrue(JourneyManifest.load(manifest.path).teardown_completed)
            self.assertIn("DELETE FROM sites WHERE id = 49", stack.statements[0])

    def test_stale_manifest_for_another_database_is_not_reclaimed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            manifest = JourneyManifest.create(Path(directory), "run", "shard", "other")
            manifest.bind_database("sitepulse_e2e_other")
            manifest.record("site_ids", 50)
            manifest.release_lock()
            stack = FakeStack()

            self.assertEqual(reclaim_stale_attempts(stack, Path(directory)), [])
            self.assertEqual(stack.statements, [])

    def test_stale_recovery_skips_corrupt_manifests_and_continues(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "broken.json").write_text("{", encoding="utf-8")
            manifest = JourneyManifest.create(root, "run", "shard", "recoverable")
            manifest.bind_database("sitepulse_e2e_test")
            manifest.record("site_ids", 51)
            manifest.release_lock()
            stack = FakeStack()

            with warnings.catch_warnings(record=True) as captured:
                warnings.simplefilter("always")
                recovered = reclaim_stale_attempts(stack, root)

            self.assertEqual(recovered, ["recoverable"])
            self.assertEqual(stack.restarts, 1)
            self.assertEqual(len(captured), 1)
            self.assertIn("broken.json", str(captured[0].message))

    def test_teardown_is_idempotent_and_scoped_to_manifest_site_ids(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            manifest = JourneyManifest.create(Path(directory), "run", "shard", "attempt")
            manifest.record("site_ids", 41)
            stack = FakeStack()

            teardown_sites(stack, manifest)
            teardown_sites(stack, manifest)

            self.assertEqual(stack.restarts, 2)
            self.assertTrue(manifest.teardown_completed)
            self.assertEqual(len(stack.statements), 2)
            for statement in stack.statements:
                self.assertIn("SET LOCAL sitepulse.allow_ledger_purge", statement)
                self.assertIn("DELETE FROM sites WHERE id = 41", statement)
                self.assertIn("DELETE FROM late_fee_accruals WHERE site_id = 41", statement)
                self.assertNotIn("TRUNCATE", statement.upper())
                self.assertNotIn("DELETE FROM sites WHERE id = 1", statement)
                self.assertLess(
                    statement.index("DELETE FROM dues_period_snapshots"),
                    statement.index("DELETE FROM dues_periods"),
                )
                self.assertLess(
                    statement.index("DELETE FROM dues_period_reopen_requests"),
                    statement.index("DELETE FROM dues_periods"),
                )

    def test_teardown_rejects_untrusted_site_ids_before_running_sql(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            manifest = JourneyManifest.create(Path(directory), "run", "shard", "attempt")
            manifest.site_ids.append("1; DROP DATABASE sitepulse_e2e")
            stack = FakeStack()

            with self.assertRaisesRegex(ValueError, "Invalid site id"):
                teardown_sites(stack, manifest)

            self.assertEqual(stack.statements, [])
            self.assertEqual(stack.restarts, 0)
            manifest.release_lock()

    def test_evidence_failure_does_not_skip_teardown_and_keeps_original_error(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            manifest = JourneyManifest.create(Path(directory), "run", "shard", "attempt")
            manifest.record("site_ids", 43)
            stack = FakeStack()
            original = AssertionError("journey assertion failed")

            def fail_to_capture() -> None:
                raise OSError("evidence capture failed")

            with self.assertRaises(BaseExceptionGroup) as raised:
                teardown_with_evidence(stack, manifest, failed=original, capture_evidence=fail_to_capture)

            self.assertIs(raised.exception.exceptions[0], original)
            self.assertIsInstance(raised.exception.exceptions[1], OSError)
            self.assertEqual(stack.restarts, 1)
            self.assertTrue(manifest.teardown_completed)

    def test_successful_evidence_and_cleanup_reraise_original_journey_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            manifest = JourneyManifest.create(Path(directory), "run", "shard", "attempt")
            manifest.record("site_ids", 47)
            stack = FakeStack()
            original = AssertionError("journey assertion failed")

            with self.assertRaises(AssertionError) as raised:
                teardown_with_evidence(stack, manifest, failed=original, capture_evidence=lambda: None)

            self.assertIs(raised.exception, original)
            self.assertEqual(stack.restarts, 1)

    def test_make_viban_generates_valid_checksum(self) -> None:
        iban = make_viban("00205", "1", "A", 14)
        self.assertTrue(iban.startswith("TR"))
        self.assertEqual(len(iban), 26)
        rearranged = f"{iban[4:]}2927{iban[2:4]}"
        self.assertEqual(int(rearranged) % 97, 1)

    def test_make_viban_matches_reference_vector(self) -> None:
        iban = make_viban("00205", "site-1", "A", 14)
        self.assertEqual(iban, "TR410020504213991067000014")

    def test_site_in_state_f3_creates_period_and_structure(self) -> None:
        from unittest.mock import MagicMock
        api = MagicMock()
        api.create_site.return_value = {"site_id": 99, "temporary_password": "temp"}
        login_session = MagicMock()
        login_session.user = {"id": 10}
        api.login.return_value = login_session
        saas = MagicMock()
        stack = FakeStack()

        with tempfile.TemporaryDirectory() as directory:
            manifest = JourneyManifest.create(Path(directory), "run", "shard", "attempt")
            fixture = site_in_state("F3", api=api, stack=stack, saas=saas, manifest=manifest)

            self.assertEqual(fixture.state, "F3")
            self.assertEqual(fixture.site_id, "99")
            self.assertEqual(len(fixture.unit_ids), 7)
            self.assertEqual(fixture.person_ids, ())
            self.assertTrue(any("INSERT INTO dues_periods" in s and "Ekim 2026" in s for s in stack.statements))
            self.assertTrue(any("UPDATE sites SET proration_enabled = TRUE" in s for s in stack.statements))
            self.assertGreaterEqual(stack.restarts, 1)
            manifest.release_lock()

    def test_site_in_state_unknown_state_raises_value_error(self) -> None:
        from unittest.mock import MagicMock
        api = MagicMock()
        saas = MagicMock()
        stack = FakeStack()

        with tempfile.TemporaryDirectory() as directory:
            manifest = JourneyManifest.create(Path(directory), "run", "shard", "attempt")
            for state in ["F8", "UNKNOWN", "FX"]:
                with self.assertRaises(ValueError):
                    site_in_state(state, api=api, stack=stack, saas=saas, manifest=manifest)
            manifest.release_lock()


if __name__ == "__main__":
    unittest.main()
