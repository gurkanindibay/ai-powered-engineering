#!/usr/bin/env python3
"""Convert SitePulse CI results into Serenity BDD JSON outcomes: one per catalogue scenario.

    python3 scripts/serenity_report.py --artifact-dir e2e-test-report --out serenity-json
    java -jar serenity-cli-<version>.jar --source serenity-json --destination site --project SitePulse

Input is the CI `e2e-test-report` artifact (`scenario-evidence.json`, `executions.jsonl`) plus the
scenario catalogue of the checkout, which must be the commit that CI tested. No test runs here.

* A scenario that pytest-bdd executed shows its Gherkin steps with the recorded status of each.
* A scenario verified by other tests (Rust, Flutter, API, linked browser tests) shows those test
  cases as its steps. Its Gherkin text is description only: those steps did not run one by one.
* The report is public, so raw error messages and stack traces are never copied; a failure names
  the exception type only.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

import feature_traceability as traceability

# Evidence state of ci_scenario_evidence.py -> Serenity result.
EVIDENCE_RESULTS = {"passing": "SUCCESS", "failing": "FAILURE", "skipped": "SKIPPED",
                    "planned": "PENDING", "scheduled": "IGNORED", "unresolved": "IGNORED"}
STEP_RESULTS = {"PASS": "SUCCESS", "FAIL": "FAILURE", "ERROR": "ERROR", "SKIPPED": "SKIPPED",
                "UNDEFINED": "ERROR", "DEFECT": "PENDING"}
CASE_RESULTS = {"passing": "SUCCESS", "failing": "FAILURE", "skipped": "SKIPPED", "unresolved": "IGNORED"}
FAILED = ("ERROR", "FAILURE")
EVIDENCE_NOTES = {
    "gherkin": "Executed by pytest-bdd; each step below has its own recorded result.",
    "cases": "Verified by the test cases listed as steps. The Gherkin steps were not executed one by one.",
    "planned": "Planned: this scenario is not automated yet.",
    "scheduled": "Scheduled: its test runs in the nightly lane, not in this run.",
    "unresolved": "CI reported no test case that could be matched to this scenario in this run.",
}
ERROR_TYPE = re.compile(r"\b([A-Z][A-Za-z0-9_]{0,60}(?:Error|Exception|Failed))\b")


def _error_type(text: str) -> str:
    match = ERROR_TYPE.search(text or "")
    return match.group(1) if match else "TestFailure"


def _failure(error_type: str) -> dict:
    return {"errorType": error_type, "stackTrace": [],
            "message": f"{error_type}. Details are in the CI run's logs and artifacts."}


def _step(description: str, result: str, duration_s: float, started: str, error: str = "",
          children: list | None = None) -> dict:
    step = {"description": description, "result": result, "duration": int(round((duration_s or 0) * 1000)),
            "startTime": started, "children": children or []}
    if result in FAILED and not children:
        step["exception"] = _failure(_error_type(error))
    return step


def _number(steps: list[dict], start: int = 1) -> int:
    for step in steps:
        step["number"] = start
        start = _number(step["children"], start + 1)
    return start


def _gherkin_steps(runs: list[dict], started: str) -> list[dict]:
    """The recorded steps of a pytest-bdd run; an outline or several browsers give one group per run."""
    groups = []
    for run in runs:
        steps = [_step(f"{s['keyword']} {s['text']}", STEP_RESULTS.get(s["status"], "ERROR"),
                       s.get("duration_s", 0), started, s.get("error", "")) for s in run["steps"]]
        if len(runs) == 1:
            return steps
        label = run.get("example_id") or run.get("test", "").split("::")[-1]
        result = STEP_RESULTS.get(run.get("status", ""), "ERROR")
        groups.append(_step(label, result, run.get("duration_s", 0), started, run.get("error", ""), steps))
    return groups


def _result(evidence: str, runs: list[dict]) -> str:
    """CI evidence decides the result; a failed or known-defect browser run is never reported as passed."""
    statuses = {run.get("status") for run in runs}
    if "ERROR" in statuses:
        return "ERROR"
    if "FAIL" in statuses:
        return "FAILURE"
    result = EVIDENCE_RESULTS.get(evidence, "IGNORED")
    if "DEFECT" in statuses and result == "SUCCESS":
        return "PENDING"
    return result


def build_outcome(scenario, row: dict, runs: list[dict], catalogue, started: str) -> dict:
    epic, story = traceability.parents_of(scenario.id)
    epic_title = f"{epic} {catalogue.epics.get(epic, '')}".strip()
    story_title = f"{story} {catalogue.stories.get(story, '')}".strip()
    evidence = row.get("evidence", "unresolved")
    result = _result(evidence, runs)
    gherkin = [run for run in runs if run.get("binding") == "gherkin" and run.get("steps")]
    if gherkin:
        kind, steps = "gherkin", _gherkin_steps(gherkin, started)
    else:
        cases = row.get("cases", [])
        kind = "cases" if cases else evidence if evidence in EVIDENCE_NOTES else "unresolved"
        steps = [_step(f"[{c.get('suite', 'unknown')}] {c.get('native_id', '')}",
                       CASE_RESULTS.get(c.get("status", ""), "IGNORED"), 0, started) for c in cases]
    _number(steps)
    note = EVIDENCE_NOTES.get(kind, EVIDENCE_NOTES["unresolved"])
    if kind == "planned" and scenario.pending_note:
        note += " " + scenario.pending_note
    feature = {"name": f"{epic_title}/{story_title}", "type": "feature", "displayName": story_title}
    tags = [feature,
            {"name": epic_title, "type": "capability", "displayName": epic_title},
            {"name": evidence, "type": "evidence", "displayName": evidence}]
    if scenario.layer:
        tags.append({"name": scenario.layer, "type": "layer", "displayName": scenario.layer})
    key = scenario.id.lower()
    outcome = {
        "id": f"{story};{key}", "scenarioId": f"{story};{key}", "methodName": key,
        "name": scenario.name, "title": f"{scenario.id} {scenario.name}",
        "description": "\n".join([note, "", *scenario.steps]),
        "context": "cucumber", "testSource": "cucumber", "projectKey": "SitePulse",
        "manual": False, "isManualTestingUpToDate": False, "actors": [],
        # A linked test covers several scenarios, so only a scenario's own Gherkin runs have a duration.
        "startTime": started, "duration": int(round(sum(r.get("duration_s", 0) for r in gherkin) * 1000)),
        "result": result, "testSteps": steps,
        "userStory": {"id": f"features/{scenario.file}", "path": f"features/{scenario.file}",
                      "storyName": story_title, "displayName": story_title, "narrative": "", "type": "feature",
                      "pathElements": [{"name": epic_title, "description": epic_title},
                                       {"name": story_title, "description": story_title}]},
        "featureTag": feature,
        "tags": tags,
    }
    if result in FAILED:
        error_type = _error_type(next((r.get("error", "") for r in runs if r.get("error")), ""))
        outcome["testFailureCause"] = _failure(error_type)
        outcome["testFailureClassname"] = error_type
        outcome["testFailureMessage"] = outcome["testFailureCause"]["message"]
    return outcome


def _start_time(run_id: str) -> str:
    """'20261125T191514Z-c7e97ad' -> ISO time; the current time when the run id has no timestamp."""
    try:
        moment = datetime.strptime((run_id or "").split("-")[0], "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        moment = datetime.now(timezone.utc)
    return moment.strftime("%Y-%m-%dT%H:%M:%S.000Z")


def convert(artifact_dir: Path, out: Path, root: Path = traceability.ROOT) -> dict:
    evidence_file = artifact_dir / "scenario-evidence.json"
    if not evidence_file.is_file():
        raise ValueError(f"{evidence_file} is missing")
    evidence = json.loads(evidence_file.read_text(encoding="utf-8"))
    runs: dict[str, list[dict]] = defaultdict(list)
    executions = artifact_dir / "executions.jsonl"
    if executions.is_file():
        for line in executions.read_text(encoding="utf-8").splitlines():
            record = json.loads(line) if line.strip() else {}
            if record.get("scenario"):
                runs[record["scenario"]].append(record)
    catalogue = traceability.load_catalogue(root)
    scenarios = {s.id: s for s in catalogue.scenarios if s.id}
    if not scenarios:
        raise ValueError(f"no scenarios found under {root}")
    if out.exists() and any(out.iterdir()):
        raise ValueError(f"output directory {out} is not empty")
    out.mkdir(parents=True, exist_ok=True)
    started = _start_time(str(evidence.get("run_id") or ""))
    rows = evidence.get("scenarios", {})
    results: Counter = Counter()
    states: Counter = Counter()
    with_steps = 0
    for scenario_id, scenario in sorted(scenarios.items()):
        row = rows.get(scenario_id, {})
        scenario_runs = runs.get(scenario_id, [])
        outcome = build_outcome(scenario, row, scenario_runs, catalogue, started)
        results[outcome["result"]] += 1
        states[row.get("evidence", "unresolved")] += 1
        with_steps += any(r.get("binding") == "gherkin" and r.get("steps") for r in scenario_runs)
        name = hashlib.sha256(outcome["id"].encode()).hexdigest() + ".json"
        (out / name).write_text(json.dumps(outcome, ensure_ascii=False), encoding="utf-8")
    return {"scenarios": len(scenarios), "results": dict(sorted(results.items())),
            "evidence": dict(sorted(states.items())), "with_gherkin_steps": with_steps,
            "not_in_catalogue": sorted(set(rows) - set(scenarios))}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--artifact-dir", type=Path, required=True, help="Downloaded e2e-test-report artifact")
    parser.add_argument("--out", type=Path, required=True, help="Empty directory for the Serenity JSON outcomes")
    parser.add_argument("--root", type=Path, default=traceability.ROOT, help="SitePulse root with .specify")
    parser.add_argument("--json", action="store_true", help="Print the summary as JSON")
    args = parser.parse_args(argv)
    try:
        summary = convert(args.artifact_dir, args.out, args.root)
    except (OSError, ValueError, KeyError) as exc:
        print(f"serenity_report: {exc}", file=sys.stderr)
        return 1
    if args.json:
        print(json.dumps(summary, indent=2))
    else:
        print(f"serenity_report: {summary['scenarios']} scenarios, results {summary['results']}, "
              f"{summary['with_gherkin_steps']} with executed Gherkin steps")
    return 0


if __name__ == "__main__":
    sys.exit(main())
