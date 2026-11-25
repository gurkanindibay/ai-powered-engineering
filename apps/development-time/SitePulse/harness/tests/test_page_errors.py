"""Self-tests for the e2e page guard's error descriptions (e2e/support/page_errors.py)."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path
from types import SimpleNamespace

E2E = Path(__file__).resolve().parents[2] / "e2e"
sys.path.insert(0, str(E2E))

from support.page_errors import (  # noqa: E402
    BUFFER,
    BUFFER_LIMIT,
    CAPTURE_PREFIX,
    CAPTURE_SCRIPT,
    describe_page_error,
    uncaught_details,
)


class DescribePageErrorTests(unittest.TestCase):
    def test_name_message_and_stack_are_kept(self) -> None:
        exc = SimpleNamespace(
            name="TypeError",
            message="x is undefined",
            stack="TypeError: x is undefined\n    at f (main.dart.js:10:5)\n    at g (main.dart.js:20:1)",
        )
        text = describe_page_error(exc)
        self.assertEqual(
            text,
            "pageerror: TypeError: x is undefined\n    at f (main.dart.js:10:5)\n    at g (main.dart.js:20:1)",
        )

    def test_webkit_stack_lines_get_an_at_prefix(self) -> None:
        exc = SimpleNamespace(name="Error", message="boom", stack="f@http://localhost:9190/main.dart.js:1:2")
        self.assertIn("    at f@http://localhost:9190/main.dart.js:1:2", describe_page_error(exc))

    def test_empty_error_says_it_is_empty(self) -> None:
        text = describe_page_error(SimpleNamespace(name="", message="", stack=""))
        self.assertTrue(text.startswith("pageerror: <empty message"))
        self.assertNotEqual(text.strip(), "pageerror:")

    def test_plain_value_falls_back_to_str(self) -> None:
        self.assertEqual(describe_page_error("boom"), "pageerror: boom")

    def test_stack_is_capped(self) -> None:
        stack = "\n".join(f"at f{i} (a.js:{i}:1)" for i in range(40))
        lines = describe_page_error(SimpleNamespace(name="Error", message="m", stack=stack)).splitlines()
        self.assertEqual(len(lines), 7)


class FakePage:
    def __init__(self, entries=None, closed: bool = False, fails: bool = False) -> None:
        self.entries, self.closed, self.fails = entries, closed, fails
        self.expressions: list[str] = []

    def is_closed(self) -> bool:
        return self.closed

    def evaluate(self, expression: str):
        self.expressions.append(expression)
        if self.fails:
            raise RuntimeError("Execution context was destroyed")
        return self.entries


class UncaughtDetailsTests(unittest.TestCase):
    def test_reads_the_page_buffer(self) -> None:
        page = FakePage(["unhandledrejection value=undefined"])
        self.assertEqual(uncaught_details(page), ["unhandledrejection value=undefined"])
        self.assertIn(BUFFER, page.expressions[0])

    def test_closed_or_broken_page_gives_nothing(self) -> None:
        self.assertEqual(uncaught_details(FakePage(closed=True)), [])
        self.assertEqual(uncaught_details(FakePage(fails=True)), [])
        self.assertEqual(uncaught_details(FakePage(None)), [])

    def test_buffer_is_capped(self) -> None:
        self.assertEqual(len(uncaught_details(FakePage([str(i) for i in range(99)]))), BUFFER_LIMIT)

    def test_script_embeds_prefix_buffer_and_limit(self) -> None:
        self.assertIn(repr(CAPTURE_PREFIX), CAPTURE_SCRIPT)
        self.assertIn(repr(BUFFER), CAPTURE_SCRIPT)
        self.assertIn(f"buffer.length < {BUFFER_LIMIT}", CAPTURE_SCRIPT)
        self.assertIn("unhandledrejection", CAPTURE_SCRIPT)


if __name__ == "__main__":
    unittest.main()
