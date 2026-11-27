"""Unit tests for TokenLedger SQLite WAL database operations."""
from __future__ import annotations

from datetime import datetime, timezone, timedelta
from decimal import Decimal
import os
from pathlib import Path
import stat
import tempfile
import unittest

from scripts.token_tracker.ledger import TokenLedger
from scripts.token_tracker.quotas import QuotaConfig


class TestTokenLedger(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.db_path = Path(self.temp_dir.name) / "test_ledger.sqlite3"
        self.ledger = TokenLedger(db_path=self.db_path)

    def tearDown(self):
        self.ledger.close()
        self.temp_dir.cleanup()

    def test_db_permissions_and_wal(self):
        # Verify file mode 0600
        mode = stat.S_IMODE(self.db_path.stat().st_mode)
        self.assertEqual(mode, 0o600)

        # Verify WAL mode
        cur = self.ledger.db.execute("PRAGMA journal_mode")
        row = cur.fetchone()
        self.assertEqual(row[0].upper(), "WAL")

    def test_record_usage_event_and_idempotence(self):
        # Insert event
        inserted = self.ledger.record_usage_event(
            source_event_key="claude:sess-1:uuid-1",
            recorded_at="2026-11-27T10:00:00Z",
            provider="claude",
            harness="claude_code",
            model="claude-sonnet-5-5",
            session_id="sess-1",
            input_tokens=1000,
            output_tokens=500,
            cache_read_tokens=200,
            cache_write_tokens=100,
            accuracy="exact",
        )
        self.assertTrue(inserted)

        # Re-insert identical key -> should be ignored (idempotent)
        inserted_again = self.ledger.record_usage_event(
            source_event_key="claude:sess-1:uuid-1",
            recorded_at="2026-11-27T10:00:00Z",
            provider="claude",
            harness="claude_code",
            model="claude-sonnet-5-5",
            session_id="sess-1",
            input_tokens=1000,
            output_tokens=500,
        )
        self.assertFalse(inserted_again)

        # Verify record contents
        row = self.ledger.db.execute(
            "SELECT * FROM usage_events WHERE source_event_key=?",
            ("claude:sess-1:uuid-1",)
        ).fetchone()
        self.assertIsNotNone(row)
        self.assertEqual(row["input_tokens"], 1000)
        self.assertEqual(row["output_tokens"], 500)
        self.assertEqual(row["accuracy"], "exact")

    def test_cursor_tracking(self):
        self.assertIsNone(self.ledger.get_cursor("claude:/path/to/log.jsonl"))
        self.ledger.set_cursor("claude:/path/to/log.jsonl", "/path/to/log.jsonl", 1024)
        cur = self.ledger.get_cursor("claude:/path/to/log.jsonl")
        self.assertEqual(cur, ("/path/to/log.jsonl", 1024))

        # Update cursor
        self.ledger.set_cursor("claude:/path/to/log.jsonl", "/path/to/log.jsonl", 2048)
        cur = self.ledger.get_cursor("claude:/path/to/log.jsonl")
        self.assertEqual(cur, ("/path/to/log.jsonl", 2048))

    def test_quota_snapshots_and_health(self):
        # Initially healthy
        health = self.ledger.get_health("claude")
        self.assertEqual(health["providers"]["claude"]["status"], "HEALTHY")

        # Record a 429 rate limit snapshot
        future_time = (datetime.now(timezone.utc) + timedelta(minutes=15)).isoformat()
        self.ledger.record_quota_snapshot(
            provider="claude",
            model_family="claude-sonnet",
            status="EXHAUSTED",
            reset_at=future_time,
            source="429_event",
        )

        health_after = self.ledger.get_health("claude")
        self.assertEqual(health_after["providers"]["claude"]["status"], "EXHAUSTED")
        self.assertEqual(health_after["providers"]["claude"]["reset_at"], future_time)
        self.assertEqual(health_after["status"], "EXHAUSTED")


if __name__ == "__main__":
    unittest.main()
