#!/usr/bin/env python3
"""Story → GUI scenario → browser-test traceability for SitePulse.

Joins three sources:
* the user stories in .specify/requirements/*.md (`### STORY-xx-yy: title`),
* the scenario catalogue in docs/GUI_TEST_PLAN.md (`| GUI-xx-nn | <story ids> | ...`,
  plus the `**Excluded:**` rows and the EPIC-05 exclusion),
* the latest GUI suite run, e2e/.artifacts/junit.xml, where every test records its
  `gui_ids` (e2e/conftest.py) and its outcome.

Per story it reports: the scenarios, the tests that ran, and a status:
  PASS     every test for the story passed
  DEFECT   at least one test is a strict xfail (a known, pinned product defect or gap)
  FAIL     a test failed or errored (includes an unexpected XPASS)
  NOT RUN  the story has scenarios but no test for it is in the report
  GAP      no GUI surface exists for the story (a confirmed product gap), with a reason
  EXCLUDED the catalogue excludes the story from the GUI, with a reason
  MISSING  neither a scenario nor an exclusion (a catalogue gap)

Usage:
    python3 scripts/gui_traceability.py                 # table
    python3 scripts/gui_traceability.py --json
    python3 scripts/gui_traceability.py --write-status  # refresh the section in COMPLETION_STATUS.md
    python3 scripts/gui_traceability.py --junit path/to/junit.xml

Exit code: 1 if any story is FAIL or MISSING, otherwise 0.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REQUIREMENTS = ROOT / ".specify" / "requirements"
CATALOGUE = ROOT / "docs" / "GUI_TEST_PLAN.md"
JUNIT = ROOT / "e2e" / ".artifacts" / "junit.xml"
STATUS_DOC = ROOT / "COMPLETION_STATUS.md"
BEGIN, END = "<!-- gui-traceability:begin -->", "<!-- gui-traceability:end -->"

STORY_HEADING = re.compile(r"^###\s+STORY-(\d{2}-\d{2}):\s*(.+?)\s*$")
SCENARIO_ROW = re.compile(r"^\|\s*(GUI-(?:[0-9X]{1,2}|J)-\d{2})\s*\|\s*([^|]*)\|")
EXCLUDED_ROW = re.compile(r"^\|\s*—\s*\|\s*([^|]+)\|.*\*\*(Excluded|Partial[^:*]*):\*\*\s*([^|]+)\|")
STORY_REF = re.compile(r"\b(\d{2}-\d{2})\b")
ORDER = ["FAIL", "MISSING", "NOT RUN", "DEFECT", "GAP", "PASS", "EXCLUDED"]


def load_stories() -> dict[str, str]:
    stories: dict[str, str] = {}
    for path in sorted(REQUIREMENTS.glob("*.md")):
        for line in path.read_text(encoding="utf-8").splitlines():
            m = STORY_HEADING.match(line)
            if m:
                stories[m.group(1)] = m.group(2)
    return stories


def load_catalogue() -> tuple[dict[str, list[str]], dict[str, tuple[str, str]]]:
    """Returns ({story: [scenario ids]}, {story: (EXCLUDED|GAP, reason)})."""
    scenarios: dict[str, list[str]] = defaultdict(list)
    excluded: dict[str, tuple[str, str]] = {}
    text = CATALOGUE.read_text(encoding="utf-8")
    # Only the catalogue (§3); later sections repeat scenario ids in result tables.
    start, end = text.find("## 3."), text.find("## 4.")
    text = text[start:end] if start != -1 and end > start else text
    for line in text.splitlines():
        m = SCENARIO_ROW.match(line)
        if m:
            for story in STORY_REF.findall(m.group(2)):
                scenarios[story].append(m.group(1))
            continue
        m = EXCLUDED_ROW.match(line)
        if m:
            kind = "GAP" if m.group(2).startswith("Partial") else "EXCLUDED"
            for story in STORY_REF.findall(m.group(1)):
                excluded[story] = (kind, m.group(3).strip().rstrip("."))
    if "EPIC-05 (05-01" in text:
        for n in range(1, 7):
            excluded.setdefault(f"05-{n:02d}", ("EXCLUDED", "backend only; covered by run_tests.py gates"))
    return dict(scenarios), excluded


def load_results(junit: Path) -> dict[str, list[tuple[str, str]]]:
    """Returns {scenario id: [(test name, outcome)]}; outcome is passed|xfail|failed|skipped."""
    by_scenario: dict[str, list[tuple[str, str]]] = defaultdict(list)
    if not junit.exists():
        return {}
    for case in ET.parse(junit).iter("testcase"):
        props = {p.get("name"): p.get("value") or "" for p in case.iter("property")}
        ids = [i for i in props.get("gui_ids", "").split(",") if i]
        if case.find("failure") is not None or case.find("error") is not None:
            outcome = "failed"
        elif (skipped := case.find("skipped")) is not None:
            outcome = "xfail" if "xfail" in (skipped.get("type") or "") else "skipped"
        else:
            outcome = "passed"
        name = f"{case.get('classname', '').rsplit('.', 1)[-1]}::{case.get('name')}"
        for gid in ids:
            by_scenario[gid].append((name, outcome))
    return dict(by_scenario)


def build(junit: Path) -> dict:
    stories = load_stories()
    scenarios, excluded = load_catalogue()
    results = load_results(junit)
    rows = []
    for story, title in stories.items():
        ids = sorted(set(scenarios.get(story, [])))
        tests = sorted({t for gid in ids for t in results.get(gid, [])})
        outcomes = {o for _, o in tests}
        if "failed" in outcomes:
            status = "FAIL"
        elif ids and not tests:
            status = "NOT RUN"
        elif "xfail" in outcomes:
            status = "DEFECT"
        elif tests:
            status = "PASS"
        elif story in excluded:
            status = excluded[story][0]
        else:
            status = "MISSING"
        rows.append({"story": f"STORY-{story}", "title": title, "scenarios": ids,
                     "passed": sum(o == "passed" for _, o in tests), "xfail": sum(o == "xfail" for _, o in tests),
                     "failed": sum(o == "failed" for _, o in tests), "status": status,
                     "note": excluded[story][1] if status in ("EXCLUDED", "GAP") else ""})
    counts = {s: sum(r["status"] == s for r in rows) for s in ORDER}
    return {"junit": str(junit.relative_to(ROOT)) if junit.is_relative_to(ROOT) else str(junit),
            "junit_found": junit.exists(), "stories": len(rows), "counts": counts, "rows": rows}


def markdown(report: dict) -> str:
    c = report["counts"]
    lines = [
        BEGIN,
        "### GUI end-to-end coverage (generated)",
        "",
        "Generated by `python3 scripts/gui_traceability.py --write-status` from `.specify/requirements`, "
        "`docs/GUI_TEST_PLAN.md` and the last GUI run (`e2e/.artifacts/junit.xml`). Do not edit by hand.",
        "",
        f"**{report['stories']} stories:** {c['PASS']} pass, {c['DEFECT']} with a pinned defect or gap (strict xfail), "
        f"{c['FAIL']} failing, {c['NOT RUN']} not run, {c['GAP']} without a GUI surface, {c['EXCLUDED']} excluded, "
        f"{c['MISSING']} missing.",
        "",
        "| Story | Title | GUI scenarios | Tests (pass / xfail / fail) | GUI status |",
        "| :--- | :--- | :--- | :---: | :---: |",
    ]
    for r in report["rows"]:
        scen = ", ".join(r["scenarios"]) or "—"
        tests = f"{r['passed']} / {r['xfail']} / {r['failed']}" if r["scenarios"] else "—"
        status = r["status"] + (f" ({r['note']})" if r["note"] else "")
        lines.append(f"| {r['story']} | {r['title']} | {scen} | {tests} | {status} |")
    lines.append(END)
    return "\n".join(lines)


def write_status(report: dict) -> None:
    text = STATUS_DOC.read_text(encoding="utf-8")
    block = markdown(report)
    if BEGIN in text and END in text:
        text = text[:text.index(BEGIN)] + block + text[text.index(END) + len(END):]
    else:
        anchor = "## 3. Persona / Role Capability Coverage"
        text = text.replace(anchor, block + "\n\n---\n\n" + anchor, 1) if anchor in text else text + "\n\n" + block
    STATUS_DOC.write_text(text, encoding="utf-8")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--junit", type=Path, default=JUNIT, help="JUnit report of a GUI run (default: last run)")
    ap.add_argument("--json", action="store_true", help="print a JSON report")
    ap.add_argument("--write-status", action="store_true", help="refresh the generated section in COMPLETION_STATUS.md")
    args = ap.parse_args(argv)
    report = build(args.junit.resolve())
    if not report["junit_found"]:
        print(f"note: no GUI run report at {args.junit}; stories with scenarios show NOT RUN", file=sys.stderr)
    if args.write_status:
        write_status(report)
    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        for r in report["rows"]:
            print(f"{r['status']:<9} {r['story']}  {', '.join(r['scenarios']) or '—':<40} "
                  f"pass {r['passed']} xfail {r['xfail']} fail {r['failed']}")
        print(json.dumps(report["counts"]))
    return 1 if report["counts"]["FAIL"] or report["counts"]["MISSING"] else 0


if __name__ == "__main__":
    sys.exit(main())
