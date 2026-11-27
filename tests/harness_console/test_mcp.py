"""Stdio JSON-RPC 2.0 MCP adapter integration tests."""
from __future__ import annotations

import io
import json
import unittest

from scripts import harness_mcp as mcp
from tests.harness_console.fixtures import SyntheticHarnessEnv


class HarnessMcpTests(unittest.TestCase):
    def setUp(self) -> None:
        self.env = SyntheticHarnessEnv()
        self.service = self.env.make_service()

    def tearDown(self) -> None:
        self.service.close()
        self.env.cleanup()

    def test_ndjson_mcp_lifecycle_and_all_seven_tools(self) -> None:
        requests = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-03-26"}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "get_status", "arguments": {"issue": 550}}},
            {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "list_pickups", "arguments": {}}},
            {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "dispatch_task", "arguments": {"task": "Add audit check", "financial": True}}},
            {"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "steer_task", "arguments": {"issue": 550, "note": "Use Decimal"}}},
            {"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "handover_task", "arguments": {"issue": 550, "to": "codex"}}},
            {"jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": {"name": "pause_task", "arguments": {"issue": 550}}},
            {"jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": {"name": "kill_task", "arguments": {"run_id": self.env.run_id}}},
        ]
        stdin = io.BytesIO(("\n".join(json.dumps(r) for r in requests) + "\n").encode("utf-8"))
        stdout = io.BytesIO()
        code = mcp.serve_stdio(self.service, stdin=stdin, stdout=stdout)
        self.assertEqual(code, 0)

        responses = [json.loads(line) for line in stdout.getvalue().decode("utf-8").splitlines() if line.strip()]
        self.assertEqual([r["id"] for r in responses], [1, 2, 3, 4, 5, 6, 7, 8, 9])

        tool_names = [t["name"] for t in responses[1]["result"]["tools"]]
        self.assertEqual(
            tool_names,
            ["dispatch_task", "steer_task", "handover_task", "pause_task", "kill_task", "get_status", "list_pickups"],
        )

        # Verify all 7 tool calls succeeded and wrote transport='mcp' commands.
        for resp in responses[2:]:
            self.assertFalse(resp["result"]["isError"], f"tool error: {resp}")

        self.assertEqual(responses[2]["result"]["structuredContent"]["board"]["items"][0]["issue"], 550)
        self.assertEqual(responses[3]["result"]["structuredContent"]["count"], 1)
        cmds = self.service.store.list_commands(limit=10)
        self.assertTrue(all(c["transport"] == "mcp" for c in cmds))

    def test_content_length_framing_and_tool_error_reporting(self) -> None:
        req = {"jsonrpc": "2.0", "id": 42, "method": "tools/call", "params": {"name": "kill_task", "arguments": {}}}
        body = json.dumps(req).encode("utf-8")
        frame = f"Content-Length: {len(body)}\r\n\r\n".encode("ascii") + body
        stdout = io.BytesIO()
        mcp.serve_stdio(self.service, stdin=io.BytesIO(frame), stdout=stdout)
        raw = stdout.getvalue().decode("utf-8")
        self.assertTrue(raw.startswith("Content-Length: "))
        payload = json.loads(raw.split("\r\n\r\n", 1)[1])
        self.assertEqual(payload["id"], 42)
        self.assertTrue(payload["result"]["isError"])


if __name__ == "__main__":
    unittest.main()
