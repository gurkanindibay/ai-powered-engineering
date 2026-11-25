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
  <out>/scenario-evidence.json and .md (named case outcomes linked to scenario IDs),
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
import hashlib
import json
import math
import os
import re
import shutil
import sys
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

PUBLIC_SCENARIO_ID = re.compile(r"^SC-\d{2}-\d{2}-\d{2,}$")

sys.path.insert(0, str(Path(__file__).resolve().parent))
import feature_traceability as ft  # noqa: E402
import product_status as ps  # noqa: E402
import ci_suite_collection as sc  # noqa: E402
import ci_coverage_report as cov  # noqa: E402
import ci_scenario_evidence as scenario_evidence  # noqa: E402
from ci_scenario_evidence import safe_public_label as _safe_public_label  # noqa: E402
from ci_scenario_evidence import safe_static_case_name as _safe_static_case_name  # noqa: E402


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


def junit_ignored_page_errors(files: list[Path]) -> int:
    """Tests whose page guard recorded WebKit's empty page errors as diagnostics (#474)."""
    count = 0
    for path in files:
        try:
            root = ET.parse(path).getroot()
        except (ET.ParseError, OSError):
            continue
        for prop in root.iter("property"):
            if prop.get("name") == "ignored_page_errors" and (prop.get("value") or "").strip():
                count += 1
    return count


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


def _public_duration(value: object) -> float | None:
    if isinstance(value, bool):
        return None
    try:
        duration = float(value)
    except (TypeError, ValueError, OverflowError):
        return None
    if not math.isfinite(duration) or duration < 0:
        return None
    return round(duration, 3)


def _evidence_cases(collected: object, inventory_cases: list[dict]) -> list[dict]:
    """Cases for scenario matching: the collected ones with their full names, never to be published.

    `_public_inventory` truncates names. It keeps the collected cases first and in order, so the
    entries after them are the legacy JUnit cases `collect_inventory` appended.
    """
    full = [case for case in collected if isinstance(case, dict)] if isinstance(collected, list) else []
    return full + inventory_cases[len(full):]


def _public_inventory(suites: object, gates: object, cases: object) -> dict:
    public_suites = []
    for suite in suites if isinstance(suites, list) else []:
        if not isinstance(suite, dict):
            continue
        raw_count = suite.get("case_count", 0)
        try:
            case_count = max(0, int(raw_count)) if not isinstance(raw_count, bool) else 0
        except (TypeError, ValueError, OverflowError):
            case_count = 0
        missing = suite.get("missing_shards", [])
        public_suites.append({
            "suite": _safe_public_label(suite.get("suite"), "unknown"),
            "gate": _safe_public_label(suite.get("gate"), ""),
            "runner": _safe_public_label(suite.get("runner"), "unknown"),
            "producer": _safe_public_label(suite.get("producer"), "unknown"),
            "status": _safe_public_label(suite.get("status"), "incomplete"),
            "case_count": case_count,
            "missing_shards": [_safe_public_label(value, "unknown") for value in missing
                               if isinstance(value, str)] if isinstance(missing, list) else [],
        })

    public_gates = []
    for gate in gates if isinstance(gates, list) else []:
        if not isinstance(gate, dict):
            continue
        exits = gate.get("exit_codes", [])
        public_gates.append({
            "gate": _safe_public_label(gate.get("gate"), "unknown"),
            "status": _safe_public_label(gate.get("status"), "incomplete"),
            "duration_s": _public_duration(gate.get("duration_s")),
            "exit_codes": [value for value in exits if isinstance(value, int) and not isinstance(value, bool)]
            if isinstance(exits, list) else [],
        })

    public_cases = []
    for case in cases if isinstance(cases, list) else []:
        if not isinstance(case, dict):
            continue
        raw_scenarios = case.get("scenario_ids", [])
        public_cases.append({
            "runner": _safe_public_label(case.get("runner"), "unknown"),
            "suite": _safe_public_label(case.get("suite"), "unknown"),
            "producer": _safe_public_label(case.get("producer"), "unknown"),
            "shard": _safe_public_label(case.get("shard"), "unknown"),
            "native_id": _safe_static_case_name(case.get("native_id")),
            "status": _safe_public_label(case.get("status"), "unknown"),
            "duration_s": _public_duration(case.get("duration_s")),
            "scenario_ids": [value for value in raw_scenarios
                             if isinstance(value, str) and PUBLIC_SCENARIO_ID.fullmatch(value)]
            if isinstance(raw_scenarios, list) else [],
        })
    return {"suites": public_suites,
            "gates": public_gates,
            "cases": public_cases,
            "unmapped_cases": [case for case in public_cases if not case.get("scenario_ids")]}


