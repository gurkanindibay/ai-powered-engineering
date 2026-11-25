"""Readable descriptions of uncaught browser-side errors for the page guard.

Playwright's ``pageerror`` hands over an ``Error`` whose ``str()`` is only the
message. WebKit reports some errors with an empty message, or splits text such
as "Fetch API cannot load http://..." at its first colon into name and message,
which left failures reading just ``pageerror:``. ``describe_page_error`` keeps
the name, the message and the top of the stack, and labels an empty error as
such so it is not mistaken for a truncated log.
"""
from __future__ import annotations

from typing import Any

STACK_LINES = 6


def _attr(exc: Any, name: str) -> str:
    try:
        value = getattr(exc, name, "")
    except Exception:  # a broken proxy must not hide the original failure
        return ""
    return str(value or "").strip()


def describe_page_error(exc: Any) -> str:
    """One readable line (plus stack lines) for a Playwright ``pageerror`` value."""
    name = _attr(exc, "name")
    message = _attr(exc, "message") if hasattr(exc, "message") else str(exc or "").strip()
    stack = _attr(exc, "stack")
    head = f"{name}: {message}" if name and message else (message or name)
    if not head:
        head = ("<empty message: the browser gave no name or text; usually a non-Error value "
                "thrown or rejected, or a sanitised cross-origin script error; open the trace for "
                "the console around it>")
    lines = [f"pageerror: {head}"]
    stack_lines = [line.strip() for line in stack.splitlines() if line.strip()]
    # Chromium repeats "Name: message" as the first stack line.
    if stack_lines and stack_lines[0] == head:
        stack_lines = stack_lines[1:]
    lines += [f"    at {line}" if not line.startswith("at ") else f"    {line}"
              for line in stack_lines[:STACK_LINES]]
    return "\n".join(lines)
