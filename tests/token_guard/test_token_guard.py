"""Self-tests for scripts/token_guard.py (Claude Code context-budget hook)."""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

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


class CheckpointGateTests(unittest.TestCase):
    """Phase 4 Layer 1: context/quota soft gates force a checkpoint."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cwd = self.tmp.name
        Path(self.cwd, "small.txt").write_text("x")

    def tearDown(self):
        self.tmp.cleanup()

    def gate(self, tool, tool_input=None, **values):
        return token_guard.checkpoint_reason(tool, tool_input or {}, **values)

    def test_edits_are_blocked_at_eighty_percent_context(self):
        self.assertIsNotNone(self.gate("Edit", {"file_path": "x.py"}, context_pct="80"))
        self.assertIsNotNone(self.gate("Write", {"file_path": "x.py"}, context_pct="84.5"))
        self.assertIsNone(self.gate("Edit", {"file_path": "x.py"}, context_pct="79.9"))

    def test_quota_gate_blocks_at_eighty_five_percent(self):
        self.assertIsNotNone(self.gate("MultiEdit", {"file_path": "x.py"}, quota_pct="85"))
        self.assertIsNone(self.gate("MultiEdit", {"file_path": "x.py"}, quota_pct="84"))

    def test_checkpoint_commands_stay_allowed_but_feature_work_does_not(self):
        for command in ("git status --short", "git diff", "git commit -m checkpoint",
                        "git push", "python3 scripts/handover.py capture --issue 549 "
                        "--reason context_ceiling", "python3 scripts/harness_coordinator.py status"):
            self.assertIsNone(self.gate("Bash", {"command": command}, context_pct="90"), command)
        for command in ("python3 scripts/run_tests.py", "rg TODO src", "git checkout main",
                        "git stash", "git branch -D old-branch", "git push --force",
                        "git push -f origin main", "git push origin +main"):
            self.assertIsNotNone(self.gate("Bash", {"command": command}, context_pct="90"), command)
        self.assertIsNone(self.gate("Bash", {"command": "git push origin HEAD"}, context_pct="90"))
        self.assertIsNone(self.gate("Bash", {"command": "git branch new-branch"}, context_pct="90"))
        self.assertIsNotNone(self.gate("Bash", {"command": "git status && rm -rf src"}, context_pct="90"))

    def test_wide_reads_are_blocked_but_ranged_and_handover_reads_are_allowed(self):
        self.assertIsNotNone(self.gate("Read", {"file_path": "src/big.py"}, context_pct="90"))
        self.assertIsNone(self.gate("Read", {"file_path": "src/big.py", "offset": 10, "limit": 40},
                                    context_pct="90"))
        self.assertIsNone(self.gate("Read", {"file_path": ".agents/local/handovers/549-001.json"},
                                    context_pct="90"))

    def test_other_tools_are_not_blocked_by_the_gate(self):
        self.assertIsNone(self.gate("Grep", {"pattern": "x"}, context_pct="99"))

    def test_session_lease_supplies_the_percentages(self):
        sessions = Path(self.cwd) / ".agents" / "local" / "sessions"
        sessions.mkdir(parents=True)
        (sessions / "t3-ses_x.json").write_text(json.dumps({
            "schema_version": 1, "harness": "t3", "session": "ses_x", "model": "deepseek-flash",
            "context_pct": "86", "quota_pct": "10", "ttl_seconds": 900,
            "updated_at": "2026-11-27T12:00:00Z"}))
        decision = token_guard.evaluate({"hook_event_name": "PreToolUse", "tool_name": "Edit",
                                         "tool_input": {"file_path": "x.py"}, "session_id": "ses_x",
                                         "cwd": self.cwd})
        self.assertTrue(denied(decision))
        self.assertIn("Checkpoint now", decision["hookSpecificOutput"]["permissionDecisionReason"])

    def test_environment_override_and_opt_out(self):
        event = {"hook_event_name": "PreToolUse", "tool_name": "Write",
                 "tool_input": {"file_path": "x.py"}, "cwd": self.cwd}
        with mock.patch.dict(os.environ, {"HARNESS_CONTEXT_PCT": "88"}, clear=False):
            self.assertTrue(denied(token_guard.evaluate(event)))
        with mock.patch.dict(os.environ, {"HARNESS_CONTEXT_PCT": "88", "TOKEN_GUARD_CHECKPOINT": "off"},
                             clear=False):
            self.assertEqual(token_guard.evaluate(event), {})
        self.assertEqual(token_guard.evaluate(event, checkpoint=False), {})

    def test_cli_flags_override_the_gate_thresholds(self):
        event = json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Edit",
                            "tool_input": {"file_path": "x.py"}, "cwd": self.cwd})
        run = lambda *extra: subprocess.run([sys.executable, str(SCRIPT), *extra], input=event,
                                            capture_output=True, text=True)
        self.assertEqual(run("--context-pct", "50", "--json").stdout.strip(), "{}")
        denied_call = json.loads(run("--context-pct", "95", "--checkpoint-context-pct", "90",
                                     "--json").stdout)
        self.assertTrue(denied(denied_call))


if __name__ == "__main__":
    unittest.main()
