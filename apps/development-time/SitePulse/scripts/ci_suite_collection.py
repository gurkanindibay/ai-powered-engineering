#!/usr/bin/env python3
"""Collect structured SitePulse suite evidence from CI producer artifacts."""
from __future__ import annotations

import json
import math
import re
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

import ci_case_results as adapters


def _read_json(path: Path) -> dict[str, Any] | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def _duration(value: object) -> float:
    try:
        duration = float(value or 0)
    except (TypeError, ValueError, OverflowError):
        return 0.0
    return duration if math.isfinite(duration) else 0.0


def _count(value: object) -> int:
    try:
        return max(0, int(value))
    except (TypeError, ValueError, OverflowError):
        return 0


def _errors(value: object) -> list[str]:
    if isinstance(value, list):
        return [str(item) for item in value]
    return [str(value)] if isinstance(value, str) and value else []


def _metadata_dirs(root: Path, prefix: str, filename: str) -> list[tuple[Path, dict[str, Any]]]:
    found = []
    if not root.is_dir():
        return found
    for folder in root.iterdir():
        if not folder.is_dir() or not folder.name.startswith(prefix):
            continue
        payload = _read_json(folder / filename)
        if payload:
            found.append((folder, payload))
    return found


def _latest_by_attempt(items: list[tuple[Path, dict[str, Any]]], run_id: str, commit: str,
                       key: str) -> dict[str, tuple[Path, dict[str, Any]]]:
    chosen: dict[str, tuple[Path, dict[str, Any]]] = {}
    for folder, metadata in items:
        if str(metadata.get("run_id")) != str(run_id):
            continue
        if commit and metadata.get("commit") and metadata.get("commit") != commit:
            continue
        value = str(metadata.get(key, ""))
        if not value:
            continue
        previous = chosen.get(value)
        try:
            attempt = int(metadata.get("attempt", 0))
            old_attempt = int(previous[1].get("attempt", 0)) if previous else -1
        except (TypeError, ValueError):
            attempt, old_attempt = 0, -1
        if previous is None or attempt > old_attempt:
            chosen[value] = (folder, metadata)
    return chosen


def _case_identity(row: dict[str, Any]) -> tuple[str, str, str, str]:
    native_id = str(row.get("native_id", ""))
    parameter = row.get("parameter_id")
    if parameter is None:
        match = re.match(r"^(.*?)(\[.+\])$", native_id)
        if match:
            native_id, parameter = match.group(1), match.group(2)[1:-1]
    row["native_id"] = native_id
    row["parameter_id"] = parameter
    return (str(row.get("runner", "")), str(row.get("suite", "")), native_id, str(parameter or ""))


def _with_attempts(rows: list[dict[str, Any]], source: str) -> list[dict[str, Any]]:
    counts: Counter[tuple[str, str, str, str]] = Counter()
    for row in rows:
        identity = _case_identity(row)
        counts[identity] += 1
        runner, suite, native_id, parameter = identity
        example = f"[{parameter}]" if parameter else ""
        row["execution_id"] = f"{source}:{runner}:{suite}:{native_id}{example}#try-{counts[identity]}"
        row["case_key"] = "|".join(identity)
        row["attempt_index"] = counts[identity]
        row["source"] = source
    return rows


def _scenario_index(shard_dir: Path) -> dict[str, list[str]]:
    index: dict[str, set[str]] = defaultdict(set)
    for path in shard_dir.rglob("executions.jsonl"):
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeError):
            continue
        for line in lines:
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(record, dict):
                continue
            test, scenario = record.get("test"), record.get("scenario")
            if not test or not isinstance(scenario, str) or not re.fullmatch(r"SC-\d{2}-\d{2}-\d{2}", scenario):
                continue
            test = str(test)
            index[test].add(scenario)
            path, separator, test_name = test.rpartition("::")
            if separator and path.endswith(".py"):
                module = path[:-3].replace("/", ".").replace("\\", ".")
                index[f"{module}::{test_name}"].add(scenario)
    return {key: sorted(values) for key, values in index.items()}


