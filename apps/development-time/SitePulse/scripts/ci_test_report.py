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


def junit_totals(files: list[Path]) -> dict:
    """Test counts summed over every shard's junit.xml (unparseable files are counted, not fatal)."""
    totals = Counter({"tests": 0, "failures": 0, "errors": 0, "skipped": 0})
    seconds, broken = 0.0, []
    for path in files:
        try:
            root = ET.parse(path).getroot()
        except ET.ParseError:
            broken.append(str(path))
            continue
        for suite in [root] if root.tag == "testsuite" else root.iter("testsuite"):
            totals.update({k: int(suite.get(k, 0)) for k in totals})
            seconds += float(suite.get("time", 0) or 0)
    passed = totals["tests"] - totals["failures"] - totals["errors"] - totals["skipped"]
    return {**totals, "passed": passed, "seconds": round(seconds, 1), "files": len(files), "unparseable": broken}


def merge_executions(files: list[Path], out: Path) -> int:
    lines = [line for path in files for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    out.write_text("".join(line + "\n" for line in lines), encoding="utf-8")
    return len(lines)


def build(shards: Path, out: Path, task: str | None, history: Path) -> dict:
    out.mkdir(parents=True, exist_ok=True)
    execution_files = sorted(shards.rglob("executions.jsonl"))
    junit = junit_totals(sorted(shards.rglob("junit.xml")))
    merged = out / "executions.jsonl"
    count = merge_executions(execution_files, merged)

    store_dir = out / "history"
    if store_dir.exists():
        shutil.rmtree(store_dir)
    if (history / "runs").is_dir():
        shutil.copytree(history / "runs", store_dir / "runs")
    store = ft.DirStore(store_dir)
    meta = ft.run_metadata(trigger="ci", task=task)
    ft.record_run(merged, store, meta)

    catalogue = ft.load_catalogue()
    records = ft.load_history(store, 10_000)
    runs = ft.build_runs(records, catalogue, limit=10_000)
    run = next((r for r in runs if r["run_id"] == meta["run_id"]), None)
    markdown = ft.run_markdown(run) if run else (
        f"# Test run {meta['run_id']}\n\nNo execution records were produced "
        f"({len(execution_files)} executions.jsonl file(s) found under {shards}).\n")
    (out / "test-report.md").write_text(markdown, encoding="utf-8")
    page = ft.render_html(ft.build_report(catalogue, records),
                          datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
                          f"committed history + CI run {meta['run_id']}", ft.build_runs(records, catalogue))
    (out / "feature-report.html").write_text(page, encoding="utf-8")
    shutil.rmtree(store_dir, ignore_errors=True)

    summary = {"run_id": meta["run_id"], "task": meta["task"], "commit": meta["commit"],
               "shards": len(execution_files), "executions": count, "junit": junit,
               "status": run["status"] if run else "NO RESULTS",
               "scenario_counts": run["counts"] if run else {},
               "scenarios_covered": f"{run['executed']}/{run['automated']}" if run else "0/0",
               "out": str(out)}
    (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
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
    parser.add_argument("--no-summary", action="store_true", help="do not append to $GITHUB_STEP_SUMMARY")
    parser.add_argument("--json", action="store_true", help="print the stats as JSON")
    args = parser.parse_args(argv)
    if not args.shards.is_dir():
        # No shard uploaded anything (e.g. every shard failed before pytest): still publish a report.
        print(f"warning: --shards {args.shards} does not exist; reporting no results", file=sys.stderr)
        args.shards.mkdir(parents=True, exist_ok=True)

    summary = build(args.shards, args.out, args.task, args.history)
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
