import json
from pathlib import Path
import tempfile
import unittest

from scripts.engineering_harness.gateway_bridge import execute, workspace_tool
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
