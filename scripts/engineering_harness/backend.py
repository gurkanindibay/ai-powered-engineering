"""Digest-pinned Docker bridge and gate executor; no host command fallback."""
from __future__ import annotations

from dataclasses import dataclass
import json
import os
from pathlib import Path
import selectors
import subprocess
import time
import tempfile
from typing import Callable

from .contracts import canonical
from .routing import HarnessError


@dataclass
class Execution:
    code: int
    output: str
    status: str
    duration_ms: int


class DockerBackend:
    def __init__(self, policy: dict):
        self.policy = policy

    def _docker(self, argv: list[str]) -> subprocess.CompletedProcess:
        try:
            return subprocess.run(["docker", *argv], capture_output=True, text=True, timeout=20)
        except (OSError, subprocess.SubprocessError) as exc:
            raise HarnessError("Docker is unavailable; no unsandboxed fallback is permitted") from exc

    def status(self, name: str) -> str:
        response = self._docker(["inspect", "--format", "{{.State.Status}}", name])
        if response.returncode:
            if "no such" in response.stderr.lower():
                return "absent"
            raise HarnessError("Unable to reconcile container state")
        return response.stdout.strip()

    def cancel(self, name: str):
        state = self.status(name)
        if state in ("running", "created", "restarting", "paused"):
            response = self._docker(["rm", "--force", name])
            if response.returncode:
                raise HarnessError("Unable to stop owned worker container")

    def execute(self, name: str, argv: list[str], *, workspace: Path | None = None,
                writable: list[Path] | None = None, cwd: str = ".", payload: dict | None = None,
                timeout: int = 60, cancelled: Callable[[], bool] = lambda: False) -> Execution:
        if cancelled():
            return Execution(-1, "", "cancelled", 0)
        limits = self.policy["limits"]
        if self.policy["network"] != "none":
            response = self._docker(["network", "inspect", "--format", "{{.Internal}}", self.policy["network"]])
            if response.returncode or response.stdout.strip() != "true":
                raise HarnessError("Provider egress network must be an administrator-created internal network")
        command = ["docker", "run", "--pull=never", "--name", name, "--label", "engineering-harness=owned",
                   "--read-only", "--log-driver=none", "--cap-drop=ALL", "--security-opt=no-new-privileges", "--init",
                   "--network", self.policy["network"], "--pids-limit", str(limits["pids"]),
                   "--memory", f"{limits['memory_mb']}m", "--memory-swap", f"{limits['memory_mb']}m",
                   "--cpus", str(limits["cpus"]), "--user", f"{os.getuid()}:{os.getgid()}",
                   "--tmpfs", "/tmp:rw,nosuid,nodev,size=128m,mode=1777", "--env", "HOME=/tmp",
                   "--env", "PYTHONDONTWRITEBYTECODE=1", "--interactive"]
        if workspace is not None:
            command += ["--mount", f"type=bind,src={workspace},dst=/workspace" + ("" if workspace in (writable or []) else ",readonly"), "--workdir", f"/workspace/{cwd}"]
            for path in writable or []:
                if path == workspace:
                    continue
                relative = path.relative_to(workspace)
                command += ["--mount", f"type=bind,src={path},dst=/workspace/{relative}"]
        command += ["--entrypoint", argv[0], self.policy["image"], *argv[1:]]
        started = time.monotonic()
        raw = (canonical(payload) if payload is not None else "").encode()
        if len(raw) > 65536:
            raise HarnessError("Bridge envelope exceeds 64 KiB; use compact artifact references")
        input_file = tempfile.TemporaryFile()
        input_file.write(raw)
        input_file.seek(0)
        try:
            process = subprocess.Popen(command, stdin=input_file, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        except OSError as exc:
            input_file.close()
            raise HarnessError("Docker is not available") from exc
        output = bytearray()
        status = "completed"
        try:
            selector = selectors.DefaultSelector()
            selector.register(process.stdout, selectors.EVENT_READ)
            while True:
                if cancelled():
                    status = "cancelled"
                    break
                if time.monotonic() - started >= timeout:
                    status = "timed_out"
                    break
                events = selector.select(timeout=0.1)
                if events:
                    chunk = os.read(process.stdout.fileno(), 65536)
                    if not chunk:
                        break
                    output.extend(chunk)
                    if len(output) > limits["output_bytes"]:
                        status = "output_limit"
                        break
                elif process.poll() is not None:
                    break
            selector.close()
            if status != "completed":
                self.cancel(name)
            try:
                code = process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
                self.cancel(name)
                code = -1
            return Execution(code, bytes(output[:limits["output_bytes"]]).decode(errors="replace"), status,
                             int((time.monotonic() - started) * 1000))
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            process.stdout.close()
            input_file.close()

    def capabilities(self, name: str, **kwargs) -> dict:
        result = self.execute(name, self.policy["bridge"], payload={"schema_version": 1, "action": "capabilities"}, **kwargs)
        if result.code or result.status != "completed":
            raise HarnessError("Live capability discovery failed")
        try:
            return json.loads(result.output)
        except ValueError as exc:
            raise HarnessError("Capability bridge did not return JSON") from exc
