"""Audit Flutter's rendered semantics on ten SitePulse screens."""
from __future__ import annotations

import json
import os
from pathlib import Path

import pytest

from pages import CapitalProjects, DuesManagement, ManagerCockpit, PaymentStream, ResidentsTab, ResidentHome, SaasAdmin, Shell


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


SCREENS = {
    "sign-in": _login,
    "manager-dashboard": _screen("manager", lambda page: ManagerCockpit(page).wait()),
    "unit-directory": _screen("manager", lambda page: ResidentsTab(page).open()),
    "add-resident": _screen("manager", lambda page: ResidentsTab(page).open().start_add()),
    "dues": _screen("manager", lambda page: DuesManagement(page).open()),
    "payment-stream": _screen("manager", lambda page: PaymentStream(page).open()),
    "capital-projects": _screen("manager", lambda page: CapitalProjects(page).open()),
    "manager-profile": _screen("manager", lambda page: Shell(page).open_profile()),
    "resident-dashboard": _screen("homeowner", lambda page: ResidentHome(page).wait()),
    "saas-sites": _screen("saas", lambda page: SaasAdmin(page).wait()),
}

# Fail on the critical threshold and on missing accessible names even when
# axe rates the affected widget as serious.
NAME_RULES = {
    "aria-command-name", "aria-input-field-name", "aria-toggle-field-name",
    "button-name", "label", "link-name", "select-name",
}


@pytest.fixture(scope="session")
def axe_script():
    path = Path(os.environ.get("SITEPULSE_AXE_JS", "node_modules/axe-core/axe.min.js"))
    if not path.is_file():
        pytest.fail("Install axe-core and set SITEPULSE_AXE_JS to the path of axe.min.js")
    return path.resolve()


@pytest.mark.parametrize("screen", SCREENS)
def test_no_critical_accessibility_violations(screen, axe_script, page, login_as, record_property):
    SCREENS[screen](page, login_as)
    page.add_script_tag(path=str(axe_script))
    result = page.evaluate("() => axe.run(document, {resultTypes: ['violations', 'passes']})")
    # Prevent a green audit caused by scanning an empty page or an engine failure.
    assert result["passes"], f"axe did not run any rules successfully on {screen}"
    violations = result["violations"]
    report = Path(__file__).resolve().parents[1] / ".artifacts" / "axe" / f"{screen}.json"
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps(violations, indent=2) + "\n", encoding="utf-8")
    record_property("axe_violations", len(violations))
    blocking = [violation["id"] for violation in violations
                if violation["impact"] == "critical" or violation["id"] in NAME_RULES]
    assert not blocking, f"{screen}: {', '.join(blocking)}. Details in {report.name}"
