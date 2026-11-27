#!/usr/bin/env python3
"""Thin stdio MCP Adapter wrapping the Unified Local Control Console (Phase 5).

Exposes ``dispatch_task``, ``steer_task``, ``handover_task``, ``pause_task``,
``kill_task``, ``get_status``, and ``list_pickups`` over local stdio JSON-RPC 2.0
for Claude Desktop, Codex Desktop, Copilot Desktop, T3 Code Desktop, and
Antigravity IDE.

Strictly local stdio transport only; never stores or exposes secrets or raw
Track B transcript message content.

Usage:
    python3 scripts/harness_mcp.py
    python3 scripts/harness_mcp.py --list-tools --json
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
from typing import Any, IO

REPO_ROOT = Path(__file__).resolve().parent.parent
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from scripts.engineering_harness.routing import HarnessError  # noqa: E402
from scripts.harness_console.service import (  # noqa: E402
    ConsoleService,
    DEFAULT_LAUNCHERS_PATH,
    DEFAULT_QUOTAS_PATH,
    DEFAULT_REGISTRY_PATH,
)
from scripts.harness_console.store import ConsoleError  # noqa: E402

SERVER_INFO = {"name": "sitepulse-harness-console", "version": "1.0.0"}
SUPPORTED_PROTOCOL_VERSIONS = ("2025-03-26", "2024-11-05")

TOOL_SCHEMAS: list[dict[str, Any]] = [
    {
        "name": "dispatch_task",
        "description": "Plan or enqueue a routed engineering task dispatch.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "task": {"type": "string", "description": "Task description"},
                "complexity": {"type": "string", "enum": ["low", "medium", "high", "critical"]},
                "files": {"type": "integer", "minimum": 1},
                "financial": {"type": "boolean"},
                "schema": {"type": "boolean"},
                "auth": {"type": "boolean"},
                "scope": {"type": "string", "enum": ["fullstack", "backend", "frontend", "mechanical"]},
                "actor": {"type": "string"},
            },
            "required": ["task"],
        },
    },
    {
        "name": "steer_task",
        "description": "Attach a mid-run steering instruction for an issue or run.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "issue": {"type": "integer", "minimum": 1},
                "run_id": {"type": "string"},
                "note": {"type": "string", "description": "Steering note to inject at next checkpoint/handover"},
                "actor": {"type": "string"},
            },
            "required": ["note"],
        },
    },
    {
        "name": "handover_task",
        "description": "Force handover routing and pin an issue or run to a target provider or T3 instance.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "issue": {"type": "integer", "minimum": 1},
                "run_id": {"type": "string"},
                "to": {"type": "string", "description": "Target provider or T3 providerInstanceId"},
                "reason": {"type": "string"},
                "pin": {"type": "boolean"},
                "actor": {"type": "string"},
            },
            "required": ["to"],
        },
    },
    {
        "name": "pause_task",
        "description": "Pause coordinator dispatches globally or for an issue, run, or provider (or resume when resume=true).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "all": {"type": "boolean"},
                "issue": {"type": "integer", "minimum": 1},
                "run_id": {"type": "string"},
                "provider": {"type": "string"},
                "reason": {"type": "string"},
                "resume": {"type": "boolean"},
                "actor": {"type": "string"},
            },
        },
    },
    {
        "name": "kill_task",
        "description": "Stop an active durable/T3 run or local worker and safely capture dirty WIP edits.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "issue": {"type": "integer", "minimum": 1},
                "run_id": {"type": "string"},
                "reason": {"type": "string"},
                "actor": {"type": "string"},
            },
        },
    },
    {
        "name": "get_status",
        "description": "Return live provider health, quota/USD spend, active work board, controls, and pickups.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "issue": {"type": "integer", "minimum": 1},
                "run_id": {"type": "string"},
                "include_github": {"type": "boolean"},
            },
        },
    },
    {
        "name": "list_pickups",
        "description": "List ready-to-paste handover pickup briefs for interactive IDE and Desktop sessions.",
        "inputSchema": {
            "type": "object",
            "properties": {},
        },
    },
]


def call_tool(service: ConsoleService, name: str, arguments: dict[str, Any] | None) -> dict[str, Any]:
    """Execute one MCP tool call against ConsoleService."""
    args = dict(arguments or {})
    actor = str(args.get("actor") or "mcp-operator")
    if name == "dispatch_task":
        return service.dispatch_task(
            task=str(args.get("task") or ""),
            complexity=args.get("complexity"),
            files=args.get("files"),
            financial=bool(args.get("financial", False)),
            schema=bool(args.get("schema", False)),
            auth=bool(args.get("auth", False)),
            scope=str(args.get("scope") or "fullstack"),
            actor=actor,
            transport="mcp",
        )
    if name == "steer_task":
        return service.steer(
            note=str(args.get("note") or ""),
            issue=args.get("issue"),
            run_id=args.get("run_id"),
            actor=actor,
            transport="mcp",
        )
    if name == "handover_task":
        return service.handover(
            to=str(args.get("to") or ""),
            issue=args.get("issue"),
            run_id=args.get("run_id"),
            reason=str(args.get("reason") or "manual"),
            pin=bool(args.get("pin", True)),
            actor=actor,
            transport="mcp",
        )
    if name == "pause_task":
        fn = service.resume if bool(args.get("resume", False)) else service.pause
        return fn(
            all_scopes=bool(args.get("all", False)),
            issue=args.get("issue"),
            run_id=args.get("run_id"),
            provider=args.get("provider"),
            reason=str(args.get("reason") or ("operator_resume" if args.get("resume") else "operator_pause")),
            actor=actor,
            transport="mcp",
        )
    if name == "kill_task":
        return service.kill(
            issue=args.get("issue"),
            run_id=args.get("run_id"),
            reason=str(args.get("reason") or "operator_kill"),
            actor=actor,
            transport="mcp",
        )
    if name == "get_status":
        return service.status(
            issue=args.get("issue"),
            run_id=args.get("run_id"),
            include_github=bool(args.get("include_github", False)),
        )
    if name == "list_pickups":
        pickups = service.list_pickups()
        return {"count": len(pickups), "pickups": pickups}
    raise ConsoleError(f"unknown MCP tool: {name}")


def handle_jsonrpc(service: ConsoleService, request: dict[str, Any]) -> dict[str, Any] | None:
    """Handle a single JSON-RPC 2.0 MCP message; return None for notifications."""
    req_id = request.get("id")
    method = request.get("method")
    params = request.get("params") or {}

    if not isinstance(method, str):
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "error": {"code": -32600, "message": "Invalid Request: missing method"},
        }

    if method.startswith("notifications/") and req_id is None:
        return None

    try:
        if method == "initialize":
            requested_ver = str(params.get("protocolVersion") or SUPPORTED_PROTOCOL_VERSIONS[0])
            ver = requested_ver if requested_ver in SUPPORTED_PROTOCOL_VERSIONS else SUPPORTED_PROTOCOL_VERSIONS[0]
            result: dict[str, Any] = {
                "protocolVersion": ver,
                "capabilities": {"tools": {"listChanged": False}},
                "serverInfo": SERVER_INFO,
            }
        elif method == "ping":
            result = {}
        elif method == "tools/list":
            result = {"tools": TOOL_SCHEMAS}
        elif method == "tools/call":
            tool_name = params.get("name")
            if not isinstance(tool_name, str) or not tool_name:
                return {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "error": {"code": -32602, "message": "tools/call requires a tool name"},
                }
            try:
                payload = call_tool(service, tool_name, params.get("arguments"))
                result = {
                    "content": [{"type": "text", "text": json.dumps(payload, indent=2, sort_keys=True)}],
                    "structuredContent": payload,
                    "isError": False,
                }
            except (ConsoleError, HarnessError, ValueError, OSError) as exc:
                err_payload = {"ok": False, "error": str(exc)}
                result = {
                    "content": [{"type": "text", "text": json.dumps(err_payload, sort_keys=True)}],
                    "structuredContent": err_payload,
                    "isError": True,
                }
        else:
            if req_id is None:
                return None
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {"code": -32601, "message": f"Method not found: {method}"},
            }
    except Exception as exc:  # noqa: BLE001
        if req_id is None:
            return None
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "error": {"code": -32603, "message": str(exc)},
        }

    if req_id is None:
        return None
    return {"jsonrpc": "2.0", "id": req_id, "result": result}


def serve_stdio(service: ConsoleService, stdin: IO[bytes] | None = None, stdout: IO[bytes] | None = None) -> int:
    """Run the MCP JSON-RPC 2.0 loop over stdin/stdout (supports ndjson and Content-Length framing)."""
    inp = stdin or sys.stdin.buffer
    out = stdout or sys.stdout.buffer

    while True:
        line = inp.readline()
        if not line:
            break
        stripped = line.strip()
        if not stripped:
            continue

        framed = False
        if stripped.lower().startswith(b"content-length:"):
            framed = True
            length = int(stripped.split(b":", 1)[1].strip())
            while True:
                hdr = inp.readline()
                if not hdr or hdr in (b"\r\n", b"\n"):
                    break
            body_bytes = inp.read(length)
        else:
            body_bytes = stripped

        try:
            req = json.loads(body_bytes.decode("utf-8"))
        except (UnicodeDecodeError, ValueError) as exc:
            resp: dict[str, Any] | None = {
                "jsonrpc": "2.0",
                "id": None,
                "error": {"code": -32700, "message": f"Parse error: {exc}"},
            }
        else:
            if not isinstance(req, dict):
                resp = {
                    "jsonrpc": "2.0",
                    "id": None,
                    "error": {"code": -32600, "message": "Invalid Request"},
                }
            else:
                resp = handle_jsonrpc(service, req)

        if resp is None:
            continue
        encoded = json.dumps(resp, separators=(",", ":")).encode("utf-8")
        if framed:
            out.write(f"Content-Length: {len(encoded)}\r\n\r\n".encode("ascii") + encoded)
        else:
            out.write(encoded + b"\n")
        out.flush()
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--list-tools", action="store_true", help="print exposed MCP tools and exit")
    parser.add_argument("--json", action="store_true", help="machine-readable JSON output for --list-tools")
    parser.add_argument("--state-root", help="local state root (default: main checkout .agents/local)")
    parser.add_argument("--repo", help="repository checkout path")
    parser.add_argument("--console-db", help="path to harness_console.sqlite3")
    parser.add_argument("--ledger", help="path to token_ledger.sqlite3")
    parser.add_argument("--runs-db", help="path to runs.sqlite3")
    parser.add_argument("--quotas", default=str(DEFAULT_QUOTAS_PATH))
    parser.add_argument("--registry", default=str(DEFAULT_REGISTRY_PATH))
    parser.add_argument("--launchers", default=str(DEFAULT_LAUNCHERS_PATH))
    parser.add_argument("--offline", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.list_tools:
        if args.json:
            print(json.dumps({"server": SERVER_INFO, "tools": TOOL_SCHEMAS}, indent=2))
        else:
            for tool in TOOL_SCHEMAS:
                print(f"{tool['name']}: {tool['description']}")
        return 0
    service = ConsoleService(
        local_root=args.state_root,
        repo_root=args.repo,
        console_db=args.console_db,
        ledger_db=args.ledger,
        runs_db=args.runs_db,
        quotas_path=args.quotas,
        registry_path=args.registry,
        launchers_path=args.launchers,
        offline=args.offline,
    )
    try:
        return serve_stdio(service)
    finally:
        service.close()


if __name__ == "__main__":
    sys.exit(main())