def collect(suite_root: Path, e2e_root: Path, run_id: str, attempt: str, commit: str,
            producer_status: dict[str, str] | None = None) -> dict[str, Any]:
    """Select best available artifacts for this run and expose gaps instead of fabricating results."""
    producer_status = producer_status or {}
    expected = adapters.expected_suites()
    producer_dirs = _metadata_dirs(suite_root, "sitepulse-suite-", "producer.json")
    producers = _latest_by_attempt(producer_dirs, run_id, commit, "job")
    e2e_dirs = _metadata_dirs(e2e_root, "e2e-shard-", "collection.json")
    shards = _latest_by_attempt(e2e_dirs, run_id, commit, "shard")
    saw_attempt_artifacts = bool(e2e_root.is_dir() and any(
        folder.is_dir() and re.search(r"-attempt-\d+$", folder.name)
        for folder in e2e_root.iterdir() if folder.name.startswith("e2e-shard-")))

    gate_rows: dict[str, dict[str, Any]] = {}
    producer_sources: dict[str, dict[str, Any]] = {}
    cases: list[dict[str, Any]] = []
    shard_inputs: dict[str, dict[str, Any]] = {}
    junit_errors: list[str] = []
    for job, (folder, metadata) in producers.items():
        producer_sources[job] = {"artifact": folder.name, "attempt": metadata.get("attempt"),
                                 "job_result": metadata.get("job_result"), "run_id": metadata.get("run_id"),
                                 "commit": metadata.get("commit")}
        for path in sorted((folder / "gates").glob("*.json")):
            payload = _read_json(path)
            if not payload:
                continue
            name = str(payload.get("gate", path.stem))
            gate = gate_rows.setdefault(name, {"gate": name, "producer": job, "status": "passed",
                                               "duration_s": 0.0, "exit_codes": [], "timed_out": False,
                                               "commands": [], "command_count": 0,
                                               "source_attempt": metadata.get("attempt")})
            gate["status"] = "failed" if gate["status"] == "failed" or not payload.get("passed") else "passed"
            gate["duration_s"] = round(_duration(gate["duration_s"]) + _duration(payload.get("duration_s")), 3)
            gate["exit_codes"].append(payload.get("exit_code"))
            gate["timed_out"] = bool(gate["timed_out"] or payload.get("timed_out", False))
            gate["commands"].append(payload.get("argv"))
            gate["command_count"] += 1
            native_totals = payload.get("native_runner_totals")
            if not isinstance(native_totals, dict):
                native_totals = None
            gate.setdefault("native_totals", []).append(native_totals)
            gate.setdefault("native_runners", []).append(payload.get("native_runner"))
            gate.setdefault("adapter_case_counts", []).append(_count(payload.get("native_case_count", payload.get("adapter_case_count", 0))))
            if isinstance(native_totals, dict) and native_totals.get("complete") is False:
                gate["stream_complete"] = False
            gate.setdefault("runner_errors", []).extend(_errors(payload.get("runner_errors", [])))
            rows = payload.get("cases", [])
            if isinstance(rows, list):
                for row in rows:
                    if isinstance(row, dict):
                        cases.append(dict(row, producer=job, source_attempt=metadata.get("attempt")))

    if shards:
        attempts = sorted({str(metadata.get("attempt")) for _, metadata in shards.values()})
        producer_sources["e2e"] = {"artifact": ", ".join(folder.name for folder, _ in shards.values()),
                                    "attempt": attempts[0] if len(attempts) == 1 else ",".join(attempts),
                                    "job_result": producer_status.get("e2e", "unknown"),
                                    "run_id": str(run_id), "commit": commit}
        for shard, (folder, metadata) in shards.items():
            for path in sorted((folder / "gates").glob("*.json")):
                payload = _read_json(path)
                if not payload:
                    continue
                name = str(payload.get("gate", path.stem))
                gate = gate_rows.setdefault(name, {"gate": name, "producer": "e2e", "status": "passed",
                                                   "duration_s": 0.0, "exit_codes": [], "timed_out": False,
                                                   "commands": [], "command_count": 0, "source_attempts": [],
                                                   "native_totals": [], "adapter_case_counts": [],
                                                   "runner_errors": []})
                gate["status"] = "failed" if gate["status"] == "failed" or not payload.get("passed") else "passed"
                gate["duration_s"] = round(_duration(gate["duration_s"]) + _duration(payload.get("duration_s")), 3)
                gate["exit_codes"].append(payload.get("exit_code"))
                gate["timed_out"] = bool(gate["timed_out"] or payload.get("timed_out", False))
                gate["commands"].append(payload.get("argv"))
                gate["command_count"] += 1
                gate["source_attempts"].append({"shard": shard, "attempt": metadata.get("attempt")})

    for producer, names in adapters.expected_gates().items():
        if producer in gate_rows and all(name in gate_rows for name in names):
            continue
        source = producer_sources.get(producer)
        result = producer_status.get(producer, "unknown")
        for name in names:
            if name in gate_rows:
                continue
            status = "cancelled" if result == "cancelled" else "not-run" if result in ("skipped", "failure") else "missing"
            gate_rows[name] = {"gate": name, "producer": producer, "status": status, "duration_s": None,
                               "exit_codes": [], "timed_out": False, "commands": [], "command_count": 0,
                               "native_totals": [], "adapter_case_counts": [], "count_parity": [],
                               "source_attempt": source.get("attempt") if source else None,
                               "producer_result": result}

    for shard, (folder, metadata) in shards.items():
        shard_inputs[shard] = {"artifact": folder.name, "attempt": metadata.get("attempt"),
                               "job_result": metadata.get("job_result")}
        scenario_index = _scenario_index(folder)
        junit_paths = sorted(folder.rglob("junit.xml"))
        if not junit_paths:
            junit_errors.append(f"shard {shard}: missing junit.xml")
        for junit_path in junit_paths:
            try:
                ET.parse(junit_path)
            except (ET.ParseError, OSError):
                junit_errors.append(f"shard {shard}: malformed {junit_path.name}")
            rows = adapters.parse_junit(junit_path)
            if not rows:
                junit_errors.append(f"shard {shard}: JUnit contained no test cases")
            for row in rows:
                row["scenario_ids"] = scenario_index.get(row["native_id"], [])
                row.update({"producer": "e2e", "shard": shard, "source_attempt": metadata.get("attempt")})
            cases.extend(rows)

    cases = _with_attempts(cases, "ci")
    suite_states = []
    for entry in expected:
        producer = str(entry["producer"])
        requested = producer_status.get(producer, "unknown")
        source = producer_sources.get(producer)
        suite_cases = [case for case in cases if case.get("suite") == entry["suite"] and case.get("runner") == entry["runner"]]
        if entry["suite"] == "e2e":
            missing_shards = [shard for shard in entry["shards"] if shard not in shards]
            selected = [str(shards[shard][1].get("attempt")) for shard in entry["shards"] if shard in shards]
            if requested == "cancelled" and not shards:
                state = "cancelled"
            elif requested == "skipped" and not shards:
                state = "not-run"
            elif missing_shards:
                state = "incomplete"
            elif junit_errors:
                state = "incomplete"
            elif selected and all(value != str(attempt) for value in selected):
                state = "reused"
            elif any(value != str(attempt) for value in selected):
                state = "mixed-attempts"
            elif any(shards[shard][1].get("job_result") == "failure" for shard in entry["shards"]):
                state = "collected-with-failures" if any(case.get("status") in ("failed", "error") for case in suite_cases) else "incomplete"
            else:
                state = "collected"
        elif source is None:
            missing_shards = list(entry["shards"])
            state = "cancelled" if requested == "cancelled" else "not-run" if requested == "skipped" else "missing"
        else:
            missing_shards = []
            own_gate = next((gate for gate in gate_rows.values() if gate["gate"] == entry.get("gate")), None)
            if requested == "cancelled":
                state = "incomplete"
            elif own_gate is None:
                state = "missing"
                missing_shards = list(entry["shards"])
            elif own_gate.get("runner_errors"):
                state = "incomplete"
            elif own_gate.get("stream_complete") is False:
                state = "incomplete"
            elif own_gate.get("evidence_complete") is False:
                state = "incomplete"
            elif str(source.get("attempt")) != str(attempt):
                state = "reused"
            elif own_gate.get("status") == "failed":
                state = "collected-with-failures" if suite_cases else "incomplete"
            elif not suite_cases:
                state = "incomplete"
            else:
                state = "collected"
        shard_results = []
        if entry["suite"] == "e2e":
            for shard in entry["shards"]:
                if shard not in shards:
                    shard_results.append({"shard": shard, "status": "missing", "attempt": None,
                                          "junit_files": 0, "case_count": 0})
                    continue
                shard_folder, shard_metadata = shards[shard]
                shard_cases = sum(1 for case in suite_cases if case.get("shard") == shard)
                junit_count = sum(1 for _ in shard_folder.rglob("junit.xml"))
                shard_result = str(shard_metadata.get("job_result", "unknown"))
                if shard_result == "cancelled":
                    shard_state = "cancelled"
                elif str(shard_metadata.get("attempt")) != str(attempt):
                    shard_state = "reused"
                elif shard_result == "failure":
                    shard_state = "failed" if shard_cases else "incomplete"
                elif not junit_count or not shard_cases:
                    shard_state = "incomplete"
                else:
                    shard_state = "passed"
                shard_results.append({"shard": shard, "status": shard_state,
                                      "attempt": shard_metadata.get("attempt"),
                                      "junit_files": junit_count, "case_count": shard_cases})
        suite_states.append({"suite": entry["suite"], "runner": entry["runner"], "producer": producer,
                             "gate": entry.get("gate"),
                             "expected_shards": entry["shards"], "source_attempt": source.get("attempt") if source else None,
                             "source_attempts": selected if entry["suite"] == "e2e" else ([source.get("attempt")] if source else []),
                             "reused_shards": [shard for shard in entry["shards"] if shard in shards and str(shards[shard][1].get("attempt")) != str(attempt)] if entry["suite"] == "e2e" else [],
                             "shard_results": shard_results,
                             "producer_result": requested, "status": state, "missing_shards": missing_shards,
                             "case_count": len(suite_cases)})

    totals = Counter(row["status"] for row in cases)
    for gate in gate_rows.values():
        gate["count_parity"] = [None if not isinstance(native, dict) else
                                _count(native.get("total", _count(native.get("passed")) + _count(native.get("failed")) + _count(native.get("errors")) + _count(native.get("skipped")))) == adapted
                                for native, adapted in zip(gate.get("native_totals", []), gate.get("adapter_case_counts", []))]
        gate["parity_mismatches"] = [index for index, parity in enumerate(gate["count_parity"]) if parity is False]
        gate["evidence_complete"] = not gate["parity_mismatches"] and all(
            native is not None for runner, native in zip(gate.get("native_runners", []), gate.get("native_totals", []))
            if runner in ("cargo", "flutter", "unittest", "sitepulse-check"))
        if not gate["evidence_complete"] and any(gate.get("native_runners", [])):
            gate["status"] = "incomplete"
    for suite in suite_states:
        if suite.get("gate"):
            own_gate = next((gate for gate in gate_rows.values() if gate["gate"] == suite["gate"]), None)
            if own_gate and own_gate.get("evidence_complete") is False:
                suite["status"] = "incomplete"
    collection = {"schema_version": 1, "run_id": str(run_id), "attempt": str(attempt), "commit": commit,
                  "producers": producer_sources, "producer_status": producer_status,
                  "shard_inputs": shard_inputs, "junit_errors": junit_errors,
                  "saw_attempt_artifacts": saw_attempt_artifacts,
                  "_selected_e2e_paths": {shard: str(folder) for shard, (folder, _) in shards.items()},
                  "junit_files": sum(1 for _, (folder, _) in shards.items() for _ in folder.rglob("junit.xml")),
                  "suites": suite_states,
                  "gates": sorted(gate_rows.values(), key=lambda row: row["gate"]),
                  "case_totals": {key: totals.get(key, 0) for key in ("passed", "failed", "skipped", "error")},
                  "case_count": len(cases), "unique_case_count": len({row["case_key"] for row in cases}),
                  "cases": cases}
    return collection


