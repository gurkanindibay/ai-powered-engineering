"""Self-tests for scripts/token_guard.py (Claude Code context-budget hook)."""
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "token_guard.py"
spec = importlib.util.spec_from_file_location("token_guard", SCRIPT)
token_guard = importlib.util.module_from_spec(spec)
sys.modules["token_guard"] = token_guard
spec.loader.exec_module(token_guard)


def pre(tool_name, tool_input, cwd):
    return token_guard.evaluate({"hook_event_name": "PreToolUse", "tool_name": tool_name,
                                 "tool_input": tool_input, "cwd": cwd}, max_file_bytes=100)


def denied(decision):
    return decision.get("hookSpecificOutput", {}).get("permissionDecision") == "deny"


class TokenGuardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cwd = self.tmp.name
        Path(self.cwd, "big.txt").write_text("x" * 500)
        Path(self.cwd, "small.txt").write_text("x")

    def tearDown(self):
        self.tmp.cleanup()

    def test_cat_of_large_file_is_denied_but_small_or_piped_is_allowed(self):
        self.assertTrue(denied(pre("Bash", {"command": "cat big.txt"}, self.cwd)))
        self.assertEqual(pre("Bash", {"command": "cat small.txt"}, self.cwd), {})
        self.assertEqual(pre("Bash", {"command": "cat big.txt | head -5"}, self.cwd), {})

    def test_recursive_listing_and_unfiltered_find_are_denied(self):
        self.assertTrue(denied(pre("Bash", {"command": "ls -laR"}, self.cwd)))
        self.assertTrue(denied(pre("Bash", {"command": "find ."}, self.cwd)))
        self.assertEqual(pre("Bash", {"command": "find . -maxdepth 2 -name '*.rs'"}, self.cwd), {})
        self.assertEqual(pre("Bash", {"command": "ls -la src"}, self.cwd), {})

    def test_read_of_large_file_requires_a_range(self):
        self.assertTrue(denied(pre("Read", {"file_path": str(Path(self.cwd, "big.txt"))}, self.cwd)))
        self.assertEqual(pre("Read", {"file_path": str(Path(self.cwd, "big.txt")), "offset": 1, "limit": 20}, self.cwd), {})

    def test_screenshots_need_a_small_scale_including_inside_batches(self):
        self.assertTrue(denied(pre("mcp__Claude_Browser__computer", {"action": "screenshot"}, self.cwd)))
        self.assertEqual(pre("mcp__Claude_Browser__computer", {"action": "screenshot", "scale": 0.4}, self.cwd), {})
        self.assertEqual(pre("mcp__Claude_Browser__computer", {"action": "left_click"}, self.cwd), {})
        batch = {"actions": [{"name": "navigate", "input": {"url": "x"}},
                             {"name": "computer", "input": {"action": "screenshot"}}]}
        self.assertTrue(denied(pre("mcp__Claude_Browser__browser_batch", batch, self.cwd)))

    def test_large_bash_output_gets_a_non_blocking_reminder(self):
        event = {"hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_response": {"stdout": "y" * 50}}
        self.assertIn("additionalContext", token_guard.evaluate(event, max_output_chars=10)["hookSpecificOutput"])
        self.assertEqual(token_guard.evaluate(event, max_output_chars=1000), {})

    def test_cli_is_silent_when_allowed_and_tolerates_bad_input(self):
        run = lambda data, *extra: subprocess.run([sys.executable, str(SCRIPT), *extra], input=data,
                                                  capture_output=True, text=True)
        ok = run(json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": "pwd"}}))
        self.assertEqual((ok.returncode, ok.stdout), (0, ""))
        self.assertEqual(run("not json").returncode, 0)
        self.assertEqual(json.loads(run("{}", "--json").stdout), {})


if __name__ == "__main__":
    unittest.main()
