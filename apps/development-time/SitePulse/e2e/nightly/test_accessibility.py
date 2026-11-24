"""Audit Flutter's rendered semantics on ten SitePulse screens."""
from __future__ import annotations

import json
import os
from pathlib import Path

import pytest

from pages import CapitalProjects, DuesManagement, ManagerCockpit, PaymentStream, ResidentsTab, ResidentHome, SaasAdmin
from support.flutter import by_id


def _login(_page, _login_as):
    # login_page has already navigated to the login screen.
    return


def _screen(role, open_screen):
    def navigate(page, login_as):
        login_as(role)
        if role == "manager":
            ManagerCockpit(page).wait()
        open_screen(page)
    return navigate


def _resident_issue_form(page, login_as):
    login_as("homeowner")
    ResidentHome(page).wait()
    by_id(page, "resident_action_requests").click()
    page.get_by_label("Açıklama").wait_for()


SCREEN_CASES = (
    pytest.param("sign-in", _login, marks=pytest.mark.covers("SC-06-05-04"), id="sign-in"),
    pytest.param("manager-dashboard", _screen("manager", lambda page: ManagerCockpit(page).wait()), id="manager-dashboard"),
    pytest.param("unit-directory", _screen("manager", lambda page: ResidentsTab(page).open()), id="unit-directory"),
    pytest.param("add-resident", _screen("manager", lambda page: ResidentsTab(page).open().start_add()), id="add-resident"),
    pytest.param("dues", _screen("manager", lambda page: DuesManagement(page).open()), id="dues"),
    pytest.param("payment-stream", _screen("manager", lambda page: PaymentStream(page).open()), id="payment-stream"),
    pytest.param("capital-projects", _screen("manager", lambda page: CapitalProjects(page).open()), id="capital-projects"),
    pytest.param("resident-issue-form", _resident_issue_form, marks=pytest.mark.covers("SC-01-04-04"), id="resident-issue-form"),
    pytest.param("resident-dashboard", _screen("homeowner", lambda page: ResidentHome(page).wait()), id="resident-dashboard"),
    pytest.param("saas-sites", _screen("saas", lambda page: SaasAdmin(page).wait()), id="saas-sites"),
)

# Fail on the critical threshold and on missing accessible names even when
# axe rates the affected widget as serious.
NAME_RULES = {
    "aria-command-name", "aria-input-field-name", "aria-toggle-field-name",
    "button-name", "label", "link-name", "select-name",
}
FLUTTER_DISABLED_TEXT_PROXY = "textarea[data-semantics-role='text-field'][disabled]"


@pytest.fixture(scope="session")
def axe_script():
    path = Path(os.environ.get("SITEPULSE_AXE_JS", "node_modules/axe-core/axe.min.js"))
    if not path.is_file():
        pytest.fail("Install axe-core and set SITEPULSE_AXE_JS to the path of axe.min.js")
    return path.resolve()


@pytest.mark.parametrize(("screen", "navigate"), SCREEN_CASES)
def test_no_critical_accessibility_violations(screen, navigate, axe_script, page, login_as, record_property):
    navigate(page, login_as)
    page.add_script_tag(path=str(axe_script))
    proxy_count = page.locator(FLUTTER_DISABLED_TEXT_PROXY).count()
    result = page.evaluate(
        "selector => axe.run({exclude: [[selector]]}, {resultTypes: ['violations', 'passes']})",
        FLUTTER_DISABLED_TEXT_PROXY,
    )
    # Prevent a green audit caused by scanning an empty page or an engine failure.
    assert result["passes"], f"axe did not run any rules successfully on {screen}"
    violations = result["violations"]
    report = Path(__file__).resolve().parents[1] / ".artifacts" / "axe" / f"{screen}.json"
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps(violations, indent=2) + "\n", encoding="utf-8")
    record_property("axe_violations", len(violations))
    record_property("excluded_disabled_flutter_text_proxies", proxy_count)
    blocking = [violation["id"] for violation in violations
                if violation["impact"] == "critical" or violation["id"] in NAME_RULES]
    assert not blocking, f"{screen}: {', '.join(blocking)}. Details in {report.name}"