def write_report(collection: dict[str, Any], output: Path) -> None:
    output.mkdir(parents=True, exist_ok=True)
    (output / "suite-collection.json").write_text(json.dumps({k: v for k, v in collection.items()
                                                               if k != "cases" and not k.startswith("_")}, indent=2) + "\n", encoding="utf-8")
    with (output / "case-results.jsonl").open("w", encoding="utf-8") as handle:
        for case in collection["cases"]:
            handle.write(json.dumps(case, ensure_ascii=False, sort_keys=True) + "\n")
    lines = ["## CI suite collection", "", f"Run `{collection['run_id']}` attempt `{collection['attempt']}` at `{collection['commit']}`.", "",
             "| Suite | Runner | Producer | Status | Cases | Missing shards |", "|---|---|---|---:|---:|---|"]
    for suite in collection["suites"]:
        lines.append(f"| {suite['suite']} | {suite['runner']} | {suite['producer']} | {suite['status']} | {suite['case_count']} | {', '.join(suite['missing_shards']) or '—'} |")
        if suite.get("shard_results"):
            lines += ["", f"**{suite['suite']} shard evidence**", "", "| Shard | Status | Attempt | JUnit files | Cases |", "|---|---|---:|---:|---:|"]
            for shard in suite["shard_results"]:
                lines.append(f"| {shard['shard']} | {shard['status']} | {shard['attempt'] or '—'} | {shard['junit_files']} | {shard['case_count']} |")
            lines.append("")
    lines += ["", "### Producer jobs", "", "| Job | Result | Source attempt | Artifact |", "|---|---|---:|---|"]
    for job, status in sorted(collection.get("producer_status", {}).items()):
        source = collection["producers"].get(job, {})
        lines.append(f"| {job} | {status} | {source.get('attempt') or '—'} | {source.get('artifact') or 'missing'} |")
    lines += ["", "### Gates", "", "| Gate | Status | Duration | Exit | Source attempt |", "|---|---|---:|---:|---:|"]
    for gate in collection["gates"]:
        exits = ", ".join("—" if value is None else str(value) for value in gate.get("exit_codes", [])) or "—"
        duration = f"{gate['duration_s']}s" if gate.get("duration_s") is not None else "—"
        source_attempt = gate.get("source_attempt")
        if source_attempt is None and gate.get("source_attempts"):
            source_attempt = ", ".join(f"{item['shard']}={item['attempt']}" for item in gate["source_attempts"])
        label = f"{gate['status']} (reused)" if source_attempt and str(source_attempt) != str(collection["attempt"]) else gate["status"]
        lines.append(f"| {gate['gate']} | {label} | {duration} | {exits} | {source_attempt or '—'} |")
    lines += ["", "### Cases", "", "| Runner | Suite | Native ID | Example | Status | Duration | Source |", "|---|---|---|---|---|---:|---|"]
    for case in collection["cases"]:
        lines.append(f"| {case['runner']} | {case['suite']} | {case['native_id']} | {case.get('parameter_id') or '—'} | {case['status']} | {case.get('duration_s') or '—'} | {case.get('shard', case.get('producer', '—'))} |")
    (output / "suite-report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
