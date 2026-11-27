#!/usr/bin/env python3
"""Single-command launcher and lifecycle manager for the Engineering Harness stack.

Starts, inspects, tails logs of, and stops the local Phase 1-5 harness runtime:
  1. Initial telemetry ingest via ``scripts/token_tracker.py ingest --provider all``
  2. Unified Control Console Web UI & SSE server (``scripts/harness_console.py serve``)
  3. 0-Token Auto-Handover Coordinator daemon (``scripts/harness_coordinator.py serve``)

Usage:
    python3 scripts/harness_stack.py up
    python3 scripts/harness_stack.py up --open
    python3 scripts/harness_stack.py status --json
    python3 scripts/harness_stack.py logs --lines 50
    python3 scripts/harness_stack.py down

Exit codes:
    0  success
    1  runtime failure (ingest, startup, or health-check failure)
    2  usage or configuration error (e.g. non-loopback host, port conflict)
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
from typing import Any, Callable
import urllib.error
import urllib.request
import webbrowser

REPO_ROOT = Path(__file__).resolve().parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from scripts.engineering_harness.contracts import redact  # noqa: E402
from scripts.engineering_harness.leases import process_start_ticks  # noqa: E402
from scripts.harness_console.store import (  # noqa: E402
    default_local_root,
    find_main_checkout,
    utc_now_iso,
)
from scripts.harness_console.web import DEFAULT_UI_HOST, DEFAULT_UI_PORT, LOOPBACK_HOSTNAMES  # noqa: E402

SCHEMA_VERSION = 1
STATE_FILENAME = "harness_stack.json"
DEFAULT_INTERVAL_SECONDS = 60.0
DEFAULT_WAIT_SECONDS = 10.0
DEFAULT_STOP_TIMEOUT_SECONDS = 5.0
COORDINATOR_STARTUP_CHECK_SECONDS = 0.35


class StackError(ValueError):
    """Usage or configuration error (exit 2)."""


class StackRuntimeError(RuntimeError):
    """Runtime startup/health error (exit 1)."""


@dataclass(frozen=True)
class CommandSpecs:
    """Injectable command builders used by tests to override subprocess targets."""

    ingest_cmd: Callable[[Path, Path, Path | None], list[str]] | None = None
    console_cmd: Callable[[Path, argparse.Namespace], list[str]] | None = None
    coordinator_cmd: Callable[[Path, argparse.Namespace], list[str]] | None = None


def _ensure_private_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(path, 0o700)
    except OSError:
        pass


def _write_private_json(path: Path, payload: dict[str, Any]) -> None:
    _ensure_private_dir(path.parent)
    tmp = path.with_name(f".{path.name}.tmp.{os.getpid()}")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    except Exception:
        try:
            tmp.unlink()
        except OSError:
            pass
        raise
    os.replace(tmp, path)


def _read_state(path: Path) -> dict[str, Any] | None:
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else None
    except (OSError, ValueError):
        return None


def _open_log_fd(path: Path) -> int:
    _ensure_private_dir(path.parent)
    return os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)


def _tail_file(path: Path, lines: int) -> list[str]:
    if not path.is_file():
        return []
    try:
        raw = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []
    return [redact(line) for line in raw[-lines:]]


def _pid_alive(pid: int | None) -> bool:
    if pid is None or pid <= 1:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    try:
        raw = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8", errors="replace")
        rparen = raw.rfind(")")
        if rparen != -1:
            fields = raw[rparen + 2 :].split()
            if fields and fields[0] in ("Z", "X"):
                return False
    except OSError:
        pass
    return True


def _service_alive(entry: dict[str, Any] | None) -> tuple[bool, str]:
    """Return (alive, reason) verifying /proc start ticks when recorded."""
    if not isinstance(entry, dict):
        return False, "not_recorded"
    pid = entry.get("pid")
    if not isinstance(pid, int) or pid <= 1:
        return False, "invalid_pid"
    if not _pid_alive(pid):
        return False, "not_running"
    recorded_ticks = entry.get("pid_start_ticks")
    if recorded_ticks is not None:
        live_ticks = process_start_ticks(pid)
        if live_ticks is None or live_ticks != recorded_ticks:
            return False, "pid_reused"
    return True, "running"


def _terminate_entry(entry: dict[str, Any] | None, *, timeout: float) -> dict[str, Any]:
    if not isinstance(entry, dict):
        return {"stopped": True, "was_running": False, "reason": "not_recorded"}
    pid = entry.get("pid")
    alive, reason = _service_alive(entry)
    if not alive:
        return {"stopped": True, "was_running": False, "pid": pid, "reason": reason}
    assert isinstance(pid, int)
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return {"stopped": True, "was_running": False, "pid": pid, "reason": "already_exited"}
    except OSError as exc:
        return {"stopped": False, "was_running": True, "pid": pid, "reason": f"sigterm_failed:{exc}"}

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not _pid_alive(pid):
            return {"stopped": True, "was_running": True, "pid": pid, "signal": "SIGTERM"}
        time.sleep(0.05)

    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        return {"stopped": True, "was_running": True, "pid": pid, "signal": "SIGTERM"}
    except OSError as exc:
        return {"stopped": False, "was_running": True, "pid": pid, "reason": f"sigkill_failed:{exc}"}

    kill_deadline = time.monotonic() + 1.0
    while time.monotonic() < kill_deadline:
        if not _pid_alive(pid):
            break
        time.sleep(0.05)
    return {"stopped": not _pid_alive(pid), "was_running": True, "pid": pid, "signal": "SIGKILL"}


def _terminate_proc(proc: subprocess.Popen[Any] | None, timeout: float = 3.0) -> None:
    if proc is None or proc.poll() is not None:
        return
    try:
        proc.terminate()
        proc.wait(timeout=timeout)
    except Exception:
        try:
            proc.kill()
            proc.wait(timeout=1.0)
        except Exception:
            pass


def _base_url(host: str, port: int) -> str:
    formatted_host = f"[{host}]" if ":" in host else host
    return f"http://{formatted_host}:{port}"


def _probe_healthz(url: str, *, timeout: float = 1.0) -> tuple[bool, str]:
    health_url = url.rstrip("/") + "/healthz"
    req = urllib.request.Request(health_url, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            if 200 <= resp.status < 300:
                return True, body.strip()
            return False, f"HTTP {resp.status}"
    except urllib.error.URLError as exc:
        return False, str(exc.reason)
    except Exception as exc:
        return False, str(exc)


def _wait_for_console_health(
    proc: subprocess.Popen[Any],
    url: str,
    log_path: Path,
    *,
    wait_seconds: float,
) -> None:
    deadline = time.monotonic() + wait_seconds
    last_reason = "not_started"
    while time.monotonic() < deadline:
        rc = proc.poll()
        if rc is not None:
            tail = "\n".join(_tail_file(log_path, 20))
            raise StackRuntimeError(
                f"harness_console exited early with status {rc}" + (f":\n{tail}" if tail else "")
            )
        ok, detail = _probe_healthz(url, timeout=0.5)
        if ok:
            return
        last_reason = detail
        time.sleep(0.1)
    tail = "\n".join(_tail_file(log_path, 20))
    raise StackRuntimeError(
        f"Timed out waiting for {url}/healthz ({last_reason})" + (f":\n{tail}" if tail else "")
    )


def _resolve_repo_root(args: argparse.Namespace) -> Path:
    explicit = getattr(args, "repo", None)
    if explicit:
        return Path(explicit).resolve()
    return find_main_checkout()


def _resolve_state_root(args: argparse.Namespace) -> Path:
    explicit = getattr(args, "state_root", None)
    if explicit:
        return Path(explicit).resolve()
    return default_local_root()


def _default_ingest_cmd(repo_root: Path, state_root: Path, ledger: Path | None) -> list[str]:
    ledger_path = ledger or (state_root / "token_ledger.sqlite3")
    return [
        sys.executable,
        str(repo_root / "scripts" / "token_tracker.py"),
        "--db",
        str(ledger_path),
        "ingest",
        "--provider",
        "all",
        "--json",
    ]


def _default_console_cmd(repo_root: Path, args: argparse.Namespace, state_root: Path) -> list[str]:
    cmd = [
        sys.executable,
        str(repo_root / "scripts" / "harness_console.py"),
        "serve",
        "--host",
        args.host,
        "--port",
        str(args.port),
        "--state-root",
        str(state_root),
        "--repo",
        str(repo_root),
    ]
    if args.ledger:
        cmd.extend(["--ledger", str(Path(args.ledger).resolve())])
    if args.t3_db:
        cmd.extend(["--runs-db", str(Path(args.t3_db).resolve())])
    if args.t3_catalog:
        cmd.extend(["--t3-catalog", str(Path(args.t3_catalog).resolve())])
    if args.offline:
        cmd.append("--offline")
    return cmd


def _default_coordinator_cmd(repo_root: Path, args: argparse.Namespace, state_root: Path) -> list[str]:
    cmd = [
        sys.executable,
        str(repo_root / "scripts" / "harness_coordinator.py"),
        "serve",
        "--interval",
        str(args.interval),
        "--state-root",
        str(state_root),
        "--repo",
        str(repo_root),
    ]
    if args.ledger:
        cmd.extend(["--ledger", str(Path(args.ledger).resolve())])
    if args.t3_db:
        cmd.extend(["--t3-db", str(Path(args.t3_db).resolve())])
    if args.t3_catalog:
        cmd.extend(["--t3-catalog", str(Path(args.t3_catalog).resolve())])
    if args.no_recover:
        cmd.append("--no-recover")
    if args.offline:
        cmd.append("--offline")
    return cmd


def _spawn_detached(cmd: list[str], *, cwd: Path, log_path: Path) -> subprocess.Popen[Any]:
    fd = _open_log_fd(log_path)
    try:
        return subprocess.Popen(
            cmd,
            cwd=str(cwd),
            stdin=subprocess.DEVNULL,
            stdout=fd,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            close_fds=True,
        )
    finally:
        os.close(fd)


def _validate_up_args(args: argparse.Namespace) -> None:
    if args.host not in LOOPBACK_HOSTNAMES:
        raise StackError(f"Refusing non-loopback host {args.host!r}; allowed: {', '.join(LOOPBACK_HOSTNAMES)}")
    if not (1 <= args.port <= 65535):
        raise StackError(f"Invalid --port {args.port}; must be between 1 and 65535")
    if args.interval <= 0:
        raise StackError(f"Invalid --interval {args.interval}; must be > 0")
    if args.wait_seconds <= 0:
        raise StackError(f"Invalid --wait-seconds {args.wait_seconds}; must be > 0")


def run_up(args: argparse.Namespace, *, specs: CommandSpecs | None = None) -> dict[str, Any]:
    _validate_up_args(args)
    specs = specs or CommandSpecs()
    repo_root = _resolve_repo_root(args)
    state_root = _resolve_state_root(args)
    state_path = state_root / STATE_FILENAME
    logs_dir = state_root / "logs"
    console_log = logs_dir / "harness-console.log"
    coordinator_log = logs_dir / "harness-coordinator.log"
    url = _base_url(args.host, args.port)

    existing = _read_state(state_path) or {}
    existing_services = existing.get("services") if isinstance(existing.get("services"), dict) else {}
    existing_console = existing_services.get("console")
    existing_coord = existing_services.get("coordinator")
    console_alive, _ = _service_alive(existing_console)
    coord_alive, _ = _service_alive(existing_coord)

    if console_alive and (existing.get("host") != args.host or existing.get("port") != args.port):
        raise StackError(
            f"harness-console is already running at {existing.get('url')}; run `down` before changing host/port"
        )

    if console_alive and coord_alive:
        healthy, _ = _probe_healthz(url, timeout=1.0)
        if healthy:
            if args.open:
                webbrowser.open(url)
            return {
                "ok": True,
                "already_running": True,
                "url": url,
                "state_path": str(state_path),
                "mcp_command": f"python3 {repo_root / 'scripts' / 'harness_mcp.py'}",
                "services": {
                    "console": {**existing_console, "alive": True, "healthy": True},
                    "coordinator": {**existing_coord, "alive": True},
                },
            }

    ingest_result: dict[str, Any] | None = None
    if not args.no_ingest:
        ledger_path = Path(args.ledger).resolve() if args.ledger else None
        ingest_cmd = (
            specs.ingest_cmd(repo_root, state_root, ledger_path)
            if specs.ingest_cmd
            else _default_ingest_cmd(repo_root, state_root, ledger_path)
        )
        done = subprocess.run(ingest_cmd, cwd=str(repo_root), capture_output=True, text=True, check=False)
        if done.returncode != 0:
            detail = (done.stderr or done.stdout).strip()[:400]
            raise StackRuntimeError(f"token_tracker ingest failed (exit {done.returncode}): {detail}")
        try:
            ingest_result = json.loads(done.stdout) if done.stdout.strip() else {"status": "ok"}
        except ValueError:
            ingest_result = {"status": "ok", "raw": done.stdout.strip()[:200]}

    started_procs: list[subprocess.Popen[Any]] = []
    try:
        if console_alive:
            console_entry = dict(existing_console)
        else:
            console_cmd = (
                specs.console_cmd(repo_root, args)
                if specs.console_cmd
                else _default_console_cmd(repo_root, args, state_root)
            )
            console_proc = _spawn_detached(console_cmd, cwd=repo_root, log_path=console_log)
            started_procs.append(console_proc)
            _wait_for_console_health(console_proc, url, console_log, wait_seconds=args.wait_seconds)
            console_entry = {
                "pid": console_proc.pid,
                "pid_start_ticks": process_start_ticks(console_proc.pid),
                "log": str(console_log),
                "command": console_cmd,
            }

        if coord_alive:
            coord_entry = dict(existing_coord)
        else:
            coord_cmd = (
                specs.coordinator_cmd(repo_root, args)
                if specs.coordinator_cmd
                else _default_coordinator_cmd(repo_root, args, state_root)
            )
            coord_proc = _spawn_detached(coord_cmd, cwd=repo_root, log_path=coordinator_log)
            started_procs.append(coord_proc)
            time.sleep(COORDINATOR_STARTUP_CHECK_SECONDS)
            rc = coord_proc.poll()
            if rc is not None:
                tail = "\n".join(_tail_file(coordinator_log, 20))
                raise StackRuntimeError(
                    f"harness_coordinator exited early with status {rc}" + (f":\n{tail}" if tail else "")
                )
            coord_entry = {
                "pid": coord_proc.pid,
                "pid_start_ticks": process_start_ticks(coord_proc.pid),
                "log": str(coordinator_log),
                "command": coord_cmd,
            }
    except Exception:
        for proc in reversed(started_procs):
            _terminate_proc(proc)
        raise

    state_payload: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "started_at": utc_now_iso(),
        "host": args.host,
        "port": args.port,
        "url": url,
        "repo_root": str(repo_root),
        "state_root": str(state_root),
        "services": {
            "console": console_entry,
            "coordinator": coord_entry,
        },
        "last_ingest": ingest_result,
    }
    _write_private_json(state_path, state_payload)

    if args.open:
        webbrowser.open(url)

    return {
        "ok": True,
        "already_running": False,
        "url": url,
        "state_path": str(state_path),
        "mcp_command": f"python3 {repo_root / 'scripts' / 'harness_mcp.py'}",
        "last_ingest": ingest_result,
        "services": {
            "console": {**console_entry, "alive": True, "healthy": True},
            "coordinator": {**coord_entry, "alive": True},
        },
    }


def run_down(args: argparse.Namespace) -> dict[str, Any]:
    if args.timeout <= 0:
        raise StackError(f"Invalid --timeout {args.timeout}; must be > 0")
    state_root = _resolve_state_root(args)
    state_path = state_root / STATE_FILENAME
    state = _read_state(state_path)
    if state is None:
        return {
            "ok": True,
            "running": False,
            "state_path": str(state_path),
            "services": {},
        }

    services = state.get("services") if isinstance(state.get("services"), dict) else {}
    results: dict[str, Any] = {}
    all_stopped = True
    for name in ("coordinator", "console"):
        res = _terminate_entry(services.get(name), timeout=args.timeout)
        results[name] = res
        if not res.get("stopped"):
            all_stopped = False

    if all_stopped:
        try:
            state_path.unlink()
        except FileNotFoundError:
            pass

    return {
        "ok": all_stopped,
        "running": not all_stopped,
        "state_path": str(state_path),
        "services": results,
    }


def run_status(args: argparse.Namespace) -> dict[str, Any]:
    state_root = _resolve_state_root(args)
    repo_root = _resolve_repo_root(args)
    state_path = state_root / STATE_FILENAME
    state = _read_state(state_path)
    if state is None:
        return {
            "ok": True,
            "status": "stopped",
            "state_path": str(state_path),
            "mcp_command": f"python3 {repo_root / 'scripts' / 'harness_mcp.py'}",
            "services": {
                "console": {"alive": False, "healthy": False, "reason": "not_started"},
                "coordinator": {"alive": False, "reason": "not_started"},
            },
        }

    services = state.get("services") if isinstance(state.get("services"), dict) else {}
    console_entry = services.get("console") or {}
    coord_entry = services.get("coordinator") or {}
    console_alive, console_reason = _service_alive(console_entry)
    coord_alive, coord_reason = _service_alive(coord_entry)
    url = str(state.get("url") or _base_url(DEFAULT_UI_HOST, DEFAULT_UI_PORT))
    console_healthy, health_detail = (_probe_healthz(url, timeout=1.0) if console_alive else (False, console_reason))

    if console_alive and console_healthy and coord_alive:
        overall = "running"
    elif not console_alive and not coord_alive:
        overall = "stopped"
    else:
        overall = "degraded"

    return {
        "ok": True,
        "status": overall,
        "started_at": state.get("started_at"),
        "url": url,
        "state_path": str(state_path),
        "mcp_command": f"python3 {repo_root / 'scripts' / 'harness_mcp.py'}",
        "services": {
            "console": {
                "pid": console_entry.get("pid"),
                "alive": console_alive,
                "healthy": console_healthy,
                "reason": "ok" if console_healthy else health_detail,
                "log": console_entry.get("log"),
            },
            "coordinator": {
                "pid": coord_entry.get("pid"),
                "alive": coord_alive,
                "reason": coord_reason,
                "log": coord_entry.get("log"),
            },
        },
    }


def run_logs(args: argparse.Namespace) -> dict[str, Any]:
    if args.lines <= 0:
        raise StackError(f"Invalid --lines {args.lines}; must be > 0")
    state_root = _resolve_state_root(args)
    logs_dir = state_root / "logs"
    targets = ("console", "coordinator") if args.service == "all" else (args.service,)
    mapping = {
        "console": logs_dir / "harness-console.log",
        "coordinator": logs_dir / "harness-coordinator.log",
    }
    output: dict[str, Any] = {}
    for name in targets:
        log_path = mapping[name]
        output[name] = {
            "path": str(log_path),
            "exists": log_path.is_file(),
            "lines": _tail_file(log_path, args.lines),
        }
    return {"ok": True, "state_root": str(state_root), "logs": output}


def _format_human(command: str, payload: dict[str, Any]) -> str:
    if command == "up":
        prefix = "Harness stack already running" if payload.get("already_running") else "Harness stack started"
        c = payload["services"]["console"]
        k = payload["services"]["coordinator"]
        lines = [
            f"{prefix}:",
            f"  Control Console : {payload['url']} (pid={c.get('pid')}, log={c.get('log')})",
            f"  Coordinator     : pid={k.get('pid')} (log={k.get('log')})",
            f"  MCP (stdio)     : {payload['mcp_command']}",
        ]
        ingest = payload.get("last_ingest")
        if isinstance(ingest, dict) and "total_new_events" in ingest:
            lines.append(
                f"  Token Ingest    : {ingest['total_new_events']} new event(s) from {ingest.get('total_files_scanned', 0)} file(s)"
            )
        return "\n".join(lines)
    if command == "down":
        if not payload["services"]:
            return f"Harness stack is not running ({payload['state_path']} absent)."
        lines = ["Harness stack stop:"]
        for name, info in payload["services"].items():
            lines.append(
                f"  {name:<12} stopped={info.get('stopped')} pid={info.get('pid')} ({info.get('signal') or info.get('reason')})"
            )
        return "\n".join(lines)
    if command == "status":
        lines = [f"Harness stack status: {payload['status']}"]
        if payload.get("url"):
            lines.append(f"  Console URL     : {payload['url']}")
        c = payload["services"]["console"]
        k = payload["services"]["coordinator"]
        lines.append(
            f"  console         : alive={c['alive']} healthy={c['healthy']} pid={c.get('pid')} ({c['reason']})"
        )
        lines.append(f"  coordinator     : alive={k['alive']} pid={k.get('pid')} ({k['reason']})")
        lines.append(f"  MCP (stdio)     : {payload['mcp_command']}")
        return "\n".join(lines)
    if command == "logs":
        blocks: list[str] = []
        for name, info in payload["logs"].items():
            blocks.append(f"=== {name} ({info['path']}) ===")
            if info["lines"]:
                blocks.extend(info["lines"])
            else:
                blocks.append("(no log lines)")
        return "\n".join(blocks)
    return json.dumps(payload, indent=2, sort_keys=True)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="harness_stack.py",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest="command", required=True)

    def add_common(target: argparse.ArgumentParser) -> None:
        target.add_argument("--state-root", help="local state root (default: main checkout .agents/local)")
        target.add_argument("--repo", help="repository checkout path (default: main checkout)")
        target.add_argument("--json", action="store_true", help="machine-readable JSON output")

    up = sub.add_parser("up", help="ingest token telemetry and start console + coordinator")
    add_common(up)
    up.add_argument("--host", default=DEFAULT_UI_HOST, help=f"loopback host (default: {DEFAULT_UI_HOST})")
    up.add_argument("--port", type=int, default=DEFAULT_UI_PORT, help=f"console port (default: {DEFAULT_UI_PORT})")
    up.add_argument("--interval", type=float, default=DEFAULT_INTERVAL_SECONDS, help="coordinator poll interval seconds")
    up.add_argument("--wait-seconds", type=float, default=DEFAULT_WAIT_SECONDS, help="health check timeout seconds")
    up.add_argument("--ledger", help="path to token_ledger.sqlite3")
    up.add_argument("--t3-db", help="path to runs.sqlite3 for coordinator watchdog")
    up.add_argument("--t3-catalog", help="optional saved T3 orchestrator_capabilities JSON")
    up.add_argument("--offline", action="store_true", help="disable GitHub CLI queries in console & coordinator")
    up.add_argument("--no-ingest", action="store_true", help="skip initial token_tracker ingest")
    up.add_argument("--no-recover", action="store_true", help="skip Layer-3 watchdog in coordinator")
    up.add_argument("--open", action="store_true", help="open Control Console URL in default browser once healthy")

    dn = sub.add_parser("down", help="stop running harness stack services")
    add_common(dn)
    dn.add_argument("--timeout", type=float, default=DEFAULT_STOP_TIMEOUT_SECONDS, help="SIGTERM grace period seconds")

    st = sub.add_parser("status", help="inspect running stack processes and console /healthz")
    add_common(st)

    lg = sub.add_parser("logs", help="print redacted tails of console and coordinator logs")
    add_common(lg)
    lg.add_argument("--service", choices=("all", "console", "coordinator"), default="all")
    lg.add_argument("--lines", type=int, default=40, help="number of trailing lines per service")

    return parser


def main(argv: list[str] | None = None, *, specs: CommandSpecs | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        if args.command == "up":
            payload = run_up(args, specs=specs)
        elif args.command == "down":
            payload = run_down(args)
        elif args.command == "status":
            payload = run_status(args)
        elif args.command == "logs":
            payload = run_logs(args)
        else:
            raise StackError(f"Unknown command {args.command}")
    except StackError as exc:
        if getattr(args, "json", False):
            print(json.dumps({"ok": False, "error": str(exc)}, indent=2, sort_keys=True))
        else:
            print(f"Error: {exc}", file=sys.stderr)
        return 2
    except StackRuntimeError as exc:
        if getattr(args, "json", False):
            print(json.dumps({"ok": False, "error": str(exc)}, indent=2, sort_keys=True))
        else:
            print(f"Error: {exc}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(_format_human(args.command, payload))
    return 0 if payload.get("ok", True) else 1


if __name__ == "__main__":
    sys.exit(main())
