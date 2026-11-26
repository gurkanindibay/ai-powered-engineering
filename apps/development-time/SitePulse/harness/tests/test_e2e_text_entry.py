"""E2E `fill()` types only into a text field the Flutter app is listening to (#520)."""
from __future__ import annotations

import importlib.util
import sys
import types
import unittest
from pathlib import Path
from unittest import mock

HELPERS = Path(__file__).resolve().parents[2] / "e2e" / "support" / "flutter.py"


def load_helpers() -> types.ModuleType:
    """Import support/flutter.py without Playwright, which the harness tests do not install."""
    sync_api = types.ModuleType("playwright.sync_api")
    sync_api.BrowserContext = sync_api.Locator = sync_api.Page = object
    stubs = {"playwright": types.ModuleType("playwright"), "playwright.sync_api": sync_api}
    spec = importlib.util.spec_from_file_location("e2e_flutter_helpers", HELPERS)
    module = importlib.util.module_from_spec(spec)
    with mock.patch.dict(sys.modules, stubs):
        spec.loader.exec_module(module)
    return module


flutter = load_helpers()


class FakeClock:
    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now


class FakeField:
    """A DOM input that Flutter starts listening to `connects_after_ms` after a focus."""

    def __init__(self, clock: FakeClock, connects_after_ms: list[float | None]) -> None:
        self.clock = clock
        self.delays = connects_after_ms
        self.connected_at: float | None = None
        self.dom_value = ""
        self.app_value = ""  # what the Flutter controller holds
        self.focuses = self.blurs = 0
        self.focused = False
        self.first = self

    def wait_for(self, **_kwargs) -> None:
        pass

    def locator(self, _selector: str) -> "FakeField":
        return self

    def click(self) -> None:
        if self.focused:
            return
        self.focused = True
        delay = self.delays[min(self.focuses, len(self.delays) - 1)]
        self.focuses += 1
        self.connected_at = None if delay is None else self.clock.now + delay / 1000

    @property
    def connected(self) -> bool:
        return self.connected_at is not None and self.clock.now >= self.connected_at

    def evaluate(self, script: str, arg: str | None = None):
        if arg == flutter.CONNECTED_ATTR:
            return self.connected
        if "blur()" in script:
            self.focused, self.connected_at = False, None
            self.blurs += 1
            return None
        return self.dom_value

    def press(self, key: str) -> None:
        if key == "Delete":
            self.type("")

    def type(self, value: str) -> None:
        self.dom_value = value
        if self.connected:
            self.app_value = value


class FakePage:
    def __init__(self, clock: FakeClock) -> None:
        self.clock = clock

    def wait_for_timeout(self, ms: float) -> None:
        self.clock.now += ms / 1000


class FillTest(unittest.TestCase):
    def fill(self, connects_after_ms: list[float | None]) -> FakeField:
        clock = FakeClock()
        field = FakeField(clock, connects_after_ms)
        with mock.patch.object(flutter, "monotonic", clock), \
                mock.patch.object(flutter, "by_id", lambda _page, _id: field):
            flutter.fill(FakePage(clock), "block_form_house_type", "Flat")
        return field

    def test_typing_waits_until_the_app_listens_to_the_field(self) -> None:
        # Typed early, the DOM keeps "Flat" and reads back fine while the app holds nothing.
        field = self.fill([800])
        self.assertEqual(field.app_value, "Flat")
        self.assertEqual(field.focuses, 1)

    def test_a_field_that_never_connected_is_focused_again(self) -> None:
        field = self.fill([None, 100])
        self.assertEqual(field.app_value, "Flat")
        self.assertEqual((field.focuses, field.blurs), (2, 1))

    def test_a_field_that_never_connects_fails_without_typing(self) -> None:
        with self.assertRaisesRegex(AssertionError, "could not set 'block_form_house_type'"):
            self.fill([None])

    def test_the_tracker_marks_the_attribute_the_wait_reads(self) -> None:
        self.assertIn(f"toggleAttribute('{flutter.CONNECTED_ATTR}', connected)", flutter.TEXT_CONNECTION_JS)


if __name__ == "__main__":
    unittest.main()
