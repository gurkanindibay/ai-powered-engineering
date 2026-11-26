#!/usr/bin/env python3
"""Give every working agent a readable name, so people can tell agents apart.

The roster (config/agent-names.json, committed) gives each model family its own
five or more historical names; no name is shared between families, so a name
always identifies the model. An agent takes its family's first free name (a
number is added only when all are busy, e.g. "Alparslan 2"). A model with no
family is refused.

Who holds which name right now is local state, shared by all worktrees of this
clone: <main checkout>/.agents/local/agent-names.json. That directory ignores
itself, so the file stays out of git on every branch (override with
$AGENT_NAMES_STATE). `issue_claim.py claim` reserves automatically and adds the
`agent:<name>` label; use `reserve` for work that has no issue (reviews, etc.).

Usage:
    python3 scripts/agent_names.py reserve --harness claude --session <id> --model claude-sonnet-5-5
    python3 scripts/agent_names.py list [--json]        # who is who, on which issue
    python3 scripts/agent_names.py release --harness claude --session <id>
    python3 scripts/agent_names.py release --name "Alparslan 2"
    python3 scripts/agent_names.py roster [--json]      # model -> name bindings

A reservation with no issue expires after 3 days without use, one with issues
after 14 days.

Exit codes: 0 ok, 1 nothing to release, 2 usage or file error.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Iterator

ROSTER_PATH = Path(__file__).resolve().parents[1] / "config" / "agent-names.json"
STATE_RELATIVE = Path(".agents") / "local" / "agent-names.json"
LABEL_PREFIX = "agent:"
IDLE_TTL = timedelta(days=3)
ISSUE_TTL = timedelta(days=14)
LOCK_TIMEOUT_SECONDS = 10.0
TITLE_MAX = 80


class RosterError(Exception):
    """Usage or file failure (exit 2)."""


def load_roster(path: Path = ROSTER_PATH) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise RosterError(f"cannot read roster {path}: {exc}") from exc


def default_state_path(env: dict[str, str]) -> Path:
    if env.get("AGENT_NAMES_STATE"):
        return Path(env["AGENT_NAMES_STATE"])
    done = subprocess.run(
        ["git", "-C", str(ROSTER_PATH.parent), "rev-parse", "--path-format=absolute", "--git-common-dir"],
        capture_output=True, text=True, check=False)
    if done.returncode != 0:
        raise RosterError(f"cannot locate the main checkout: {done.stderr.strip()}")
    return Path(done.stdout.strip()).parent / STATE_RELATIVE


def normalize_model(model: str) -> str:
    return re.sub(r"[\s._/]+", "-", model.strip().lower())


def family_of(roster: dict, model: str) -> dict | None:
    wanted = normalize_model(model)
    return next((m for m in roster["models"] if re.search(m["pattern"], wanted)), None)


def require_family(roster: dict, model: str) -> dict:
    family = family_of(roster, model)
    if family is None:
        raise RosterError(f"no agent names for model '{model}': pass the exact model id, "
                          f"or add a family with five names to {ROSTER_PATH.name}")
    return family


def same_identity(roster: dict, left: str, right: str) -> bool:
    """Two spellings of one model ("sonnet", "claude-sonnet-5-5") share a name."""
    family = family_of(roster, left)
    return family is not None and family == family_of(roster, right)


def pick_name(roster: dict, model: str, taken: set[str]) -> str:
    """The model family's first free name; numbered only once all are busy."""
    names = require_family(roster, model)["names"]
    number = 1
    while True:
        for candidate in names:
            name = candidate if number == 1 else f"{candidate} {number}"
            if name not in taken:
                return name
        number += 1


@contextlib.contextmanager
def locked(path: Path) -> Iterator[None]:
    """flock: the kernel drops it if the holder dies, so there is no stale lock to break."""
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.parent.name == STATE_RELATIVE.parent.name:
        # Ignores itself, so it works on branches without our root .gitignore line.
        ignore = path.parent / ".gitignore"
        if not ignore.exists():
            ignore.write_text("*\n", encoding="utf-8")
    deadline = time.monotonic() + LOCK_TIMEOUT_SECONDS
    with open(path.with_name(path.name + ".lock"), "a", encoding="utf-8") as lock:
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() > deadline:
                    raise RosterError(f"timed out waiting for {lock.name}")
                time.sleep(0.05)
        yield  # closing the file releases the lock


def read_state(path: Path) -> list[dict]:
    if not path.exists():
        return []
    try:
        return json.loads(path.read_text(encoding="utf-8"))["reservations"]
    except (OSError, ValueError, KeyError) as exc:
        # Never overwrite a file we cannot read: it holds other agents' names.
        raise RosterError(f"cannot read {path}: {exc}; fix or delete it") from exc


def write_state(path: Path, reservations: list[dict]) -> None:
    temp = path.with_name(path.name + ".tmp")
    temp.write_text(json.dumps({"reservations": reservations}, ensure_ascii=False, indent=2) + "\n",
                    encoding="utf-8")
    os.replace(temp, path)


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def alive(entry: dict, now: datetime) -> bool:
    ttl = ISSUE_TTL if entry["issues"] else IDLE_TTL
    return now - datetime.fromisoformat(entry["updated_at"]) < ttl


