#!/usr/bin/env python3
"""Merges the e2e shard results of one CI run into a test report (GitHub artifact + job summary).

CI runs the browser suite as parallel shards (.github/workflows/sitepulse-ci.yml); each shard
uploads its e2e/.artifacts (junit.xml, executions.jsonl). The `test-report` job downloads them
into one directory and runs this tool, which
* merges every shard's executions.jsonl into one run, stamped with the CI run's metadata,
* records that run in a copy of the committed history (.specify/executions is never modified),
* writes <out>/test-report.md (the run: totals, regressions/fixes, every executed test),
  <out>/feature-report.html (the dashboard: committed history plus this run),
  <out>/executions.jsonl (the merged records) and <out>/summary.json (the stats),
  <out>/product-status.json and <out>/product-status.html (scripts/product_status.py: coverage
  per epic and trends; the published site keeps one snapshot per run to draw them),
* appends the stats and the report to $GITHUB_STEP_SUMMARY, so they show on the run page.

The workflow uploads <out> as artifact `e2e-test-report`. With CI reporting every PR, task
branches no longer commit recorded runs (gate `test-run-recorded` is switched off in
.specify/executions/settings.json; see scripts/feature_traceability.py).

Usage:
  python3 scripts/ci_test_report.py --shards shard-results --out e2e-test-report --task "PR 131"
  python3 scripts/ci_test_report.py --shards shard-results --out /tmp/report --json --no-summary

Exit code: 0 (a failing test fails its e2e shard job, not the report; a missing --shards
directory is reported as NO RESULTS); 2 on bad arguments.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import shutil
import sys
import xml.etree.ElementTree as ET
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import feature_traceability as ft  # noqa: E402
import product_status as ps  # noqa: E402
import ci_suite_collection as sc  # noqa: E402


def junit_totals(files: list[Path]) -> dict:
    """Test counts summed over every shard's junit.xml (unparseable files are counted, not fatal)."""
    totals = Counter({"tests": 0, "failures": 0, "errors": 0, "skipped": 0})
    seconds, broken = 0.0, []
    for path in files:
        try:
            root = ET.parse(path).getroot()
        except (ET.ParseError, OSError):
            broken.append(str(path))
            continue
        suites = [root] if root.tag == "testsuite" else list(root.iter("testsuite"))
        if not suites:
            broken.append(str(path))
            continue
        malformed = False
        for suite in suites:
            for key in totals:
                try:
                    totals[key] += int(suite.get(key, 0) or 0)
                except (TypeError, ValueError, OverflowError):
                    malformed = True
            try:
                duration = float(suite.get("time", 0) or 0)
                if not math.isfinite(duration):
                    raise ValueError("non-finite JUnit time")
                seconds += duration
            except (TypeError, ValueError, OverflowError):
                malformed = True
        if malformed:
            broken.append(str(path))
    passed = totals["tests"] - totals["failures"] - totals["errors"] - totals["skipped"]
    return {**totals, "passed": passed, "seconds": round(seconds, 1), "files": len(files), "unparseable": broken}


def merge_executions(files: list[Path], out: Path) -> tuple[int, int]:
    count = invalid = 0
    with out.open("w", encoding="utf-8") as merged:
        for path in files:
            try:
                lines = path.read_text(encoding="utf-8").splitlines()
            except (OSError, UnicodeError):
                invalid += 1
                continue
            for line in lines:
                if not line.strip():
                    continue
                try:
                    record = json.loads(line)
                except (ValueError, RecursionError):
                    invalid += 1
                    continue
                if not isinstance(record, dict) or not isinstance(record.get("status"), str):
                    invalid += 1
                    continue
                merged.write(line + "\n")
                count += 1
    return count, invalid


def incomplete_suite_count(suites: list[dict]) -> int:
    """Count suites without a complete evidence set for the requested attempt."""
    incomplete_statuses = {"incomplete", "missing", "cancelled", "mixed-attempts", "reused"}
    return sum(1 for suite in suites if suite.get("status") in incomplete_statuses)


