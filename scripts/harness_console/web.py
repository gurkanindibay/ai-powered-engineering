"""Loopback-only Control Console Web UI & SSE server (Phase 5).

Follows the security model of ``pm_workbench_web.py`` with even stricter
loopback enforcement (per issue #550: strictly loopback-only ``127.0.0.1``):
  - Refuses to bind any non-loopback host (no ``--allow-remote`` bypass).
  - Validates ``Host`` against loopback hostnames (prevents DNS rebinding).
  - Validates ``Origin``, ``Referer``, and ``Sec-Fetch-Site`` on mutating
    POST requests against the server's exact loopback port (CSRF defense).
  - Requires ``Content-Type: application/json`` on POST requests (forces a
    CORS preflight that this server never approves).
  - Never exposes provider API keys, GitHub App keys, or raw Track B
    transcript message content.

Threat model assumption:
  - Designed for a single-user local developer workstation. Like
    ``pm_workbench_web.py``, loopback POST endpoints enforce browser-level
    same-origin / CSRF protections without per-user bearer authentication, so
    any local process running as the user (or another user on a shared host)
    that can connect to loopback TCP can submit commands.
"""
from __future__ import annotations

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import logging
from pathlib import Path
import sys
import time
from typing import Any
from urllib.parse import parse_qs, urlparse
import uuid

from scripts.engineering_harness.routing import HarnessError
from scripts.token_tracker.quotas import money  # noqa: F401 - keeps Decimal validation consistent

from .service import ConsoleService
from .store import ConsoleError

LOGGER = logging.getLogger(__name__)

DEFAULT_UI_HOST = "127.0.0.1"
DEFAULT_UI_PORT = 9096
LOOPBACK_HOSTNAMES = ("127.0.0.1", "localhost", "::1")
MAX_REQUEST_BYTES = 64 * 1024
UI_HTML_PATH = Path(__file__).resolve().with_name("ui.html")

GET_ROUTES = (
    "/",
    "/index.html",
    "/healthz",
    "/api/status",
    "/api/health",
    "/api/board",
    "/api/timeline",
    "/api/tail",
    "/api/stream",
    "/api/pickups",
    "/api/commands",
)
POST_ROUTES = (
    "/api/dispatch",
    "/api/pause",
    "/api/resume",
    "/api/kill",
    "/api/steer",
    "/api/handover",
    "/api/pin",
    "/api/unpin",
    "/api/takeover",
    "/api/set-budget",
    "/api/mark-status",
    "/api/set-gate",
    "/api/approve",
)


class ConsoleWebError(Exception):
    """Typed HTTP error mapped cleanly to a JSON status response."""

    status: int = 400
    code: str = "bad_request"

    def payload(self) -> dict[str, Any]:
        return {"error": str(self), "code": self.code}


class ForbiddenError(ConsoleWebError):
    status = 403
    code = "forbidden"


class UnsupportedMediaTypeError(ConsoleWebError):
    status = 415
    code = "unsupported_media_type"


class PayloadTooLargeError(ConsoleWebError):
    status = 413
    code = "payload_too_large"


class BadRequestError(ConsoleWebError):
    status = 400
    code = "bad_request"


def render_index_html() -> str:
    try:
        return UI_HTML_PATH.read_text(encoding="utf-8")
    except OSError:
        return (
            "<!DOCTYPE html><html lang='en'><head><meta charset='utf-8'>"
            "<title>Harness Control Console</title></head><body>"
            "<h1>Harness Control Console</h1>"
            "<p>UI asset missing; use <code>/api/status</code>.</p></body></html>"
        )


def _optional_int_param(value: Any, name: str) -> int | None:
    if value is None or value == "":
        return None
    if isinstance(value, bool):
        raise BadRequestError(f"{name} must be an integer")
    try:
        parsed = int(value)
    except (TypeError, ValueError) as exc:
        raise BadRequestError(f"{name} must be an integer") from exc
    if parsed <= 0:
        raise BadRequestError(f"{name} must be positive")
    return parsed


