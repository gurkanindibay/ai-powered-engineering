"""Readable descriptions of uncaught browser-side errors for the page guard.

Playwright's ``pageerror`` hands over an ``Error`` whose ``str()`` is only the
message. WebKit reports some exceptions with an empty message (a non-Error
value thrown or rejected, or a cross-origin script error that the browser
sanitises), which left failures reading just ``pageerror:``. This module turns
the event into ``name: message`` plus the top of the stack, and installs a
small in-page listener that records what ``window.onerror`` and
``unhandledrejection`` saw (source URL, line, value type), so an empty error
still says where it came from.
"""
from __future__ import annotations

from typing import Any, Iterable

# Console prefix used by CAPTURE_SCRIPT; the page guard collects these lines.
CAPTURE_PREFIX = "[sitepulse-e2e:uncaught]"

STACK_LINES = 6

# Runs before any page script. It records the event and leaves default handling
# alone, so Playwright still raises its own pageerror.
CAPTURE_SCRIPT = """
(() => {
  const prefix = %r;
  const describe = (value) => {
    if (value === undefined) return 'undefined';
    if (value === null) return 'null';
    const type = Object.prototype.toString.call(value);
    let text = '';
    try { text = String(value); } catch (_) { text = '<String() threw>'; }
    const name = value && value.name ? String(value.name) : '';
    const stack = value && value.stack ? String(value.stack).split('\\n').slice(0, 6).join(' | ') : '';
    return [type, name, text, stack].filter(Boolean).join(' ; ');
  };
  window.addEventListener('error', (event) => {
    if (!(event instanceof ErrorEvent)) return;  // resource load errors are not exceptions
    const where = (event.filename || '<no source>') + ':' + event.lineno + ':' + event.colno;
    console.error(prefix + ' error at ' + where + ' message=' + JSON.stringify(event.message || '')
      + ' value=' + describe(event.error));
  }, true);
  window.addEventListener('unhandledrejection', (event) => {
    console.error(prefix + ' unhandledrejection value=' + describe(event.reason));
  });
})();
""" % CAPTURE_PREFIX


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
                "thrown or rejected, or a sanitised cross-origin script error; see the uncaught "
                "lines below>")
    lines = [f"pageerror: {head}"]
    stack_lines = [line.strip() for line in stack.splitlines() if line.strip()]
    # Chromium repeats "Name: message" as the first stack line.
    if stack_lines and stack_lines[0] == head:
        stack_lines = stack_lines[1:]
    lines += [f"    at {line}" if not line.startswith("at ") else f"    {line}"
              for line in stack_lines[:STACK_LINES]]
    return "\n".join(lines)


def uncaught_details(console_lines: Iterable[str]) -> list[str]:
    """The CAPTURE_SCRIPT lines among the console messages, without the prefix."""
    return [line[len(CAPTURE_PREFIX):].strip() for line in console_lines
            if line.startswith(CAPTURE_PREFIX)]