def reserve(path: Path, harness: str, session: str, model: str, issue: int | None = None,
            taken_elsewhere: set[str] | None = None, roster: dict | None = None,
            now: datetime | None = None) -> dict:
    """Return this agent's reservation, creating it on first use.

    `taken_elsewhere` holds names seen on GitHub that other sessions use (agents
    on other machines do not share the local file).
    """
    roster = roster or load_roster()
    require_family(roster, model)
    now = now or now_utc()
    with locked(path):
        entries = [e for e in read_state(path) if alive(e, now)]
        own = [e for e in entries if (e["harness"], e["session"]) == (harness, session)]
        mine = next((e for e in own if same_identity(roster, e["model"], model)), None)
        if mine is None:
            taken = {e["name"] for e in entries} | (taken_elsewhere or set())
            mine = {"name": pick_name(roster, model, taken), "harness": harness, "session": session,
                    "model": normalize_model(model), "issues": [], "reserved_at": now.isoformat(timespec="seconds")}
            entries.append(mine)
        mine["model"] = normalize_model(model)
        if issue is not None:
            # The model changed mid-task: the issue moves to the new name.
            for other in own:
                if other is not mine and issue in other["issues"]:
                    other["issues"].remove(issue)
                    if not other["issues"]:
                        entries.remove(other)
            if issue not in mine["issues"]:
                mine["issues"].append(issue)
        mine["updated_at"] = now.isoformat(timespec="seconds")
        write_state(path, entries)
    return dict(mine)


def release(path: Path, harness: str | None = None, session: str | None = None,
            name: str | None = None, issue: int | None = None) -> list[str]:
    """Free names. With `issue`, only that issue's holders are touched, and a
    name is freed once it has no issue left. Returns the freed names."""
    freed: list[str] = []
    with locked(path):
        kept = []
        for entry in read_state(path):
            match = entry["name"] == name if name else (entry["harness"], entry["session"]) == (harness, session)
            if match and issue is not None:
                match = issue in entry["issues"]
                if match:
                    entry["issues"].remove(issue)
                    match = not entry["issues"]
            if match:
                freed.append(entry["name"])
            else:
                kept.append(entry)
        write_state(path, kept)
    return freed


def label_for(name: str) -> str:
    return f"{LABEL_PREFIX}{name}"


def session_title(name: str, issue: int | None = None, summary: str = "") -> str:
    parts = [f"[{name}]"]
    if issue is not None:
        parts.append(f"#{issue}")
    if summary:
        parts.append(summary.strip())
    title = " ".join(parts)
    return title if len(title) <= TITLE_MAX else title[: TITLE_MAX - 1].rstrip() + "…"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("action", choices=["reserve", "list", "release", "roster"])
    parser.add_argument("--harness", help="harness name, e.g. claude, codex, antigravity")
    parser.add_argument("--session", help="harness session id (default: env or generated)")
    parser.add_argument("--model", help="model id, e.g. claude-sonnet-5-5 (default: $AGENT_MODEL)")
    parser.add_argument("--name", help="release by agent name")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    return parser


def main(argv: list[str] | None = None, env: dict[str, str] | None = None) -> int:
    from issue_claim import ClaimError, resolve_session, slug  # same ids as claim labels

    args = build_parser().parse_args(argv)
    env = dict(os.environ) if env is None else env
    try:
        if args.action == "roster":
            roster = load_roster()
            lines = [f"{m['model']:<26} {', '.join(m['names'])}" for m in roster["models"]]
            print(json.dumps(roster, ensure_ascii=False) if args.json else "\n".join(lines))
            return 0
        path = default_state_path(env)
        if args.action == "list":
            entries = [e for e in read_state(path) if alive(e, now_utc())]
            lines = [f"{e['name']:<22} {e['model']:<22} {e['harness']}/{e['session']}  "
                     f"{' '.join(f'#{i}' for i in e['issues']) or '-'}" for e in entries]
            print(json.dumps(entries, ensure_ascii=False) if args.json else
                  "\n".join(lines) or "no agent names reserved")
            return 0
        if args.action == "release" and args.name:
            freed = release(path, name=args.name)
        else:
            if not args.harness:
                raise RosterError("--harness is required")
            harness = slug(args.harness)
            session = resolve_session(harness, args.session, env)
            if args.action == "reserve":
                model = args.model or env.get("AGENT_MODEL")
                if not model:
                    raise RosterError("--model (or $AGENT_MODEL) is required")
                entry = reserve(path, harness, session, model)
                title = session_title(entry["name"])
                print(json.dumps({**entry, "title_prefix": title}, ensure_ascii=False) if args.json else
                      f"you are {entry['name']} (session id: {session})\n"
                      f"start your session title or summary with: {title}")
                return 0
            freed = release(path, harness, session)
        print(json.dumps({"freed": freed}, ensure_ascii=False) if args.json else
              f"freed: {', '.join(freed) or 'nothing'}")
        return 0 if freed else 1
    except (RosterError, ClaimError) as exc:
        print(json.dumps({"ok": False, "error": str(exc)}) if args.json else f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
