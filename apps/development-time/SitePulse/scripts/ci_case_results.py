#!/usr/bin/env python3
"""Expected SitePulse CI suites and adapters for native test output.

The adapters consume output from the existing runners. They do not select tests or
decide whether a gate passed; the native process exit code remains authoritative.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
from pathlib import Path
from typing import Iterable


def expected_suites() -> list[dict[str, object]]:
    """Describe the suites CI intends to run, including explicit PG selections."""
    return [
        {"suite": "e2e", "runner": "pytest-playwright", "producer": "e2e", "shards": [f"{i}/8" for i in range(1, 9)]},
        {"suite": "rust", "runner": "cargo", "producer": "rust", "gate": "rust-test", "shards": ["rust-test"]},
        {"suite": "rust-db-test", "runner": "cargo", "producer": "rust", "gate": "rust-db-test", "shards": ["rust-db-test"]},
        {"suite": "flutter", "runner": "flutter", "producer": "flutter", "gate": "flutter-test", "shards": ["flutter-test"]},
        {"suite": "money-fixtures", "runner": "cargo", "producer": "flutter", "gate": "money-fixtures", "shards": ["financial_fixtures"]},
        {"suite": "money-fixtures", "runner": "flutter", "producer": "flutter", "gate": "money-fixtures", "shards": ["test/financial_fixture_test.dart"]},
        {"suite": "harness-selftest", "runner": "unittest", "producer": "lint", "gate": "harness-selftest", "shards": ["harness/tests"]},
        {"suite": "api-system", "runner": "sitepulse-check", "producer": "rust", "gate": "api-system", "shards": ["api-system"]},
        {"suite": "schema-integrity", "runner": "sitepulse-check", "producer": "rust", "gate": "schema-integrity", "shards": ["schema-integrity"]},
    ]


def expected_gates() -> dict[str, list[str]]:
    """Mirror CI's group partition so absent gate artifacts are visible in reports."""
    return {
        "lint": ["harness-selftest", "persistence-lint", "rust-standards-lint", "test-quality-lint", "tenant-lint", "lock-lint",
                 "testid-lint", "feature-traceability", "ui-style-lint", "flutter-reuse", "logging-standards-lint", "security-lint"],
        "rust": ["rust-build", "rust-clippy", "rust-test", "schema-integrity", "rust-db-test", "api-system"],
        "flutter": ["money-fixtures", "flutter-analyze", "flutter-test"],
        "e2e": ["gui-e2e"],
        "verify": ["test-run-recorded"],
    }


def _case(runner: str, suite: str, native_id: str, status: str, *, duration_s: float | None = None,
          detail: str | None = None) -> dict[str, object]:
    return {"runner": runner, "suite": suite, "native_id": native_id,
            "parameter_id": None, "status": status,
            "duration_s": duration_s, "detail": detail}


def _number(value: object, divisor: float = 1.0) -> float | None:
    try:
        result = float(value or 0) / divisor
    except (TypeError, ValueError, OverflowError):
        return None
    return result if math.isfinite(result) else None


def parse_cargo(output: str, suite: str) -> list[dict[str, object]]:
    """Parse stable libtest human output, including doctests and ignored tests."""
    cases: list[dict[str, object]] = []
    target = ""
    pattern = re.compile(r"^test (.+?) \.\.\. (ok|FAILED|ignored)(?:,?\s*(.*))?$")
    for line in output.splitlines():
        text = line.strip()
        doctest = re.match(r"^Doc-tests ([A-Za-z0-9_-]+)$", text)
        running = re.match(r"^Running (?:unittests|tests|benches|examples) (.+?) \(target/", text)
        if doctest:
            target = f"doc-{doctest.group(1)}"
            continue
        if running:
            source = running.group(1).replace("\\", "/")
            target = "lib" if source == "src/lib.rs" else Path(source).stem
            continue
        match = pattern.match(text)
        if match:
            status = {"ok": "passed", "FAILED": "failed", "ignored": "skipped"}[match.group(2)]
            native_id = f"{target}::{match.group(1)}" if target else match.group(1)
            cases.append(_case("cargo", suite, native_id, status, detail=match.group(3) or None))
    return cases


