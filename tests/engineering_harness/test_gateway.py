import json
from pathlib import Path
import tempfile
import unittest

from scripts.engineering_harness.gateway_bridge import (HISTORY_CHARS, KEEP_RECENT_RESULTS, TOOL_RESULT_CHARS,
                                                        compact_history, execute, workspace_tool)
from scripts.engineering_harness.contracts import validate_result
from scripts.engineering_harness.routing import HarnessError
from support import capabilities


class FakeGateway:
    def __init__(self, responses):
        self.responses = iter(responses)
        self.calls = []

    def capabilities(self, registry):
        return registry

    def request(self, path, body):
        self.calls.append((path, body.copy()))
        return next(self.responses)


def completion(name, args, input_tokens=10, output_tokens=5):
    return {"choices": [{"message": {"role": "assistant", "tool_calls": [{"id": "call-1", "type": "function",
             "function": {"name": name, "arguments": json.dumps(args)}}]}}],
            "usage": {"prompt_tokens": input_tokens, "completion_tokens": output_tokens}}


class GatewayTests(unittest.TestCase):
    def envelope(self):
        target = capabilities()["targets"][0]
        return {"schema_version": 1, "run_id": "r", "task_id": "t", "attempt_id": "a", "candidate": "c",
                "role": "developer", "target": dict(target, selected_options={}), "risk": {"effective_tier": "low"},
                "allowed_paths": ["src"], "max_tokens": 20000, "timeout_seconds": 30, "acceptance": {"criterion": ["unit"]}}

    def test_tool_loop_writes_only_allowed_paths_and_uses_gateway_usage(self):
        finish = {"status": "completed", "summary": "Implemented value", "issues": [],
                  "artifacts": {"changes": ["src/value.py"], "tests": ["unit"]}}
        gateway = FakeGateway([completion("write_file", {"path": "src/value.py", "text": "VALUE = 1\n"}), completion("finish", finish)])
        with tempfile.TemporaryDirectory() as temp:
            envelope = self.envelope()
            result = execute(envelope, gateway, capabilities(), Path(temp))
            validate_result(result, envelope)
            self.assertEqual(result["usage"], {"input_tokens": 20, "output_tokens": 10})
            self.assertEqual((Path(temp) / "src/value.py").read_text(), "VALUE = 1\n")
        self.assertEqual(len(gateway.calls), 2)
        self.assertIn("max_completion_tokens", gateway.calls[0][1])

    def test_low_reservation_rejects_call_before_spending(self):
        envelope = self.envelope()
        envelope["max_tokens"] = 1
        gateway = FakeGateway([])
        with self.assertRaises(HarnessError):
            execute(envelope, gateway, capabilities(), Path.cwd())
        self.assertFalse(gateway.calls)

    def test_model_cannot_forge_usage_or_result_identity(self):
        finish = {"status": "completed", "summary": "Done", "artifacts": {}, "issues": [], "usage": {"input_tokens": 0}}
        with self.assertRaises(HarnessError):
            execute(self.envelope(), FakeGateway([completion("finish", finish)]), capabilities(), Path.cwd())

    def test_tool_rejects_read_escape_and_write_outside_assignment(self):
        with tempfile.TemporaryDirectory() as temp:
            for name, args in [("read_file", {"path": "../secret"}), ("read_file", {"path": ".git/config"}),
                               ("write_file", {"path": "checks/weak.py", "text": "bad"})]:
                with self.assertRaises(HarnessError):
                    workspace_tool(name, args, self.envelope(), Path(temp))

    def test_read_file_supports_line_ranges_and_caps_output(self):
        with tempfile.TemporaryDirectory() as temp:
            (Path(temp) / "src").mkdir()
            (Path(temp) / "src/a.py").write_text("".join(f"line {i}\n" for i in range(1, 11)))
            self.assertEqual(workspace_tool("read_file", {"path": "src/a.py", "start_line": 3, "end_line": 4},
                                            self.envelope(), Path(temp)), "line 3\nline 4\n")
            (Path(temp) / "src/big.py").write_text("x" * 100 + "\n" * 0 + ("y" * 99 + "\n") * 1000)
            out = workspace_tool("read_file", {"path": "src/big.py"}, self.envelope(), Path(temp))
            self.assertLess(len(out), TOOL_RESULT_CHARS + 200)
            self.assertIn("[truncated at line", out)
            with self.assertRaises(HarnessError):
                workspace_tool("read_file", {"path": "src/a.py", "start_line": 5, "end_line": 2}, self.envelope(), Path(temp))

    def test_search_returns_capped_matches_and_skips_git_and_symlinks(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "src").mkdir()
            (root / ".git").mkdir()
            (root / "src/a.py").write_text("def total():\n    return 1\n")
            (root / ".git/config").write_text("def total(): secret\n")
            outside = tempfile.NamedTemporaryFile("w", suffix=".py", delete=False)
            outside.write("def total(): outside\n")
            outside.close()
            (root / "src/link.py").symlink_to(outside.name)
            out = workspace_tool("search", {"pattern": r"def total", "path": "."}, self.envelope(), root)
            self.assertEqual(out, "src/a.py:1: def total():")
            (root / "src/many.py").write_text("hit\n" * 200)
            self.assertIn("[more matches", workspace_tool("search", {"pattern": "hit", "path": "src"}, self.envelope(), root))
            with self.assertRaises(HarnessError):
                workspace_tool("search", {"pattern": "(", "path": "src"}, self.envelope(), root)
            Path(outside.name).unlink()

    def test_history_compaction_stubs_old_results_and_keeps_prefix(self):
        messages = [{"role": "system", "content": "s"}, {"role": "user", "content": "envelope"}]
        for i in range(KEEP_RECENT_RESULTS + 3):
            messages.append({"role": "assistant", "content": None, "tool_calls": []})
            messages.append({"role": "tool", "tool_call_id": str(i), "content": "z" * (HISTORY_CHARS // 4)})
        compact_history(messages)
        tools = [m for m in messages if m["role"] == "tool"]
        self.assertTrue(all(m["content"].startswith("[elided") for m in tools[:-KEEP_RECENT_RESULTS]))
        self.assertTrue(all(m["content"].startswith("z") for m in tools[-KEEP_RECENT_RESULTS:]))
        self.assertEqual(messages[:2], [{"role": "system", "content": "s"}, {"role": "user", "content": "envelope"}])
