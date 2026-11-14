"""pytest plugin: one execution record per scenario, written to .artifacts/executions.jsonl.

A record is produced for
* every Gherkin scenario run through pytest-bdd (binding "gherkin", with one entry per step), and
* every plain pytest test that declares `@pytest.mark.covers("SC-xx-yy-nn")` (binding "linked").

Scenario tags drive the rest: `@SC-…`, `@STORY-…`, `@EPIC-…` identify the scenario,
`@GUI-…` becomes the `gui_id` marker, `@layer:<name>` names the test layer, and
`@pending` / `@linked` scenarios are deselected (nothing to execute here).
scripts/feature_traceability.py stores the records in the run history and reports on them.
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


def pytest_collection_modifyitems(config, items):
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
    return [{"scenario": sid, "name": item.name, "binding": "linked", "layer": "gui", "feature_file": ""}
            for sid in ids if SCENARIO_ID.match(sid)]


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_makereport(item, call):
    outcome = yield
    report = outcome.get_result()
    phases = item.stash.setdefault(PHASES, {})
    phases[report.when] = report
    if report.when != "teardown":
        return
    targets = _targets(item)
    if not targets:
        return
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
            epic, story = parents_of(target["scenario"])
            out.write(json.dumps({"epic": epic, "story": story, **target, **common}, ensure_ascii=False) + "\n")
