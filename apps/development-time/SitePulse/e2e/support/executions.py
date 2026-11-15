"""pytest plugin: one execution record per test, written to .artifacts/executions.jsonl.

A record is produced for
* every Gherkin scenario run through pytest-bdd (binding "gherkin", with one entry per step),
* every plain pytest test that declares `@pytest.mark.covers("SC-xx-yy-nn")` (binding "linked"), and
* every other test (binding "unlinked": no scenario yet, attributed to its epic through its GUI id).

Every test also gets an `epic_NN` marker (from its `GUI-NN-…` id or `@EPIC-NN` tag), which is what
`gui_e2e.py run --affected` selects on.

Scenario tags drive the rest: `@SC-…`, `@STORY-…`, `@EPIC-…` identify the scenario,
`@GUI-…` becomes the `gui_id` marker, `@layer:<name>` names the test layer, and
`@pending` / `@linked` scenarios are deselected (nothing to execute here).
`scripts/gui_e2e.py run --record` stores the records in the run history (.specify/executions);
scripts/feature_traceability.py reports on them.
"""
from __future__ import annotations

import json
import re
import time
from pathlib import Path

import pytest

E2E = Path(__file__).resolve().parents[1]
FEATURES = E2E.parent / ".specify" / "features"
EXECUTIONS = E2E / ".artifacts" / "executions.jsonl"

SCENARIO_ID = re.compile(r"^SC-(\d{2})-(\d{2})-\d{2}$")
TRACE_TAG = re.compile(r"^(EPIC-\d{2}|STORY-\d{2}-\d{2}|SC-\d{2}-\d{2}-\d{2})$")
GUI_TAG = re.compile(r"^GUI-(?:[0-9X]{1,2}|J)-\d{2}$")
EPIC_OF_GUI = re.compile(r"^GUI-(\d{2})-\d{2}$")
NOT_EXECUTED = ("pending", "linked")
MAX_ERROR_CHARS = 2000

STEPS = pytest.StashKey[list]()
STEP_STARTED = pytest.StashKey[float]()
PHASES = pytest.StashKey[dict]()


def parents_of(scenario_id: str) -> tuple[str, str]:
    """'SC-10-01-02' -> ('EPIC-10', 'STORY-10-01')."""
    m = SCENARIO_ID.match(scenario_id)
    if not m:
        raise ValueError(f"not a scenario id: {scenario_id!r}")
    return f"EPIC-{m.group(1)}", f"STORY-{m.group(1)}-{m.group(2)}"


def overall_status(phases: dict) -> str:
    """Scenario status from the pytest reports of the setup, call and teardown phases."""
    setup, call, teardown = phases.get("setup"), phases.get("call"), phases.get("teardown")
    if setup is not None and setup.failed:
        return "ERROR"
    if setup is not None and setup.skipped:
        return "DEFECT" if hasattr(setup, "wasxfail") else "SKIPPED"
    if call is None:
        return "ERROR"
    if call.skipped:
        return "DEFECT" if hasattr(call, "wasxfail") else "SKIPPED"
    if call.failed or (teardown is not None and teardown.failed):
        return "FAIL"
    return "PASS"


# ---------------------------------------------------------------- collection

def pytest_bdd_apply_tag(tag, function):
    if TRACE_TAG.match(tag) or ":" in tag:
        return True  # identifiers and key:value tags are read from the scenario, not turned into markers
    if GUI_TAG.match(tag):
        pytest.mark.gui_id(tag)(function)
        return True
    return None  # smoke, core, role_*, pending, linked: ordinary markers


def epics_of(item) -> list[str]:
    """['EPIC-10'] from the test's GUI ids, the scenarios it `covers`, and a Gherkin @EPIC tag.

    A linked test belongs to the epic of every scenario it covers, so `-m epic_12` (used by
    `gui_e2e.py run --affected`) selects it whenever EPIC-12 is affected, even if its GUI id
    names another epic.
    """
    found = {f"EPIC-{m.group(1)}" for marker in item.iter_markers("gui_id") if marker.args
             for m in [EPIC_OF_GUI.match(str(marker.args[0]))] if m}
    found |= {f"EPIC-{m.group(1)}" for marker in item.iter_markers("covers") for arg in marker.args
              for m in [SCENARIO_ID.match(str(arg))] if m}
    scenario = getattr(getattr(item, "obj", None), "__scenario__", None)
    if scenario is not None:
        found |= {t for t in _tags(scenario) if re.fullmatch(r"EPIC-\d{2}", t)}
    return sorted(found)


def pytest_configure(config):
    for number in range(1, 100):
        config.addinivalue_line("markers", f"epic_{number:02d}: test belongs to EPIC-{number:02d} (set automatically)")