def public_report_from_inventory(inventory: dict, coverage: dict | None = None) -> dict:
    """Translate the internal collection into Pages schema 1 using public fields only."""
    status_map = {
        "passed": "PASS", "collected": "PASS", "success": "PASS", "pass": "PASS",
        "failed": "FAIL", "collected-with-failures": "FAIL", "failure": "FAIL", "fail": "FAIL",
        "skipped": "SKIPPED", "cancelled": "SKIPPED", "not-run": "SKIPPED",
        "error": "ERROR", "incomplete": "INCOMPLETE", "missing": "INCOMPLETE",
        "mixed-attempts": "INCOMPLETE", "reused": "INCOMPLETE", "unknown": "UNKNOWN",
    }
    suite_gate_status: dict[str, list[str]] = defaultdict(list)
    for suite in inventory.get("suites", []):
        if not isinstance(suite, dict):
            continue
        gate_name = suite.get("gate") or ("gui-e2e" if suite.get("suite") == "e2e" else "")
        if isinstance(gate_name, str) and gate_name:
            suite_gate_status[gate_name].append(str(suite.get("status", "unknown")).lower())

    gates = []
    for gate in inventory.get("gates", []):
        name = _safe_public_label(gate.get("gate")) if isinstance(gate, dict) else ""
        if not name:
            continue
        states = suite_gate_status.get(name, [])
        if any(state in {"incomplete", "missing", "mixed-attempts", "reused"} for state in states):
            public_status = "INCOMPLETE"
        elif any(state in {"cancelled", "not-run"} for state in states):
            public_status = "SKIPPED"
        elif any(state == "collected-with-failures" for state in states):
            public_status = "FAIL"
        else:
            public_status = status_map.get(str(gate.get("status", "unknown")).lower(), "UNKNOWN")
        public_gate = {"name": name, "status": public_status}
        duration = _public_duration(gate.get("duration_s"))
        if duration is not None:
            public_gate["duration_seconds"] = duration
        gates.append(public_gate)

    cases = []
    seen: defaultdict[tuple[str, str, str], int] = defaultdict(int)
    for case in inventory.get("cases", []):
        if not isinstance(case, dict):
            continue
        runner = _safe_public_label(case.get("runner"), "unknown")
        suite = _safe_public_label(case.get("suite"), "unknown")
        name = _safe_static_case_name(case.get("native_id"))
        identity = (runner, suite, name)
        seen[identity] += 1
        ordinal = seen[identity]
        digest = hashlib.sha256("\0".join(identity).encode("utf-8")).hexdigest()[:16]
        public_case = {
            "id": f"case-{digest}-{ordinal}",
            "name": f"{name} example-{ordinal}",
            "status": status_map.get(str(case.get("status", "unknown")).lower(), "UNKNOWN"),
        }
        duration = _public_duration(case.get("duration_s"))
        if duration is not None:
            public_case["duration_seconds"] = duration
        scenarios = case.get("scenario_ids", [])
        if isinstance(scenarios, list):
            scenario_ids = [value for value in scenarios
                            if isinstance(value, str) and PUBLIC_SCENARIO_ID.fullmatch(value)]
            if len(scenario_ids) == 1:
                public_case["scenario_id"] = scenario_ids[0]
        cases.append(public_case)
    report = {"schema": 1, "gates": gates, "cases": cases}
    if coverage is not None:
        report["coverage"] = coverage
    return report


