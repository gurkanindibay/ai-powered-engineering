#!/usr/bin/env python3
"""Claude Code hook that keeps tool results from flooding the context window.

Every tool result stays in the conversation and is re-sent on every later
model call, so one 200 KB dump is paid for again on every following step.
This hook stops the known-wasteful calls before they run and nudges the agent
when a result turns out large anyway.

PreToolUse (denied, with a cheaper alternative in the reason):
  * Bash `cat FILE...` (no pipe/redirect) whose files total more than
    --max-file-bytes.
  * Bash `ls -R` or an unfiltered `find` without a pipe.
  * Read of a file larger than --max-file-bytes without offset/limit.
  * Browser screenshots (built-in browser, Claude in Chrome, and items inside
    browser_batch) without `scale` <= --max-screenshot-scale.

Checkpoint gate (Phase 4, §4.6 Layer 1; harness-agnostic):
  At context >= --checkpoint-context-pct (default 80) or quota >=
  --checkpoint-quota-pct (default 85), new feature edits and wide reads are
  denied so the worker checkpoints instead of hitting the wall mid-edit. The
  percentages come from this session's lease (``.agents/local/sessions/``,
  matched by the hook's ``session_id``), then ``HARNESS_CONTEXT_PCT`` /
  ``HARNESS_QUOTA_PCT``, then the CLI flags. Bash is limited to a small
  checkpoint allowlist (git state/commit/push, ``handover.py capture``, claim
  and tracker status). ``TOKEN_GUARD_CHECKPOINT=off`` disables only this gate.

PostToolUse (non-blocking): adds a reminder when a Bash result exceeds
--max-output-chars.

Wiring: `.claude/settings.json` runs `python3 scripts/token_guard.py` for both
events. Set TOKEN_GUARD=off to disable for one session.

Usage:
    echo '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat big.log"}}' \\
        | python3 scripts/token_guard.py --json
    python3 scripts/token_guard.py --context-pct 84 --json < event.json
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
from typing import Any, Optional

MAX_FILE_BYTES = 50_000
MAX_OUTPUT_CHARS = 30_000
MAX_SCREENSHOT_SCALE = 0.5
CHECKPOINT_CONTEXT_PCT = 80
CHECKPOINT_QUOTA_PCT = 85

SHELL_CONTROL = re.compile(r"[|;&<>`]|\$\(")
SCREENSHOT_TOOLS = ("mcp__Claude_Browser__computer", "mcp__claude-in-chrome__computer")
BATCH_TOOLS = ("mcp__Claude_Browser__browser_batch", "mcp__claude-in-chrome__browser_batch")
EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch"}
GIT_CHECKPOINT = {"status", "diff", "log", "show", "rev-parse", "branch", "add", "commit", "push"}
CHECKPOINT_SCRIPTS = {
    "handover.py": {"capture", "validate", "render"},
    "harness_coordinator.py": {"heartbeat", "status", "handover"},
    "issue_claim.py": {"status", "accept"},
    "token_tracker.py": {"health", "budget-check", "record"},
}


def _resolve(path: str, cwd: str) -> Path:
    candidate = Path(path).expanduser()
    return candidate if candidate.is_absolute() else Path(cwd) / candidate


def _file_size(path: Path) -> int:
    try:
        return path.stat().st_size if path.is_file() else 0
    except OSError:
        return 0


def check_bash(command: str, cwd: str, max_file_bytes: int) -> Optional[str]:
    """Returns a denial reason for a wasteful standalone Bash command, else None."""
    if SHELL_CONTROL.search(command):
        return None  # Piped, chained or redirected: the author already shaped the output.
    try:
        argv = shlex.split(command)
    except ValueError:
        return None
    if not argv:
        return None
    program, args = Path(argv[0]).name, argv[1:]
    if program == "cat":
        files = [a for a in args if not a.startswith("-")]
        total = sum(_file_size(_resolve(f, cwd)) for f in files)
        if total > max_file_bytes:
            return (f"`cat` would put {total:,} bytes into context. Locate first (`rg -n PATTERN FILE | head -30`, "
                    "`graphify query`), then read a range with `sed -n 'START,ENDp' FILE` or Read with offset/limit.")
    if program == "ls" and any(re.fullmatch(r"-[A-Za-z]*R[A-Za-z]*", a) or a == "--recursive" for a in args):
        return "Recursive `ls` floods context. Use `rg --files DIR | head -50`, `find DIR -maxdepth 2 -name PATTERN`, or `graphify query`."
    if program == "find":
        filters = {"-name", "-iname", "-path", "-ipath", "-regex", "-maxdepth", "-newer", "-mmin", "-mtime", "-size"}
        if not filters.intersection(args):
            return "Unfiltered `find` lists every file. Add `-maxdepth N` or `-name PATTERN`, or pipe through `| head -50`."
    return None


def check_read(tool_input: dict, cwd: str, max_file_bytes: int) -> Optional[str]:
    if tool_input.get("offset") is not None or tool_input.get("limit") is not None:
        return None
    path = tool_input.get("file_path")
    if not isinstance(path, str) or Path(path).suffix.lower() in {".png", ".jpg", ".jpeg", ".gif", ".webp", ".pdf", ".ipynb"}:
        return None
    size = _file_size(_resolve(path, cwd))
    if size > max_file_bytes:
        return (f"{path} is {size:,} bytes. Find the relevant lines first (`grep -n PATTERN FILE | head -30`), "
                "then Read with offset/limit for just that range.")
    return None


def _screenshot_reason(action_input: dict, max_scale: float) -> Optional[str]:
    if action_input.get("action") != "screenshot":
        return None
    scale = action_input.get("scale")
    if isinstance(scale, (int, float)) and not isinstance(scale, bool) and scale <= max_scale:
        return None
    return (f"Full-size screenshots cost 100K+ characters and stay in context. Prefer get_page_text/read_page/find "
            f"to verify text and structure; if the visual layout matters, retry with \"scale\": {max_scale} or less.")


def check_browser(tool_name: str, tool_input: dict, max_scale: float) -> Optional[str]:
    if tool_name in SCREENSHOT_TOOLS:
        return _screenshot_reason(tool_input, max_scale)
    if tool_name in BATCH_TOOLS:
        for item in tool_input.get("actions") or []:
            if isinstance(item, dict) and str(item.get("name", "")).endswith("computer"):
                reason = _screenshot_reason(item.get("input") or {}, max_scale)
                if reason:
                    return "A browser_batch item takes a screenshot. " + reason
    return None


# ------------------------------------------------------------ checkpoint gate


def _decimal(value: Any):
    from decimal import Decimal, InvalidOperation

    if value is None or (isinstance(value, str) and not value.strip()):
        return None
    try:
        parsed = Decimal(str(value))
    except (InvalidOperation, ValueError):
        return None
    return parsed if parsed.is_finite() and parsed >= 0 else None


_SESSIONS_DIRS: dict[tuple[str, str | None], Path] = {}


def sessions_dir(cwd: str) -> Path:
    """The main checkout's lease directory, shared by every worktree (cached per process)."""
    override = os.environ.get("HARNESS_SESSIONS_DIR")
    key = (os.path.abspath(cwd), override)
    if key in _SESSIONS_DIRS:
        return _SESSIONS_DIRS[key]
    if override:
        directory = Path(override)
    else:
        done = subprocess.run(["git", "-C", cwd, "rev-parse", "--path-format=absolute",
                               "--git-common-dir"], capture_output=True, text=True, check=False)
        if done.returncode == 0 and done.stdout.strip():
            common = Path(done.stdout.strip())
            directory = (common.parent if common.name == ".git" else common) / ".agents" / "local" / "sessions"
        else:
            directory = Path(cwd) / ".agents" / "local" / "sessions"
    _SESSIONS_DIRS[key] = directory
    return directory