def make_handler(service: ConsoleService) -> type[BaseHTTPRequestHandler]:
    """Build a request handler bound to one ConsoleService instance."""

    class ConsoleRequestHandler(BaseHTTPRequestHandler):
        server_version = "HarnessControlConsole/1.0"

        def log_message(self, fmt: str, *args: Any) -> None:
            LOGGER.debug("%s %s", self.address_string(), fmt % args)

        def _path(self) -> str:
            path = urlparse(self.path).path or "/"
            return path.rstrip("/") or "/"

        def _query(self) -> dict[str, list[str]]:
            return parse_qs(urlparse(self.path).query)

        # -- loopback & CSRF guardrails -----------------------------------

        def _host_name(self, value: str) -> str:
            parsed = urlparse(value if "//" in value else f"//{value}")
            return (parsed.hostname or "").lower()

        def _check_host(self) -> None:
            host_header = self.headers.get("Host")
            if not host_header:
                return
            if self._host_name(host_header) not in LOOPBACK_HOSTNAMES:
                raise ForbiddenError(
                    "Control console only accepts loopback Host headers "
                    f"({', '.join(LOOPBACK_HOSTNAMES)})."
                )

        def _check_origin_header(self, raw_value: str, header_name: str) -> None:
            parsed = urlparse(raw_value if "//" in raw_value else f"//{raw_value}")
            try:
                port = parsed.port
            except ValueError as exc:
                raise ForbiddenError(f"Malformed {header_name} header.") from exc
            if (parsed.hostname or "").lower() not in LOOPBACK_HOSTNAMES:
                raise ForbiddenError(f"Cross-origin {header_name} is not allowed.")
            if port != self.server.server_address[1]:
                raise ForbiddenError(f"Cross-port {header_name} is not allowed.")

        def _check_csrf(self) -> None:
            sec_fetch_site = (self.headers.get("Sec-Fetch-Site") or "").strip().lower()
            if sec_fetch_site and sec_fetch_site not in ("same-origin", "none"):
                raise ForbiddenError(f"Cross-site request blocked (Sec-Fetch-Site={sec_fetch_site}).")
            origin = self.headers.get("Origin")
            if origin:
                self._check_origin_header(origin, "Origin")
            referer = self.headers.get("Referer")
            if referer:
                self._check_origin_header(referer, "Referer")

        def _check_json_content_type(self) -> None:
            content_type = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
            if content_type != "application/json":
                raise UnsupportedMediaTypeError("POST requests must use Content-Type: application/json.")

        # -- response helpers ---------------------------------------------

        def _send_body(self, status: int, body: bytes, content_type: str) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("X-Frame-Options", "DENY")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def _send_json(self, status: int, payload: dict[str, Any]) -> None:
            body = json.dumps(payload, ensure_ascii=False, indent=2).encode("utf-8")
            self._send_body(status, body, "application/json; charset=utf-8")

        def _method_not_allowed(self, allowed: str) -> None:
            self.send_response(405)
            self.send_header("Allow", allowed)
            body = json.dumps(
                {"error": f"{self.command} is not supported on {self._path()}; allowed: {allowed}."}
            ).encode("utf-8")
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _read_json_body(self) -> dict[str, Any]:
            raw_length = self.headers.get("Content-Length")
            try:
                length = int(raw_length) if raw_length else 0
            except ValueError as exc:
                raise BadRequestError("Content-Length must be an integer.") from exc
            if length > MAX_REQUEST_BYTES:
                raise PayloadTooLargeError(f"Request body exceeds {MAX_REQUEST_BYTES} bytes.")
            if length <= 0:
                return {}
            raw = self.rfile.read(length)
            try:
                payload = json.loads(raw.decode("utf-8"))
            except (UnicodeDecodeError, ValueError) as exc:
                raise BadRequestError("Request body must be valid JSON.") from exc
            if not isinstance(payload, dict):
                raise BadRequestError("Request body must be a JSON object.")
            return payload

        # -- dispatch -----------------------------------------------------

        def do_GET(self) -> None:  # noqa: N802
            self._dispatch("GET")

        def do_HEAD(self) -> None:  # noqa: N802
            self._dispatch("GET")

        def do_POST(self) -> None:  # noqa: N802
            self._dispatch("POST")

        def do_OPTIONS(self) -> None:  # noqa: N802
            # Never approve cross-origin CORS preflights.
            self._method_not_allowed("GET, POST")

        def _dispatch(self, method: str) -> None:
            path = self._path()
            try:
                self._check_host()
                if method == "GET":
                    self._handle_get(path)
                else:
                    self._check_csrf()
                    self._check_json_content_type()
                    self._handle_post(path)
            except ConsoleWebError as err:
                self._send_json(err.status, err.payload())
            except (ConsoleError, HarnessError, ValueError) as err:
                self._send_json(400, {"error": str(err), "code": "invalid_request"})
            except Exception:  # noqa: BLE001 - never leak tracebacks or secrets
                request_id = uuid.uuid4().hex[:12]
                LOGGER.exception("Unhandled console error on %s %s (%s)", method, path, request_id)
                self._send_json(500, {"error": "Internal console error.", "request_id": request_id})

        def _handle_get(self, path: str) -> None:
            query = self._query()
            if path in ("/", "/index.html"):
                self._send_body(200, render_index_html().encode("utf-8"), "text/html; charset=utf-8")
            elif path == "/healthz":
                self._send_json(200, {"status": "ok", "service": "harness-console"})
            elif path == "/api/status":
                issue = _optional_int_param((query.get("issue") or [None])[0], "issue")
                run_id = (query.get("run") or [None])[0]
                include_gh = (query.get("github") or ["0"])[0] in ("1", "true", "yes")
                self._send_json(200, service.status(issue=issue, run_id=run_id, include_github=include_gh))
            elif path == "/api/health":
                self._send_json(200, service.provider_health())
            elif path == "/api/board":
                issue = _optional_int_param((query.get("issue") or [None])[0], "issue")
                run_id = (query.get("run") or [None])[0]
                include_gh = (query.get("github") or ["0"])[0] in ("1", "true", "yes")
                self._send_json(200, service.active_board(issue=issue, run_id=run_id, include_github=include_gh))
            elif path == "/api/timeline":
                issue = _optional_int_param((query.get("issue") or [None])[0], "issue")
                pr = _optional_int_param((query.get("pr") or [None])[0], "pr")
                run_id = (query.get("run") or [None])[0]
                self._send_json(200, service.timeline(issue=issue, pr=pr, run_id=run_id))
            elif path == "/api/tail":
                issue = _optional_int_param((query.get("issue") or [None])[0], "issue")
                run_id = (query.get("run") or [None])[0]
                lines = _optional_int_param((query.get("lines") or ["100"])[0], "lines") or 100
                self._send_json(200, service.tail(issue=issue, run_id=run_id, lines=lines))
            elif path == "/api/pickups":
                pickups = service.list_pickups()
                self._send_json(200, {"count": len(pickups), "pickups": pickups})
            elif path == "/api/commands":
                limit = _optional_int_param((query.get("limit") or ["50"])[0], "limit") or 50
                unacked = (query.get("unacked") or ["0"])[0] in ("1", "true", "yes")
                cmds = service.store.list_commands(limit=limit, unacked_only=unacked)
                self._send_json(200, {"count": len(cmds), "commands": cmds})
            elif path == "/api/stream":
                self._handle_sse(query)
            elif path in POST_ROUTES:
                self._method_not_allowed("POST")
            else:
                self._send_json(404, {"error": f"Unknown path {path}."})

        def _handle_sse(self, query: dict[str, list[str]]) -> None:
            issue = _optional_int_param((query.get("issue") or [None])[0], "issue")
            run_id = (query.get("run") or [None])[0]
            once = (query.get("once") or ["0"])[0] in ("1", "true", "yes")

            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "close" if once else "keep-alive")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            if self.command == "HEAD":
                return

            seen_keys: set[tuple[str, str, str]] = set()
            while True:
                try:
                    tail_data = service.tail(issue=issue, run_id=run_id, lines=50)
                    for entry in tail_data["entries"]:
                        key = (entry["timestamp"], entry["source"], entry["message"])
                        if key in seen_keys:
                            continue
                        seen_keys.add(key)
                        frame = f"event: log\ndata: {json.dumps(entry, ensure_ascii=False)}\n\n"
                        self.wfile.write(frame.encode("utf-8"))
                    snapshot = {
                        "checked_at": service.provider_health()["checked_at"],
                        "controls": service.store.state_snapshot(),
                    }
                    self.wfile.write(
                        f"event: status\ndata: {json.dumps(snapshot, ensure_ascii=False)}\n\n".encode("utf-8")
                    )
                    self.wfile.flush()
                    if once:
                        break
                    time.sleep(2.0)
                except (BrokenPipeError, ConnectionResetError, OSError):
                    break

        def _handle_post(self, path: str) -> None:
            payload = self._read_json_body()
            actor = str(payload.get("actor") or "web-operator")
            if path == "/api/dispatch":
                res = service.dispatch_task(
                    task=str(payload.get("task") or ""),
                    complexity=payload.get("complexity"),
                    files=_optional_int_param(payload.get("files"), "files"),
                    financial=bool(payload.get("financial", False)),
                    schema=bool(payload.get("schema", False)),
                    auth=bool(payload.get("auth", False)),
                    scope=str(payload.get("scope") or "fullstack"),
                    actor=actor,
                    transport="web",
                )
            elif path == "/api/pause":
                res = service.pause(
                    all_scopes=bool(payload.get("all", False)),
                    issue=_optional_int_param(payload.get("issue"), "issue"),
                    run_id=payload.get("run_id"),
                    provider=payload.get("provider"),
                    reason=str(payload.get("reason") or "operator_pause"),
                    actor=actor,
                    transport="web",
                )
            elif path == "/api/resume":
                res = service.resume(
                    all_scopes=bool(payload.get("all", False)),
                    issue=_optional_int_param(payload.get("issue"), "issue"),
                    run_id=payload.get("run_id"),
                    provider=payload.get("provider"),
                    reason=str(payload.get("reason") or "operator_resume"),
                    actor=actor,
                    transport="web",
                )
            elif path == "/api/kill":
                res = service.kill(
                    issue=_optional_int_param(payload.get("issue"), "issue"),
                    run_id=payload.get("run_id"),
                    reason=str(payload.get("reason") or "operator_kill"),
                    actor=actor,
                    transport="web",
                )
            elif path == "/api/steer":
                res = service.steer(
                    note=str(payload.get("note") or ""),
                    issue=_optional_int_param(payload.get("issue"), "issue"),
                    run_id=payload.get("run_id"),
                    actor=actor,
                    transport="web",
                )
            elif path == "/api/handover":
                res = service.handover(
                    to=str(payload.get("to") or ""),
                    issue=_optional_int_param(payload.get("issue"), "issue"),
                    run_id=payload.get("run_id"),
                    reason=str(payload.get("reason") or "manual"),
                    pin=bool(payload.get("pin", True)),
                    actor=actor,
                    transport="web",
                )
            elif path == "/api/pin":
                res = service.pin(
                    to=str(payload.get("to") or ""),
                    issue=_optional_int_param(payload.get("issue"), "issue"),
                    run_id=payload.get("run_id"),
                    actor=actor,
                    transport="web",
                )
            elif path == "/api/unpin":
                res = service.unpin(
                    issue=_optional_int_param(payload.get("issue"), "issue"),
                    run_id=payload.get("run_id"),
                    actor=actor,
                    transport="web",
                )
            elif path == "/api/takeover":
                res = service.takeover(
                    issue=_optional_int_param(payload.get("issue"), "issue"),
                    run_id=payload.get("run_id"),
                    release_claim=bool(payload.get("release_claim", False)),
                    actor=actor,
                    transport="web",
                )
            elif path == "/api/set-budget":
                res = service.set_budget(
                    provider=str(payload.get("provider") or "copilot-deepseek"),
                    usd=str(payload.get("usd") or ""),
                    actor=actor,
                    transport="web",
                )
            elif path == "/api/mark-status":
                res = service.mark_status(
                    provider=str(payload.get("provider") or ""),
                    status=str(payload.get("status") or ""),
                    model_family=str(payload.get("model_family") or "all"),
                    reset_at=payload.get("reset_at"),
                    utilization_pct=payload.get("utilization_pct"),
                    actor=actor,
                    transport="web",
                )
            elif path == "/api/set-gate":
                res = service.set_gate(
                    tier=str(payload.get("tier") or ""),
                    require_approval=bool(payload.get("require_approval", True)),
                    actor=actor,
                    transport="web",
                )
            elif path == "/api/approve":
                res = service.approve(
                    issue=_optional_int_param(payload.get("issue"), "issue"),
                    run_id=payload.get("run_id"),
                    handover_id=payload.get("handover_id"),
                    actor=actor,
                    transport="web",
                )
            elif path in GET_ROUTES:
                self._method_not_allowed("GET")
                return
            else:
                self._send_json(404, {"error": f"Unknown path {path}."})
                return
            self._send_json(200, res)

    return ConsoleRequestHandler


def create_server(
    service: ConsoleService,
    *,
    host: str = DEFAULT_UI_HOST,
    port: int = DEFAULT_UI_PORT,
) -> ThreadingHTTPServer:
    """Create the loopback-only HTTP server; non-loopback binds are unconditionally refused."""
    if host not in LOOPBACK_HOSTNAMES:
        raise ConsoleError(
            f"Refusing to bind non-loopback host {host!r}: Control Console is strictly loopback-only "
            f"({', '.join(LOOPBACK_HOSTNAMES)})."
        )
    server = ThreadingHTTPServer((host, port), make_handler(service))
    server.daemon_threads = True
    return server


def serve(
    service: ConsoleService,
    *,
    host: str = DEFAULT_UI_HOST,
    port: int = DEFAULT_UI_PORT,
) -> None:
    server = create_server(service, host=host, port=port)
    bound_host, bound_port = server.server_address[:2]
    sys.stderr.write(f"Harness Control Console listening on http://{bound_host}:{bound_port}\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        sys.stderr.write("Harness Control Console stopped.\n")
    finally:
        server.server_close()
