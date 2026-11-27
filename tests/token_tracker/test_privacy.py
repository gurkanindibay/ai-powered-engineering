"""Unit tests ensuring zero message content / prompt leakage into SQLite (Rule 8)."""
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


class TestTranscriptPrivacy(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.db_path = self.root / "ledger.sqlite3"
        self.ledger = TokenLedger(db_path=self.db_path)

    def tearDown(self):
        self.ledger.close()
        self.temp_dir.cleanup()

    def test_zero_message_content_leakage(self):
        canary_prompt = "CANARY_PROMPT_12345_VERIFY_ABSENT"
        canary_code = "CANARY_SOURCE_CODE_DEF_FOO_BAR"
        canary_tool_output = "CANARY_OUTPUT_FRAGMENT_987654321"

        # 1. Claude log with sensitive text in message content & tool outputs
        claude_dir = self.root / "claude"
        claude_dir.mkdir()
        claude_file = claude_dir / "sess.jsonl"
        with open(claude_file, "w") as f:
            f.write(json.dumps({
                "type": "assistant",
                "sessionId": "sess-priv-1",
                "uuid": "u-1",
                "timestamp": "2026-11-27T10:00:00Z",
                "message": {
                    "model": "claude-sonnet-5-5",
                    "content": [{"type": "text", "text": canary_prompt}],
                    "tool_use": {"name": "run_command", "input": {"CommandLine": canary_code}},
                    "usage": {"input_tokens": 100, "output_tokens": 50}
                }
            }) + "\n")

        # 2. Codex log with sensitive turn context / tool call
        codex_dir = self.root / "codex"
        codex_dir.mkdir()
        codex_file = codex_dir / "sess.jsonl"
        with open(codex_file, "w") as f:
            f.write(json.dumps({
                "type": "token_usage_record",
                "timestamp": "2026-11-27T10:01:00Z",
                "ordinal": 1,
                "payload": {
                    "session_id": "sess-priv-2",
                    "response_id": "resp-priv-1",
                    "prompt_text": canary_prompt,
                    "code_patch": canary_code,
                    "usage": {"input_tokens": 200, "output_tokens": 75}
                }
            }) + "\n")

        # 3. Gemini log with content and thinking
        gemini_dir = self.root / "gemini" / "brain" / "sess-priv-3" / ".system_generated" / "logs"
        gemini_dir.mkdir(parents=True)
        gemini_file = gemini_dir / "transcript.jsonl"
        with open(gemini_file, "w") as f:
            f.write(json.dumps({
                "step_index": 1,
                "source": "PLANNER_RESPONSE",
                "created_at": "2026-11-27T10:02:00Z",
                "input_tokens": 300,
                "output_tokens": 120,
                "content": canary_prompt,
                "thinking": canary_code,
                "tool_calls": [{"name": "eval", "result": canary_tool_output}],
            }) + "\n")

        # Collect all
        ClaudeCollector(self.ledger).collect(source_override=claude_dir)
        CodexCollector(self.ledger).collect(source_override=codex_dir)
        GeminiCollector(self.ledger).collect(source_override=self.root / "gemini")

        # Now inspect every single text column in the entire SQLite database
        rows = self.ledger.db.execute("SELECT * FROM usage_events").fetchall()
        self.assertEqual(len(rows), 3)

        for r in rows:
            row_dict = dict(r)
            for k, val in row_dict.items():
                val_str = str(val)
                self.assertNotIn(canary_prompt, val_str, f"Found canary prompt in column {k}!")
                self.assertNotIn(canary_code, val_str, f"Found canary code in column {k}!")
                self.assertNotIn(canary_tool_output, val_str, f"Found canary tool output in column {k}!")

        # Also search raw database binary content
        db_raw = self.db_path.read_bytes()
        self.assertNotIn(canary_prompt.encode("utf-8"), db_raw)
        self.assertNotIn(canary_code.encode("utf-8"), db_raw)
        self.assertNotIn(canary_tool_output.encode("utf-8"), db_raw)


if __name__ == "__main__":
    unittest.main()
