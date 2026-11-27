"""Unit and lifecycle tests for scripts/harness_stack.py."""
from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import io
import json
import os
from pathlib import Path
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from scripts import harness_stack as stack


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def _run_cli(argv: list[str], *, specs: stack.CommandSpecs | None = None) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with redirect_stdout(out), redirect_stderr(err):
        try:
            code = stack.main(argv, specs=specs)
        except SystemExit as exc:
            code = int(exc.code or 0)
    return code, out.getvalue(), err.getvalue()


_DUMMY_CONSOLE = """
import http.server, json, signal, sys, time
port = int(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            body = json.dumps({"status": "ok"}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()
    def log_message(self, fmt, *args):
        pass
server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
print("console ready token=sk-secret-value-1234567890", flush=True)
server.serve_forever()
"""

_DUMMY_COORDINATOR = """
import signal, sys, time
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
print("coordinator loop started", flush=True)
while True:
    time.sleep(0.2)
"""

_DUMMY_INGEST = """
import json
print(json.dumps({"status": "ok", "total_files_scanned": 2, "total_new_events": 5}))
"""


class HarnessStackTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="harness-stack-test-"))
        self.state_root = self.tmp / "state"
        self.repo_root = self.tmp / "repo"
        self.repo_root.mkdir(parents=True, exist_ok=True)
        self.specs = stack.CommandSpecs(
            ingest_cmd=lambda _repo, _state, _ledger: [sys.executable, "-c", _DUMMY_INGEST],
            console_cmd=lambda _repo, args: [sys.executable, "-c", _DUMMY_CONSOLE, str(args.port)],
            coordinator_cmd=lambda _repo, _args: [sys.executable, "-c", _DUMMY_COORDINATOR],
        )

    def tearDown(self) -> None:
        _run_cli(["down", "--state-root", str(self.state_root), "--repo", str(self.repo_root), "--json"])
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_help_and_non_loopback_rejected(self) -> None:
        code, out, _ = _run_cli(["--help"])
        self.assertEqual(code, 0)
        self.assertIn("harness_stack.py", out)

        code, out, _ = _run_cli([
            "up", "--host", "0.0.0.0", "--state-root", str(self.state_root), "--repo", str(self.repo_root), "--json"
        ], specs=self.specs)
        self.assertEqual(code, 2)
        self.assertFalse(json.loads(out)["ok"])

    def test_full_lifecycle_up_status_logs_down(self) -> None:
        port = _free_port()
        common = ["--state-root", str(self.state_root), "--repo", str(self.repo_root), "--json"]

        code, out, err = _run_cli(["up", "--port", str(port), *common], specs=self.specs)
        self.assertEqual(code, 0, err or out)
        up_data = json.loads(out)
        self.assertTrue(up_data["ok"])
        self.assertFalse(up_data["already_running"])
        self.assertEqual(up_data["last_ingest"]["total_new_events"], 5)
        self.assertTrue(up_data["services"]["console"]["healthy"])
        self.assertTrue(up_data["services"]["coordinator"]["alive"])

        state_file = self.state_root / stack.STATE_FILENAME
        self.assertTrue(state_file.is_file())
        self.assertEqual(stat.S_IMODE(state_file.stat().st_mode), 0o600)

        # Idempotent second `up` keeps same PIDs and avoids duplicate spawns.
        code, out, _ = _run_cli(["up", "--port", str(port), "--no-ingest", *common], specs=self.specs)
        self.assertEqual(code, 0)
        second = json.loads(out)
        self.assertTrue(second["already_running"])
        self.assertEqual(second["services"]["console"]["pid"], up_data["services"]["console"]["pid"])

        # Port conflict while running returns exit 2.
        code, out, _ = _run_cli(["up", "--port", str(_free_port()), *common], specs=self.specs)
        self.assertEqual(code, 2)

        # Status reports running.
        code, out, _ = _run_cli(["status", *common])
        self.assertEqual(code, 0)
        status_data = json.loads(out)
        self.assertEqual(status_data["status"], "running")
        self.assertTrue(status_data["services"]["console"]["healthy"])

        # Logs are redacted.
        code, out, _ = _run_cli(["logs", "--lines", "20", *common])
        self.assertEqual(code, 0)
        logs_data = json.loads(out)
        console_lines = "\n".join(logs_data["logs"]["console"]["lines"])
        self.assertNotIn("sk-secret-value-1234567890", console_lines)
        self.assertIn("console ready", console_lines)

        # Clean shutdown removes state file and stops processes.
        code, out, _ = _run_cli(["down", *common])
        self.assertEqual(code, 0)
        down_data = json.loads(out)
        self.assertTrue(down_data["ok"])
        self.assertFalse(state_file.exists())

        code, out, _ = _run_cli(["status", *common])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out)["status"], "stopped")

    def test_rollback_when_coordinator_exits_early(self) -> None:
        port = _free_port()
        failing_specs = stack.CommandSpecs(
            ingest_cmd=self.specs.ingest_cmd,
            console_cmd=self.specs.console_cmd,
            coordinator_cmd=lambda _repo, _args: [sys.executable, "-c", "import sys; print('boom'); sys.exit(3)"],
        )
        code, out, _ = _run_cli([
            "up", "--port", str(port), "--state-root", str(self.state_root), "--repo", str(self.repo_root), "--json"
        ], specs=failing_specs)
        self.assertEqual(code, 1)
        data = json.loads(out)
        self.assertFalse(data["ok"])
        self.assertIn("harness_coordinator exited early", data["error"])
        self.assertFalse((self.state_root / stack.STATE_FILENAME).exists())
        # Console was rolled back so the port is free again.
        ok, _ = stack._probe_healthz(f"http://127.0.0.1:{port}", timeout=0.3)
        self.assertFalse(ok)

    def test_down_skips_reused_pid_with_mismatched_start_ticks(self) -> None:
        proc = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(10)"])
        try:
            state_path = self.state_root / stack.STATE_FILENAME
            stack._write_private_json(state_path, {
                "schema_version": 1,
                "host": "127.0.0.1",
                "port": 9096,
                "url": "http://127.0.0.1:9096",
                "services": {
                    "console": {"pid": proc.pid, "pid_start_ticks": 999999999999},
                    "coordinator": {"pid": None, "pid_start_ticks": None},
                },
            })
            with mock.patch("scripts.harness_stack.process_start_ticks", return_value=12345):
                code, out, _ = _run_cli([
                    "down", "--state-root", str(self.state_root), "--repo", str(self.repo_root), "--json"
                ])
            self.assertEqual(code, 0)
            payload = json.loads(out)
            self.assertFalse(payload["services"]["console"]["was_running"])
            self.assertEqual(payload["services"]["console"]["reason"], "pid_reused")
            self.assertIsNone(proc.poll())
        finally:
            proc.terminate()
            proc.wait(timeout=3)


if __name__ == "__main__":
    unittest.main()