def build(shards: Path, out: Path, task: str | None, history: Path,
          evidence_out: Path | None = None, run_id: str | None = None, attempt: str | None = None,
          suite_artifacts: Path | None = None, producer_status: dict[str, str] | None = None,
          commit_override: str | None = None) -> dict:
    out.mkdir(parents=True, exist_ok=True)
    meta = ft.run_metadata(trigger="ci", task=task)
    collection = sc.collect(suite_artifacts or Path("."), shards,
                            run_id or meta["run_id"], attempt or "1",
                            commit_override or meta.get("commit", ""), producer_status)
    if collection["saw_attempt_artifacts"]:
        selected_shards = [Path(path) for _, path in sorted(collection["_selected_e2e_paths"].items())]
        execution_files = sorted(path for folder in selected_shards for path in folder.rglob("executions.jsonl"))
        junit_files = sorted(path for folder in selected_shards for path in folder.rglob("junit.xml"))
    else:
        # Compatibility for historical artifacts created before attempt metadata existed.
        selected_shards = []
        execution_files = sorted(shards.rglob("executions.jsonl"))
        junit_files = sorted(shards.rglob("junit.xml"))
    junit = junit_totals(junit_files)
    merged = out / "executions.jsonl"
    count, invalid_executions = merge_executions(execution_files, merged)
    collection["invalid_execution_inputs"] = invalid_executions
    if invalid_executions:
        for suite in collection["suites"]:
            if suite["suite"] == "e2e" and suite["status"] not in {"cancelled", "not-run"}:
                suite["status"] = "incomplete"

    store_dir = out / "history"
    if store_dir.exists():
        shutil.rmtree(store_dir)
    if (history / "runs").is_dir():
        shutil.copytree(history / "runs", store_dir / "runs")
    store = ft.DirStore(store_dir)
    ft.record_run(merged, store, meta)

    # Keep the disposable execution history in its own Actions-only payload. The publisher selects
    # public report files, so evidence stays separate from the report output entirely.
    if evidence_out is not None:
        if not run_id or not attempt:
            raise ValueError("Actions evidence requires both run_id and attempt")
        evidence_runs = evidence_out / f"run-{run_id}" / f"attempt-{attempt}" / "runs"
        if evidence_runs.exists():
            shutil.rmtree(evidence_runs)
        if (store_dir / "runs").is_dir():
            evidence_runs.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(store_dir / "runs", evidence_runs)

    sc.write_report(collection, out)
    if collection["shard_inputs"]:
        e2e_cases = [row for row in collection["cases"] if row.get("runner") == "pytest-playwright"]
        e2e_counts = {status: sum(1 for row in e2e_cases if row.get("status") == status)
                       for status in ("failed", "error", "skipped")}
        junit = {"tests": len(e2e_cases), "failures": e2e_counts["failed"], "errors": e2e_counts["error"],
                 "skipped": e2e_counts["skipped"], "passed": len(e2e_cases) - sum(e2e_counts.values()),
                 "seconds": round(sum(float(row.get("duration_s") or 0) for row in e2e_cases), 1),
                 "files": collection["junit_files"], "unparseable": collection["junit_errors"]}

    catalogue = ft.load_catalogue()
    records = ft.load_history(store, 10_000)
    runs = ft.build_runs(records, catalogue, limit=10_000)
    run = next((r for r in runs if r["run_id"] == meta["run_id"]), None)
    markdown = ft.run_markdown(run) if run else (
        f"# Test run {meta['run_id']}\n\nNo execution records were produced "
        f"({len(execution_files)} executions.jsonl file(s) found under {shards}).\n")
    (out / "test-report.md").write_text(markdown, encoding="utf-8")
    with (out / "test-report.md").open("a", encoding="utf-8") as handle:
        handle.write("\n" + (out / "suite-report.md").read_text(encoding="utf-8"))
    page = ft.render_html(ft.build_report(catalogue, records),
                          datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
                          f"committed history + CI run {meta['run_id']}", ft.build_runs(records, catalogue))
    (out / "feature-report.html").write_text(page, encoding="utf-8")
    shutil.rmtree(store_dir, ignore_errors=True)

    summary = {"run_id": meta["run_id"], "actions_run_id": str(run_id or ""),
               "attempt": str(attempt or ""), "task": meta["task"], "commit": commit_override or meta["commit"],
               "shards": len(execution_files), "executions": count, "junit": junit,
               "ci_suites": {"case_count": collection["case_count"], "unique_case_count": collection["unique_case_count"],
                             "case_totals": collection["case_totals"],
                             "incomplete_suites": incomplete_suite_count(collection["suites"])},
               "status": "INCOMPLETE" if invalid_executions else (run["status"] if run else "NO RESULTS"),
               "scenario_counts": run["counts"] if run else {},
               "scenarios_covered": f"{run['executed']}/{run['automated']}" if run else "0/0",
               "out": str(out)}
    (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    # Product status counts this run's results only: an older pass does not make a scenario pass today.
    run_records = [r for r in records if r.get("run_id") == meta["run_id"]]
    snapshot = ps.build_snapshot(catalogue, run_records, summary, ps.catalogue_history())
    (out / "product-status.json").write_text(json.dumps(snapshot, indent=1) + "\n", encoding="utf-8")
    (out / "product-status.html").write_text(
        ps.render_html([snapshot], {"detail": "feature-report.html", "history": "feature-report.html"}),
        encoding="utf-8")
    return summary


def step_summary(summary: dict, markdown: str) -> str:
    j = summary["junit"]
    counts = ", ".join(f"{n} {s}" for s, n in sorted(summary["scenario_counts"].items())) or "none"
    head = ["## E2E test report", "",
            "| Tests | Passed | Failed | Errors | Skipped | Test time | Shards |", "|---|---|---|---|---|---|---|",
            f"| {j['tests']} | {j['passed']} | {j['failures']} | {j['errors']} | {j['skipped']} | "
            f"{j['seconds']:.0f}s | {summary['shards']} |", "",
            f"**Result:** {summary['status']} ({counts}); scenarios covered: {summary['scenarios_covered']}. "
            "Full report and HTML dashboard: artifact `e2e-test-report`.", "",
            "<details><summary>Executed tests</summary>", ""]
    body = re.sub(r"(?m)^(#+) ", lambda m: "##" + m.group(1) + " ", markdown)
    return "\n".join(head) + "\n" + body + "\n</details>\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--shards", type=Path, required=True, help="directory holding the downloaded shard artifacts")
    parser.add_argument("--out", type=Path, required=True, help="directory to write the report into")
    parser.add_argument("--task", help="label of the run (default: $SITEPULSE_TASK, else the branch)")
    parser.add_argument("--history", type=Path, default=Path(ft.DEFAULT_STORE),
                        help="committed run history to show next to this run (default: .specify/executions)")
    parser.add_argument("--evidence-out", type=Path,
                        help="optional Actions-only output directory for this run's execution history")
    parser.add_argument("--run-id", help="GitHub Actions run id used to namespace the evidence payload")
    parser.add_argument("--attempt", help="GitHub Actions run attempt used to namespace the evidence payload")
    parser.add_argument("--suite-artifacts", type=Path, help="downloaded per-suite producer artifacts")
    parser.add_argument("--commit", help="CI commit SHA for report identity")
    parser.add_argument("--producer-status", help="JSON object mapping lint/rust/flutter/e2e to job state")
    parser.add_argument("--no-summary", action="store_true", help="do not append to $GITHUB_STEP_SUMMARY")
    parser.add_argument("--json", action="store_true", help="print the stats as JSON")
    args = parser.parse_args(argv)
    if not args.shards.is_dir():
        # No shard uploaded anything (e.g. every shard failed before pytest): still publish a report.
        print(f"warning: --shards {args.shards} does not exist; reporting no results", file=sys.stderr)
        args.shards.mkdir(parents=True, exist_ok=True)

    try:
        producer_status = json.loads(args.producer_status) if args.producer_status else None
    except json.JSONDecodeError as exc:
        parser.error(f"invalid --producer-status JSON: {exc}")
    summary = build(args.shards, args.out, args.task, args.history,
                    args.evidence_out, args.run_id, args.attempt,
                    args.suite_artifacts, producer_status, args.commit)
    target = os.environ.get("GITHUB_STEP_SUMMARY")
    if target and not args.no_summary:
        with open(target, "a", encoding="utf-8") as handle:
            handle.write(step_summary(summary, (args.out / "test-report.md").read_text(encoding="utf-8")))
    if args.json:
        print(json.dumps(summary, indent=2))
    else:
        j = summary["junit"]
        print(f"{summary['status']}: {j['tests']} tests ({j['passed']} passed, {j['failures']} failed, "
              f"{j['errors']} errors, {j['skipped']} skipped) from {summary['shards']} shard(s); "
              f"report in {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
