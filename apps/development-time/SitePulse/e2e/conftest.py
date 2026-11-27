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
from support.flutter import by_id, track_text_connections, wait_for_app  # noqa: E402
from support.page_errors import describe_page_error  # noqa: E402
from pages import LoginPage  # noqa: E402

ARTIFACTS = E2E / ".artifacts"

pytest_plugins = [
    "support.executions",
    "support.hang_guard",
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
    try:
        st.build_web(force=os.environ.get("GUI_E2E_REBUILD") == "1")
        s = st.E2EStack(ARTIFACTS / "logs")
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
    violations = stack.sql("SELECT count(*) FROM v_integrity_violations;").strip()
    assert violations == "0", (
        "ledger integrity invariant failed after E2E/API test: "
        f"v_integrity_violations contains {violations} row(s)"
    )


# WebKit's web process rasterises with Skia on the GPU. On GPU-less hosts (GitHub runners,
# containers) its software EGL lacks fence sync, libepoxy aborts with "No provider of
# eglDestroySync found" and the page crashes, about one load in five, which surfaced as
# hung clicks and selector timeouts right after Flutter's first frame (issue #422).
# CPU rasterisation removes that code path; it changes no rendered result the tests read.
#
# JavaScriptCore compiling on background threads while the code already runs corrupts
# CanvasKit's wasm now and then: "RuntimeError: Out of bounds memory access" while laying out
# a paragraph (the screen then stays blank), or a dead renderer process (issue #527). Playwright
# 1.55.0 (WebKit 26.0) failed about 1 load in 70; with concurrent JIT off, none did. All JIT
# tiers stay on, so CanvasKit keeps its speed. Re-check with scripts/webkit_load_soak.py when
# Playwright is upgraded.
WEBKIT_LAUNCH_ENV = {
    "WEBKIT_SKIA_ENABLE_CPU_RENDERING": "1",
    "JSC_useConcurrentJIT": "0",
}


@pytest.fixture(scope="session")
def browser_type_launch_args(browser_type_launch_args, browser_name):
    if browser_name != "webkit":
        return browser_type_launch_args
    env = {**os.environ, **browser_type_launch_args.get("env", {}), **WEBKIT_LAUNCH_ENV}
    return {**browser_type_launch_args, "env": env}


@pytest.fixture(scope="session")
def browser_context_args(browser_context_args, browser_name):
    mobile_width = os.environ.get("SITEPULSE_E2E_VIEWPORT_WIDTH")
    viewport = {"width": int(mobile_width), "height": 812} if mobile_width else {"width": 1280, "height": 900}
    args = {**browser_context_args, "viewport": viewport, "locale": "tr-TR"}
    if browser_name == "chromium":
        args["permissions"] = ["clipboard-read", "clipboard-write"]
    return args


@pytest.fixture
def context(context):
    """Let `fill()` see when Flutter is listening to a text field (see support/flutter.py)."""
    track_text_connections(context)
    return context


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
def page_guard(request, page, browser_name):
    """Fail on uncaught JS errors, backend 5xx and calls refused by the password gate; other 4xx are recorded only."""
    errors: list[str] = []
    client_errors: list[str] = []
    gate_errors: list[str] = []
    page_errors: list[str] = []
    ignored_page_errors: list[str] = []

    def on_page_error(exc):
        described = describe_page_error(exc)
        # WebKit occasionally raises a page error with an empty name and message (usually a
        # non-Error value thrown or rejected) whose stack holds only compiled main.dart.js
        # frames. That cannot distinguish a browser/rasteriser fault from application code, so
        # the lane keeps it as evidence instead of failing (#474). Named errors still fail.
        if browser_name == "webkit" and described.startswith("pageerror: <empty message:"):
            ignored_page_errors.append(described)
            return
        page_errors.append(described)

    page.on("pageerror", on_page_error)
    # A crashed renderer makes every later call hang until its timeout; say so instead.
    page.on("crash", lambda _page: errors.append("page crashed: the browser's renderer process died"))

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
    if ignored_page_errors:
        request.node.user_properties.append(("ignored_page_errors", "; ".join(ignored_page_errors)))
    if "allow_server_errors" in request.keywords:
        errors, page_errors = [], []
    if "allow_password_gate" not in request.keywords:
        errors += gate_errors
    errors = page_errors + errors
    if errors:
        pytest.fail("page/server errors during test:\n" + "\n".join(errors), pytrace=False)


@pytest.fixture
def login_page(page, stack) -> LoginPage:
    return LoginPage(page, st.web_base()).open()


@pytest.fixture
def login_as(page, api, actors):
    """login_as('manager') -> seeds authenticated storage_state via API without UI sign-in."""
    def _login(role: str) -> None:
        actor = actors[role]
        data = api.call(
            "POST",
            "/api/v1/auth/login",
            body={"email": actor["email"], "password": actor["password"]},
        )
        state_path = ARTIFACTS / f"storage_state_{os.getpid()}_{role}.json"
        state_path.parent.mkdir(parents=True, exist_ok=True)
        payload_str = json.dumps(data)
        state = {
            "cookies": [],
            "origins": [
                {
                    "origin": st.web_base(),
                    "localStorage": [{"name": "sitepulse.e2e_session", "value": payload_str}],
                }
            ],
        }
        state_path.write_text(json.dumps(state), encoding="utf-8")
        entries_js = json.dumps([["sitepulse.e2e_session", payload_str]])
        page.add_init_script(
            f"""(() => {{
                if (!window.sessionStorage.getItem('__e2e_seeded')) {{
                    window.sessionStorage.setItem('__e2e_seeded', '1');
                    for (const [k, v] of {entries_js}) window.localStorage.setItem(k, v);
                }}
            }})();"""
        )
        page.goto(st.web_base())
        wait_for_app(page)
        by_id(page, "login_tab_quickAll").wait_for(state="detached", timeout=20_000)
    return _login