def collect_inventory(shards: Path, records: list[dict] | None = None,
                      collection: dict | None = None) -> dict:
    if isinstance(collection, dict):
        inventory = _public_inventory(collection.get("suites"), collection.get("gates"), collection.get("cases"))
        has_e2e_cases = any(case.get("runner") == "pytest-playwright" for case in inventory["cases"])
        if not has_e2e_cases and any(shards.rglob("junit.xml")):
            legacy = collect_inventory(shards, records)
            inventory["cases"].extend(legacy["cases"])
            inventory["unmapped_cases"] = [case for case in inventory["cases"] if not case.get("scenario_ids")]
        return inventory

    records = records or []
    suite_files = list(shards.rglob("suite-collection.json"))
    case_files = list(shards.rglob("case-results.jsonl"))
    if suite_files and case_files:
        try:
            suite_data = json.loads(suite_files[0].read_text(encoding="utf-8"))
            cases = [json.loads(line) for line in case_files[0].read_text(encoding="utf-8").splitlines() if line.strip()]
            if not isinstance(suite_data, dict):
                raise ValueError("suite collection root is not an object")
            return _public_inventory(suite_data.get("suites"), suite_data.get("gates"), cases)
        except (OSError, UnicodeError, json.JSONDecodeError, ValueError, RecursionError, TypeError):
            pass

    scenario_by_test: dict[str, set[str]] = defaultdict(set)
    for r in records:
        test = r.get("test")
        sc = r.get("scenario")
        if test and sc:
            scenario_by_test[test].add(sc)
            scenario_by_test[test.split("::")[-1]].add(sc)
            base_test = re.sub(r"\[.*\]$", "", test)
            scenario_by_test[base_test].add(sc)
            scenario_by_test[base_test.split("::")[-1]].add(sc)

    cases = []
    junit_files = sorted(shards.rglob("junit.xml"))
    for jf in junit_files:
        try:
            root = ET.parse(jf).getroot()
        except (ET.ParseError, OSError):
            continue
        testcases = root.findall(".//testcase") if root.tag != "testcase" else [root]
        shard_name = jf.parent.name
        for tc in testcases:
            classname = tc.get("classname", "")
            raw_name = tc.get("name", "")
            match = re.match(r"^(.*?)\[(.*)\]$", raw_name)
            if match:
                native_id = match.group(1)
                parameter_id = match.group(2)
            else:
                native_id = raw_name
                parameter_id = None
            duration_s = _public_duration(tc.get("time") or 0)
            if tc.find("failure") is not None:
                status = "failed"
            elif tc.find("error") is not None:
                status = "error"
            elif tc.find("skipped") is not None:
                status = "skipped"
            else:
                status = "passed"
            scenarios = (scenario_by_test.get(f"{classname}::{raw_name}") or
                         scenario_by_test.get(raw_name) or
                         scenario_by_test.get(f"{classname}::{native_id}") or
                         scenario_by_test.get(native_id) or set())
            cases.append({
                "runner": "pytest-playwright",
                "suite": "e2e",
                "producer": "e2e",
                "shard": shard_name,
                "native_id": native_id,
                "parameter_id": parameter_id,
                "status": status,
                "duration_s": duration_s,
                "scenario_ids": sorted(scenarios)
            })

    unmapped = [c for c in cases if not c.get("scenario_ids")]
    has_failures = any(c["status"] in ("failed", "error") for c in cases)
    suites = [{
        "suite": "e2e",
        "runner": "pytest-playwright",
        "producer": "e2e",
        "status": "collected-with-failures" if has_failures else "collected",
        "case_count": len(cases),
        "missing_shards": []
    }] if cases else []
    gates = [{
        "gate": "gui-e2e",
        "status": "failed" if has_failures else "passed",
        "duration_s": round(sum(c.get("duration_s") or 0 for c in cases), 1),
        "exit_codes": [1 if has_failures else 0]
    }] if cases else []

    return _public_inventory(suites, gates, cases)


