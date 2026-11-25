"""Tests for scripts/agent_usage_collector.py (no network, no gh)."""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("agent_usage_collector", ROOT / "scripts" / "agent_usage_collector.py")
auc = importlib.util.module_from_spec(SPEC)
sys.modules["agent_usage_collector"] = auc
SPEC.loader.exec_module(auc)

NOW = datetime(2026, 11, 25, 12, 0, tzinfo=timezone.utc)


def ts(hours_ago: float) -> str:
    return (NOW - timedelta(hours=hours_ago)).isoformat().replace("+00:00", "Z")


def write_jsonl(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(json.dumps(r) for r in rows) + "\nnot json\n", encoding="utf-8")


def claude_row(hours_ago: float, msg_id: str, tokens: int, session: str = "s-1") -> dict:
    return {"type": "assistant", "timestamp": ts(hours_ago), "sessionId": session, "requestId": "r" + msg_id,
            "cwd": "/home/me/secret/projects/app",
            "message": {"id": msg_id, "model": "claude-opus-5-5",
                        "usage": {"input_tokens": tokens, "output_tokens": 0, "cache_read_input_tokens": 999}}}


class ClaudeTests(unittest.TestCase):
    def test_windows_dedupe_and_limits(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            write_jsonl(home / ".claude/projects/p/s-1.jsonl", [
                claude_row(1, "a", 100), claude_row(1, "a", 100),   # streamed twice, counted once
                claude_row(10, "b", 50), claude_row(100, "c", 7), claude_row(200, "old", 1000),
                {"type": "user", "timestamp": ts(1)},
            ])
            p = auc.collect_claude(home, NOW, limit_5h=1000, limit_7d=None)
            windows = {w["label"]: w for w in p.windows}
            self.assertEqual(windows["5h"]["tokens"], 100)
            self.assertEqual(windows["5h"]["used_percent"], 10.0)
            self.assertEqual(windows["24h"]["tokens"], 150)
            self.assertEqual(windows["7d"]["tokens"], 157)
            session = p.to_json()["sessions"][0]
            self.assertEqual(session["project"], "app")  # folder name only, never the full path
            self.assertEqual(session["tokens"], 157)

    def test_missing_directory_is_unavailable(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(auc.collect_claude(Path(tmp), NOW, None, None).status, "unavailable")


class CodexTests(unittest.TestCase):
    def test_rate_limits_from_latest_event(self) -> None:
        def token_event(hours_ago: float, total: int, last: int, primary: float) -> dict:
            return {"timestamp": ts(hours_ago), "type": "event_msg", "payload": {
                "type": "token_count",
                "info": {"total_token_usage": {"total_tokens": total}, "last_token_usage": {"total_tokens": last}},
                "rate_limits": {"primary": {"used_percent": primary, "window_minutes": 300, "resets_in_seconds": 3600},
                                "secondary": {"used_percent": 12.5, "window_minutes": 10080}}}}
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            write_jsonl(home / ".codex/sessions/2026/11/25/rollout-x.jsonl", [
                {"timestamp": ts(3), "type": "session_meta", "payload": {"id": "019a-codex", "cwd": "/w/repo"}},
                {"timestamp": ts(3), "type": "turn_context", "payload": {"model": "gpt-6.2-sol"}},
                token_event(3, 500, 500, 10.0),
                token_event(2, 800, 300, 42.0),
            ])
            p = auc.collect_codex(home, NOW).to_json()
            windows = {w["label"]: w for w in p["windows"]}
            self.assertEqual(windows["5h"]["used_percent"], 42.0)
            self.assertEqual(windows["5h"]["resets_at"], "2026-11-25T11:00:00Z")
            self.assertEqual(windows["7d"]["used_percent"], 12.5)
            self.assertEqual(windows["24h"]["tokens"], 800)
            self.assertEqual(p["sessions"][0]["session_id"], "019a-codex")
            self.assertEqual(p["sessions"][0]["tokens"], 800)
            self.assertEqual(p["sessions"][0]["model"], "gpt-6.2-sol")


class DeepSeekTests(unittest.TestCase):
    def test_balance_stays_decimal_text(self) -> None:
        data = {"is_available": True, "balance_infos": [
            {"currency": "USD", "total_balance": "1.10", "granted_balance": "0.10", "topped_up_balance": "1.00"}]}
        p = auc.collect_deepseek("k", fetch=lambda key: data)
        self.assertEqual(p.balance[0]["total_balance"], "1.10")

    def test_without_key(self) -> None:
        self.assertEqual(auc.collect_deepseek(None).status, "unavailable")


class CopilotAndPublishTests(unittest.TestCase):
    def test_premium_requests(self) -> None:
        calls = []

        def run(args, stdin):
            calls.append(args)
            if args[1] == "user":
                return "me\n"
            return json.dumps({"usageItems": [{"product": "Copilot", "grossQuantity": 30.5},
                                              {"product": "Actions", "grossQuantity": 999}]})
        w = auc.collect_copilot(run, NOW, 300).windows[0]
        self.assertEqual(w["requests"], "30.5")
        self.assertEqual(w["used_percent"], 10.2)
        self.assertEqual(w["resets_at"], "2026-12-01T00:00:00Z")
        self.assertIn("year=2026&month=11", calls[1][1])

    def test_gh_failure_is_unavailable(self) -> None:
        def run(args, stdin):
            raise RuntimeError("HTTP 403")
        self.assertEqual(auc.collect_copilot(run, NOW, 300).status, "unavailable")

    def test_publish_updates_secret_gist(self) -> None:
        sent = []
        gist = auc.publish(lambda args, stdin: sent.append((args, stdin)) or "", {"a": 1}, "abc")
        self.assertEqual(gist, "abc")
        args, stdin = sent[0]
        self.assertEqual(args[:4], ["api", "-X", "PATCH", "gists/abc"])
        self.assertIn(auc.GIST_FILE, json.loads(stdin)["files"])
        created = auc.publish(lambda args, stdin: sent.append((args, stdin)) or "new-id\n", {"a": 1}, None)
        self.assertEqual(created, "new-id")
        self.assertFalse(json.loads(sent[1][1])["public"])

    def test_snapshot_shape(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            args = auc.build_parser().parse_args(["--skip", "copilot", "--skip", "deepseek",
                                                  "--antigravity-file", str(Path(tmp) / "none.json")])
            snap = auc.build_snapshot(args, home=Path(tmp), now=NOW)
            self.assertEqual(snap["schema_version"], 1)
            self.assertEqual([p["id"] for p in snap["providers"]], ["claude", "codex", "antigravity"])

    def test_watch_minimum(self) -> None:
        self.assertEqual(auc.main(["--watch", "5"]), 2)


if __name__ == "__main__":
    unittest.main()
