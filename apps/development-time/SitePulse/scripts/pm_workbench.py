#!/usr/bin/env python3
"""SitePulse Product Manager Test Workbench CLI (pm_workbench.py).

Provides a single command to launch, manage, seed, and control the local
development sandbox with deterministic E2E clock control.

Subcommands:
  up:     Starts local PostgreSQL, Axum Rust backend (with --features e2e),
          and Flutter Web, recording runtime PIDs.
  down:   Cleanly terminates running workbench processes and removes the pidfile.
  seed:   Seeds reference scenario presets (F0-F7) via pm_scenarios.seeder,
          synchronizes the E2E clock, and prints a formatted cheat sheet or JSON.
  clock:  Controls the deterministic E2E clock (set, advance, tick, reset).
  status: Inspects running workbench processes and API health.

Per AGENTS.md rules 4, 5, and 6:
  - English-only identifiers, docstrings, and messages.
  - Full support for --help and --json on all subcommands.
  - Zero floating-point arithmetic for financial figures.
  - Strict production guardrail refusing execution under production env.
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from decimal import Decimal
from pathlib import Path
from typing import Any

# Base path resolution
SCRIPT_DIR = Path(__file__).resolve().parent
SITEPULSE_ROOT = SCRIPT_DIR.parent
BACKEND_DIR = SITEPULSE_ROOT / "backend"
FLUTTER_DIR = SITEPULSE_ROOT / "flutter"

# Ensure pm_scenarios and scripts directory is importable
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

try:
    from pm_scenarios.seeder import REFERENCE_CLOCKS, seed_preset
except ImportError:
    REFERENCE_CLOCKS = {
        "F0": "2026-09-01",
        "F1": "2026-09-01",
        "F2": "2026-09-01",
        "F3": "2026-10-01",
        "F4": "2026-11-19",
        "F5": "2026-11-19",
        "F6": "2026-11-19",
        "F7": "2026-11-19",
    }
    seed_preset = None  # type: ignore[assignment]


# ---------------------------------------------------------------------------
# Production Guardrail
# ---------------------------------------------------------------------------

class ProductionGuardrailError(RuntimeError):
    """Raised when execution is attempted in a production environment."""


def check_production_guardrail(env: dict[str, str] | None = None) -> None:
    """Enforces safety guardrail: refuse execution if APP_ENV or ENVIRONMENT is production."""
    lookup = os.environ if env is None else env
    app_env = lookup.get("APP_ENV", "").strip().lower()
    env_val = lookup.get("ENVIRONMENT", "").strip().lower()
    if app_env == "production" or env_val == "production":
        raise ProductionGuardrailError(
            "Refusing execution in production environment (APP_ENV=production or ENVIRONMENT=production)"
        )


# ---------------------------------------------------------------------------
# Runtime PID File & Process Management
# ---------------------------------------------------------------------------

DEFAULT_PID_PATH = Path.home() / ".sitepulse" / "workbench.pid"


def resolve_pid_path(custom: str | Path | None = None, env: dict[str, str] | None = None) -> Path:
    """Resolves the pidfile path from argument, environment, or default location."""
    if custom is not None:
        return Path(custom).resolve()
    lookup = os.environ if env is None else env
    env_path = lookup.get("SITEPULSE_WORKBENCH_PIDFILE")
    if env_path:
        return Path(env_path).resolve()
    return DEFAULT_PID_PATH


def read_pidfile(pid_path: Path) -> dict[str, Any] | None:
    """Reads and parses the JSON pidfile if present and valid."""
    if not pid_path.is_file():
        return None
    try:
        data = json.loads(pid_path.read_text(encoding="utf-8"))
        if isinstance(data, dict):
            return data
    except Exception:
        pass
    return None


def write_pidfile(pid_path: Path, data: dict[str, Any]) -> None:
    """Atomically writes JSON runtime state to the pidfile."""
    pid_path.parent.mkdir(parents=True, exist_ok=True)
    temp_path = pid_path.with_suffix(".tmp")
    temp_path.write_text(json.dumps(data, indent=2), encoding="utf-8")
    temp_path.replace(pid_path)


def remove_pidfile(pid_path: Path) -> None:
    """Removes the pidfile if it exists."""
    try:
        if pid_path.is_file():
            pid_path.unlink()
    except OSError:
        pass


def is_process_alive(pid: int | None) -> bool:
    """Checks whether a process with the given PID is actively running."""
    if pid is None or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, OSError):
        return False


def terminate_process(pid: int | None, timeout_sec: float = 5.0) -> bool:
    """Gracefully terminates a process (SIGTERM), falling back to SIGKILL if necessary."""
    if pid is None or not is_process_alive(pid):
        return True
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        return True

    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        if not is_process_alive(pid):
            return True
        time.sleep(0.1)

    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        pass
    time.sleep(0.2)
    return not is_process_alive(pid)


# ---------------------------------------------------------------------------
# Network & Dependency Helpers
# ---------------------------------------------------------------------------

def is_port_listening(host: str, port: int, timeout: float = 0.5) -> bool:
    """Checks if a TCP port is open and accepting connections."""
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except (OSError, socket.timeout):
        return False


def check_url_health(url: str, timeout: float = 1.0) -> bool:
    """Performs an HTTP GET request to check whether an endpoint is healthy (HTTP 200)."""
    try:
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return 200 <= resp.status < 400
    except Exception:
        return False


def start_database_dependencies() -> None:
    """Starts local PostgreSQL and Adminer containers via dev-db-up.sh."""
    dev_db_up = SCRIPT_DIR / "dev-db-up.sh"
    if dev_db_up.is_file() and os.access(dev_db_up, os.X_OK):
        proc = subprocess.run(
            ["bash", str(dev_db_up)],
            cwd=BACKEND_DIR,
            capture_output=True,
            text=True,
        )
        if proc.returncode != 0:
            raise RuntimeError(f"dev-db-up.sh failed:\n{proc.stderr.strip() or proc.stdout.strip()}")
    else:
        # Fallback to direct docker compose
        docker_cmd = "docker"
        if not shutil.which(docker_cmd):
            docker_cmd = "sudo docker"
        proc = subprocess.run(
            [docker_cmd, "compose", "up", "-d", "postgres", "adminer"],
            cwd=BACKEND_DIR,
            capture_output=True,
            text=True,
        )
        if proc.returncode != 0:
            raise RuntimeError(f"docker compose up failed:\n{proc.stderr.strip() or proc.stdout.strip()}")


def stop_database_dependencies() -> None:
    """Stops local PostgreSQL and Adminer containers via dev-db-down.sh."""
    dev_db_down = SCRIPT_DIR / "dev-db-down.sh"
    if dev_db_down.is_file() and os.access(dev_db_down, os.X_OK):
        subprocess.run(["bash", str(dev_db_down)], cwd=BACKEND_DIR, capture_output=True, text=True)
    else:
        docker_cmd = "docker"
        if not shutil.which(docker_cmd):
            docker_cmd = "sudo docker"
        subprocess.run(
            [docker_cmd, "compose", "down"],
            cwd=BACKEND_DIR,
            capture_output=True,
            text=True,
        )


# ---------------------------------------------------------------------------
# E2E Clock API Client
# ---------------------------------------------------------------------------

def call_clock_api(
    api_url: str,
    payload: dict[str, Any],
    timeout: float = 10.0,
) -> dict[str, Any]:
    """Invokes the backend deterministic E2E clock endpoint with automatic fallback.

    First attempts /api/e2e/clock; if not found (404), falls back to /__e2e/clock.
    """
    base = api_url.rstrip("/")
    endpoints = [f"{base}/api/e2e/clock", f"{base}/__e2e/clock"]
    data = json.dumps(payload).encode("utf-8")
    last_err: Exception | None = None

    for url in endpoints:
        req = urllib.request.Request(
            url,
            data=data,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                body = resp.read().decode("utf-8")
                return json.loads(body) if body.strip() else {"status": "OK"}
        except urllib.error.HTTPError as err:
            last_err = err
            if err.code == 404:
                continue  # Try fallback endpoint
            err_body = err.read().decode("utf-8")
            try:
                err_json = json.loads(err_body)
                raise RuntimeError(err_json.get("message") or err_json.get("error") or err_body)
            except Exception:
                raise RuntimeError(f"HTTP {err.code}: {err_body or err.reason}")
        except Exception as err:
            last_err = err

    raise RuntimeError(f"Failed to communicate with E2E clock at {api_url}: {last_err}")


# ---------------------------------------------------------------------------
# Subcommand Implementations
# ---------------------------------------------------------------------------

def run_up(
    api_port: int = 8080,
    web_port: int = 9090,
    skip_db: bool = False,
    skip_flutter: bool = False,
    backend_release: bool = False,
    pid_file: Path | None = None,
    timeout: float = 40.0,
    no_wait: bool = False,
    as_json: bool = False,
) -> int:
    """Brings up the SitePulse sandbox stack."""
    check_production_guardrail()
    pid_path = resolve_pid_path(pid_file)
    existing = read_pidfile(pid_path)

    backend_alive = existing and is_process_alive(existing.get("backend_pid"))
    flutter_alive = existing and is_process_alive(existing.get("flutter_pid"))

    if backend_alive:
        res = {
            "status": "ALREADY_RUNNING",
            "backend_pid": existing.get("backend_pid"),
            "flutter_pid": existing.get("flutter_pid"),
            "api_url": existing.get("api_url", f"http://localhost:{api_port}"),
            "web_url": existing.get("web_url", f"http://localhost:{web_port}"),
            "clock_url": f"{existing.get('api_url', f'http://localhost:{api_port}')}/api/e2e/clock",
            "message": "SitePulse workbench is already running.",
        }
        if as_json:
            print(json.dumps(res, indent=2))
        else:
            print("SitePulse PM Workbench is already running.")
            print(f"  ● Backend API:    {res['api_url']}/api/v1/health (PID: {res['backend_pid']})")
            print(f"  ● E2E Clock API:  {res['clock_url']}")
            if flutter_alive:
                print(f"  ● Flutter Web:    {res['web_url']} (PID: {res['flutter_pid']})")
        return 0

    # Clean up stale pidfile if any
    remove_pidfile(pid_path)

    # 1. Start Database dependencies
    if not skip_db:
        if not is_port_listening("127.0.0.1", 5432):
            if not as_json:
                print("Starting PostgreSQL and Adminer database containers...")
            start_database_dependencies()

    # 2. Launch Rust Backend with --features e2e
    cargo_bin = shutil.which("cargo") or str(Path.home() / ".cargo" / "bin" / "cargo")
    if not shutil.which(cargo_bin):
        raise RuntimeError("Cargo binary not found in PATH or ~/.cargo/bin.")

    backend_env = os.environ.copy()
    backend_env["APP_ENV"] = "development"
    backend_env["SITEPULSE_E2E"] = "true"
    backend_env["SITEPULSE_ENABLE_DEV_ROUTES"] = "true"
    backend_env["SITEPULSE_SEED_TEST_DATA"] = "false"
    backend_env["PORT"] = str(api_port)

    # Load backend/.env defaults if present
    backend_env_file = BACKEND_DIR / ".env"
    if backend_env_file.is_file():
        for line in backend_env_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                k = k.strip()
                v = v.strip().strip('"').strip("'")
                if k not in backend_env:
                    backend_env[k] = v

    cargo_cmd = [cargo_bin, "run", "--features", "e2e"]
    if backend_release:
        cargo_cmd.append("--release")

    backend_log_path = Path("/tmp/sitepulse-workbench-backend.log")
    if not as_json:
        print(f"Launching Rust Backend (Axum + E2E Clock) on port {api_port}...")
    with open(backend_log_path, "a", encoding="utf-8") as backend_log_file:
        proc_backend = subprocess.Popen(
            cargo_cmd,
            cwd=str(BACKEND_DIR),
            env=backend_env,
            stdout=backend_log_file,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    backend_pid = proc_backend.pid

    # 3. Launch Flutter Web Client
    flutter_pid: int | None = None
    flutter_bin = (
        shutil.which("flutter")
        or str(Path(os.environ.get("FLUTTER_ROOT", str(Path.home() / "flutter"))) / "bin" / "flutter")
    )

    if not skip_flutter and Path(flutter_bin).is_file():
        flutter_cmd = [
            flutter_bin,
            "run",
            "-d",
            "web-server",
            "--web-port",
            str(web_port),
            "--web-hostname",
            "0.0.0.0",
        ]
        flutter_log_path = Path("/tmp/sitepulse-workbench-flutter.log")
        if not as_json:
            print(f"Launching Flutter Web Server on port {web_port}...")
        with open(flutter_log_path, "a", encoding="utf-8") as flutter_log_file:
            proc_flutter = subprocess.Popen(
                flutter_cmd,
                cwd=str(FLUTTER_DIR),
                stdout=flutter_log_file,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
        flutter_pid = proc_flutter.pid

    # Record runtime PID file
    pid_data = {
        "backend_pid": backend_pid,
        "flutter_pid": flutter_pid,
        "api_port": api_port,
        "web_port": web_port,
        "api_url": f"http://localhost:{api_port}",
        "web_url": f"http://localhost:{web_port}",
        "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }
    write_pidfile(pid_path, pid_data)

    # 4. Wait for backend health check
    health_url = f"http://localhost:{api_port}/api/v1/health"
    if not no_wait:
        if not as_json:
            print("Waiting for backend API health check...", end="", flush=True)
        ready = False
        deadline = time.time() + timeout
        while time.time() < deadline:
            if proc_backend.poll() is not None:
                if not as_json:
                    print(" [FAILED]")
                raise RuntimeError(
                    f"Backend process exited prematurely with code {proc_backend.returncode}. "
                    f"Check {backend_log_path} for details."
                )
            if check_url_health(health_url) or check_url_health(f"http://localhost:{api_port}/health"):
                ready = True
                break
            if not as_json:
                print(".", end="", flush=True)
            time.sleep(0.5)

        if not ready:
            if not as_json:
                print(" [TIMEOUT]")
            raise RuntimeError(
                f"Timed out waiting for backend health check at {health_url}. Check {backend_log_path}."
            )
        if not as_json:
            print(" [ONLINE]")

    clock_url = f"http://localhost:{api_port}/api/e2e/clock"
    summary = {
        "status": "ONLINE",
        "backend_pid": backend_pid,
        "flutter_pid": flutter_pid,
        "api_url": f"http://localhost:{api_port}",
        "web_url": f"http://localhost:{web_port}",
        "clock_url": clock_url,
        "adminer_url": "http://localhost:8081",
    }

    if as_json:
        print(json.dumps(summary, indent=2))
    else:
        print("\n" + "=" * 68)
        print("          SITEPULSE PRODUCT MANAGER WORKBENCH IS ONLINE         ")
        print("=" * 68)
        print(f"  ● Backend API:     http://localhost:{api_port}/api/v1/health (PID: {backend_pid})")
        print(f"  ● E2E Clock API:   {clock_url}")
        if flutter_pid:
            print(f"  ● Flutter Web:     http://localhost:{web_port}/ (PID: {flutter_pid})")
        print("  ● Adminer DB GUI:  http://localhost:8081")
        print("=" * 68)
        print("Sandbox is ready. Run `pm_workbench.py seed F5` to seed a scenario.")

    return 0


def run_down(
    pid_file: Path | None = None,
    stop_db: bool = False,
    as_json: bool = False,
) -> int:
    """Cleanly terminates running workbench processes."""
    check_production_guardrail()
    pid_path = resolve_pid_path(pid_file)
    data = read_pidfile(pid_path)

    if not data:
        msg = "No active SitePulse workbench runtime found."
        if as_json:
            print(json.dumps({"status": "NOT_RUNNING", "message": msg}, indent=2))
        else:
            print(msg)
        return 0

    backend_pid = data.get("backend_pid")
    flutter_pid = data.get("flutter_pid")

    if not as_json:
        print("Stopping SitePulse workbench processes...")

    stopped_backend = terminate_process(backend_pid)
    stopped_flutter = terminate_process(flutter_pid)

    if stop_db:
        if not as_json:
            print("Stopping PostgreSQL and Adminer database containers...")
        stop_database_dependencies()

    remove_pidfile(pid_path)

    res = {
        "status": "STOPPED",
        "backend_pid": backend_pid,
        "flutter_pid": flutter_pid,
        "backend_stopped": stopped_backend,
        "flutter_stopped": stopped_flutter,
    }

    if as_json:
        print(json.dumps(res, indent=2))
    else:
        print("SitePulse workbench stopped cleanly.")

    return 0


def run_seed(
    preset: str,
    api_url: str = "http://localhost:8080",
    saas_email: str = "admin@sitepulse.io",
    saas_password: str = "E2E-Bootstrap-Admin-1",
    db_name: str = "sitepulse",
    skip_reload: bool = False,
    as_json: bool = False,
) -> int:
    """Seeds a reference preset scenario and synchronizes the E2E clock."""
    check_production_guardrail()
    if seed_preset is None:
        raise RuntimeError("pm_scenarios.seeder is unavailable.")

    # 1. Seed scenario via the shared seeder
    result = seed_preset(
        preset,
        api_url=api_url,
        saas_email=saas_email,
        saas_password=saas_password,
        db_name=db_name,
        reload_fn=(lambda: None) if skip_reload else None,
    )

    # 2. Ensure /api/e2e/clock is explicitly updated to the reference date
    ref_clock = REFERENCE_CLOCKS.get(preset, "2026-11-19")
    try:
        call_clock_api(api_url, {"action": "set_date", "date": ref_clock})
    except Exception as clock_err:
        if not as_json:
            print(f"Warning: E2E clock call returned notice: {clock_err}", file=sys.stderr)

    m = result.manifest
    if as_json:
        print(m.to_json(indent=2))
        return 0

    # Human-readable Cheat Sheet
    print("=" * 68)
    print(f"SitePulse Scenario Seeded: {m.preset}")
    print("=" * 68)
    print(f"Site ID:         {m.site_id}")
    print(f"Site Name:       {m.site_name}")
    print(f"Reference Clock: {m.reference_clock}")

    print("\nExpected Site Totals:")
    for k, v in m.expected_site_totals.items():
        print(f"  {k:20s}: {v}")

    print("\nPersonas Credentials Cheat Sheet:")
    print(f"  {'ROLE':15s} {'NAME':18s} {'UNIT':6s} {'EMAIL':32s} {'CREDENTIALS'}")
    print("  " + "-" * 85)
    for p in m.personas:
        unit = p.get("unit") or "-"
        print(f"  {p['role']:15s} {p['name']:18s} {unit:6s} {p['email']:32s} [configured]")
    print("  Note: Standard E2E password configured for all personas (use --json for raw test fields).")

    if m.unit_by_unit_expected_balances:
        print("\nUnit Balances:")
        for u in m.unit_by_unit_expected_balances:
            status = "PAID" if u.get("is_paid") else "OVERDUE"
            print(
                f"  Unit {u['unit']} ({u.get('house_type', 'Flat')}): "
                f"Due={u['amount_due']} TRY, Advance={u['advance_balance']} TRY [{status}]"
            )
    print("=" * 68)
    return 0


def run_clock(
    action: str,
    value: str | None = None,
    api_url: str = "http://localhost:8080",
    as_json: bool = False,
) -> int:
    """Wraps /api/e2e/clock control commands."""
    check_production_guardrail()
    action = action.lower()

    if action == "set":
        if not value:
            raise ValueError("Clock action 'set' requires a date (e.g. 2026-11-20) or RFC3339 timestamp.")
        payload = {"action": "set_instant", "at": value} if "T" in value else {"action": "set_date", "date": value}
    elif action == "advance":
        if not value:
            raise ValueError("Clock action 'advance' requires a target date (e.g. 2026-11-29).")
        payload = {"action": "advance_to", "date": value}
    elif action == "tick":
        payload = {"action": "tick"}
    elif action in ("reset", "clear"):
        payload = {"action": "clear"}
    else:
        raise ValueError(f"Unknown clock action: {action!r}. Supported: set, advance, tick, reset, clear.")

    resp = call_clock_api(api_url, payload)

    if as_json:
        print(json.dumps(resp, indent=2))
    else:
        resp_action = resp.get("action", action)
        if resp_action == "date_set":
            print(f"Clock date set to {resp.get('date')}.")
        elif resp_action == "advanced":
            print(f"Clock date advanced to {resp.get('date')}.")
        elif resp_action == "instant_set":
            print(f"Clock instant set to {resp.get('at')}.")
        elif resp_action == "cleared":
            print("Clock returned to system wall clock.")
        elif resp_action == "ticked":
            report = resp.get("report", {})
            print(f"Clock ticked at {resp.get('date')}. Scheduler report: {report}")
        else:
            print(f"Clock action '{action}' executed successfully: {resp}")

    return 0


def run_status(
    pid_file: Path | None = None,
    api_url: str = "http://localhost:8080",
    as_json: bool = False,
) -> int:
    """Reports status of the local workbench stack."""
    check_production_guardrail()
    pid_path = resolve_pid_path(pid_file)
    data = read_pidfile(pid_path)

    backend_pid = data.get("backend_pid") if data else None
    flutter_pid = data.get("flutter_pid") if data else None

    backend_running = is_process_alive(backend_pid)
    flutter_running = is_process_alive(flutter_pid)
    api_target = data.get("api_url", api_url) if data else api_url
    api_healthy = check_url_health(f"{api_target}/api/v1/health") or check_url_health(f"{api_target}/health")

    status_str = "ONLINE" if backend_running and api_healthy else ("DEGRADED" if backend_running else "STOPPED")

    info = {
        "status": status_str,
        "backend_pid": backend_pid,
        "backend_running": backend_running,
        "api_healthy": api_healthy,
        "flutter_pid": flutter_pid,
        "flutter_running": flutter_running,
        "api_url": api_target,
        "web_url": data.get("web_url", "http://localhost:9090") if data else "http://localhost:9090",
    }

    if as_json:
        print(json.dumps(info, indent=2))
    else:
        print("SitePulse Workbench Status:")
        print(f"  ● Overall Status:   {status_str}")
        print(f"  ● Backend Process:  {'ALIVE' if backend_running else 'STOPPED'} (PID: {backend_pid or '-'})")
        print(f"  ● API Health:       {'OK' if api_healthy else 'UNREACHABLE'} ({api_target})")
        print(f"  ● Flutter Process:  {'ALIVE' if flutter_running else 'STOPPED'} (PID: {flutter_pid or '-'})")

    return 0 if status_str == "ONLINE" else 1


# ---------------------------------------------------------------------------
# CLI Parser & Entry Point
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    """Builds the main argument parser for pm_workbench.py."""
    parser = argparse.ArgumentParser(
        prog="pm_workbench.py",
        description="SitePulse Product Manager Sandbox Launcher & CLI Workbench",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--json", action="store_true", help="Format output as structured JSON")
    parser.add_argument("--pid-file", default=None, help="Custom path for runtime workbench pidfile")

    subparsers = parser.add_subparsers(dest="subcommand", help="Workbench action")

    # up
    parser_up = subparsers.add_parser("up", help="Start local PostgreSQL, Rust backend and Flutter Web")
    parser_up.add_argument("--api-port", type=int, default=8080, help="Backend API port")
    parser_up.add_argument("--web-port", type=int, default=9090, help="Flutter Web port")
    parser_up.add_argument("--skip-db", action="store_true", help="Skip launching database containers")
    parser_up.add_argument("--skip-flutter", action="store_true", help="Skip launching Flutter Web server")
    parser_up.add_argument("--backend-release", action="store_true", help="Run backend with --release")
    parser_up.add_argument("--timeout", type=float, default=40.0, help="Timeout in seconds for health check")
    parser_up.add_argument("--no-wait", action="store_true", help="Do not wait for health checks before returning")
    parser_up.add_argument("--json", action="store_true", help="Format output as JSON")

    # down
    parser_down = subparsers.add_parser("down", help="Stop local workbench processes")
    parser_down.add_argument("--stop-db", action="store_true", help="Also stop database containers")
    parser_down.add_argument("--json", action="store_true", help="Format output as JSON")

    # seed
    parser_seed = subparsers.add_parser("seed", help="Seed a scenario preset (F0-F7) and set E2E clock")
    parser_seed.add_argument("preset", nargs="?", default="F4", help="Scenario preset to seed (e.g. F0, F4, F5)")
    parser_seed.add_argument("--preset", dest="opt_preset", help="Alternative flag to specify preset")
    parser_seed.add_argument("--api-url", default="http://localhost:8080", help="Backend API base URL")
    parser_seed.add_argument("--saas-email", default="admin@sitepulse.io", help="SaaS bootstrap admin email")
    parser_seed.add_argument("--saas-password", default="E2E-Bootstrap-Admin-1", help="SaaS bootstrap admin password")
    parser_seed.add_argument("--db-name", default="sitepulse", help="PostgreSQL database name")
    parser_seed.add_argument("--skip-reload", action="store_true", help="Skip state reload")
    parser_seed.add_argument("--json", action="store_true", help="Output Scenario Manifest as structured JSON")

    # clock
    parser_clock = subparsers.add_parser("clock", help="Deterministic E2E clock control")
    parser_clock.add_argument(
        "action",
        choices=["set", "advance", "tick", "reset", "clear"],
        help="Clock action to execute",
    )
    parser_clock.add_argument("value", nargs="?", default=None, help="Target date or RFC3339 timestamp")
    parser_clock.add_argument("--api-url", default="http://localhost:8080", help="Backend API base URL")
    parser_clock.add_argument("--json", action="store_true", help="Output response as structured JSON")

    # status
    parser_status = subparsers.add_parser("status", help="Inspect status of workbench processes")
    parser_status.add_argument("--api-url", default="http://localhost:8080", help="Backend API base URL")
    parser_status.add_argument("--json", action="store_true", help="Output status as structured JSON")

    return parser


def main(argv: list[str] | None = None, env: dict[str, str] | None = None) -> int:
    """Main CLI entry point for pm_workbench.py."""
    parser = build_parser()
    args = parser.parse_args(argv)

    # Global or subcommand --json flag
    as_json = bool(args.json or getattr(args, "json", False))

    # Fast production guardrail check before any action
    try:
        check_production_guardrail(env)
    except ProductionGuardrailError as guard_err:
        if as_json:
            print(json.dumps({"status": "ERROR", "error": str(guard_err)}, indent=2))
        else:
            print(f"Error: {guard_err}", file=sys.stderr)
        return 1

    if not args.subcommand:
        parser.print_help()
        return 0

    try:
        if args.subcommand == "up":
            return run_up(
                api_port=args.api_port,
                web_port=args.web_port,
                skip_db=args.skip_db,
                skip_flutter=args.skip_flutter,
                backend_release=args.backend_release,
                pid_file=args.pid_file,
                timeout=args.timeout,
                no_wait=args.no_wait,
                as_json=as_json,
            )
        elif args.subcommand == "down":
            return run_down(
                pid_file=args.pid_file,
                stop_db=args.stop_db,
                as_json=as_json,
            )
        elif args.subcommand == "seed":
            target_preset = args.opt_preset or args.preset
            return run_seed(
                preset=target_preset,
                api_url=args.api_url,
                saas_email=args.saas_email,
                saas_password=args.saas_password,
                db_name=args.db_name,
                skip_reload=args.skip_reload,
                as_json=as_json,
            )
        elif args.subcommand == "clock":
            return run_clock(
                action=args.action,
                value=args.value,
                api_url=args.api_url,
                as_json=as_json,
            )
        elif args.subcommand == "status":
            return run_status(
                pid_file=args.pid_file,
                api_url=args.api_url,
                as_json=as_json,
            )
    except Exception as err:
        if as_json:
            print(json.dumps({"status": "ERROR", "error": str(err)}, indent=2))
        else:
            print(f"Error: {err}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