def attach_outline_examples(report: dict, records: list[dict]) -> None:
    records_by_sc: dict[str, list[dict]] = defaultdict(list)
    for r in records:
        if r.get("scenario"):
            records_by_sc[r["scenario"]].append(r)
    for epic in report.get("epics", []):
        for story in epic.get("stories", []):
            for row in story.get("scenarios", []):
                sc_records = records_by_sc.get(row["id"], [])
                if len(sc_records) > 1:
                    examples = []
                    for i, r in enumerate(sc_records):
                        param = f"example-{i+1}"
                        examples.append({
                            "id": param,
                            "parameter_id": param,
                            "status": r.get("status", "PASS"),
                            "duration_s": r.get("duration_s", 0.0)
                        })
                    row["examples"] = examples


def build(shards: Path, out: Path, task: str | None, history: Path,
          evidence_out: Path | None = None, run_id: str | None = None, attempt: str | None = None,
          suite_artifacts: Path | None = None, producer_status: dict[str, str] | None = None,
          commit_override: str | None = None, coverage_base_ref: str | None = None,
          require_diff_cover: bool = False) -> dict:
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
    ignored_page_errors = junit_ignored_page_errors(junit_files)
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
    if ignored_page_errors:
        with (out / "test-report.md").open("a", encoding="utf-8") as handle:
            handle.write(
                f"\n> {ignored_page_errors} test(s) recorded WebKit's empty page errors (#474) "
                "as diagnostics; every named page error still fails.\n")
    with (out / "test-report.md").open("a", encoding="utf-8") as handle:
        handle.write("\n" + (out / "suite-report.md").read_text(encoding="utf-8"))

    run_records = [r for r in records if r.get("run_id") == meta["run_id"]]
    inventory = collect_inventory(shards, run_records, collection)
    rep = ft.build_report(catalogue, records)
    attach_outline_examples(rep, run_records)
    page = ft.render_html(rep,
                          datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
                          f"committed history + CI run {meta['run_id']}",
                          ft.build_runs(records, catalogue),
                          public_safe=True,
                          inventory=inventory)
    (out / "feature-report.html").write_text(page, encoding="utf-8")
    shutil.rmtree(store_dir, ignore_errors=True)

    clean_junit = {k: v for k, v in junit.items() if k != "unparseable"}
    clean_junit["unparseable"] = [Path(p).name for p in junit.get("unparseable", [])]

    coverage = None
    cov_root = suite_artifacts if suite_artifacts and suite_artifacts.is_dir() else None
    has_cov_files = bool(cov_root and any(
        cov_root.rglob(pat) for pat in ("rust-summary.json", "rust.lcov", "flutter.lcov", "lcov.info", "python.json", "python.lcov")
    ))
    if coverage_base_ref or has_cov_files:
        coverage = cov.build_coverage(
            cov_root or shards,
            out,
            base_ref=coverage_base_ref,
            repo_root=Path(__file__).resolve().parents[4],
            require_diff_cover=require_diff_cover,
        )
        with (out / "test-report.md").open("a", encoding="utf-8") as handle:
            handle.write("\n" + (out / "coverage-report.md").read_text(encoding="utf-8"))

    summary = {"run_id": meta["run_id"], "actions_run_id": str(run_id or ""),
               "attempt": str(attempt or ""), "task": meta["task"], "commit": commit_override or meta["commit"],
               "shards": len(execution_files), "executions": count, "junit": clean_junit,
               "ignored_page_errors": ignored_page_errors,
               "ci_suites": {"case_count": collection["case_count"], "unique_case_count": collection["unique_case_count"],
                             "case_totals": collection["case_totals"],
                             "incomplete_suites": incomplete_suite_count(collection["suites"])},
               "status": "INCOMPLETE" if invalid_executions else (run["status"] if run else "NO RESULTS"),
               "scenario_counts": run["counts"] if run else {},
               "scenarios_covered": f"{run['executed']}/{run['automated']}" if run else "0/0",
               "inventory": {"suites": len(inventory.get("suites", [])),
                             "unmapped_cases": len(inventory.get("unmapped_cases", []))}}
    if coverage is not None:
        summary["coverage"] = coverage
    snapshot = ps.build_snapshot(catalogue, run_records, summary, ps.catalogue_history(), inventory=inventory)
    evidence = scenario_evidence.build_evidence(
        snapshot["scenarios"], _evidence_cases(collection.get("cases"), inventory.get("cases", [])),
        scenario_evidence.named_links(catalogue), meta["run_id"], commit_override or meta["commit"])
    feature_page = (out / "feature-report.html").read_text(encoding="utf-8")
    (out / "feature-report.html").write_text(scenario_evidence.add_html_section(feature_page, evidence),
                                             encoding="utf-8")
    (out / "scenario-evidence.json").write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    evidence_markdown = scenario_evidence.render_markdown(evidence)
    (out / "scenario-evidence.md").write_text(evidence_markdown, encoding="utf-8")
    with (out / "test-report.md").open("a", encoding="utf-8") as handle:
        handle.write("\n" + evidence_markdown)
    summary["scenario_evidence"] = evidence["evidence_counts"]
    (out / "summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    (out / "public-report.json").write_text(
        json.dumps(public_report_from_inventory(inventory, coverage=coverage), indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    (out / "product-status.json").write_text(json.dumps(snapshot, indent=1) + "\n", encoding="utf-8")
    (out / "product-status.html").write_text(
        ps.render_html([snapshot], {"detail": "feature-report.html", "history": "feature-report.html"}),
        encoding="utf-8")
    return summary


def step_summary(summary: dict, markdown: str, coverage_md: str = "") -> str:
    j = summary["junit"]
    counts = ", ".join(f"{n} {s}" for s, n in sorted(summary["scenario_counts"].items())) or "none"
    head = ["## E2E test report", "",
            "| Tests | Passed | Failed | Errors | Skipped | Test time | Shards |", "|---|---|---|---|---|---|---|",
            f"| {j['tests']} | {j['passed']} | {j['failures']} | {j['errors']} | {j['skipped']} | "
            f"{j['seconds']:.0f}s | {summary['shards']} |", "",
            f"**Result:** {summary['status']} ({counts}); scenarios covered: {summary['scenarios_covered']}. "
            "Full report and HTML dashboard: artifact `e2e-test-report`.", ""]
    if summary.get("ignored_page_errors"):
        head.extend([f"> WebKit empty page errors recorded as diagnostics: "
                     f"{summary['ignored_page_errors']} test(s) (#474).", ""])
    if coverage_md:
        head.extend([coverage_md.rstrip(), ""])
    head.extend(["<details><summary>Executed tests</summary>", ""])
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
    parser.add_argument("--coverage-base-ref", default=os.environ.get("SITEPULSE_COVERAGE_BASE_REF"),
                        help="base git ref for diff-cover changed-lines coverage")
    parser.add_argument("--require-diff-cover", action="store_true",
                        help="fail if diff-cover is not installed when --coverage-base-ref is set")
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
                    args.suite_artifacts, producer_status, args.commit,
                    args.coverage_base_ref, args.require_diff_cover)
    target = os.environ.get("GITHUB_STEP_SUMMARY")
    if target and not args.no_summary:
        cov_md_path = args.out / "coverage-report.md"
        cov_md = cov_md_path.read_text(encoding="utf-8") if cov_md_path.is_file() else ""
        with open(target, "a", encoding="utf-8") as handle:
            handle.write(step_summary(summary, (args.out / "test-report.md").read_text(encoding="utf-8"), cov_md))
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