@pytest.hookimpl(tryfirst=True)  # before pytest applies -m, so `-m epic_10` can select
def pytest_collection_modifyitems(config, items):
    for item in items:
        for epic in epics_of(item):
            item.add_marker(getattr(pytest.mark, f"epic_{epic[5:]}"))
    dropped = [item for item in items if any(item.get_closest_marker(name) for name in NOT_EXECUTED)]
    if dropped:
        config.hook.pytest_deselected(items=dropped)
        items[:] = [item for item in items if item not in dropped]


def pytest_sessionstart(session):
    EXECUTIONS.parent.mkdir(parents=True, exist_ok=True)
    EXECUTIONS.write_text("", encoding="utf-8")


# ---------------------------------------------------------------- steps

def _add_step(request, step, status: str, error: str | None = None) -> None:
    started = request.node.stash.get(STEP_STARTED, None)
    entry = {"keyword": step.keyword.strip(), "text": step.name, "status": status,
             "duration_s": round(time.monotonic() - started, 3) if started else 0.0}
    if error:
        entry["error"] = error[:MAX_ERROR_CHARS]
    request.node.stash.setdefault(STEPS, []).append(entry)
    request.node.stash[STEP_STARTED] = 0.0


def pytest_bdd_before_step(request, feature, scenario, step, step_func):
    request.node.stash[STEP_STARTED] = time.monotonic()


def pytest_bdd_after_step(request, feature, scenario, step, step_func, step_func_args):
    _add_step(request, step, "PASS")


def pytest_bdd_step_error(request, feature, scenario, step, step_func, step_func_args, exception):
    _add_step(request, step, "FAIL", f"{type(exception).__name__}: {exception}")


def pytest_bdd_step_func_lookup_error(request, feature, scenario, step, exception):
    _add_step(request, step, "UNDEFINED", str(exception))


def pytest_bdd_after_scenario(request, feature, scenario):
    """Steps that never ran (after a failure) are listed as SKIPPED, so a record always shows the whole scenario."""
    recorded = request.node.stash.setdefault(STEPS, [])
    for step in scenario.steps[len(recorded):]:
        recorded.append({"keyword": step.keyword.strip(), "text": step.name, "status": "SKIPPED", "duration_s": 0.0})


# ---------------------------------------------------------------- records

def _tags(scenario) -> set[str]:
    return set(scenario.tags) | set(scenario.feature.tags)


def _targets(item) -> list[dict]:
    """The scenarios this test item reports on, with the static part of their record."""
    scenario = getattr(getattr(item, "obj", None), "__scenario__", None)
    if scenario is not None:
        tags = _tags(scenario)
        ids = sorted(t for t in tags if SCENARIO_ID.match(t))
        layer = next((t.split(":", 1)[1] for t in sorted(tags) if t.startswith("layer:")), "")
        feature_file = Path(scenario.feature.filename).resolve()
        rel = feature_file.relative_to(FEATURES).as_posix() if feature_file.is_relative_to(FEATURES) else feature_file.name
        return [{"scenario": sid, "name": scenario.name, "binding": "gherkin", "layer": layer, "feature_file": rel}
                for sid in ids]
    ids = sorted({str(m.args[0]) for m in item.iter_markers("covers") if m.args})
    linked = [{"scenario": sid, "name": item.name, "binding": "linked", "layer": "gui", "feature_file": ""}
              for sid in ids if SCENARIO_ID.match(sid)]
    return linked or [{"scenario": "", "name": item.name, "binding": "unlinked", "layer": "gui", "feature_file": ""}]


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_makereport(item, call):
    outcome = yield
    report = outcome.get_result()
    phases = item.stash.setdefault(PHASES, {})
    phases[report.when] = report
    if report.when != "teardown":
        return
    targets = _targets(item)
    epics = epics_of(item)
    failed = next((phases[w] for w in ("setup", "call", "teardown") if w in phases and phases[w].failed), None)
    common = {
        "test": item.nodeid,
        "status": overall_status(phases),
        "duration_s": round(sum(r.duration for r in phases.values()), 3),
        "steps": item.stash.get(STEPS, []),
        "error": str(failed.longrepr)[-MAX_ERROR_CHARS:] if failed is not None else "",
        "gui_ids": sorted({str(m.args[0]) for m in item.iter_markers("gui_id") if m.args}),
    }
    with EXECUTIONS.open("a", encoding="utf-8") as out:
        for target in targets:
            epic, story = parents_of(target["scenario"]) if target["scenario"] else (epics[0] if epics else "", "")
            out.write(json.dumps({"epic": epic, "story": story, **target, **common}, ensure_ascii=False) + "\n")
