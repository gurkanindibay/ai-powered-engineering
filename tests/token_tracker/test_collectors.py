"""Unit tests for telemetry collectors using synthetic log fixtures."""
from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

from scripts.token_tracker.ledger import TokenLedger
from scripts.token_tracker.collectors import (
    ClaudeCollector,
    CodexCollector,
    GeminiCollector,
    CopilotCollector,
)


class TestCollectors(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.db_path = self.root / "ledger.sqlite3"
        self.ledger = TokenLedger(db_path=self.db_path)

    def tearDown(self):
        self.ledger.close()
        self.temp_dir.cleanup()

    def test_claude_collector_synthetic(self):
        project_dir = self.root / "claude_project"
        project_dir.mkdir(parents=True)
        log_file = project_dir / "session-1.jsonl"

        lines = [
            {"type": "user", "timestamp": "2026-11-27T10:00:00Z", "sessionId": "sess-c1"},
            {
                "type": "assistant",
                "sessionId": "sess-c1",
                "uuid": "msg-1",
                "timestamp": "2026-11-27T10:00:05Z",
                "message": {
                    "model": "claude-sonnet-5-5",
                    "usage": {
                        "input_tokens": 1200,
                        "output_tokens": 350,
                        "cache_read_input_tokens": 400,
                        "cache_creation_input_tokens": 150,
                        "output_tokens_details": {"thinking_tokens": 50},
                    }
                }
            }
        ]
        with open(log_file, "w") as f:
            for l in lines:
                f.write(json.dumps(l) + "\n")

        collector = ClaudeCollector(self.ledger)
        res = collector.collect(source_override=project_dir)
        self.assertEqual(res["new_events"], 1)

        # Verify cursor moved
        offset1 = collector.get_cursor(str(log_file))
        self.assertGreater(offset1, 0)

        # Run again without changes -> 0 new events
        res2 = collector.collect(source_override=project_dir)
        self.assertEqual(res2["new_events"], 0)

        # Append a new line -> 1 new event
        new_line = {
            "type": "assistant",
            "sessionId": "sess-c1",
            "uuid": "msg-2",
            "timestamp": "2026-11-27T10:01:00Z",
            "message": {
                "model": "claude-sonnet-5-5",
                "usage": {
                    "input_tokens": 500,
                    "output_tokens": 100,
                }
            }
        }
        with open(log_file, "a") as f:
            f.write(json.dumps(new_line) + "\n")

        res3 = collector.collect(source_override=project_dir)
        self.assertEqual(res3["new_events"], 1)

    def test_codex_collector_synthetic(self):
        codex_dir = self.root / "codex_sessions" / "2026" / "11" / "27"
        codex_dir.mkdir(parents=True)
        log_file = codex_dir / "rollout-1.jsonl"

        lines = [
            {"type": "session_meta", "payload": {"session_id": "sess-codex-1", "model": "gpt-6-2-sol"}},
            {
                "type": "token_usage_record",
                "timestamp": "2026-11-27T11:00:00Z",
                "ordinal": 5,
                "payload": {
                    "session_id": "sess-codex-1",
                    "response_id": "resp-001",
                    "usage": {
                        "input_tokens": 2500,
                        "cached_input_tokens": 500,
                        "output_tokens": 600,
                        "reasoning_output_tokens": 150,
                    }
                }
            }
        ]
        with open(log_file, "w") as f:
            for l in lines:
                f.write(json.dumps(l) + "\n")

        collector = CodexCollector(self.ledger)
        res = collector.collect(source_override=codex_dir)
        self.assertEqual(res["new_events"], 1)

        row = self.ledger.db.execute(
            "SELECT * FROM usage_events WHERE provider='codex'"
        ).fetchone()
        self.assertIsNotNone(row)
        self.assertEqual(row["input_tokens"], 2500)
        self.assertEqual(row["cache_read_tokens"], 500)
        self.assertEqual(row["output_tokens"], 600)
        self.assertEqual(row["reasoning_tokens"], 150)
        self.assertEqual(row["accuracy"], "exact")

    def test_gemini_collector_synthetic(self):
        brain_dir = self.root / "gemini_brain" / "brain" / "test-gemini-session" / ".system_generated" / "logs"
        brain_dir.mkdir(parents=True)
        log_file = brain_dir / "transcript.jsonl"

        lines = [
            {"step_index": 1, "source": "USER_INPUT", "created_at": "2026-11-27T12:00:00Z"},
            {
                "step_index": 2,
                "source": "PLANNER_RESPONSE",
                "model": "gemini-3-8-flash",
                "created_at": "2026-11-27T12:00:05Z",
                "input_tokens": 1500,
                "output_tokens": 400,
                "cache_read_tokens": 300,
            },
            {
                "step_index": 3,
                "source": "PLANNER_RESPONSE",
                "model": "gemini-3-8-flash",
                "created_at": "2026-11-27T12:00:10Z",
                "content": "This is a response without explicit tokens.",
            }
        ]
        with open(log_file, "w") as f:
            for l in lines:
                f.write(json.dumps(l) + "\n")

        collector = GeminiCollector(self.ledger)
        res = collector.collect(source_override=self.root / "gemini_brain")
        self.assertEqual(res["new_events"], 2)

        # Check accuracy tagging
        rows = self.ledger.db.execute(
            "SELECT source_event_key, accuracy FROM usage_events WHERE provider='gemini' ORDER BY id"
        ).fetchall()
        self.assertEqual(rows[0]["accuracy"], "exact")
        self.assertEqual(rows[1]["accuracy"], "estimated")

    def test_copilot_collector_synthetic(self):
        copilot_dir = self.root / "copilot_logs"
        copilot_dir.mkdir(parents=True)
        log_file = copilot_dir / "copilot.jsonl"

        lines = [
            {
                "id": "ev-1",
                "session_id": "copilot-sess-1",
                "timestamp": "2026-11-27T13:00:00Z",
                "model": "o1",
                "request_count": 2,
            },
            {
                "id": "ev-2",
                "session_id": "copilot-sess-1",
                "timestamp": "2026-11-27T13:05:00Z",
                "model": "deepseek-v3",
                "prompt_tokens": 5000,
                "completion_tokens": 1000,
            }
        ]
        with open(log_file, "w") as f:
            for l in lines:
                f.write(json.dumps(l) + "\n")

        collector = CopilotCollector(self.ledger)
        res = collector.collect(source_override=copilot_dir)
        self.assertEqual(res["new_events"], 2)

        rows = self.ledger.db.execute(
            "SELECT model, premium_requests, accuracy, billing_mode FROM usage_events WHERE provider='copilot' ORDER BY id"
        ).fetchall()
        # o1 has multiplier 3.0 * 2 requests = 6.00 premium requests
        self.assertEqual(rows[0]["model"], "o1")
        self.assertEqual(rows[0]["premium_requests"], "6.00")
        self.assertEqual(rows[0]["accuracy"], "request_metered")
        self.assertEqual(rows[0]["billing_mode"], "subscription")

        # deepseek has billing_mode api
        self.assertEqual(rows[1]["model"], "deepseek-v3")
        self.assertEqual(rows[1]["billing_mode"], "api")
        self.assertEqual(rows[1]["accuracy"], "exact")


if __name__ == "__main__":
    unittest.main()