def lease_percentages(cwd: str, session: str | None):
    """(context_pct, quota_pct) recorded by the newest lease for this session."""
    if not session:
        return None, None
    directory = sessions_dir(cwd)
    if not directory.is_dir():
        return None, None
    context, quota, updated = None, None, ""
    for path in directory.glob("*.json"):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(data, dict) or str(data.get("session")) != str(session):
            continue
        if str(data.get("updated_at", "")) >= updated:
            updated = str(data.get("updated_at", ""))
            context, quota = _decimal(data.get("context_pct")), _decimal(data.get("quota_pct"))
    return context, quota


def _checkpoint_bash(command: str) -> bool:
    """True when the command only reads state or checkpoints the work."""
    if SHELL_CONTROL.search(command):
        return False  # chained/redirected commands cannot be qualified safely
    try:
        argv = shlex.split(command)
    except ValueError:
        return False
    while argv and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", argv[0]):
        argv.pop(0)
    if not argv:
        return False
    program = Path(argv[0]).name
    rest = argv[1:]
    if program == "git":
        sub = next((part for part in rest if not part.startswith("-")), "")
        if sub not in GIT_CHECKPOINT:
            return False
        if sub == "branch" and any(part in {"-d", "-D", "--delete"} or part.startswith(("-D", "-d"))
                                   for part in rest):
            return False  # never let the gate delete or rewrite branches
        if sub == "push" and any(part.startswith(("--force", "-f", "+")) for part in rest):
            return False  # force-push (including a + refspec) is not checkpointing
        return True
    if program in ("python", "python3", "py"):
        for index, part in enumerate(rest):
            script = Path(part).name
            if script in CHECKPOINT_SCRIPTS:
                sub = next((value for value in rest[index + 1:] if not value.startswith("-")), "")
                return sub in CHECKPOINT_SCRIPTS[script]
        return False
    if program in CHECKPOINT_SCRIPTS:
        sub = next((part for part in rest if not part.startswith("-")), "")
        return sub in CHECKPOINT_SCRIPTS[program]
    return False