def parse_flutter_json(output: str, suite: str) -> list[dict[str, object]]:
    """Parse Flutter test's JSON reporter stream; malformed lines are omitted for gap detection."""
    names: dict[int, str] = {}
    suite_paths: dict[int, str] = {}
    cases: list[dict[str, object]] = []
    for line in output.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(event, dict):
            continue
        kind = event.get("type")
        if kind == "suite":
            suite_info = event.get("suite")
            if isinstance(suite_info, dict) and isinstance(suite_info.get("id"), int):
                path = suite_info.get("path")
                if isinstance(path, str):
                    normalized = path.replace("\\", "/")
                    parts = normalized.split("/")
                    suite_paths[suite_info["id"]] = "/".join(parts[parts.index("flutter"):] if "flutter" in parts else parts)
        elif kind == "testStart":
            test_info = event.get("test") if isinstance(event.get("test"), dict) else {}
            test_id = event.get("testID", test_info.get("id"))
            if isinstance(test_id, int):
                name = str(event.get("name", test_info.get("name", test_id)))
                suite_id = event.get("suiteID", test_info.get("suiteID"))
                path = suite_paths.get(suite_id)
                names[test_id] = f"{path}::{name}" if path else name
        elif kind == "testDone":
            test_id = event.get("testID")
            if not isinstance(test_id, int):
                continue
            if event.get("hidden"):
                continue
            result = str(event.get("result", "error")).lower()
            status = "skipped" if event.get("skipped") else {"success": "passed", "failure": "failed", "skipped": "skipped", "error": "error"}.get(result, "error")
            name = names.get(test_id, str(event.get("name", test_id)))
            cases.append(_case("flutter", suite, name, status,
                               duration_s=_number(event.get("time"), 1000),
                               detail=event.get("message")))
    return cases


def flutter_reporter_errors(output: str) -> list[str]:
    errors = []
    for line in output.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(event, dict):
            continue
        if event.get("type") == "error":
            errors.append(str(event.get("error", event)))
    return errors


def parse_unittest_verbose(output: str, suite: str) -> list[dict[str, object]]:
    """Parse `unittest discover -v` case status lines, retaining skip/failure/error."""
    cases: list[dict[str, object]] = []
    pattern = re.compile(r"^(.*?) \.\.\. (ok|FAIL|ERROR|skipped)(?: \((.*?)\))?$")
    for line in output.splitlines():
        match = pattern.match(line.strip())
        if match:
            status = {"ok": "passed", "FAIL": "failed", "ERROR": "error", "skipped": "skipped"}[match.group(2)]
            cases.append(_case("unittest", suite, match.group(1), status, detail=match.group(3)))
    return cases


def parse_check_json(payload: dict[str, object], runner: str, suite: str) -> list[dict[str, object]]:
    """Convert existing structured API/schema gate check rows into case records."""
    if not isinstance(payload, dict):
        return []
    rows = payload.get("checks", payload.get("findings", []))
    cases = []
    for row in rows if isinstance(rows, list) else []:
        if not isinstance(row, dict):
            continue
        passed = row.get("passed", row.get("ok"))
        status = "passed" if passed is True else "failed" if passed is False else "error"
        cases.append(_case(runner, suite, str(row.get("name", row.get("check", "unnamed"))), status,
                           detail=str(row.get("detail", ""))))
    return cases


def parse_junit(path: Path, runner: str = "pytest-playwright", suite: str = "e2e") -> list[dict[str, object]]:
    """Read JUnit testcase rows without conflating duplicate attempts."""
    import xml.etree.ElementTree as ET
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, OSError):
        return []
    cases = []
    for element in root.iter("testcase"):
        failed = element.find("failure")
        error = element.find("error")
        skipped = element.find("skipped")
        status = "failed" if failed is not None else "error" if error is not None else "skipped" if skipped is not None else "passed"
        native_id = "::".join(filter(None, [element.get("classname"), element.get("name")]))
        outcome = failed if failed is not None else error if error is not None else skipped
        cases.append(_case(runner, suite, native_id, status,
                           duration_s=_number(element.get("time")),
                           detail=outcome.get("message") if outcome is not None else None))
    return cases


