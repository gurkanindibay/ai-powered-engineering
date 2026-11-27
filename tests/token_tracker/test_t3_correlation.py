"""Unit tests for T3 Code child session correlation and reservation refunding."""
from __future__ import annotations

import json
from pathlib import Path
import sqlite3
import tempfile
import time
import unittest

from scripts.token_tracker.ledger import TokenLedger
from scripts.token_tracker.collectors import HarnessCollector


class TestT3Correlation(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.db_path = self.root / "ledger.sqlite3"
        self.ledger = TokenLedger(db_path=self.db_path)
        self.runs_db_path = self.root / "runs.sqlite3"
        self._create_mock_runs_db()

    def tearDown(self):
        self.ledger.close()
        self.temp_dir.cleanup()

    def _create_mock_runs_db(self):
        conn = sqlite3.connect(str(self.runs_db_path))
        conn.executescript("""
        CREATE TABLE runs (
            id TEXT PRIMARY KEY, status TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 0,
            created REAL NOT NULL, deadline REAL NOT NULL, repository TEXT NOT NULL,
            source_revision TEXT NOT NULL, candidate TEXT NOT NULL, policy TEXT NOT NULL,
            plan TEXT NOT NULL, cost TEXT NOT NULL DEFAULT '0', tokens INTEGER NOT NULL DEFAULT 0,
            gate_attempts INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE tasks (
            run_id TEXT NOT NULL, id TEXT NOT NULL, role TEXT NOT NULL,
            status TEXT NOT NULL, depends TEXT NOT NULL, repairs INTEGER NOT NULL DEFAULT 0,
            result TEXT, PRIMARY KEY(run_id,id)
        );
        CREATE TABLE attempts (
            id TEXT PRIMARY KEY, run_id TEXT NOT NULL, task_id TEXT NOT NULL,
            status TEXT NOT NULL, lease REAL NOT NULL, envelope TEXT NOT NULL,
            reservation TEXT NOT NULL, tokens INTEGER NOT NULL, result_hash TEXT,
            result TEXT
        );
        CREATE TABLE events (
            seq INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT NOT NULL,
            created REAL NOT NULL, body TEXT NOT NULL, previous TEXT NOT NULL, hash TEXT NOT NULL
        );
        """)

        now = time.time()
        conn.execute("""
            INSERT INTO runs (id, status, created, deadline, repository, source_revision, candidate, policy, plan)
            VALUES (?, 'RUNNING', ?, ?, 'test_repo', 'sha1', '/path/to/candidate', '{}', '{}')
        """, ("run-001", now, now + 3600))

        envelope = {
            "task_id": "backend_developer",
            "attempt_id": "att-001",
            "provider": "claude",
            "model": "claude-sonnet-5-5",
            "role": "backend_developer",
            "candidate": "/path/to/candidate"
        }
        conn.execute("""
            INSERT INTO attempts (id, run_id, task_id, status, lease, envelope, reservation, tokens)
            VALUES (?, ?, ?, 'RUNNING', ?, ?, '1.50', 50000)
        """, ("att-001", "run-001", "backend_developer", now + 600, json.dumps(envelope)))

        conn.commit()
        conn.close()

    def test_uncorrelated_attempt_records_reserved_ceiling(self):
        collector = HarnessCollector(self.ledger)
        res = collector.collect(source_override=self.runs_db_path)
        self.assertEqual(res["new_events"], 1)

        row = self.ledger.db.execute(
            "SELECT * FROM usage_events WHERE source_event_key='t3:run-001:att-001'"
        ).fetchone()
        self.assertIsNotNone(row)
        self.assertEqual(row["accuracy"], "reserved_estimated")
        self.assertEqual(row["input_tokens"], 50000)
        self.assertEqual(row["estimated_cost_usd"], "1.500000")

    def test_correlated_session_updates_to_exact_and_refunds_reservation(self):
        # 1. Ingest baseline reservation
        collector = HarnessCollector(self.ledger)
        collector.collect(source_override=self.runs_db_path)

        # 2. Simulate underlying Claude session that correlated with att-001
        self.ledger.record_usage_event(
            source_event_key="claude:sess-t3-child:msg-1",
            recorded_at="2026-11-27T10:00:00Z",
            provider="claude",
            harness="claude_code",
            model="claude-sonnet-5-5",
            session_id="att-001",
            harness_run_id="run-001",
            harness_attempt_id="att-001",
            input_tokens=12000,
            output_tokens=3000,
            cache_read_tokens=1000,
            cache_write_tokens=500,
            accuracy="exact",
        )

        # 3. Ingest harness again -> should correlate and update reservation to exact
        collector.collect(source_override=self.runs_db_path)

        row = self.ledger.db.execute(
            "SELECT * FROM usage_events WHERE source_event_key='t3:run-001:att-001'"
        ).fetchone()
        self.assertIsNotNone(row)
        self.assertEqual(row["accuracy"], "exact")
        self.assertEqual(row["input_tokens"], 12000)
        self.assertEqual(row["output_tokens"], 3000)
        self.assertEqual(row["cache_read_tokens"], 1000)
        self.assertEqual(row["cache_write_tokens"], 500)
        # Unused tokens (50000 - 12000 = 38000) are refunded from the reservation record


if __name__ == "__main__":
    unittest.main()
