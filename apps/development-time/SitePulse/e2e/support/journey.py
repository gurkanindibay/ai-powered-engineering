"""Building blocks for per-role user journey tests (tests/journeys, docs/GUI_TEST_PLAN.md §9).

A journey is one test that walks a single user from their first sign-in with a
temporary password through everything that role does, and ends signed out.
Each part is a named `step(...)`, so a failure says where the journey broke
and the JUnit report lists the steps that ran.

`NetworkLog` records every backend call the page makes. Journeys assert on
outcomes the user would see (data on screen, matching the API) and on the
network: a client that calls business routes it is not allowed to call, or
that skips loading its data, fails here even when the screen looks fine.
"""
from __future__ import annotations

import contextlib
import re
from dataclasses import dataclass, field

import pytest
from playwright.sync_api import Page, Response

from .stack import E2E_API_PORT

AUTH_PREFIX = "/api/v1/auth/"


@dataclass(frozen=True)
class Call:
    method: str
    path: str
    status: int
    page_path: str  # app route the browser was on when the answer arrived


@dataclass
class NetworkLog:
    """Backend calls seen by the page, in order."""

    calls: list[Call] = field(default_factory=list)

    @classmethod
    def attach(cls, page: Page) -> "NetworkLog":
        log = cls()

        def on_response(resp: Response) -> None:
            if f":{E2E_API_PORT}" not in resp.url:
                return
            path = re.sub(r"^https?://[^/]+", "", resp.url).split("?", 1)[0]
            page_path = page.url.split("#", 1)[1] if "#" in page.url else ""
            log.calls.append(Call(resp.request.method, path, resp.status, page_path))

        page.on("response", on_response)
        return log

    def mark(self) -> int:
        """Position to pass to the *_since helpers."""
        return len(self.calls)

    def since(self, mark: int) -> list[Call]:
        return self.calls[mark:]

    def business_calls_since(self, mark: int) -> list[Call]:
        """Calls other than /api/v1/auth/* (login, me, change-password, logout)."""
        return [c for c in self.since(mark) if not c.path.startswith(AUTH_PREFIX)]

    def failures_since(self, mark: int) -> list[Call]:
        return [c for c in self.since(mark) if c.status >= 400]

    def paths_since(self, mark: int) -> set[str]:
        return {c.path for c in self.since(mark)}


@dataclass
class Journey:
    """Named steps of one user journey; the step that failed is in the failure message."""

    request: pytest.FixtureRequest
    role: str
    steps: list[str] = field(default_factory=list)

    @contextlib.contextmanager
    def step(self, name: str):
        self.steps.append(name)
        try:
            yield
        except AssertionError as exc:
            raise AssertionError(f"[{self.role} journey] step {len(self.steps)} '{name}' failed: {exc}") from exc
        except Exception as exc:  # Playwright timeouts and API errors
            raise AssertionError(
                f"[{self.role} journey] step {len(self.steps)} '{name}' failed: {type(exc).__name__}: {exc}"
            ) from exc
        finally:
            self.request.node.user_properties.append(("journey_steps", " > ".join(self.steps)))


def assert_no_failures(log: NetworkLog, mark: int, what: str, allowed: tuple[str, ...] = ()) -> None:
    """No 4xx/5xx since `mark`, except paths matching an `allowed` regex."""
    bad = [c for c in log.failures_since(mark) if not any(re.search(a, c.path) for a in allowed)]
    assert not bad, f"{what}: backend refused calls {[(c.method, c.path, c.status) for c in bad]}"


@dataclass
class Account:
    login_role: str      # login tab key in pages/login.py
    email: str
    temporary_password: str
    new_password: str


_ROUTE_JS = "() => (location.hash.replace(/^#/, '') || location.pathname).split('?')[0]"


def push_route(page, path: str) -> None:
    """Open an app link without reloading, as a click on a link or a browser back would (hash URLs)."""
    page.evaluate("p => { location.hash = p; }", path)


def route(page) -> str:
    """The app route, e.g. '/manager/home' for '.../#/manager/home'."""
    return page.evaluate(_ROUTE_JS)


def wait_route(page, prefix: str, timeout_ms: int = 10_000) -> None:
    page.wait_for_function(f"p => ({_ROUTE_JS})().startsWith(p)", arg=prefix, timeout=timeout_ms)
