"""Shared helpers for GUI journey tests: sign in to a journey site and read what a page shows."""
from __future__ import annotations

import os
import re
from contextlib import contextmanager
from decimal import Decimal
from pathlib import Path

from playwright.sync_api import Page
from playwright.sync_api import TimeoutError as PlaywrightTimeoutError

from pages import DuesManagement, ManagerCockpit, Shell
from support.flutter import by_id, text_of
from support.journey_attempts import JourneyManifest, site_in_state, teardown_with_evidence
from support.money import parse_try

E2E = Path(__file__).resolve().parents[1]


def page_lines(page: Page) -> list[str]:
    """Every label the Flutter semantics tree currently exposes, one visible line each, in document order."""
    raw = page.evaluate(
        """() => {
            const lines = [];
            for (const e of document.querySelectorAll('flt-semantics')) {
                const own = [...e.childNodes].filter(n => n.nodeType === 3).map(n => n.textContent).join('');
                const text = (e.getAttribute('aria-label') || own || '').trim();
                if (text) lines.push(text);
            }
            return lines;
        }"""
    )
    return [part.strip() for line in raw for part in line.split("\n") if part.strip()]


def page_lines_until(page: Page, pattern: re.Pattern[str], timeout_ms: int = 10_000) -> list[str]:
    """Page lines once one of them matches `pattern`, or the lines shown when time runs out.

    A screen's body (for example a list's empty state) can paint a frame or a fetch after the
    control the test waited for; slower engines such as WebKit expose that gap.
    """
    flags = "i" if pattern.flags & re.IGNORECASE else ""
    try:
        page.wait_for_function(
            """([source, flags]) => {
                const re = new RegExp(source, flags);
                return [...document.querySelectorAll('flt-semantics')].some(e => {
                    const own = [...e.childNodes].filter(n => n.nodeType === 3).map(n => n.textContent).join('');
                    return re.test(e.getAttribute('aria-label') || own || '');
                });
            }""",
            arg=[pattern.pattern, flags],
            timeout=timeout_ms,
        )
    except PlaywrightTimeoutError:
        pass  # the caller asserts on the lines and reports what the page showed
    return page_lines(page)


def page_text(page: Page) -> str:
    """The page labels as one text block."""
    return "\n".join(page_lines(page))


def id_text(page: Page, test_id: str) -> str:
    """Text of the widget tagged `test_id`, or an empty string when it is not on the page."""
    locator = by_id(page, test_id)
    return text_of(locator) if locator.count() else ""


def amount_of(page: Page, test_id: str) -> Decimal:
    """The Turkish-formatted money amount shown by the widget tagged `test_id`."""
    return parse_try(text_of(by_id(page, test_id)))


def sign_in_manager(page: Page, login_page, fixture) -> ManagerCockpit:
    """Sign the journey site's manager in through the login screen and wait for the cockpit."""
    login_page.login("manager", fixture.manager_email, fixture.manager_password)
    cockpit = ManagerCockpit(page).wait()
    page.wait_for_load_state("networkidle")
    return cockpit


def open_dues_segment(page: Page, index: int) -> DuesManagement:
    dues = DuesManagement(page).open()
    dues.segment(index)
    page.wait_for_load_state("networkidle")
    page.evaluate("() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))")
    return dues


def open_people_directory(page: Page) -> None:
    """Residents tab -> full-screen module -> people directory."""
    Shell(page).nav("residents")
    by_id(page, "open_owners_residents_module").click()
    by_id(page, "module_people_directory_btn").click()
    by_id(page, "people_search_input").wait_for(timeout=10_000)
    page.wait_for_load_state("networkidle")


@contextmanager
def journey_site(request, api, actors, stack, state: str, **options):
    """Build the isolated site for `state`, hand over its fixture, then tear it down with evidence."""
    saas = api.login(actors["saas"]["email"], actors["saas"]["password"])
    manifest = JourneyManifest.create(
        E2E / ".artifacts" / "journeys",
        run_id=request.node.nodeid,
        shard_id=os.environ.get("PYTEST_XDIST_WORKER", "main"),
    )
    try:
        fixture = site_in_state(state, api=api, stack=stack, saas=saas, manifest=manifest, **options)
        yield fixture
    except BaseException as failure:
        teardown_with_evidence(stack, manifest, failed=failure, capture_evidence=manifest.save)
        raise
    else:
        teardown_with_evidence(stack, manifest, failed=None, capture_evidence=manifest.save)


def resident_email(stack, fixture, full_name: str) -> str:
    """E-mail of a reference person of the site (F2 and later states share the manager's password)."""
    return stack.sql(
        f"SELECT email FROM persons WHERE site_id = {int(fixture.site_id)} AND full_name = '{full_name}';"
    )
