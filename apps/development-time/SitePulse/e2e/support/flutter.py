"""Playwright helpers for the SitePulse Flutter web client (E2E build).

The app must be built with `--dart-define=E2E=true`: that turns on the
semantics tree and renders every `testId(...)` widget as a DOM node carrying
`flt-semantics-identifier="<id>"`.
"""
from __future__ import annotations

from time import monotonic

from playwright.sync_api import BrowserContext, Locator, Page

ID_ATTR = "flt-semantics-identifier"
# How long a typed value must survive before the widget is trusted with it.
SETTLE_MS = 300
# How long Flutter may take to connect a focused text field before it is focused again.
CONNECT_MS = 3_000
# Set on an <input>/<textarea> while the app is listening to what is typed into it.
CONNECTED_ATTR = "data-e2e-text-connected"

# Flutter web adds the field's `input` listener only once the framework has processed the
# focus, and removes it when the field is disconnected. Nothing in the DOM says so, hence
# this wrapper around the listener registration. Text typed without that listener stays in
# the DOM input and never reaches the app, so reading the value back cannot detect it.
TEXT_CONNECTION_JS = """(() => {
    if (window.__e2eTextConnections) return;
    window.__e2eTextConnections = true;
    // A field stays connected while any `input` listener is left on it. A Set mirrors the
    // DOM, which ignores a repeated add and a removal of a listener it does not have.
    const attached = new WeakMap();
    for (const [method, adds] of [['addEventListener', true], ['removeEventListener', false]]) {
        const original = EventTarget.prototype[method];
        EventTarget.prototype[method] = function (type, listener, ...rest) {
            const result = original.call(this, type, listener, ...rest);
            if (type === 'input' && listener
                    && (this instanceof HTMLInputElement || this instanceof HTMLTextAreaElement)) {
                const listeners = attached.get(this) || new Set();
                attached.set(this, listeners);
                if (adds) listeners.add(listener);
                else listeners.delete(listener);
                this.toggleAttribute('%s', listeners.size > 0);
            }
            return result;
        };
    }
})();""" % CONNECTED_ATTR


def track_text_connections(context: BrowserContext) -> None:
    """Mark connected text fields in every page of `context`; call before the app loads."""
    context.add_init_script(TEXT_CONNECTION_JS)


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
    field.first.wait_for(state="attached")
    # Flutter web creates the DOM <input> only while the field has focus, and syncs its editing
    # state asynchronously; a select-all issued too early can miss prefilled text. So focus first,
    # use the input once it exists, and verify the value instead of trusting one attempt.
    for _ in range(3):
        field.first.click()
        target = field.locator("input, textarea").first
        try:
            target.wait_for(state="attached", timeout=3_000)
        except Exception:
            target = page.locator("input:focus, textarea:focus").first
        if not wait_text_connected(page, target):
            target.evaluate("e => e.blur()")  # so the next click focuses it again
            continue
        target.press("Control+a")
        target.press("Delete")
        if (target.evaluate("e => e.value ?? ''") or "") != "":
            continue
        target.type(value)
        if target.evaluate("e => e.value ?? ''") == value and _survives(page, target, value):
            return
    raise AssertionError(f"could not set {test_id!r} to {value!r}")


def wait_text_connected(page: Page, target: Locator) -> bool:
    """True once the app receives what is typed into `target`.

    Pages of a context without `track_text_connections` cannot tell and are trusted.
    """
    deadline = monotonic() + CONNECT_MS / 1000
    while True:
        if target.evaluate(
            "(e, attr) => !window.__e2eTextConnections || e.hasAttribute(attr)", CONNECTED_ATTR
        ):
            return True
        if monotonic() >= deadline:
            return False
        page.wait_for_timeout(50)


def _survives(page: Page, target: Locator, value: str) -> bool:
    """True when the app keeps the typed value instead of resetting the input to empty.

    Flutter web connects a focused text field to the framework asynchronously. Text
    typed before that connection is pushed back to the widget, whose controller is
    still empty, and the DOM input is cleared a frame later: the field looks filled
    for one call and is empty when the app validates the form (#502, the password on a
    freshly booted tab). Typing again after the connection exists sticks, so the
    caller retries while the value disappears.
    """
    if not value:
        return True
    deadline = monotonic() + SETTLE_MS / 1000
    while True:
        if (target.evaluate("e => e.value ?? ''") or "") == "":
            return False
        if monotonic() >= deadline:
            return True
        page.wait_for_timeout(100)


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


def input_value(page: Page, test_id: str) -> str:
    """Current text of the TextField tagged with test_id (the DOM input's value)."""
    field = by_id(page, test_id)
    field.first.wait_for(state="attached")
    target = field.locator("input, textarea").first
    return target.evaluate("e => e.value ?? ''") if target.count() else ""


def nav_tab_count(page: Page) -> int:
    """Number of navigation destinations (bottom bar or rail; each is tagged nav_<key>, see pages.Shell)."""
    return by_id_prefix(page, "nav_").count()