def _wide_read(tool_input: dict) -> bool:
    if tool_input.get("offset") is not None or tool_input.get("limit") is not None:
        return False
    path = str(tool_input.get("file_path", ""))
    normalised = "/" + path.replace("\\", "/").lstrip("/")
    if "/.agents/local/handovers/" in normalised or Path(path).suffix.lower() in {".patch", ".diff"}:
        return False
    return True


def checkpoint_reason(tool_name: str, tool_input: dict,
                      context_pct: Any = None, quota_pct: Any = None,
                      context_gate: float = CHECKPOINT_CONTEXT_PCT,
                      quota_gate: float = CHECKPOINT_QUOTA_PCT) -> Optional[str]:
    """Deny new edits/wide reads once context or quota is near the wall."""
    context, quota = _decimal(context_pct), _decimal(quota_pct)
    triggered = []
    if context is not None and context >= _decimal(context_gate):
        triggered.append(f"context {context}% (gate {context_gate}%)")
    if quota is not None and quota >= _decimal(quota_gate):
        triggered.append(f"quota {quota}% (gate {quota_gate}%)")
    if not triggered:
        return None
    if tool_name in EDIT_TOOLS:
        action = "edit"
    elif tool_name == "Read" and _wide_read(tool_input):
        action = "wide read"
    elif tool_name == "Bash" and not _checkpoint_bash(str(tool_input.get("command", ""))):
        action = "command"
    else:
        return None
    return (f"{action} blocked: {' and '.join(triggered)}. Checkpoint now: "
            "`python3 scripts/handover.py capture --issue <n> --reason context_ceiling ...` and "
            "`python3 scripts/harness_coordinator.py handover --issue <n> --envelope <.agents/local/handovers/...json>`; "
            "git status/diff/commit/push and the handover, claim and tracker tools remain allowed.")


