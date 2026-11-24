"""pytest fixtures for the SitePulse GUI suite.

Session: one isolated stack (throwaway DB + backend :8180 + web :9190).
Per test: database reset to the seed, fresh browser context, and a guard that
fails the test on uncaught page errors or 5xx API responses.
Run through scripts/gui_e2e.py, which sets DB_PASS and browser options.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import pytest

# Linux limits UNIX domain socket paths to 108 chars (sockaddr_un.sun_path).
# When run under agent harnesses, TMPDIR can be 70+ chars long, causing
# Chrome's SingletonSocket creation to abort with "Socket path too long".
if len(os.environ.get("TMPDIR", "")) > 30:
    os.environ["TMPDIR"] = "/tmp"

E2E = Path(__file__).resolve().parent
sys.path.insert(0, str(E2E))

from support import stack as st  # noqa: E402
from support.api import Api, Builders  # noqa: E402
from support.journey_attempts import reclaim_stale_attempts  # noqa: E402
from pages import LoginPage  # noqa: E402

ARTIFACTS = E2E / ".artifacts"

pytest_plugins = [
    "support.executions",
    "steps.capital_steps",
    "steps.epic01_steps",
    "steps.epic02_steps",
    "steps.epic03_steps",
    "steps.epic04_steps",
    "steps.epic05_steps",
    "steps.epic06_steps",
    "steps.epic07_steps",
    "steps.epic08_steps",
    "steps.epic09_steps",
    "steps.epic11_steps",
]


def _actors() -> dict:
    real = E2E / "fixtures" / "actors.json"
    data = json.loads((real if real.exists() else E2E / "fixtures" / "actors.example.json").read_text())
    data["saas"] = {"email": st.SAAS_ADMIN_EMAIL, "password": st.SAAS_ADMIN_PASSWORD}
    return data


@pytest.fixture(scope="session")
def stack():
    st.build_web(force=os.environ.get("GUI_E2E_REBUILD") == "1")
    s = st.E2EStack(ARTIFACTS / "logs")
    try:
        s.start()
        reclaim_stale_attempts(s, ARTIFACTS / "journeys")
    except st.SetupError as exc:
        pytest.exit(f"E2E stack setup failed: {exc}", returncode=3)
    yield s
    s.stop()


@pytest.fixture(scope="session")
def actors() -> dict:
    return _actors()


@pytest.fixture(scope="session")
def api(stack) -> Api:
    return Api(stack=stack)


@pytest.fixture
def builders(stack) -> Builders:
    return Builders(stack)


@pytest.fixture(autouse=True)
def fresh_data(stack):
    """Every test starts from the seed; a reset takes about a second."""
    stack.reset()
    yield


@pytest.fixture(scope="session")
def browser_context_args(browser_context_args, browser_name):
    mobile_width = os.environ.get("SITEPULSE_E2E_VIEWPORT_WIDTH")
    viewport = {"width": int(mobile_width), "height": 812} if mobile_width else {"width": 1280, "height": 900}
    args = {**browser_context_args, "viewport": viewport, "locale": "tr-TR"}
    if browser_name == "chromium":
        args["permissions"] = ["clipboard-read", "clipboard-write"]
    return args


@pytest.fixture(autouse=True)
def record_gui_ids(request):
    """Write each test's GUI scenario ids into the JUnit report (read by scripts/gui_traceability.py)."""
    ids = [m.args[0] for m in request.node.iter_markers("gui_id")]
    request.node.user_properties.append(("gui_ids", ",".join(sorted(set(ids)))))
    yield


def _is_password_gate(resp) -> bool:
    try:
        return "PASSWORD_CHANGE_REQUIRED" in resp.text()
    except Exception:  # body no longer available
        return False


@pytest.fixture(autouse=True)
def page_guard(request, page):
    """Fail on uncaught JS errors, backend 5xx and calls refused by the password gate; other 4xx are recorded only."""
    errors: list[str] = []
    client_errors: list[str] = []
    gate_errors: list[str] = []
    page.on("pageerror", lambda exc: errors.append(f"pageerror: {exc}"))

    def on_response(resp):
        if f":{st.E2E_API_PORT}" in resp.url:
            if resp.status >= 500:
                errors.append(f"{resp.status} {resp.request.method} {resp.url}")
            elif resp.status >= 400:
                client_errors.append(f"{resp.status} {resp.request.method} {resp.url}")
                # A business call made while the password is still temporary is a client fault
                # (STORY-06-06): the change screen must be the only thing the app opens.
                if resp.status == 403 and _is_password_gate(resp):
                    gate_errors.append(f"403 PASSWORD_CHANGE_REQUIRED {resp.request.method} {resp.url}")

    page.on("response", on_response)
    yield
    request.node.user_properties.append(("client_errors", "; ".join(sorted(set(client_errors)))))
    if "allow_server_errors" in request.keywords:
        errors = []
    if "allow_password_gate" not in request.keywords:
        errors += gate_errors
    if errors:
        pytest.fail("page/server errors during test:\n" + "\n".join(errors), pytrace=False)


@pytest.fixture
def login_page(page, stack) -> LoginPage:
    return LoginPage(page, st.web_base()).open()


@pytest.fixture
def login_as(login_page, actors):
    """login_as('manager') -> logs in through the UI with the seed account."""
    def _login(role: str) -> None:
        actor = actors[role]
        login_page.login(role, actor["email"], actor["password"])
    return _login
