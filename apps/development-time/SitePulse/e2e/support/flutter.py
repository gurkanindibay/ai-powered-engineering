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
    # Flutter syncs its editing state asynchronously; a select-all issued too early can miss
    # prefilled text. Verify the DOM value and retry instead of trusting one attempt.
    for _ in range(3):
        target.click()
        target.press("Control+a")
        target.press("Delete")
        if target.evaluate("e => e.value ?? ''") != "":
            continue
        target.type(value)
        if target.evaluate("e => e.value ?? ''") == value:
            return
    raise AssertionError(f"could not set {test_id!r} to {value!r} "
                         f"(field shows {target.evaluate('e => e.value ?? null')!r})")


def text_of(locator: Locator) -> str:
    """Text Flutter exposes for a tagged widget (its semantics label or text content)."""
    locator.first.wait_for(state="attached")
    # Some widgets (e.g. SelectableText, text fields) put the label on a child node or an <input>.
    return locator.first.evaluate("""e => {
        const own = (e.getAttribute('aria-label') || e.textContent || '').trim();
        if (own) return own;
        const parts = [...e.querySelectorAll('[aria-label], input, textarea')].map(
            c => (c.getAttribute('aria-label') || c.value || '').trim()).filter(Boolean);
        return parts.join(' ');
    }""")


def visible_ids(page: Page) -> list[str]:
    """All automation ids currently in the DOM (for diagnostics)."""
    return page.eval_on_selector_all(
        f"[{ID_ATTR}]", f"els => els.map(e => e.getAttribute('{ID_ATTR}'))"
    )
