"""Lease lifecycle for the 0-token coordinator (Phase 4, Layer 3)."""
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

from scripts.engineering_harness import leases


def moment(offset_seconds: float = 0) -> datetime:
    return datetime(2026, 11, 27, 12, 0, tzinfo=timezone.utc) + timedelta(seconds=offset_seconds)


class LeaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "sessions"

    def tearDown(self):
        self.tmp.cleanup()

    def lease(self, updated_at: str | None = None, **overrides) -> leases.Lease:
        data = {"harness": "t3", "session": "ses_abc", "model": "deepseek-flash", "issue": 549,
                "pr": 554, "worktree": "/tmp/worktree", "branch": "feature/x", "transport": "t3",
                "context_pct": "42.5", "quota_pct": "10", "ttl_seconds": 60,
                "updated_at": updated_at or leases.isoformat(moment())}
        data.update(overrides)
        return leases.Lease(**data).validate()

    def test_heartbeat_writes_a_private_lease_and_refreshes_updated_at(self):
        store = leases.LeaseStore(self.root, now=lambda: moment(1))
        path = store.write(self.lease(updated_at=leases.isoformat(moment(-1))))
        self.assertEqual(path.parent, self.root)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        store.heartbeat(store.read(path))
        refreshed = store.read(path)
        self.assertEqual(refreshed.updated_at, leases.isoformat(moment(1)))
        self.assertEqual(refreshed.context_pct, "42.5")

    def test_state_is_alive_stale_then_expired(self):
        lease = self.lease(updated_at=leases.isoformat(moment(-30)))
        self.assertEqual(lease.state(moment()), "alive")
        self.assertEqual(lease.state(moment(70)), "stale")    # 100s: past TTL, inside one more TTL
        self.assertEqual(lease.state(moment(130)), "expired")  # 160s: past two TTLs

    def test_expired_filters_only_stalled_sessions(self):
        store = leases.LeaseStore(self.root, now=lambda: moment())
        store.write(self.lease(session="fresh", updated_at=leases.isoformat(moment())))
        store.write(self.lease(session="stalled", updated_at=leases.isoformat(moment(-300))))
        expired = store.expired()
        self.assertEqual([lease.session for lease in expired], ["stalled"])

    def test_scan_groups_states_and_reports_corrupt_files(self):
        store = leases.LeaseStore(self.root, now=lambda: moment())
        store.write(self.lease(session="fresh"))
        store.write(self.lease(session="stalled", updated_at=leases.isoformat(moment(-300))))
        (self.root / "broken.json").write_text("{not json", encoding="utf-8")
        snapshot = leases.scan(self.root, now=moment())
        self.assertEqual(snapshot["counts"]["alive"], 1)
        self.assertEqual(snapshot["counts"]["expired"], 1)
        self.assertEqual(len(snapshot["corrupt"]), 1)

    def test_percentages_must_be_decimal_strings_in_range(self):
        for value in (101, "-1", 85.5, True, "NaN"):
            with self.assertRaises(leases.LeaseError):
                self.lease(context_pct=value)
        self.assertEqual(self.lease(context_pct=85).context_pct, "85")

    def test_unknown_or_malformed_lease_is_rejected(self):
        with self.assertRaises(leases.LeaseError):
            leases.Lease.from_dict({"harness": "t3", "session": "s", "surprise": 1})
        with self.assertRaises(leases.LeaseError):
            leases.Lease.from_dict({"harness": "", "session": "s"})
        with self.assertRaises(leases.LeaseError):
            leases.Lease.from_dict({"harness": "t3", "session": "s", "ttl_seconds": 0})

    def test_for_session_finds_the_newest_matching_lease(self):
        store = leases.LeaseStore(self.root, now=lambda: moment())
        store.write(self.lease(session="other"))
        store.write(self.lease(updated_at=leases.isoformat(moment(-1))))
        store.write(self.lease(updated_at=leases.isoformat(moment()), context_pct="81"))
        self.assertEqual(store.for_session("ses_abc").context_pct, "81")
        self.assertIsNone(store.for_session("missing"))

    def test_leases_at_or_above_both_soft_gates(self):
        cold = self.lease(session="cold", context_pct="40", quota_pct="10")
        hot_context = self.lease(session="hot", context_pct="80", quota_pct="10")
        hot_quota = self.lease(session="quota", context_pct="10", quota_pct="85")
        hits = leases.leases_at_or_above([cold, hot_context, hot_quota], context_pct="80", quota_pct="85")
        self.assertEqual({lease.session for lease in hits}, {"hot", "quota"})


class T3LeaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.db = Path(self.tmp.name) / "runs.sqlite3"
        db = sqlite3.connect(self.db)
        db.executescript("""
        CREATE TABLE attempts (id TEXT, run_id TEXT, task_id TEXT, status TEXT, lease REAL);
        INSERT INTO attempts VALUES ('att-1', 'run-1', 'stage-01', 'RUNNING', 100);
        INSERT INTO attempts VALUES ('att-2', 'run-1', 'stage-02', 'RUNNING', 900);
        INSERT INTO attempts VALUES ('att-3', 'run-1', 'stage-03', 'COMPLETED', 100);
        """)
        db.commit()
        db.close()

    def tearDown(self):
        self.tmp.cleanup()

    def test_only_running_attempts_past_their_lease_are_expired(self):
        expired = leases.t3_leases(self.db, now_epoch=500)
        self.assertEqual([lease.attempt_id for lease in expired], ["att-1"])
        self.assertTrue(expired[0].expired(500))

    def test_missing_database_is_empty_not_an_error(self):
        self.assertEqual(leases.t3_leases(Path(self.tmp.name) / "absent.sqlite3"), [])


if __name__ == "__main__":
    unittest.main()
