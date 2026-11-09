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

PostToolUse (non-blocking): adds a reminder when a Bash result exceeds
--max-output-chars.

Wiring: `.claude/settings.json` runs `python3 scripts/token_guard.py` for both
events. Set TOKEN_GUARD=off to disable for one session.

Usage:
    echo '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat big.log"}}' \\
        | python3 scripts/token_guard.py --json
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import sys
from typing import Optional

MAX_FILE_BYTES = 50_000
MAX_OUTPUT_CHARS = 30_000
MAX_SCREENSHOT_SCALE = 0.5

SHELL_CONTROL = re.compile(r"[|;&<>`]|\$\(")
SCREENSHOT_TOOLS = ("mcp__Claude_Browser__computer", "mcp__claude-in-chrome__computer")
BATCH_TOOLS = ("mcp__Claude_Browser__browser_batch", "mcp__claude-in-chrome__browser_batch")


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


def evaluate(event: dict, max_file_bytes: int = MAX_FILE_BYTES, max_output_chars: int = MAX_OUTPUT_CHARS,
             max_screenshot_scale: float = MAX_SCREENSHOT_SCALE) -> dict:
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
    args = parser.parse_args(argv)

    if os.environ.get("TOKEN_GUARD", "").lower() in {"off", "0", "false"}:
        return 0
    try:
        event = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0  # Never break the session because of a malformed event.
    if not isinstance(event, dict):
        return 0
    decision = evaluate(event, args.max_file_bytes, args.max_output_chars, args.max_screenshot_scale)
    if decision or args.json:
        print(json.dumps(decision))
    return 0


if __name__ == "__main__":
    sys.exit(main())
