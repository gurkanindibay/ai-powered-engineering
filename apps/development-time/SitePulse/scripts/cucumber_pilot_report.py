#!/usr/bin/env python3
"""Create a public-safe comparison summary from Cucumber pilot outputs.

Raw JUnit and execution JSONL files can contain test data, failure messages,
and example values. This exporter reads only result fields and emits a fixed
allowlist of suite metadata and the five known pilot cases.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path

CASES = (
    ("SC-10-01-01", None, "SC-10-01-01", "Land share split without rounding drift"),
    ("SC-10-04-01", None, "SC-10-04-01", "Virman dialog offers real advance"),
    ("SC-10-04-02", None, "SC-10-04-02", "Virman transfer clears capital due"),
    ("SC-07-06-03", 1, "SC-07-06-03-example-1", "Excel sample download example 1"),
    ("SC-07-06-03", 2, "SC-07-06-03-example-2", "Excel sample download example 2"),
)
CASE_INDEX = {(scenario, row): (case_id, label) for scenario, row, case_id, label in CASES}
SAFE_STATUSES = {"PASS", "FAIL", "SKIP", "ERROR", "NOT_RUN", "INCOMPLETE"}


def _status(value: object) -> str:
    normalized = str(value or "").upper()
    return normalized if normalized in SAFE_STATUSES else "ERROR"


def _junit_counts(path: Path) -> Counter:
    root = ET.parse(path).getroot()
    counts: Counter = Counter()
    for case in root.iter("testcase"):
        counts["tests"] += 1
        if case.find("failure") is not None:
            counts["failed"] += 1
        elif case.find("error") is not None:
            counts["errors"] += 1
        elif case.find("skipped") is not None:
            counts["skipped"] += 1
        else:
            counts["passed"] += 1
    return counts


def _read_executions(path: Path) -> dict[str, dict]:
    result: dict[str, dict] = {}
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as error:
            raise ValueError(f"invalid execution JSON on line {line_number}") from error
        scenario = str(row.get("scenario", ""))
        example_row = row.get("example_row")
        case = CASE_INDEX.get((scenario, example_row))
        if not case:
            continue
        case_id, label = case
        if case_id in result:
            raise ValueError(f"duplicate result for {case_id}")
        duration = row.get("duration_s")
        if not isinstance(duration, (int, float)) or isinstance(duration, bool) or duration < 0:
            duration = 0.0
        result[case_id] = {
            "case_id": case_id,
            "scenario_id": scenario,
            "example_id": case_id if example_row is not None else None,
            "label": label,
            "status": _status(row.get("status")),
            "duration_s": round(float(duration), 3),
            "comparison_label": "Cucumber comparison; pytest remains authoritative",
        }
    return result


def build(junit: Path, executions: Path, run_id: str, attempt: str,
          commit: str, repository: str) -> dict:
    """Return the fixed public result schema; raw test values are never copied."""
    if not (run_id.isdigit() and attempt.isdigit()
            and re.fullmatch(r"[0-9a-fA-F]{7,40}", commit)
            and re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository)):
        raise ValueError("run ID, attempt, commit, or repository is not a safe identifier")

    cases_by_id: dict[str, dict] = {}
    junit_counts: Counter = Counter()
    complete = junit.is_file() and executions.is_file()
    if complete:
        try:
            junit_counts = _junit_counts(junit)
            cases_by_id = _read_executions(executions)
            record_counts = Counter(case["status"] for case in cases_by_id.values())
            complete = (
                junit_counts["tests"] == len(CASES)
                and len(cases_by_id) == len(CASES)
                and record_counts["PASS"] == junit_counts["passed"]
                and record_counts["FAIL"] == junit_counts["failed"]
                and record_counts["ERROR"] == junit_counts["errors"]
                and record_counts["SKIP"] == junit_counts["skipped"]
            )
        except (OSError, ValueError, ET.ParseError):
            complete = False

    if not complete:
        cases = [{
            "case_id": case_id,
            "scenario_id": scenario,
            "example_id": case_id if row is not None else None,
            "label": label,
            "status": "NOT_RUN",
            "duration_s": 0.0,
            "comparison_label": "Cucumber comparison; pytest remains authoritative",
        } for scenario, row, case_id, label in CASES]
        status = "INCOMPLETE"
    else:
        cases = [cases_by_id[case_id] for _, _, case_id, _ in CASES]
        statuses = {case["status"] for case in cases}
        if statuses - {"PASS"}:
            status = "FAIL" if statuses & {"FAIL", "ERROR"} else "SKIP"
        else:
            status = "PASS"

    totals = Counter(case["status"] for case in cases)
    run_url = f"https://github.com/{repository}/actions/runs/{run_id}/attempts/{attempt}"
    return {
        "schema_version": 1,
        "suite_id": "cucumber-serenity-pilot",
        "authority": "comparison-only",
        "status": status,
        "run": {"id": run_id, "attempt": int(attempt), "commit": commit.lower(), "url": run_url},
        "counts": {
            "tests": len(cases), "passed": totals["PASS"], "failed": totals["FAIL"],
            "errors": totals["ERROR"], "skipped": totals["SKIP"], "not_run": totals["NOT_RUN"],
        },
        "duration_s": round(sum(case["duration_s"] for case in cases), 3),
        "cases": cases,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--junit", type=Path, required=True, help="private native JUnit XML input")
    parser.add_argument("--executions", type=Path, required=True, help="private Cucumber JSONL input")
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--attempt", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--repository", required=True, help="owner/repository")
    parser.add_argument("--out", type=Path, required=True, help="safe JSON output")
    parser.add_argument("--json", action="store_true", help="print the safe result summary as JSON")
    args = parser.parse_args()
    try:
        report = build(args.junit, args.executions, args.run_id, args.attempt, args.commit, args.repository)
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    except (OSError, ValueError, ET.ParseError) as error:
        print(f"Cucumber result export failed: {error}", file=sys.stderr)
        return 1
    summary = {"status": report["status"], "cases": report["counts"]["tests"], "output": str(args.out)}
    print(json.dumps(summary) if args.json else
          f"Wrote {report['status']} Cucumber comparison report ({report['counts']['tests']} cases)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
