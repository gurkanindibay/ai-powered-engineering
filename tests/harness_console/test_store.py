"""Unit tests for the append-only SQLite command queue and control state."""
from __future__ import annotations

from decimal import Decimal
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest

from scripts.harness_console.store import ConsoleError, ConsoleStore


class ConsoleStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.db_path = Path(self.tmp.name) / "harness_console.sqlite3"
        self.store = ConsoleStore(self.db_path)

    def tearDown(self) -> None:
        self.store.close()
        self.tmp.cleanup()

    def test_wal_permissions_and_append_only_triggers(self) -> None:
        mode = self.store.db.execute("PRAGMA journal_mode").fetchone()[0]
        self.assertEqual(mode.lower(), "wal")
        self.assertEqual(os.stat(self.db_path).st_mode & 0o777, 0o600)

        cmd = self.store.enqueue(
            command="pause",
            target_type="all",
            payload={"reason": "maintenance"},
            actor="tester",
            transport="cli",
        )
        self.assertTrue(self.store.audit_chain())

        with self.assertRaises(sqlite3.DatabaseError):
            self.store.db.execute(
                "UPDATE operator_commands SET actor='attacker' WHERE command_id=?",
                (cmd["command_id"],),
            )
        with self.assertRaises(sqlite3.DatabaseError):
            self.store.db.execute(
                "DELETE FROM operator_commands WHERE command_id=?",
                (cmd["command_id"],),
            )

    def test_pause_resume_pin_steer_gate_and_decimal_budget(self) -> None:
        self.store.enqueue(command="pause", target_type="issue", target_id="550", payload={"reason": "check"})
        self.assertIsNotNone(self.store.is_paused(issue=550))
        self.assertIsNone(self.store.is_paused(issue=551))

        self.store.enqueue(command="resume", target_type="issue", target_id="550", payload={})
        self.assertIsNone(self.store.is_paused(issue=550))

        self.store.enqueue(command="pin", target_type="issue", target_id="550", payload={"to": "codex"})
        self.assertEqual(self.store.get_pin(issue=550)["provider"], "codex")
        self.store.enqueue(command="unpin", target_type="issue", target_id="550", payload={})
        self.assertIsNone(self.store.get_pin(issue=550))

        self.store.enqueue(command="steer", target_type="issue", target_id="550", payload={"note": "Keep Decimal"})
        notes = self.store.pending_steering(issue=550)
        self.assertEqual(len(notes), 1)
        self.assertEqual(notes[0]["note"], "Keep Decimal")
        self.store.mark_steering_consumed([notes[0]["id"]])
        self.assertEqual(self.store.pending_steering(issue=550), [])

        self.store.enqueue(
            command="set_budget",
            target_type="provider",
            target_id="copilot-deepseek",
            payload={"usd": "42.50"},
        )
        self.assertEqual(self.store.get_budget_override("copilot-deepseek"), Decimal("42.50"))
        self.assertEqual(self.store.get_budget_override("copilot"), Decimal("42.50"))

        with self.assertRaises(ValueError):
            self.store.enqueue(
                command="set_budget",
                target_type="provider",
                target_id="copilot-deepseek",
                payload={"usd": 12.5},  # binary float prohibited
            )

        self.store.enqueue(
            command="set_gate",
            target_type="tier",
            target_id="critical",
            payload={"tier": "critical", "require_approval": True},
        )
        self.assertTrue(self.store.gate_requires_approval("critical"))
        self.assertFalse(self.store.is_approved(issue=550))
        self.store.enqueue(command="approve", target_type="issue", target_id="550", payload={})
        self.assertTrue(self.store.is_approved(issue=550))

        self.assertTrue(self.store.audit_chain())


if __name__ == "__main__":
    unittest.main()
