"""Readable descriptions of uncaught browser-side errors for the page guard.

Playwright's ``pageerror`` hands over an ``Error`` whose ``str()`` is only the
message. WebKit reports some exceptions with an empty message (a non-Error
value thrown or rejected, or a cross-origin script error that the browser
sanitises), which left failures reading just ``pageerror:``. This module turns
the event into ``name: message`` plus the top of the stack, and installs a
small in-page listener that records what ``window.onerror`` and
``unhandledrejection`` saw (source URL, line, value type) in ``window[BUFFER]``,
so an empty error still says where it came from. The guard reads that buffer
only after a page error, never through a console listener: forwarding every
console line of the chatty E2E build made WebKit runs several times slower.
"""
from __future__ import annotations

from typing import Any

# Window property holding what CAPTURE_SCRIPT recorded (at most BUFFER_LIMIT entries).
BUFFER = "__sitepulseUncaught"
BUFFER_LIMIT = 20
# Prefix of the console.error line each entry also gets, so a trace shows it in order.
CAPTURE_PREFIX = "[sitepulse-e2e:uncaught]"

STACK_LINES = 6

# Runs before any page script. It records the event and leaves default handling
# alone, so Playwright still raises its own pageerror.
CAPTURE_SCRIPT = """
(() => {
  const prefix = %r;
  const buffer = window[%r] = [];
  const record = (text) => {
    if (buffer.length < %d) buffer.push(text);
    console.error(prefix + ' ' + text);
  };
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
    record('error at ' + where + ' message=' + JSON.stringify(event.message || '')
      + ' value=' + describe(event.error));
  }, true);
  window.addEventListener('unhandledrejection', (event) => {
    record('unhandledrejection value=' + describe(event.reason));
  });
})();
""" % (CAPTURE_PREFIX, BUFFER, BUFFER_LIMIT)


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


def uncaught_details(page: Any) -> list[str]:
    """What CAPTURE_SCRIPT recorded on `page`; empty when the page is gone or unreadable.

    Call it only after a page error: the page answered the driver then, so the read is short.
    """
    try:
        if page.is_closed():
            return []
        entries = page.evaluate(f"() => window[{BUFFER!r}] || []")
    except Exception:  # a navigated or broken page must not hide the original failure
        return []
    return [str(entry) for entry in entries or []][:BUFFER_LIMIT]
