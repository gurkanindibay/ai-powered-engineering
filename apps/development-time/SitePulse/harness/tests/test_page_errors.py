"""Self-tests for the e2e page guard's error descriptions (e2e/support/page_errors.py)."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path
from types import SimpleNamespace

E2E = Path(__file__).resolve().parents[2] / "e2e"
sys.path.insert(0, str(E2E))

from support.page_errors import (  # noqa: E402
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


class UncaughtDetailsTests(unittest.TestCase):
    def test_only_capture_lines_are_returned(self) -> None:
        lines = [
            "Failed to load resource: 401",
            f"{CAPTURE_PREFIX} unhandledrejection value=undefined",
        ]
        self.assertEqual(uncaught_details(lines), ["unhandledrejection value=undefined"])

    def test_script_embeds_the_prefix(self) -> None:
        self.assertIn(repr(CAPTURE_PREFIX), CAPTURE_SCRIPT)
        self.assertIn("unhandledrejection", CAPTURE_SCRIPT)


if __name__ == "__main__":
    unittest.main()