def native_totals(output: str, runner: str, payload: dict[str, object] | None = None) -> dict[str, int] | None:
    """Extract runner-reported totals for parity checks; unknown formats stay unknown."""
    if runner == "cargo":
        totals = {"passed": 0, "failed": 0, "skipped": 0}
        found = False
        pattern = re.compile(r"test result: .*? (\d+) passed; (\d+) failed; (\d+) ignored;")
        for match in pattern.finditer(output):
            found = True
            totals["passed"] += int(match.group(1))
            totals["failed"] += int(match.group(2))
            totals["skipped"] += int(match.group(3))
        return totals if found else None
    if runner == "unittest":
        match = re.search(r"^Ran (\d+) tests? in ", output, re.MULTILINE)
        if not match:
            return None
        failed = len(re.findall(r"^FAIL: ", output, re.MULTILINE))
        errors = len(re.findall(r"^ERROR: ", output, re.MULTILINE))
        skipped = len(re.findall(r"^skipped .*? - ", output, re.MULTILINE))
        return {"total": int(match.group(1)), "failed": failed, "errors": errors, "skipped": skipped}
    if runner == "flutter":
        completed = 0
        done = False
        for line in output.splitlines():
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(event, dict):
                continue
            if event.get("type") == "testDone" and not event.get("hidden"):
                completed += 1
            elif event.get("type") == "done":
                done = True
        return {"total": completed, "complete": done}
    if payload is not None:
        if not isinstance(payload, dict):
            return None
        rows = payload.get("checks", payload.get("findings", []))
        if isinstance(rows, list):
            passed = sum(1 for row in rows if isinstance(row, dict) and row.get("passed", row.get("ok")) is True)
            failed = sum(1 for row in rows if isinstance(row, dict) and row.get("passed", row.get("ok")) is False)
            return {"total": len(rows), "passed": passed, "failed": failed}
    return None


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="print expected-suite manifest as JSON")
    parser.add_argument("--metadata-out", type=Path, help="write producer metadata beside collected gate output")
    parser.add_argument("--job", help="producer job name")
    parser.add_argument("--run-id", default="", help="GitHub run ID")
    parser.add_argument("--attempt", default="", help="GitHub run attempt")
    parser.add_argument("--sha", default="", help="commit SHA")
    parser.add_argument("--job-result", default="unknown", help="producer job result")
    parser.add_argument("--shard-id", help="E2E shard identity such as 1/8")
    parser.add_argument("--shard-metadata-out", type=Path, help="write one E2E shard collection metadata file")
    parser.add_argument("--gate-manifest-out", type=Path, help="write expected gates by producer job")
    args = parser.parse_args(argv)
    result = expected_suites()
    if args.metadata_out:
        args.metadata_out.parent.mkdir(parents=True, exist_ok=True)
        args.metadata_out.write_text(json.dumps({"job": args.job, "run_id": args.run_id, "attempt": args.attempt,
                                                 "commit": args.sha, "job_result": args.job_result,
                                                 "expected_suites": result}, indent=2) + "\n", encoding="utf-8")
    if args.shard_metadata_out:
        args.shard_metadata_out.parent.mkdir(parents=True, exist_ok=True)
        args.shard_metadata_out.write_text(json.dumps({"shard": args.shard_id, "run_id": args.run_id,
                                                        "attempt": args.attempt, "commit": args.sha,
                                                        "job_result": args.job_result}, indent=2) + "\n", encoding="utf-8")
    if args.gate_manifest_out:
        args.gate_manifest_out.parent.mkdir(parents=True, exist_ok=True)
        args.gate_manifest_out.write_text(json.dumps(expected_gates(), indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2) if args.json else "\n".join(f"{row['suite']} ({row['runner']}): {', '.join(row['shards'])}" for row in result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
