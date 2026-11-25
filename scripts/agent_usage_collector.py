#!/usr/bin/env python3
"""Collect coding-agent token usage on this machine and publish it for the Agent Monitor app.

The Android app (apps/agent-monitor) reads GitHub directly for "which agent is
working on which issue" (the `claim:<harness>/<session>` labels of
scripts/issue_claim.py). Token usage and quota live on the machine the agents
run on, so this collector reads them here and writes one JSON snapshot that the
app downloads from a secret GitHub gist.

Sources (each one is optional; a missing source is reported, never invented):
    claude       ~/.claude/projects/**/*.jsonl   per-message `usage` of Claude Code
    codex        ~/.codex/sessions/**/*.jsonl    `token_count` events, incl. the
                                                 plan's rate-limit percentages
    copilot      GitHub billing API (via `gh`)   premium requests this month
    deepseek     https://api.deepseek.com/user/balance   ($DEEPSEEK_API_KEY)
    antigravity  ~/.config/agent-monitor/antigravity.json  (no public quota API;
                 a hand-kept or exported file in the same "windows" shape)

Usage:
    python3 scripts/agent_usage_collector.py --json                  # print snapshot
    python3 scripts/agent_usage_collector.py --output usage.json
    python3 scripts/agent_usage_collector.py --create-gist           # prints the gist id
    python3 scripts/agent_usage_collector.py --publish-gist <id> --watch 300

Limits: Claude Code transcripts carry token counts but not the plan's remaining
quota, so pass --claude-5h-limit / --claude-7d-limit (tokens) to get a
percentage. Codex sessions carry the real percentages. Amounts of money stay
decimal strings.

Exit codes: 0 ok, 2 usage or publish error.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any, Callable, Iterable, Iterator

SCHEMA_VERSION = 1
GIST_FILE = "agent-usage.json"
WINDOWS = (("5h", timedelta(hours=5)), ("24h", timedelta(hours=24)), ("7d", timedelta(days=7)))
RECENT_SESSIONS = 15
DEEPSEEK_BALANCE_URL = "https://api.deepseek.com/user/balance"

Runner = Callable[[list[str], str | None], str]


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def iso(value: datetime | None) -> str | None:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z") if value else None


def parse_ts(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def read_jsonl(path: Path) -> Iterator[dict[str, Any]]:
    try:
        with path.open(encoding="utf-8", errors="replace") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(row, dict):
                    yield row
    except OSError:
        return


def recent_files(root: Path, since: datetime) -> list[Path]:
    """*.jsonl files under root modified after `since` (bounded walk, no symlinks)."""
    if not root.is_dir():
        return []
    cutoff = since.timestamp()
    found = []
    for path in root.rglob("*.jsonl"):
        try:
            if path.is_file() and not path.is_symlink() and path.stat().st_mtime >= cutoff:
                found.append(path)
        except OSError:
            continue
    return found


@dataclass
class Session:
    session_id: str
    project: str = ""
    model: str = ""
    started_at: datetime | None = None
    last_activity: datetime | None = None
    tokens: int = 0

    def touch(self, ts: datetime | None) -> None:
        if ts is None:
            return
        if self.started_at is None or ts < self.started_at:
            self.started_at = ts
        if self.last_activity is None or ts > self.last_activity:
            self.last_activity = ts

    def to_json(self) -> dict[str, Any]:
        return {
            "session_id": self.session_id,
            "project": self.project,
            "model": self.model,
            "started_at": iso(self.started_at),
            "last_activity": iso(self.last_activity),
            "tokens": self.tokens,
        }


@dataclass
class Provider:
    id: str
    name: str
    status: str = "ok"  # ok | unavailable | error
    source: str = ""
    note: str = ""
    windows: list[dict[str, Any]] = field(default_factory=list)
    balance: list[dict[str, str]] = field(default_factory=list)
    sessions: list[Session] = field(default_factory=list)

    def to_json(self) -> dict[str, Any]:
        recent = sorted(self.sessions, key=lambda s: s.last_activity or datetime.min.replace(tzinfo=timezone.utc),
                        reverse=True)[:RECENT_SESSIONS]
        return {
            "id": self.id,
            "name": self.name,
            "status": self.status,
            "source": self.source,
            "note": self.note,
            "windows": self.windows,
            "balance": self.balance,
            "sessions": [s.to_json() for s in recent],
        }


def window(label: str, tokens: int | None = None, used_percent: float | None = None,
           limit_tokens: int | None = None, resets_at: datetime | None = None) -> dict[str, Any]:
    if used_percent is None and tokens is not None and limit_tokens:
        used_percent = round(100.0 * tokens / limit_tokens, 1)
    return {"label": label, "tokens": tokens, "limit_tokens": limit_tokens,
            "used_percent": used_percent, "resets_at": iso(resets_at)}


def project_name(cwd: Any) -> str:
    """Only the folder name: full paths stay on this machine."""
    return Path(cwd).name if isinstance(cwd, str) and cwd else ""


# --- Claude Code ------------------------------------------------------------------------------

def claude_usage_tokens(usage: dict[str, Any]) -> int:
    """Tokens that count toward the plan: input, output and cache writes (cache reads are cheap)."""
    total = 0
    for key in ("input_tokens", "output_tokens", "cache_creation_input_tokens"):
        value = usage.get(key)
        if isinstance(value, int) and value > 0:
            total += value
    return total


def collect_claude(home: Path, now: datetime, limit_5h: int | None, limit_7d: int | None) -> Provider:
    provider = Provider("claude", "Claude Code", source="~/.claude/projects")
    root = home / ".claude" / "projects"
    if not root.is_dir():
        provider.status, provider.note = "unavailable", "No Claude Code transcripts on this machine."
        return provider
    horizon = now - timedelta(days=7)
    seen: set[str] = set()
    sessions: dict[str, Session] = {}
    events: list[tuple[datetime, int]] = []
    for path in recent_files(root, horizon):
        for row in read_jsonl(path):
            if row.get("type") != "assistant":
                continue
            message = row.get("message") if isinstance(row.get("message"), dict) else {}
            usage = message.get("usage")
            ts = parse_ts(row.get("timestamp"))
            if not isinstance(usage, dict) or ts is None or ts < horizon:
                continue
            # Streaming writes the same message more than once; count it once.
            key = f"{message.get('id', '')}:{row.get('requestId', '')}"
            if key != ":" and key in seen:
                continue
            seen.add(key)
            tokens = claude_usage_tokens(usage)
            events.append((ts, tokens))
            sid = str(row.get("sessionId") or path.stem)
            session = sessions.setdefault(sid, Session(sid, project_name(row.get("cwd"))))
            session.model = str(message.get("model") or session.model)
            session.tokens += tokens
            session.touch(ts)
    limits = {"5h": limit_5h, "7d": limit_7d}
    for label, span in WINDOWS:
        used = sum(tokens for ts, tokens in events if ts >= now - span)
        provider.windows.append(window(label, used, limit_tokens=limits.get(label)))
    provider.sessions = list(sessions.values())
    if not limit_5h and not limit_7d:
        provider.note = "Token counts from transcripts; set --claude-5h-limit/--claude-7d-limit for a percentage."
    return provider


# --- Codex ------------------------------------------------------------------------------------

def codex_resets_at(limit: dict[str, Any], ts: datetime) -> datetime | None:
    if isinstance(limit.get("resets_at"), (int, float)):
        return datetime.fromtimestamp(limit["resets_at"], timezone.utc)
    parsed = parse_ts(limit.get("resets_at"))
    if parsed:
        return parsed
    seconds = limit.get("resets_in_seconds")
    return ts + timedelta(seconds=seconds) if isinstance(seconds, (int, float)) else None


def codex_window_label(limit: dict[str, Any], fallback: str) -> str:
    minutes = limit.get("window_minutes")
    if isinstance(minutes, int) and minutes > 0:
        return f"{minutes // 60}h" if minutes < 1440 else f"{minutes // 1440}d"
    return fallback


def collect_codex(home: Path, now: datetime) -> Provider:
    provider = Provider("codex", "Codex", source="~/.codex/sessions")
    root = home / ".codex" / "sessions"
    if not root.is_dir():
        provider.status, provider.note = "unavailable", "No Codex sessions on this machine."
        return provider
    horizon = now - timedelta(days=7)
    sessions: dict[str, Session] = {}
    events: list[tuple[datetime, int]] = []
    latest_limits: tuple[datetime, dict[str, Any]] | None = None
    for path in recent_files(root, horizon):
        session = Session(path.stem)
        for row in read_jsonl(path):
            payload = row.get("payload") if isinstance(row.get("payload"), dict) else {}
            ts = parse_ts(row.get("timestamp"))
            if row.get("type") == "session_meta":
                session.session_id = str(payload.get("id") or session.session_id)
                session.project = project_name(payload.get("cwd"))
            elif row.get("type") == "turn_context":
                session.model = str(payload.get("model") or session.model)
            if row.get("type") != "event_msg" or payload.get("type") != "token_count" or ts is None:
                continue
            session.touch(ts)
            info = payload.get("info") if isinstance(payload.get("info"), dict) else {}
            total = (info.get("total_token_usage") or {}).get("total_tokens")
            if isinstance(total, int):
                session.tokens = max(session.tokens, total)
            last = (info.get("last_token_usage") or {}).get("total_tokens")
            if isinstance(last, int) and ts >= horizon:
                events.append((ts, last))
            limits = payload.get("rate_limits")
            if isinstance(limits, dict) and (latest_limits is None or ts > latest_limits[0]):
                latest_limits = (ts, limits)
        if session.last_activity:
            sessions[session.session_id] = session
    if latest_limits:
        ts, limits = latest_limits
        for key in ("primary", "secondary"):
            limit = limits.get(key)
            if isinstance(limit, dict) and isinstance(limit.get("used_percent"), (int, float)):
                provider.windows.append(window(codex_window_label(limit, key),
                                               used_percent=float(limit["used_percent"]),
                                               resets_at=codex_resets_at(limit, ts)))
    for label, span in WINDOWS:
        if not any(w["label"] == label for w in provider.windows):
            provider.windows.append(window(label, sum(t for ts, t in events if ts >= now - span)))
    provider.sessions = list(sessions.values())
    if not latest_limits:
        provider.note = "No rate-limit event in recent sessions; showing token counts only."
    return provider


# --- GitHub Copilot ---------------------------------------------------------------------------

def gh(args: list[str], stdin: str | None = None) -> str:
    result = subprocess.run(["gh", *args], input=stdin, capture_output=True, text=True, timeout=60, check=False)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"gh {' '.join(args)} failed")
    return result.stdout


def collect_copilot(run: Runner, now: datetime, allowance: int) -> Provider:
    provider = Provider("copilot", "GitHub Copilot", source="GitHub billing API")
    try:
        user = run(["api", "user", "--jq", ".login"], None).strip()
        raw = run(["api", f"users/{user}/settings/billing/premium_request/usage"
                   f"?year={now.year}&month={now.month}"], None)
        data = json.loads(raw)
    except (RuntimeError, json.JSONDecodeError, OSError, subprocess.TimeoutExpired) as exc:
        provider.status = "unavailable"
        provider.note = f"Premium request usage not readable ({str(exc)[:120]}). Needs a token with the Plan: read permission."
        return provider
    used = Decimal(0)
    for item in data.get("usageItems", []) if isinstance(data, dict) else []:
        if "copilot" in str(item.get("product", "")).lower():
            try:
                used += Decimal(str(item.get("grossQuantity", 0)))
            except InvalidOperation:
                continue
    month_end = (now.replace(day=1) + timedelta(days=32)).replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    provider.windows.append({"label": "month", "tokens": None, "requests": str(used),
                             "limit_requests": allowance,
                             "used_percent": round(float(100 * used / allowance), 1) if allowance else None,
                             "resets_at": iso(month_end)})
    provider.note = "Premium requests, not tokens."
    return provider


# --- DeepSeek ---------------------------------------------------------------------------------

def fetch_deepseek(api_key: str) -> dict[str, Any]:
    request = urllib.request.Request(DEEPSEEK_BALANCE_URL, headers={
        "Authorization": f"Bearer {api_key}", "Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=30) as response:  # noqa: S310 - fixed https URL
        return json.loads(response.read().decode("utf-8"))


def collect_deepseek(api_key: str | None, fetch: Callable[[str], dict[str, Any]] = fetch_deepseek) -> Provider:
    provider = Provider("deepseek", "DeepSeek", source="api.deepseek.com/user/balance")
    if not api_key:
        provider.status, provider.note = "unavailable", "Set DEEPSEEK_API_KEY (or enter the key in the app)."
        return provider
    try:
        data = fetch(api_key)
    except (urllib.error.URLError, OSError, json.JSONDecodeError, ValueError) as exc:
        provider.status, provider.note = "error", f"Balance request failed: {str(exc)[:120]}"
        return provider
    for info in data.get("balance_infos", []):
        entry = {"currency": str(info.get("currency", ""))}
        for key in ("total_balance", "granted_balance", "topped_up_balance"):
            try:
                entry[key] = str(Decimal(str(info.get(key, "0"))))
            except InvalidOperation:
                entry[key] = "0"
        provider.balance.append(entry)
    if not data.get("is_available", True):
        provider.note = "DeepSeek reports the balance is not sufficient for API calls."
    return provider


# --- Antigravity ------------------------------------------------------------------------------

def collect_antigravity(path: Path) -> Provider:
    provider = Provider("antigravity", "Antigravity", source=str(path).replace(str(Path.home()), "~"))
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        provider.status = "unavailable"
        provider.note = "Antigravity has no public quota API; keep its numbers in this file to show them."
        return provider
    except (OSError, json.JSONDecodeError) as exc:
        provider.status, provider.note = "error", f"Unreadable file: {exc}"
        return provider
    provider.windows = [w for w in data.get("windows", []) if isinstance(w, dict) and w.get("label")]
    provider.note = str(data.get("note", "Manually maintained."))
    return provider


# --- Snapshot & publishing --------------------------------------------------------------------

def build_snapshot(args: argparse.Namespace, run: Runner = gh, home: Path | None = None,
                   now: datetime | None = None) -> dict[str, Any]:
    home = home or Path.home()
    now = now or utc_now()
    skip = set(args.skip or [])
    providers: list[Provider] = []
    if "claude" not in skip:
        providers.append(collect_claude(home, now, args.claude_5h_limit, args.claude_7d_limit))
    if "codex" not in skip:
        providers.append(collect_codex(home, now))
    if "copilot" not in skip:
        providers.append(collect_copilot(run, now, args.copilot_allowance))
    if "deepseek" not in skip:
        providers.append(collect_deepseek(os.environ.get("DEEPSEEK_API_KEY")))
    if "antigravity" not in skip:
        providers.append(collect_antigravity(Path(args.antigravity_file).expanduser()))
    return {"schema_version": SCHEMA_VERSION, "generated_at": iso(now), "machine": args.machine,
            "providers": [p.to_json() for p in providers]}


def gist_payload(snapshot: dict[str, Any], create: bool) -> str:
    body: dict[str, Any] = {"files": {GIST_FILE: {"content": json.dumps(snapshot, indent=2)}}}
    if create:
        body.update({"description": "Agent Monitor usage snapshot", "public": False})
    return json.dumps(body)


def publish(run: Runner, snapshot: dict[str, Any], gist_id: str | None) -> str:
    if gist_id:
        run(["api", "-X", "PATCH", f"gists/{gist_id}", "--input", "-"], gist_payload(snapshot, False))
        return gist_id
    out = run(["api", "-X", "POST", "gists", "--input", "-", "--jq", ".id"], gist_payload(snapshot, True))
    return out.strip()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    parser.add_argument("--json", action="store_true", help="print the snapshot as JSON")
    parser.add_argument("--output", help="also write the snapshot to this file")
    target = parser.add_mutually_exclusive_group()
    target.add_argument("--publish-gist", metavar="ID", help="update this secret gist with the snapshot")
    target.add_argument("--create-gist", action="store_true", help="create a secret gist and print its id")
    parser.add_argument("--watch", type=int, metavar="SECONDS", help="repeat every SECONDS (min 60)")
    parser.add_argument("--machine", default=os.environ.get("AGENT_MONITOR_MACHINE", "workstation"),
                        help="label for this machine in the app (default: workstation)")
    parser.add_argument("--claude-5h-limit", type=int, help="tokens your Claude plan allows per 5 hours")
    parser.add_argument("--claude-7d-limit", type=int, help="tokens your Claude plan allows per 7 days")
    parser.add_argument("--copilot-allowance", type=int, default=300,
                        help="premium requests included per month (default 300, Copilot Pro)")
    parser.add_argument("--antigravity-file", default="~/.config/agent-monitor/antigravity.json")
    parser.add_argument("--skip", action="append", choices=["claude", "codex", "copilot", "deepseek", "antigravity"],
                        help="leave a provider out (repeatable)")
    return parser


def summary_lines(snapshot: dict[str, Any]) -> Iterable[str]:
    for p in snapshot["providers"]:
        parts = [f"{w['label']}: " + (f"{w['used_percent']}%" if w.get("used_percent") is not None
                                      else f"{w.get('tokens') or 0} tokens") for w in p["windows"]]
        parts += [f"{b['total_balance']} {b['currency']}" for b in p["balance"]]
        yield f"{p['name']:<15} {p['status']:<12} {', '.join(parts) or p['note']}"


def main(argv: list[str] | None = None, run: Runner = gh) -> int:
    args = build_parser().parse_args(argv)
    if args.watch is not None and args.watch < 60:
        sys.stderr.write("--watch must be at least 60 seconds\n")
        return 2
    gist_id = args.publish_gist
    while True:
        snapshot = build_snapshot(args, run)
        if args.output:
            Path(args.output).write_text(json.dumps(snapshot, indent=2), encoding="utf-8")
        if args.create_gist or gist_id:
            try:
                gist_id = publish(run, snapshot, gist_id)
            except (RuntimeError, OSError, subprocess.TimeoutExpired) as exc:
                sys.stderr.write(f"publish failed: {exc}\n")
                if not args.watch:
                    return 2
            if args.create_gist:
                sys.stdout.write(f"gist id: {gist_id}  (enter it in the app's settings)\n")
                args.create_gist = False
        if args.json:
            sys.stdout.write(json.dumps(snapshot, indent=2) + "\n")
        else:
            sys.stdout.write("\n".join(summary_lines(snapshot)) + "\n")
        sys.stdout.flush()
        if not args.watch:
            return 0
        time.sleep(args.watch)


if __name__ == "__main__":
    sys.exit(main())
