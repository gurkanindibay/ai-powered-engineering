"""Playwright helpers for the SitePulse Flutter web client (E2E build).

The app must be built with `--dart-define=E2E=true`: that turns on the
semantics tree and renders every `testId(...)` widget as a DOM node carrying
`flt-semantics-identifier="<id>"`.
"""
from __future__ import annotations

from playwright.sync_api import Locator, Page

ID_ATTR = "flt-semantics-identifier"


def by_id(page: Page, test_id: str) -> Locator:
    """Locator for the widget tagged with testId(test_id)."""
    return page.locator(f'[{ID_ATTR}="{test_id}"]')


def by_id_prefix(page: Page, prefix: str) -> Locator:
    """Locator for dynamic ids such as btn_edit_site_<id>."""
    return page.locator(f'[{ID_ATTR}^="{prefix}"]')


def wait_for_app(page: Page, timeout_ms: int = 30_000) -> None:
    """Wait until Flutter has rendered its first frame with semantics on."""
    page.wait_for_selector("flt-semantics-host, flt-semantics", state="attached", timeout=timeout_ms)


def fill(page: Page, test_id: str, value: str) -> None:
    """Replace the text of a TextField tagged with test_id."""
    field = by_id(page, test_id)
    target = field.locator("input, textarea").first
    if target.count() == 0:
        target = field
    target.click()
    target.press("Control+a")
    target.press("Delete")
    target.type(value)


def visible_ids(page: Page) -> list[str]:
    """All automation ids currently in the DOM (for diagnostics)."""
    return page.eval_on_selector_all(
        f"[{ID_ATTR}]", f"els => els.map(e => e.getAttribute('{ID_ATTR}'))"
    )