def evaluate(event: dict, max_file_bytes: int = MAX_FILE_BYTES, max_output_chars: int = MAX_OUTPUT_CHARS,
             max_screenshot_scale: float = MAX_SCREENSHOT_SCALE, *, checkpoint: bool = True,
             context_pct: Any = None, quota_pct: Any = None,
             context_gate: float = CHECKPOINT_CONTEXT_PCT,
             quota_gate: float = CHECKPOINT_QUOTA_PCT) -> dict:
    """Returns the hook response for one event ({} when the call is fine)."""
    hook = event.get("hook_event_name")
    tool_name = event.get("tool_name", "")
    tool_input = event.get("tool_input") or {}
    cwd = event.get("cwd") or os.getcwd()

    if hook == "PreToolUse":
        reason = None
        if tool_name == "Bash":
            reason = check_bash(str(tool_input.get("command", "")), cwd, max_file_bytes)
        elif tool_name == "Read":
            reason = check_read(tool_input, cwd, max_file_bytes)
        else:
            reason = check_browser(tool_name, tool_input, max_screenshot_scale)
        if reason is None and checkpoint and os.environ.get("TOKEN_GUARD_CHECKPOINT", "").lower() not in {"off", "0", "false"}:
            lease_context, lease_quota = lease_percentages(cwd, event.get("session_id"))
            context = context_pct if context_pct is not None else (
                lease_context if lease_context is not None else os.environ.get("HARNESS_CONTEXT_PCT"))
            quota = quota_pct if quota_pct is not None else (
                lease_quota if lease_quota is not None else os.environ.get("HARNESS_QUOTA_PCT"))
            reason = checkpoint_reason(tool_name, tool_input, context, quota, context_gate, quota_gate)
        if reason:
            return {"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                           "permissionDecisionReason": f"[token_guard] {reason}"}}
    elif hook == "PostToolUse" and tool_name == "Bash":
        size = len(json.dumps(event.get("tool_response", "")))
        if size > max_output_chars:
            return {"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": (
                f"[token_guard] That command returned ~{size:,} characters, which is now re-sent on every later step. "
                "Next time filter it (`| tail -40`, `| grep -E 'FAIL|error' | head -30`, `--summary`/`--json` modes).")}}
    return {}


def main(argv: Optional[list] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--json", action="store_true", help="Always print a JSON decision, including {} for allowed calls")
    parser.add_argument("--max-file-bytes", type=int, default=MAX_FILE_BYTES)
    parser.add_argument("--max-output-chars", type=int, default=MAX_OUTPUT_CHARS)
    parser.add_argument("--max-screenshot-scale", type=float, default=MAX_SCREENSHOT_SCALE)
    parser.add_argument("--no-checkpoint", action="store_true", help="Disable the context/quota checkpoint gate")
    parser.add_argument("--context-pct", help="Context used, 0-100 (default: session lease, then $HARNESS_CONTEXT_PCT)")
    parser.add_argument("--quota-pct", help="Quota used, 0-100 (default: session lease, then $HARNESS_QUOTA_PCT)")
    parser.add_argument("--checkpoint-context-pct", type=float, default=CHECKPOINT_CONTEXT_PCT)
    parser.add_argument("--checkpoint-quota-pct", type=float, default=CHECKPOINT_QUOTA_PCT)
    args = parser.parse_args(argv)

    if os.environ.get("TOKEN_GUARD", "").lower() in {"off", "0", "false"}:
        return 0
    try:
        event = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0  # Never break the session because of a malformed event.
    if not isinstance(event, dict):
        return 0
    decision = evaluate(event, args.max_file_bytes, args.max_output_chars, args.max_screenshot_scale,
                        checkpoint=not args.no_checkpoint, context_pct=args.context_pct,
                        quota_pct=args.quota_pct, context_gate=args.checkpoint_context_pct,
                        quota_gate=args.checkpoint_quota_pct)
    if decision or args.json:
        print(json.dumps(decision))
    return 0


if __name__ == "__main__":
    sys.exit(main())
